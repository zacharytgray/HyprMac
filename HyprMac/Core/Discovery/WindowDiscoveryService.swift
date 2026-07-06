// Discovery service: detects window-set changes between polls, mutates the
// window state cache for the lifecycle/classification half, and surfaces a
// `WindowChanges` value so the caller can apply the rest in one explicit
// pass.

import Cocoa

/// Single-cycle discovery delta returned by
/// `WindowDiscoveryService.computeChanges`.
///
/// The service updates its owned cache state — `knownWindowIDs`,
/// `hiddenWindowIDs`, `windowOwners`, `originalFrames`, plus
/// `floatingWindowIDs` for auto-float and `tiledPositions` /
/// `cachedWindows` pruning on the gone path. Everything else surfaces in
/// this struct so the caller can apply the engine, workspace, and focus
/// reactions in one explicit pass.
struct WindowChanges {
    /// Newly discovered windows. Cache state is already updated. The
    /// caller assigns each to a workspace, except for ids in
    /// `newOnDisabledMonitor` (those auto-floated with no slot).
    let newWindows: [HyprWindow]

    /// Subset of `newWindows` that opened on a disabled monitor. The
    /// caller skips workspace assignment for these.
    let newOnDisabledMonitor: Set<CGWindowID>

    /// Windows that came back from hidden state. Cache is already
    /// updated (removed from `hiddenWindowIDs`, re-added to
    /// `knownWindowIDs` and `windowOwners`); the caller's only follow-up
    /// is the retile that `needsRetile` will request.
    let returned: [HyprWindow]

    /// Windows that disappeared. Each id is either in
    /// `fullyForgottenIDs` (pid dead) or moved to `hiddenWindowIDs` (pid
    /// alive, app minimized or window closed but app still running).
    let goneIDs: Set<CGWindowID>

    /// Every id the service called `stateCache.forget(_:)` on this
    /// cycle. Includes pid-dead windows from the gone path plus ids
    /// swept during stale-state reconciliation. The caller runs external
    /// cleanup for each: engine min-size memory, workspace assignment,
    /// focus + border + dim state.
    let fullyForgottenIDs: Set<CGWindowID>

    /// Windows whose physical screen no longer matches their recorded
    /// workspace's screen — typically a manual cross-monitor drag or a
    /// dock-click that raised the window on the wrong screen. The
    /// caller calls `workspaceManager.moveWindow` for each.
    let screenDrift: [(windowID: CGWindowID, fromWorkspace: Int, toWorkspace: Int)]

    /// `true` when the previously-focused window id is in `goneIDs`
    /// (whether moved to hidden or fully forgotten). The caller should
    /// re-focus a window under the cursor.
    let focusedWindowGone: Bool

    /// `true` when at least one observed change warrants a retile.
    /// Stale-state sweeps do not bump this — they are silent state
    /// hygiene with no visual consequence.
    var needsRetile: Bool {
        !newWindows.isEmpty || !goneIDs.isEmpty || !returned.isEmpty || !screenDrift.isEmpty
    }
}

/// Detects window-set changes between poll cycles.
///
/// Owns the lifecycle and classification half of `WindowStateCache`
/// mutation on the discovery path: new, returned, gone, hidden, fully
/// forgotten, plus auto-float of excluded apps and disabled-monitor
/// windows. Everything else — workspace assignment, tree mutation,
/// retile, focus reactions — is surfaced in `WindowChanges` and applied
/// by the caller.
///
/// The `@objc` notification handlers (app launch/terminate, app
/// hide/unhide) stay on `WindowManager` because they compose cache
/// updates with scheduling and per-app cleanup that does not belong on
/// this service.
///
/// Threading: main-thread only.
final class WindowDiscoveryService {

    private let stateCache: WindowStateCache
    private let accessibility: AccessibilityManager
    private let displayManager: DisplayManager
    private let workspaceManager: WorkspaceManager

    /// Resolves a process id to its bundle identifier. Injected so tests
    /// can swap a deterministic lookup; production uses
    /// `NSRunningApplication`.
    private let bundleIDForPID: (pid_t) -> String?

    /// Consecutive cycles skipped by the mass-gone guard. Bounded so a
    /// genuine mass close is delayed, not deadlocked.
    private var massGoneSkips = 0

    /// Hidden ids that went gone via minimize / Cmd-H (or where AX
    /// couldn't tell). These keep their workspace on return — only ids
    /// that were verifiably CLOSED qualify for the recycled-id reopen
    /// reassignment, otherwise un-minimizing a hidden-ws window would
    /// teleport it to the foreground workspace.
    private var userHiddenIDs: Set<CGWindowID> = []

    init(stateCache: WindowStateCache,
         accessibility: AccessibilityManager,
         displayManager: DisplayManager,
         workspaceManager: WorkspaceManager,
         bundleIDForPID: @escaping (pid_t) -> String? = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }) {
        self.stateCache = stateCache
        self.accessibility = accessibility
        self.displayManager = displayManager
        self.workspaceManager = workspaceManager
        self.bundleIDForPID = bundleIDForPID
    }

    /// Production entry point: snapshot AX, capture running pids, and
    /// run the diff.
    ///
    /// - Parameter excludedBundleIDs: Apps that should auto-float on
    ///   discovery (never enter tiling).
    /// - Parameter focusedWindowID: Window currently believed to have
    ///   focus; used to populate `focusedWindowGone`.
    func detectChanges(excludedBundleIDs: Set<String>, focusedWindowID: CGWindowID) -> WindowChanges {
        let snapshot = accessibility.getAllWindows()
        let runningPIDs = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
        return computeChanges(
            snapshot: snapshot,
            runningPIDs: runningPIDs,
            excludedBundleIDs: excludedBundleIDs,
            focusedWindowID: focusedWindowID
        )
    }

    /// Testable entry point. Pure with respect to AX and `NSWorkspace`:
    /// the caller supplies the snapshot and running-pid set, and this
    /// method does the diff and mutates the cache.
    ///
    /// - Returns: a `WindowChanges` value describing what changed and
    ///   what the caller still needs to apply (workspace assignment,
    ///   external cleanup, retile, refocus).
    func computeChanges(snapshot: [HyprWindow],
                        runningPIDs: Set<pid_t>,
                        excludedBundleIDs: Set<String>,
                        focusedWindowID: CGWindowID) -> WindowChanges {
        let currentIDs = Set(snapshot.map { $0.windowID })

        // partial AX snapshots (post-wake, unresponsive apps) can report half
        // the desktop gone in one cycle; real user actions never do. skip the
        // whole cycle before mutating any cache state — but only a bounded
        // number of times, so a genuine mass close still processes.
        let apparentlyGone = stateCache.knownWindowIDs.subtracting(currentIDs)
        if apparentlyGone.count >= 3, apparentlyGone.count * 2 > stateCache.knownWindowIDs.count,
           massGoneSkips < 3 {
            massGoneSkips += 1
            hyprLog(.notice, .discovery, "mass-gone guard: \(apparentlyGone.count)/\(stateCache.knownWindowIDs.count) known windows missing from one snapshot — skipping cycle (\(massGoneSkips)/3)")
            return WindowChanges(newWindows: [], newOnDisabledMonitor: [], returned: [],
                                 goneIDs: [], fullyForgottenIDs: [], screenDrift: [],
                                 focusedWindowGone: false)
        }
        massGoneSkips = 0

        var newWindows: [HyprWindow] = []
        var newOnDisabled: Set<CGWindowID> = []
        var returned: [HyprWindow] = []
        var goneIDs: Set<CGWindowID> = []
        var fullyForgotten: Set<CGWindowID> = []

        // returned (hidden → present)
        for w in snapshot where stateCache.hiddenWindowIDs.contains(w.windowID) {
            stateCache.hiddenWindowIDs.remove(w.windowID)
            stateCache.knownWindowIDs.insert(w.windowID)
            stateCache.windowOwners[w.windowID] = w.ownerPID
            returned.append(w)
            hyprLog(.debug, .discovery, "window returned: '\(w.title ?? "?")' (\(w.windowID))")
        }

        // new
        for w in snapshot where !stateCache.knownWindowIDs.contains(w.windowID) {
            if let frame = w.frame {
                let onScreen = displayManager.screens.contains { screen in
                    frame.isSubstantiallyVisible(on: displayManager.cgRect(for: screen))
                }
                if onScreen {
                    stateCache.originalFrames[w.windowID] = frame
                }
            }
            stateCache.knownWindowIDs.insert(w.windowID)
            stateCache.windowOwners[w.windowID] = w.ownerPID

            // auto-float excluded apps
            if let bundleID = bundleIDForPID(w.ownerPID), excludedBundleIDs.contains(bundleID) {
                stateCache.floatingWindowIDs.insert(w.windowID)
                w.isFloating = true
                hyprLog(.debug, .discovery, "auto-float excluded app: '\(w.title ?? "?")'")
            }

            // auto-float on disabled monitors — surface so caller skips workspace assignment
            if let screen = displayManager.screen(for: w), workspaceManager.isMonitorDisabled(screen) {
                if !stateCache.floatingWindowIDs.contains(w.windowID) {
                    stateCache.floatingWindowIDs.insert(w.windowID)
                    w.isFloating = true
                    hyprLog(.debug, .discovery, "auto-float on disabled monitor: '\(w.title ?? "?")'")
                }
                newOnDisabled.insert(w.windowID)
                hyprLog(.debug, .discovery, "new window (disabled monitor): '\(w.title ?? "?")' (\(w.windowID))")
            } else {
                hyprLog(.debug, .discovery, "new window: '\(w.title ?? "?")' (\(w.windowID))")
            }

            newWindows.append(w)
        }

        // gone
        let gone = stateCache.knownWindowIDs.subtracting(currentIDs)
        for id in gone {
            goneIDs.insert(id)
            stateCache.tiledPositions.removeValue(forKey: id)
            stateCache.cachedWindows.removeValue(forKey: id)

            if let pid = stateCache.windowOwners[id], runningPIDs.contains(pid) {
                // app still running — window minimized/hidden/closed-but-app-alive.
                // keep cache state intact apart from moving to hidden, so an
                // un-minimize comes back as "returned" not "new".
                stateCache.knownWindowIDs.remove(id)
                stateCache.hiddenWindowIDs.insert(id)
                // nil (AX unreadable) counts as user-hidden — the safe side
                if accessibility.isWindowMinimizedOrAppHidden(windowID: id, pid: pid) != false {
                    userHiddenIDs.insert(id)
                }
                if workspaceManager.isWindowVisible(id) {
                    hyprLog(.debug, .discovery, "window hidden: \(id)")
                } else {
                    hyprLog(.debug, .discovery, "window hidden (inactive ws): \(id)")
                }
            } else {
                stateCache.forget(id)
                fullyForgotten.insert(id)
                hyprLog(.debug, .discovery, "window gone: \(id)")
            }
        }

        // sweep stale entries — terminated apps whose hidden windows didn't
        // show up in the gone set, or generic drift across cache fields.
        let swept = sweepStaleState(runningPIDs: runningPIDs)
        fullyForgotten.formUnion(swept)

        // drift detection. just-returned windows that were verifiably CLOSED
        // (not minimized/Cmd-H'd) get special handling: a recycled-CGWindowID
        // reopen (Teams, Mail) comes back "returned" with a stale assignment
        // to a hidden workspace. user-hidden returns keep their workspace.
        let reopened = Set(returned.map { $0.windowID }).subtracting(userHiddenIDs)
        userHiddenIDs.subtract(returned.map { $0.windowID })
        userHiddenIDs.formIntersection(stateCache.hiddenWindowIDs)
        let drift = detectScreenDrift(snapshot, justReturned: reopened)

        let focusedGone = goneIDs.contains(focusedWindowID)

        return WindowChanges(
            newWindows: newWindows,
            newOnDisabledMonitor: newOnDisabled,
            returned: returned,
            goneIDs: goneIDs,
            fullyForgottenIDs: fullyForgotten,
            screenDrift: drift,
            focusedWindowGone: focusedGone
        )
    }

    /// Fully forget every window owned by `pid`.
    ///
    /// Called from the `appDidTerminate` path before scheduling a poll,
    /// so hidden or minimized windows owned by the dead app do not leak
    /// in the cache — those ids never appear in the gone-detect set
    /// because the gone path only sees windows still in
    /// `knownWindowIDs`.
    ///
    /// - Returns: the set of ids forgotten, so the caller can run
    ///   external cleanup for each.
    @discardableResult
    func forgetApp(_ pid: pid_t) -> Set<CGWindowID> {
        let ids = Set(stateCache.windowOwners.compactMap { $0.value == pid ? $0.key : nil })
        for id in ids { stateCache.forget(id) }
        return ids
    }

    // MARK: - private helpers

    /// Sweep cache state for ids that are no longer alive anywhere.
    ///
    /// Catches drift from edge cases the gone-detect pass misses: race
    /// conditions during a poll, terminated apps whose windows
    /// disappeared via a different path, hidden windows whose owners
    /// died. Returns the ids forgotten so the caller can run external
    /// cleanup.
    private func sweepStaleState(runningPIDs: Set<pid_t>) -> Set<CGWindowID> {
        var forgotten: Set<CGWindowID> = []

        // hidden windows whose owner pid died — fully forget
        for id in stateCache.hiddenWindowIDs {
            if let pid = stateCache.windowOwners[id], !runningPIDs.contains(pid) {
                stateCache.forget(id)
                forgotten.insert(id)
            }
        }
        // workspace assignments for ids we no longer track at all
        let live = stateCache.knownWindowIDs.union(stateCache.hiddenWindowIDs)
        for (id, _) in workspaceManager.allWindowWorkspaces() where !live.contains(id) {
            stateCache.forget(id)
            forgotten.insert(id)
        }
        // floating set / originalFrames / windowOwners shouldn't outlive known+hidden either
        for id in stateCache.floatingWindowIDs where !live.contains(id) {
            stateCache.forget(id); forgotten.insert(id)
        }
        for (id, _) in stateCache.originalFrames where !live.contains(id) {
            stateCache.forget(id); forgotten.insert(id)
        }
        for (id, _) in stateCache.windowOwners where !live.contains(id) {
            stateCache.forget(id); forgotten.insert(id)
        }

        return forgotten
    }

    /// Detect tiled windows whose physical screen no longer matches the
    /// screen of their recorded workspace.
    ///
    /// Sources include manual cross-monitor drag, dock-click activations
    /// that raise an app's window on the wrong screen, and close-then-
    /// reopen of an app that recycles its CGWindowID (Teams, Mail, etc.)
    /// — those come back via the `returned` path with a stale workspace
    /// assignment pointing at a now-hidden workspace.
    ///
    /// Floating windows are skipped (they can be anywhere by design).
    /// Windows without a substantially visible frame are skipped — that
    /// covers hide-corner park slivers and stale/transient AX reads, so
    /// drift only ever acts on a window the user can actually see.
    private func detectScreenDrift(_ allWindows: [HyprWindow],
                                   justReturned: Set<CGWindowID> = []) -> [(windowID: CGWindowID, fromWorkspace: Int, toWorkspace: Int)] {
        let visibleWorkspaces = Set(workspaceManager.monitorWorkspace.values)
        var drifts: [(CGWindowID, Int, Int)] = []
        for w in allWindows {
            guard let recordedWs = workspaceManager.workspaceFor(w.windowID) else { continue }
            // scratchpad members (ws 0) never drift — a tiled member is
            // non-floating and passes the floater skip below, so it needs an
            // explicit bail. (it's currently safe only by accident: ws 0 is
            // never in monitorWorkspace.values.)
            guard recordedWs != ScratchpadController.workspace else { continue }
            // floating windows can be anywhere by design — skip
            guard !stateCache.floatingWindowIDs.contains(w.windowID) else { continue }
            // majority frame overlap, not center-point: a min-size-crammed
            // window inflated across a monitor edge keeps a majority on its
            // own screen, and park slivers / stale off-screen frames fail
            // the substantial check entirely (the guard the doc above
            // promises — previously dead code).
            guard hasSubstantialOnScreenFrame(w),
                  let physicalScreen = majorityOverlapScreen(w) else { continue }
            // skip if the window sits on a disabled monitor — handled elsewhere
            guard !workspaceManager.isMonitorDisabled(physicalScreen) else { continue }
            let physicalWs = workspaceManager.workspaceForScreen(physicalScreen)
            guard physicalWs != recordedWs else { continue }
            // a window that just returned from hidden while its recorded ws
            // is hidden is a recycled-id reopen — without reassignment it
            // ghosts untiled over the current workspace (invisible to FFM
            // and tiling) and teleports cross-monitor when clicked. bypass
            // the placement guards so it lands where it visibly opened.
            let reopenedOntoHiddenWs = justReturned.contains(w.windowID)
                && !visibleWorkspaces.contains(recordedWs)
            if !reopenedOntoHiddenWs {
                // with static workspace anchoring, a window whose recorded
                // workspace's home matches its physical screen is correctly
                // placed — even if some other workspace happens to be visible
                // on that screen right now.
                if let homeScreen = workspaceManager.homeScreenForWorkspace(recordedWs),
                   homeScreen == physicalScreen { continue }
                // recorded ws hidden: never drift. on Tahoe, AX can return
                // the old pre-hide frame for >1 sec after the position write,
                // so a stale read would falsely conclude the window drifted
                // (logs 2026-05-04 09:53:01.998). when the recorded ws is
                // shown again, the tile pass places the window correctly.
                if !visibleWorkspaces.contains(recordedWs) { continue }
            }
            drifts.append((w.windowID, recordedWs, physicalWs))
            hyprLog(.notice, .discovery, "drift: '\(w.title ?? "?")' (\(w.windowID)) ws\(recordedWs) → ws\(physicalWs) (now on \(physicalScreen.localizedName))\(reopenedOntoHiddenWs ? " [reopened onto hidden ws]" : "")")
        }
        return drifts
    }

    /// Screen with the largest overlap area with `w`'s frame, or nil when
    /// the frame overlaps no screen. Center-point resolution misjudges
    /// windows protruding across a monitor edge.
    private func majorityOverlapScreen(_ w: HyprWindow) -> NSScreen? {
        guard let frame = w.frame else { return nil }
        var best: (screen: NSScreen, area: CGFloat)?
        for screen in displayManager.screens {
            let overlap = frame.intersection(displayManager.cgRect(for: screen))
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (screen, area) }
        }
        return best?.screen
    }

    /// `true` when more than half of `w`'s frame is visible on any
    /// enabled screen. Hide-corner-parked windows have a single-pixel
    /// sliver on screen so they fail this check; a genuinely returned
    /// window with a real on-screen frame passes.
    ///
    /// Conservative on missing data: a nil or zero-area frame returns
    /// `false` so we do not drift a window we cannot inspect.
    private func hasSubstantialOnScreenFrame(_ w: HyprWindow) -> Bool {
        guard let frame = w.frame else { return false }
        let frameArea = frame.width * frame.height
        guard frameArea > 0 else { return false }
        var visibleArea: CGFloat = 0
        for screen in displayManager.screens {
            let overlap = frame.intersection(displayManager.cgRect(for: screen))
            if !overlap.isNull { visibleArea += overlap.width * overlap.height }
        }
        return visibleArea / frameArea > 0.5
    }

}
