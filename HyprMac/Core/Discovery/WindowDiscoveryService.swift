import Cocoa

// describes a single poll-cycle delta produced by WindowDiscoveryService.detectChanges.
//
// the service updates its owned cache state (knownWindowIDs, hiddenWindowIDs,
// windowOwners, originalFrames, floatingWindowIDs for auto-float, plus
// tiledPositions/cachedWindows pruning on gone). everything else surfaces here
// so the caller can apply external side effects in one explicit pass.
//
// per plan §3.2, the long-term shape is detect → ActionDispatcher.applyChanges.
// in Phase 3 the caller is WindowManager; Phase 4 lifts that loop into the
// dispatcher with no shape change here.
struct WindowChanges {
    // newly discovered windows (wid not in knownWindowIDs at call time).
    // cache state already updated for these. caller should:
    //   - call workspaceManager.assignWindow(wid, toWorkspace:) for each EXCEPT
    //     those whose wid is in newOnDisabledMonitor (auto-floated, no slot).
    let newWindows: [HyprWindow]
    let newOnDisabledMonitor: Set<CGWindowID>

    // windows that returned from hidden state. cache updated (removed from
    // hiddenWindowIDs, re-inserted into knownWindowIDs/owners). no other
    // action required from the caller beyond the resulting retile.
    let returned: [HyprWindow]

    // windows that disappeared. cache updated:
    //   - if owner pid still alive → moved to hiddenWindowIDs (kept in cache).
    //   - if owner pid dead → fullyForgottenIDs.contains(id), full forget done.
    let goneIDs: Set<CGWindowID>

    // every wid the service called stateCache.forget(_:) on this cycle.
    // includes pid-dead windows from the gone path AND ids swept during
    // reconcileWindowState. caller must run external cleanup per id:
    //   - tilingEngine.forgetMinimumSize(windowID:)
    //   - workspaceManager.removeWindow(_:)
    //   - focusController + focusBorder + dimmingOverlay cleanup if matches
    let fullyForgottenIDs: Set<CGWindowID>

    // (windowID, fromWorkspace, toWorkspace) for windows whose physical screen
    // no longer matches their recorded workspace's screen. caller should call
    // workspaceManager.moveWindow(wid, toWorkspace: toWorkspace) for each.
    let screenDrift: [(windowID: CGWindowID, fromWorkspace: Int, toWorkspace: Int)]

    // true if the previously focused wid disappeared in goneIDs (whether to
    // hidden or to forgotten). caller should refocusUnderCursor.
    let focusedWindowGone: Bool

    // true if anything happened that warrants a retile. sweep-only forgets
    // do not bump this — they're silent state hygiene.
    var needsRetile: Bool {
        !newWindows.isEmpty || !goneIDs.isEmpty || !returned.isEmpty || !screenDrift.isEmpty
    }
}

// detects window-set changes since the last call. owns the lifecycle/classification
// cache mutations (per §3.3, WindowStateCache is the cache; this service is the
// only thing that mutates it on the discovery path).
//
// what does NOT live here:
//   - workspace assignment (surfaced in WindowChanges, applied by caller).
//   - tree mutation / retile (surfaced via needsRetile, applied by caller).
//   - focus reactions (surfaced via focusedWindowGone, applied by caller).
//   - the @objc notification handlers (stay on WindowManager — they also do
//     forgetApp + scheduling, which compose cache + lifecycle responsibilities).
//
// main-thread is a precondition. no synchronization beyond that.
final class WindowDiscoveryService {

    private let stateCache: WindowStateCache
    private let accessibility: AccessibilityManager
    private let displayManager: DisplayManager
    private let workspaceManager: WorkspaceManager

    // injected so tests don't depend on NSRunningApplication. production uses
    // the default; tests provide a deterministic lookup.
    private let bundleIDForPID: (pid_t) -> String?

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

    // production entry: snapshot AX + running pids, run the diff.
    func detectChanges(excludedBundleIDs: Set<String>, focusedWindowID: CGWindowID, animationInProgress: Bool) -> WindowChanges {
        let snapshot = accessibility.getAllWindows()
        let runningPIDs = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
        return computeChanges(
            snapshot: snapshot,
            runningPIDs: runningPIDs,
            excludedBundleIDs: excludedBundleIDs,
            focusedWindowID: focusedWindowID,
            animationInProgress: animationInProgress
        )
    }

    // testable entry: pure with respect to AX + NSWorkspace. caller supplies
    // a window snapshot and the running-pid set; this method does the diff
    // and mutates the cache.
    func computeChanges(snapshot: [HyprWindow],
                        runningPIDs: Set<pid_t>,
                        excludedBundleIDs: Set<String>,
                        focusedWindowID: CGWindowID,
                        animationInProgress: Bool) -> WindowChanges {
        let currentIDs = Set(snapshot.map { $0.windowID })

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
                    isFrameVisible(frame, on: displayManager.cgRect(for: screen))
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

        // drift detection
        let drift: [(windowID: CGWindowID, fromWorkspace: Int, toWorkspace: Int)]
        if animationInProgress {
            drift = []
        } else {
            drift = detectScreenDrift(snapshot)
        }

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

    // fully forget every window owned by `pid`. used by the appDidTerminate path
    // before scheduling a poll, so hidden/minimized windows owned by the dead app
    // don't leak in the cache (they wouldn't appear in the gone-detect set).
    // returns the set of forgotten ids so the caller can run external cleanup.
    @discardableResult
    func forgetApp(_ pid: pid_t) -> Set<CGWindowID> {
        let ids = Set(stateCache.windowOwners.compactMap { $0.value == pid ? $0.key : nil })
        for id in ids { stateCache.forget(id) }
        return ids
    }

    // MARK: - private helpers

    // sweep state for ids that are no longer alive anywhere. catches drift from
    // edge cases (race conditions, terminated apps whose windows weren't seen
    // disappearing first, hidden windows whose owners died). returns the set of
    // ids that were forgotten so the caller can run external cleanup for each.
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

    // detect tiled windows that physically drifted to a different screen than
    // their recorded workspace lives on (e.g. user dragged across monitors,
    // macOS dock-clicked an app and raised a window on the wrong screen).
    // surfaces (id, fromWorkspace, toWorkspace) tuples; the caller applies
    // workspaceManager.moveWindow for each.
    private func detectScreenDrift(_ allWindows: [HyprWindow]) -> [(windowID: CGWindowID, fromWorkspace: Int, toWorkspace: Int)] {
        let visibleWorkspaces = Set(workspaceManager.monitorWorkspace.values)
        var drifts: [(CGWindowID, Int, Int)] = []
        for w in allWindows {
            guard let recordedWs = workspaceManager.workspaceFor(w.windowID) else { continue }
            // only check windows whose recorded workspace is currently on screen
            guard visibleWorkspaces.contains(recordedWs) else { continue }
            // floating windows can be anywhere by design — skip
            guard !stateCache.floatingWindowIDs.contains(w.windowID) else { continue }
            guard let physicalScreen = displayManager.screen(for: w) else { continue }
            // skip if the window sits on a disabled monitor — handled elsewhere
            guard !workspaceManager.isMonitorDisabled(physicalScreen) else { continue }
            let physicalWs = workspaceManager.workspaceForScreen(physicalScreen)
            guard physicalWs != recordedWs else { continue }
            // ignore windows whose recorded screen and physical screen are the
            // same — guards against transient frame reads during retile
            if let recordedScreen = workspaceManager.screenForWorkspace(recordedWs),
               recordedScreen == physicalScreen { continue }
            drifts.append((w.windowID, recordedWs, physicalWs))
            hyprLog(.debug, .discovery, "drift: '\(w.title ?? "?")' ws\(recordedWs) → ws\(physicalWs) (now on \(physicalScreen.localizedName))")
        }
        return drifts
    }

    // check if at least 25% of the frame is visible on the given screen rect
    private func isFrameVisible(_ frame: CGRect, on screenRect: CGRect) -> Bool {
        let overlap = frame.intersection(screenRect)
        guard !overlap.isNull else { return false }
        let overlapArea = overlap.width * overlap.height
        let frameArea = frame.width * frame.height
        guard frameArea > 0 else { return false }
        return overlapArea / frameArea > 0.25
    }
}
