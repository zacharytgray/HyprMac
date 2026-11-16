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
    /// `fullyForgottenIDs` (pid dead, or a Quick Look panel) or moved to
    /// `hiddenWindowIDs` (pid alive, app minimized or window closed but
    /// app still running).
    let goneIDs: Set<CGWindowID>

    /// Every id the service called `stateCache.forget(_:)` on this
    /// cycle. Includes pid-dead windows and Quick Look panels from the
    /// gone path, plus ids swept during stale-state reconciliation. The
    /// caller runs external cleanup for each: engine min-size memory,
    /// workspace assignment, focus + border + dim state.
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
    /// `true` when a guarded partial snapshot should be checked again soon
    /// instead of waiting for the slow reconcile timer.
    let requestsRecheck: Bool
    /// `true` when the cycle was skipped because the session is locked or
    /// the displays are asleep. The snapshot is not the desktop, so the
    /// caller does nothing else with it either.
    var heldForInterruption = false
    /// Subset of `returned` that AX confirmed as minimized or Cmd-H'd
    /// while hidden. Not an unreadable hide, and not a verified close.
    var returnedFromUserHide: Set<CGWindowID> = []
    /// Subset of `screenDrift`: a verified close whose app reused the id
    /// (Mail, Teams), back on screen while its recorded workspace is hidden.
    /// A pinned app's one goes to its pin instead of drifting.
    var reopenedOntoHiddenWorkspace: Set<CGWindowID> = []
    /// Windows auto-floated as not resizable that a re-check found
    /// resizable. The service cleared their floating flag; the retile
    /// tiles them like any other member of their workspace.
    var unfloated: Set<CGWindowID> = []
    /// Subset of `returned` that came back after a verified close: hidden
    /// as absent from its app's list, so never reserved (Teams keeps the id
    /// across a close and reopen). The caller places it like a new window.
    var reopenedAfterClose: Set<CGWindowID> = []

    /// `true` when at least one observed change warrants a retile.
    /// Stale-state sweeps do not bump this — they are silent state
    /// hygiene with no visual consequence.
    var needsRetile: Bool {
        !newWindows.isEmpty || !goneIDs.isEmpty || !returned.isEmpty || !screenDrift.isEmpty
            || !unfloated.isEmpty
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
    private let isWindowSizeSettable: (HyprWindow) -> Bool?

    /// Consecutive cycles skipped by the mass-gone guard. Bounded so a
    /// genuine mass close is delayed, not deadlocked.
    private var massGoneSkips = 0

    /// Hidden ids that went gone via minimize / Cmd-H (or where AX
    /// couldn't tell). These keep their workspace on return — only ids
    /// that were verifiably CLOSED qualify for the recycled-id reopen
    /// reassignment, otherwise un-minimizing a hidden-ws window would
    /// teleport it to the foreground workspace.
    private var userHiddenIDs: Set<CGWindowID> = []

    /// Hidden ids AX confirmed as minimized or Cmd-H'd, without the
    /// unreadable guesses `userHiddenIDs` takes. Only these mark a return
    /// as the user's: a slow app's window that drops out of one walk must
    /// not pull the user to its workspace.
    private var minimizedOrAppHiddenIDs: Set<CGWindowID> = []

    /// Reserved hidden ids where AX could not answer when they vanished,
    /// so the reservation is a guess, with the cycles spent asking. Re-checked
    /// until AX gives a real answer or the budget runs out (then it stays
    /// reserved — the safe side).
    private var unverifiedReservedIDs: [CGWindowID: Int] = [:]
    private static let maxReverifyAttempts = 5

    /// When each id went gone-but-pid-alive. A return within seconds is a
    /// flap — a stale/partial AX snapshot, not a real minimize — and each
    /// flap cycle drives two retiles (sibling expands full-screen, then
    /// shrinks back). See "Retile churn" in docs/debugging.md.
    private var hiddenAt: [CGWindowID: Date] = [:]
    /// windows sent to the cursor's monitor, by deadline. drift leaves each
    /// alone until it stands mostly on its workspace's screen or the
    /// deadline passes, so it is not sent back while on its way
    private var driftExemptions: [CGWindowID: Date] = [:]
    static let driftExemptionSpan: TimeInterval = 2

    /// Keep drift off `windowID` while it moves to the cursor's monitor.
    func exemptFromDrift(_ windowID: CGWindowID) {
        driftExemptions[windowID] = now().addingTimeInterval(Self.driftExemptionSpan)
    }

    func endDriftExemption(_ windowID: CGWindowID) {
        driftExemptions.removeValue(forKey: windowID)
    }

    var driftExemptWindowIDs: Set<CGWindowID> { Set(driftExemptions.keys) }
    private static let flapWindowSec: TimeInterval = 5.0

    /// A locked session, sleeping displays or a switched-out user session
    /// empty the on-screen window list, so a missing window says nothing
    /// then. Without this a lock outlasted the 4 s wake suppression and the
    /// three mass-gone skips, every window was marked hidden and pulled out
    /// of its tree, and the unlock rebuilt each tree in reading order with
    /// default ratios. Each reason keeps the time it began.
    private var interruptions: [String: Date] = [:]
    private var interruptionHoldLogged = false
    /// how long a span may last if its end notification never comes. long
    /// enough for a night. a hotkey press, a menu action or a stop also
    /// ends it: the lock screen keeps all of those from happening.
    static let interruptionCap: TimeInterval = 12 * 60 * 60
    /// injected so tests can move past the cap
    var now: () -> Date = { Date() }

    private static let interruptionSpans: [String: (reason: String, begins: Bool)] = [
        "com.apple.screenIsLocked": ("locked", true),
        "com.apple.screenIsUnlocked": ("locked", false),
        NSWorkspace.screensDidSleepNotification.rawValue: ("screens asleep", true),
        NSWorkspace.screensDidWakeNotification.rawValue: ("screens asleep", false),
        NSWorkspace.sessionDidResignActiveNotification.rawValue: ("session inactive", true),
        NSWorkspace.sessionDidBecomeActiveNotification.rawValue: ("session inactive", false),
    ]

    /// Quick Look panels in the last snapshot. The panel is one long-lived
    /// window per app: closing it orders it out, the app stops listing it,
    /// and the next preview brings back the same id. Left to the ordinary
    /// gone path it would become a ghost that keeps its workspace and its
    /// floating flag, and the next preview would come back "returned" to
    /// wherever the last one was. So a panel that leaves the snapshot is
    /// forgotten outright, for any reason — closed, its app hidden or
    /// deactivated, Quick Look's full-screen view — and each opening is a
    /// new floating window.
    private var quickLookPanelIDs: Set<CGWindowID> = []

    init(stateCache: WindowStateCache,
         accessibility: AccessibilityManager,
         displayManager: DisplayManager,
         workspaceManager: WorkspaceManager,
         bundleIDForPID: @escaping (pid_t) -> String? = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier },
         isWindowSizeSettable: @escaping (HyprWindow) -> Bool? = { $0.isSizeSettable }) {
        self.stateCache = stateCache
        self.accessibility = accessibility
        self.displayManager = displayManager
        self.workspaceManager = workspaceManager
        self.bundleIDForPID = bundleIDForPID
        self.isWindowSizeSettable = isWindowSizeSettable
    }

    /// Known windows the last cycle held because AX could not read them.
    /// Kept so the outage is logged at its edges rather than every cycle.
    private var heldUnreadableIDs: Set<CGWindowID> = []
    /// Known windows the last cycle held because their app still lists
    /// them while the window server no longer shows them on screen.
    private var heldListedIDs: Set<CGWindowID> = []
    /// When each listed-but-off-screen window was first missed, for the
    /// hold's span.
    private var listedSince: [CGWindowID: Date] = [:]

    /// How long a window its app still lists is held after it leaves the
    /// screen. Long enough for a native full-screen excursion that lasts a
    /// look, a Space switched and switched back, or a stale snapshot; a
    /// window moved to another Space for good is hidden once it passes.
    static let listedHoldSpan: TimeInterval = 5.0

    /// Every known window the last cycle held, for whatever reason. A tile
    /// pass between polls keeps their leaves and writes them nothing.
    var heldWindowIDs: Set<CGWindowID> { heldUnreadableIDs.union(heldListedIDs) }

    /// How long until the earliest off-screen hold runs out, so the caller
    /// can poll then rather than at the next reconcile. nil without one.
    var secondsUntilAHoldEnds: TimeInterval? {
        guard let earliest = listedSince.values.min() else { return nil }
        return max(0.1, Self.listedHoldSpan - now().timeIntervalSince(earliest))
    }

    /// Windows the walk saw but could not use, and when to look again: on
    /// screen but unreadable, or listed by their app before the window
    /// server showed them. No event follows when such a window becomes
    /// readable, so without these it waited for the ten-second reconcile.
    private var readinessRetries: [CGWindowID: (attempts: Int, due: Date)] = [:]
    /// the gaps between looks; one look per gap, then it waits for events
    static let readinessDelays: [TimeInterval] = [0.25, 0.5, 1, 2]

    /// Windows auto-floated because their size was not settable at first
    /// sight, and when to ask again. Some apps make a new window resizable
    /// a moment after it opens.
    private var fixedSizeRechecks: [CGWindowID: (attempts: Int, due: Date)] = [:]
    static let fixedSizeRecheckDelays: [TimeInterval] = [0.5, 1, 2]

    /// How long until discovery wants another poll for something no event
    /// will report: a window not ready yet, a fixed-size re-check, or an
    /// app the walk is skipping (stalled, or left out by its budget) whose
    /// windows, held or new, it reads once the app is asked again. nil
    /// without one.
    var secondsUntilARetryIsDue: TimeInterval? {
        let now = self.now()
        let dues = readinessRetries.values.map(\.due) + fixedSizeRechecks.values.map(\.due)
        // a look still due after the cycle means the cycle was guarded
        // (mass-gone) and checked nothing; give the guard its own pace
        let ours = dues.filter { $0 != .distantFuture }.min()
            .map { $0 > now ? max(0.05, $0.timeIntervalSince(now)) : Self.overdueRetry }
        return [ours, accessibility.secondsUntilABackoffEnds].compactMap { $0 }.min()
    }
    static let overdueRetry: TimeInterval = 0.5

    /// Not-ready windows that still have a quick look to come.
    var windowsAwaitingALook: Set<CGWindowID> {
        Set(readinessRetries.filter { $0.value.due != .distantFuture }.keys)
    }

    /// Advance the readiness looks for this cycle's not-ready windows. A
    /// look is spent by a poll at or after its due time; one that resolves
    /// or leaves drops its entry.
    private func noteNotReady(_ pending: Set<CGWindowID>) {
        let now = self.now()
        readinessRetries = readinessRetries.filter { pending.contains($0.key) }
        let delays = Self.readinessDelays
        for id in pending.sorted() {
            guard let entry = readinessRetries[id] else {
                readinessRetries[id] = (0, now.addingTimeInterval(delays[0]))
                continue
            }
            guard now >= entry.due else { continue }
            let next = entry.attempts + 1
            if next < delays.count {
                readinessRetries[id] = (next, now.addingTimeInterval(delays[next]))
            } else {
                readinessRetries[id] = (next, .distantFuture)
                hyprLog(.debug, .discovery, "window \(id) still not readable after \(next) quick look(s) — left to events and the reconcile")
            }
        }
    }

    private func noteHeld(unreadable: Set<CGWindowID>, listed: Set<CGWindowID>) {
        if unreadable != heldUnreadableIDs {
            let began = unreadable.subtracting(heldUnreadableIDs)
            let ended = heldUnreadableIDs.subtracting(unreadable)
            heldUnreadableIDs = unreadable
            if !began.isEmpty {
                hyprLog(.notice, .discovery, "holding \(began.count) unreadable window(s) in place: "
                        + "\(began.sorted()) — on screen, but their app did not answer AX")
            }
            if !ended.isEmpty {
                hyprLog(.notice, .discovery, "unreadable window(s) readable again: \(ended.sorted())")
            }
        }
        if listed != heldListedIDs {
            let began = listed.subtracting(heldListedIDs)
            let ended = heldListedIDs.subtracting(listed)
            heldListedIDs = listed
            if !began.isEmpty {
                hyprLog(.notice, .discovery, "holding \(began.count) window(s) off the screen in place: "
                        + "\(began.sorted()) — their app still lists them (another Space, full screen,"
                        + " or a stale snapshot); hidden if not back within"
                        + " \(Int(Self.listedHoldSpan))s")
            }
            if !ended.isEmpty {
                hyprLog(.notice, .discovery, "off-screen hold ended: \(ended.sorted())")
            }
        }
    }

    /// The missing windows their app still lists, as long as the hold
    /// lasts. The window server no longer shows the window on screen and
    /// its app says it is neither minimized nor hidden with the app: it is
    /// on another Space, in a native full-screen excursion, or the snapshot
    /// was stale. Those come back on their own within seconds, and a window
    /// taken out of its tree meanwhile expands its neighbour over the slot
    /// and comes back somewhere else. Held for `listedHoldSpan`; one still
    /// missing after that is hidden like any other gone window, with its reservation.
    private func listedButOffScreen(_ candidates: Set<CGWindowID>, runningPIDs: Set<pid_t>,
                                    state: (CGWindowID, pid_t) -> AccessibilityManager.HiddenWindowState?)
        -> Set<CGWindowID> {
        let now = self.now()
        var held: Set<CGWindowID> = []
        for id in listedSince.keys where !candidates.contains(id) {
            listedSince.removeValue(forKey: id)
        }
        for id in candidates.sorted() {
            guard let pid = stateCache.windowOwners[id], runningPIDs.contains(pid),
                  !quickLookPanelIDs.contains(id),
                  stateCache.cachedWindows[id]?.isQuickLookPanel != true,
                  state(id, pid) == .present else {
                listedSince.removeValue(forKey: id)
                continue
            }
            let since = listedSince[id] ?? now
            if now.timeIntervalSince(since) < Self.listedHoldSpan {
                listedSince[id] = since
                held.insert(id)
            } else {
                listedSince.removeValue(forKey: id)
            }
        }
        return held
    }

    /// Start or end one reason for a session interruption, by notification
    /// name. Names that open or close no span are ignored.
    func noteSystemInterruption(_ name: String) {
        guard let span = Self.interruptionSpans[name] else { return }
        let wasActive = !interruptions.isEmpty
        if span.begins {
            guard interruptions[span.reason] == nil else { return }
            interruptions[span.reason] = now()
            if !wasActive {
                interruptionHoldLogged = false
                hyprLog(.notice, .discovery, "session interruption began (\(span.reason))"
                        + " — missing windows are not marked gone until it ends")
            }
            return
        }
        guard let since = interruptions.removeValue(forKey: span.reason) else { return }
        let seconds = Int(now().timeIntervalSince(since))
        if interruptions.isEmpty {
            hyprLog(.notice, .discovery, "session interruption ended (\(span.reason)) after \(seconds)s")
        } else {
            hyprLog(.notice, .discovery, "session interruption: \(span.reason) ended after \(seconds)s,"
                    + " still \(interruptions.keys.sorted().joined(separator: ", "))")
        }
    }

    /// End any interruption on evidence that the session is in use.
    func endSessionInterruption(evidence: String) {
        guard !interruptions.isEmpty else { return }
        hyprLog(.notice, .discovery, "session interruption ended by \(evidence)"
                + " (was \(interruptions.keys.sorted().joined(separator: ", ")))")
        interruptions.removeAll()
    }

    /// Whether a lock, display sleep or switched-out session span is open.
    /// The admission recovery reads this so its own retry timer never runs
    /// an attempt from the partial window list a poll would ignore.
    var isSessionInterrupted: Bool { sessionInterruptionActive() }

    /// Whether an interruption is in effect. Past the cap it ends itself.
    private func sessionInterruptionActive() -> Bool {
        guard let start = interruptions.values.min() else { return false }
        let elapsed = now().timeIntervalSince(start)
        guard elapsed < Self.interruptionCap else {
            hyprLog(.notice, .discovery, "session interruption cap reached after \(Int(elapsed))s"
                    + " (\(interruptions.keys.sorted().joined(separator: ", "))) — missing windows count again")
            interruptions.removeAll()
            return false
        }
        return true
    }

    /// Testable entry point. Pure with respect to AX and `NSWorkspace`:
    /// the caller supplies the snapshot and running-pid set, and this
    /// method does the diff and mutates the cache.
    ///
    /// - Returns: a `WindowChanges` value describing what changed and
    ///   what the caller still needs to apply (workspace assignment,
    ///   external cleanup, retile, refocus).
    /// - Parameter unreadableWindowIDs: windows the walk could not read
    ///   although the window server shows them. They are held: not gone, not
    ///   hidden, not returned, and nothing about them changes this cycle. A
    ///   missing window its app still lists is held the same way for
    ///   `listedHoldSpan`.
    func computeChanges(snapshot: [HyprWindow],
                        runningPIDs: Set<pid_t>,
                        excludedBundleIDs: Set<String>,
                        focusedWindowID: CGWindowID,
                        unreadableWindowIDs: Set<CGWindowID> = []) -> WindowChanges {
        let currentIDs = Set(snapshot.map { $0.windowID })
        // a window the walk saw but could not use gets a few quick looks:
        // one on screen whose app or frame did not answer, and a new one its
        // app lists before the window server shows it
        noteNotReady(unreadableWindowIDs.subtracting(currentIDs)
            .union(accessibility.unboundWindowIDs.subtracting(currentIDs)
                .subtracting(stateCache.knownWindowIDs).subtracting(stateCache.hiddenWindowIDs)))

        // a known window missing from the snapshot is gone only when AX
        // answered for it. one that is on screen by the window server's
        // account but whose app did not answer is held where it is, in every
        // store, until a pass can read it again: a single failed read used to
        // pull the window out of its tree, expand the neighbour over it, and
        // re-insert it somewhere else on the next poll.
        let missing = stateCache.knownWindowIDs.subtracting(currentIDs)
        let unreadable = missing.intersection(unreadableWindowIDs)
        // one AX question per missing window per cycle, shared between the
        // hold and the hidden classification below
        var states: [CGWindowID: AccessibilityManager.HiddenWindowState?] = [:]
        func hiddenState(_ id: CGWindowID, pid: pid_t) -> AccessibilityManager.HiddenWindowState? {
            if let asked = states[id] { return asked }
            let state = accessibility.hiddenWindowState(windowID: id, pid: pid)
            states[id] = state
            return state
        }
        let listed = listedButOffScreen(missing.subtracting(unreadable), runningPIDs: runningPIDs,
                                        state: hiddenState)
        let held = unreadable.union(listed)
        noteHeld(unreadable: unreadable, listed: listed)

        // partial AX snapshots (post-wake, unresponsive apps) can report half
        // the desktop gone in one cycle; real user actions never do. skip the
        // whole cycle before mutating any cache state — but only a bounded
        // number of times, so a genuine mass close still processes.
        let apparentlyGone = missing.subtracting(held)
        // while locked or asleep nothing is marked gone, and nothing else in
        // the cycle is applied either: the snapshot is not the desktop
        if !apparentlyGone.isEmpty, sessionInterruptionActive() {
            let line = "session interruption: \(apparentlyGone.count)/\(stateCache.knownWindowIDs.count)"
                + " known windows missing — holding them, nothing marked gone"
            hyprLog(interruptionHoldLogged ? .debug : .notice, .discovery, line)
            interruptionHoldLogged = true
            return WindowChanges(newWindows: [], newOnDisabledMonitor: [], returned: [],
                                 goneIDs: [], fullyForgottenIDs: [], screenDrift: [],
                                 focusedWindowGone: false, requestsRecheck: false,
                                 heldForInterruption: true)
        }
        if apparentlyGone.count >= 3, apparentlyGone.count * 2 > stateCache.knownWindowIDs.count,
           massGoneSkips < 3 {
            massGoneSkips += 1
            hyprLog(.notice, .discovery, "mass-gone guard: \(apparentlyGone.count)/\(stateCache.knownWindowIDs.count) known windows missing from one snapshot — skipping cycle (\(massGoneSkips)/3)")
            return WindowChanges(newWindows: [], newOnDisabledMonitor: [], returned: [],
                                 goneIDs: [], fullyForgottenIDs: [], screenDrift: [],
                                 focusedWindowGone: false, requestsRecheck: true)
        }
        massGoneSkips = 0

        reverifyUnresolvedReservations(currentIDs: currentIDs, runningPIDs: runningPIDs)

        var newWindows: [HyprWindow] = []
        var newOnDisabled: Set<CGWindowID> = []
        var returned: [HyprWindow] = []
        var reopenedAfterClose: Set<CGWindowID> = []
        var goneIDs: Set<CGWindowID> = []
        var fullyForgotten: Set<CGWindowID> = []

        // returned (hidden → present)
        for w in snapshot where stateCache.hiddenWindowIDs.contains(w.windowID) {
            stateCache.hiddenWindowIDs.remove(w.windowID)
            stateCache.knownWindowIDs.insert(w.windowID)
            stateCache.windowOwners[w.windowID] = w.ownerPID
            returned.append(w)
            if let t = hiddenAt.removeValue(forKey: w.windowID),
               Date().timeIntervalSince(t) < Self.flapWindowSec {
                let ms = Int(Date().timeIntervalSince(t) * 1000)
                hyprLog(.notice, .discovery, "FLAP: '\(w.title ?? "?")' (\(w.windowID)) returned \(ms)ms after vanishing — likely stale AX snapshot (busy app); each flap retiles the sibling full-screen and back")
            }
            // not reserved while hidden: a verified close, not a hide
            let afterClose = !stateCache.reservedHiddenWindowIDs.contains(w.windowID)
            if afterClose { reopenedAfterClose.insert(w.windowID) }
            hyprLog(.notice, .discovery, "window returned: '\(w.title ?? "?")' (\(w.windowID))"
                    + (afterClose ? " — reopened after a close" : ""))
        }

        // new
        for w in snapshot where !stateCache.knownWindowIDs.contains(w.windowID) {
            admitNew(w, excludedBundleIDs: excludedBundleIDs, newOnDisabled: &newOnDisabled)
            newWindows.append(w)
        }

        let unfloated = recheckFixedSize(snapshot)

        // gone. the held ids stay out of this: they are still known
        let gone = apparentlyGone
        for id in gone {
            goneIDs.insert(id)
            // startup and Retile All register windows without a discovery
            // pass, so the cached window is the other place a panel shows up
            let isQuickLookPanel = quickLookPanelIDs.contains(id)
                || stateCache.cachedWindows[id]?.isQuickLookPanel == true
            stateCache.tiledPositions.removeValue(forKey: id)
            stateCache.cachedWindows.removeValue(forKey: id)

            if isQuickLookPanel {
                // never a ghost and never reserved; its floating flag goes
                // with it
                let bundle = stateCache.windowOwners[id].flatMap(bundleIDForPID) ?? "?"
                stateCache.forget(id)
                fullyForgotten.insert(id)
                hiddenAt.removeValue(forKey: id)
                hyprLog(.notice, .discovery, "quick look panel gone: \(id) (\(bundle)) — forgotten with its floating state, no ghost")
            } else if let pid = stateCache.windowOwners[id], runningPIDs.contains(pid) {
                // app still running — window minimized/hidden/closed-but-app-alive.
                // keep cache state intact apart from moving to hidden, so an
                // un-minimize comes back as "returned" not "new".
                stateCache.knownWindowIDs.remove(id)
                stateCache.hiddenWindowIDs.insert(id)
                hiddenAt[id] = Date()
                // anything but a verified close keeps its tile slot: minimized,
                // Cmd-H'd, on another Space, or unreadable. nil (AX unreadable)
                // reserves too — the safe side — but gets re-checked next cycle
                // so a close isn't reserved forever.
                let state = hiddenState(id, pid: pid)
                if state != .absent {
                    stateCache.reservedHiddenWindowIDs.insert(id)
                    if state == nil { unverifiedReservedIDs[id] = 0 }
                }
                if state == nil || state == .minimized || state == .appHidden {
                    userHiddenIDs.insert(id)
                }
                if state == .minimized || state == .appHidden {
                    minimizedOrAppHiddenIDs.insert(id)
                }
                let bundle = bundleIDForPID(pid) ?? "pid \(pid)"
                if workspaceManager.isWindowVisible(id) {
                    hyprLog(.notice, .discovery, "window hidden: \(id) (\(bundle))")
                } else {
                    hyprLog(.notice, .discovery, "window hidden (inactive ws): \(id) (\(bundle))")
                }
            } else {
                stateCache.forget(id)
                fullyForgotten.insert(id)
                hiddenAt.removeValue(forKey: id)
                hyprLog(.debug, .discovery, "window gone: \(id)")
            }
        }

        // sweep stale entries — terminated apps whose hidden windows didn't
        // show up in the gone set, or generic drift across cache fields.
        let swept = sweepStaleState(runningPIDs: runningPIDs)
        fullyForgotten.formUnion(swept)
        for id in fullyForgotten { driftExemptions.removeValue(forKey: id) }

        // drift detection. just-returned windows that were verifiably CLOSED
        // (not minimized/Cmd-H'd) get special handling: a recycled-CGWindowID
        // reopen (Teams, Mail) comes back "returned" with a stale assignment
        // to a hidden workspace. user-hidden returns keep their workspace.
        let reopened = Set(returned.map { $0.windowID }).subtracting(userHiddenIDs)
        let fromUserHide = Set(returned.map { $0.windowID }).intersection(minimizedOrAppHiddenIDs)
        userHiddenIDs.subtract(returned.map { $0.windowID })
        userHiddenIDs.formIntersection(stateCache.hiddenWindowIDs)
        minimizedOrAppHiddenIDs.subtract(returned.map { $0.windowID })
        minimizedOrAppHiddenIDs.formIntersection(stateCache.hiddenWindowIDs)
        stateCache.reservedHiddenWindowIDs.subtract(returned.map { $0.windowID })
        stateCache.reservedHiddenWindowIDs.formIntersection(stateCache.hiddenWindowIDs)
        unverifiedReservedIDs = unverifiedReservedIDs.filter { stateCache.hiddenWindowIDs.contains($0.key) }
        let (drift, reopenedOntoHidden) = detectScreenDrift(snapshot, justReturned: reopened)

        quickLookPanelIDs = Set(snapshot.lazy.filter(\.isQuickLookPanel).map(\.windowID))

        let focusedGone = goneIDs.contains(focusedWindowID)

        var changes = WindowChanges(
            newWindows: newWindows,
            newOnDisabledMonitor: newOnDisabled,
            returned: returned,
            goneIDs: goneIDs,
            fullyForgottenIDs: fullyForgotten,
            screenDrift: drift,
            focusedWindowGone: focusedGone,
            requestsRecheck: false,
            returnedFromUserHide: fromUserHide,
            reopenedOntoHiddenWorkspace: reopenedOntoHidden,
            unfloated: unfloated
        )
        changes.reopenedAfterClose = reopenedAfterClose
        return changes
    }

    /// First sight of `w`: the cache half of admitting it. Known from now
    /// on, its owner and on-screen frame kept, auto-floated when policy or a
    /// disabled monitor says so (then in `newOnDisabled`).
    private func admitNew(_ w: HyprWindow, excludedBundleIDs: Set<String>,
                          newOnDisabled: inout Set<CGWindowID>) {
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

        // auto-float excluded apps, explicitly fixed-size windows and
        // quick look previews
        let excluded = bundleIDForPID(w.ownerPID).map(excludedBundleIDs.contains) ?? false
        if let reason = FloatingAdmissionPolicy.reason(
            isExcluded: excluded,
            isSizeSettable: isWindowSizeSettable(w),
            isQuickLookPanel: w.isQuickLookPanel
        ) {
            stateCache.setFloating(true, window: w)
            if reason == .fixedSize {
                // read once, at first sight. some apps make a window
                // resizable a moment after it opens, so ask again
                fixedSizeRechecks[w.windowID] = (0, now().addingTimeInterval(Self.fixedSizeRecheckDelays[0]))
                hyprLog(.notice, .discovery, "auto-float \(reason.rawValue): '\(w.title ?? "?")' (\(w.windowID))"
                        + " \(bundleIDForPID(w.ownerPID) ?? "pid \(w.ownerPID)") — re-checked"
                        + " \(Self.fixedSizeRecheckDelays.count) times over"
                        + " \(Self.fixedSizeRecheckDelays.reduce(0, +))s")
            } else {
                hyprLog(.debug, .discovery, "auto-float \(reason.rawValue): '\(w.title ?? "?")'")
            }
        }

        // auto-float on disabled monitors — surface so caller skips workspace assignment
        if let screen = displayManager.screen(for: w), workspaceManager.isMonitorDisabled(screen) {
            if !stateCache.floatingWindowIDs.contains(w.windowID) {
                stateCache.setFloating(true, window: w)
                hyprLog(.debug, .discovery, "auto-float on disabled monitor: '\(w.title ?? "?")'")
            }
            newOnDisabled.insert(w.windowID)
            // it floats for the monitor, whatever its size says
            fixedSizeRechecks[w.windowID] = nil
            hyprLog(.debug, .discovery, "new window (disabled monitor): '\(w.title ?? "?")' (\(w.windowID))")
        } else {
            hyprLog(.debug, .discovery, "new window: '\(w.title ?? "?")' (\(w.windowID))")
        }
    }

    /// The admit-only diff a workspace switch's transition hold allows once
    /// the switch is done. Only windows discovery has never known are taken:
    /// not known, not hidden (a ghost, a minimized or Cmd-H'd window), with
    /// no workspace assignment (nothing the switch parked or revealed), and
    /// readable in this walk. Those get the same cache half as in
    /// `computeChanges`. Nothing else in the snapshot is looked at: no
    /// gone, hidden, returned or held bookkeeping, no fixed-size re-check,
    /// no screen drift. The full poll after the hold does all of that.
    func computeAdmissions(snapshot: [HyprWindow], excludedBundleIDs: Set<String>,
                           unreadableWindowIDs: Set<CGWindowID> = []) -> WindowChanges {
        var newWindows: [HyprWindow] = []
        var newOnDisabled: Set<CGWindowID> = []
        // a locked or asleep session's walk is not the desktop
        if !sessionInterruptionActive() {
            for w in snapshot where Self.isBrandNew(
                w.windowID, known: stateCache.knownWindowIDs, hidden: stateCache.hiddenWindowIDs,
                unreadable: unreadableWindowIDs, assigned: workspaceManager.workspaceFor(w.windowID) != nil) {
                admitNew(w, excludedBundleIDs: excludedBundleIDs, newOnDisabled: &newOnDisabled)
                if w.isQuickLookPanel { quickLookPanelIDs.insert(w.windowID) }
                newWindows.append(w)
            }
        }
        return WindowChanges(newWindows: newWindows, newOnDisabledMonitor: newOnDisabled, returned: [],
                             goneIDs: [], fullyForgottenIDs: [], screenDrift: [],
                             focusedWindowGone: false, requestsRecheck: false)
    }

    /// A window id discovery has never known, so admitting it cannot touch
    /// any window the switch is moving.
    static func isBrandNew(_ id: CGWindowID, known: Set<CGWindowID>, hidden: Set<CGWindowID>,
                           unreadable: Set<CGWindowID>, assigned: Bool) -> Bool {
        !known.contains(id) && !hidden.contains(id) && !unreadable.contains(id) && !assigned
    }

    /// Ask again whether the windows auto-floated as not resizable are.
    /// One that is now goes back to tiling: its floating flag clears and
    /// the caller's retile places it. One the user tiled meanwhile, one
    /// floating for another reason now, and one that left are dropped;
    /// one held this cycle keeps its turn.
    private func recheckFixedSize(_ snapshot: [HyprWindow]) -> Set<CGWindowID> {
        guard !fixedSizeRechecks.isEmpty else { return [] }
        let now = self.now()
        let byID = Dictionary(snapshot.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        var unfloated: Set<CGWindowID> = []
        for (id, entry) in fixedSizeRechecks.sorted(by: { $0.key < $1.key }) {
            guard let w = byID[id] else {
                if !stateCache.knownWindowIDs.contains(id) {
                    fixedSizeRechecks[id] = nil
                } else if now >= entry.due {
                    // held this cycle: same turn, asked after the same gap
                    fixedSizeRechecks[id] = (entry.attempts,
                                             now.addingTimeInterval(Self.fixedSizeRecheckDelays[entry.attempts]))
                }
                continue
            }
            guard now >= entry.due else { continue }
            guard stateCache.floatingWindowIDs.contains(id),
                  let workspace = workspaceManager.workspaceFor(id),
                  workspace != ScratchpadController.workspace,
                  !(displayManager.screen(for: w).map(workspaceManager.isMonitorDisabled) ?? false) else {
                fixedSizeRechecks[id] = nil
                continue
            }
            if isWindowSizeSettable(w) == true {
                fixedSizeRechecks[id] = nil
                stateCache.setFloating(false, window: w)
                unfloated.insert(id)
                hyprLog(.notice, .discovery, "auto-float re-check: '\(w.title ?? "?")' (\(id)) is resizable now"
                        + " — handing it back to tiling")
                continue
            }
            let next = entry.attempts + 1
            if next < Self.fixedSizeRecheckDelays.count {
                fixedSizeRechecks[id] = (next, now.addingTimeInterval(Self.fixedSizeRecheckDelays[next]))
            } else {
                fixedSizeRechecks[id] = nil
                hyprLog(.debug, .discovery, "auto-float re-check: \(id) still not resizable — stays floating")
            }
        }
        return unfloated
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

    /// Re-ask AX about hidden ids whose reservation was a guess (the query
    /// returned nil when they vanished). A window the user actually closed
    /// would otherwise hold its workspace slot until the app quits.
    ///
    /// Ids back in this cycle's snapshot are left alone: the returned pass
    /// in `computeChanges` owns them, and AX would answer "not minimized" for a window
    /// that is plainly on screen — stripping the reservation and misfiling
    /// the return as a recycled-id reopen.
    private func reverifyUnresolvedReservations(currentIDs: Set<CGWindowID>, runningPIDs: Set<pid_t>) {
        for (id, attempts) in unverifiedReservedIDs {
            guard stateCache.hiddenWindowIDs.contains(id) else {
                unverifiedReservedIDs[id] = nil
                continue
            }
            guard !currentIDs.contains(id) else { continue }
            guard let pid = stateCache.windowOwners[id], runningPIDs.contains(pid) else { continue }
            // an app the walk is backing off from would answer nil without
            // being asked; that is not one of the few asks this gets
            guard !accessibility.isBackingOff(pid: pid) else { continue }
            switch accessibility.hiddenWindowState(windowID: id, pid: pid) {
            case .absent:
                stateCache.reservedHiddenWindowIDs.remove(id)
                unverifiedReservedIDs[id] = nil
                userHiddenIDs.remove(id)
                minimizedOrAppHiddenIDs.remove(id)
                hyprLog(.debug, .discovery, "hidden window \(id) verified closed — releasing its workspace reservation")
            case .minimized, .appHidden:
                unverifiedReservedIDs[id] = nil
                minimizedOrAppHiddenIDs.insert(id)
            case .present:
                unverifiedReservedIDs[id] = nil
            case nil:
                // one AX round trip per cycle; stop asking after a few
                if attempts + 1 >= Self.maxReverifyAttempts {
                    unverifiedReservedIDs[id] = nil
                } else {
                    unverifiedReservedIDs[id] = attempts + 1
                }
            }
        }
    }

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
                hiddenAt.removeValue(forKey: id)
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
    /// Floating windows are skipped (they can be anywhere by design),
    /// except a recycled-id reopen onto a hidden workspace, which drifts
    /// like a tiled one so the park repair does not re-park it.
    /// Windows without a substantially visible frame are skipped — that
    /// covers hide-corner park slivers and stale/transient AX reads, so
    /// drift only ever acts on a window the user can actually see.
    private func detectScreenDrift(_ allWindows: [HyprWindow],
                                   justReturned: Set<CGWindowID> = [])
        -> (drifts: [(windowID: CGWindowID, fromWorkspace: Int, toWorkspace: Int)],
            reopenedOntoHidden: Set<CGWindowID>) {
        let visibleWorkspaces = Set(workspaceManager.monitorWorkspace.values)
        let clock = now()
        driftExemptions = driftExemptions.filter { $0.value > clock }
        var drifts: [(CGWindowID, Int, Int)] = []
        var reopenedOntoHidden: Set<CGWindowID> = []
        for w in allWindows {
            guard let recordedWs = workspaceManager.workspaceFor(w.windowID) else { continue }
            // scratchpad members (ws 0) never drift — a tiled member is
            // non-floating and passes the floater skip below, so it needs an
            // explicit bail. (it's currently safe only by accident: ws 0 is
            // never in monitorWorkspace.values.)
            guard recordedWs != ScratchpadController.workspace else { continue }
            // a window that just returned from hidden while its recorded ws
            // is hidden is a recycled-id reopen — without reassignment it
            // ghosts untiled over the current workspace (invisible to FFM
            // and tiling) and teleports cross-monitor when clicked, and a
            // floater gets parked by the park repair. bypass the placement
            // guards so it lands where it visibly opened.
            let reopenedOntoHiddenWs = justReturned.contains(w.windowID)
                && !visibleWorkspaces.contains(recordedWs)
            // floating windows can be anywhere by design — skip, unless
            // reopened onto a hidden ws
            let floating = stateCache.floatingWindowIDs.contains(w.windowID)
            guard !floating || reopenedOntoHiddenWs else { continue }
            // majority frame overlap, not center-point: a min-size-crammed
            // window inflated across a monitor edge keeps a majority on its
            // own screen, and park slivers / stale off-screen frames fail
            // the substantial check entirely (the guard the doc above
            // promises).
            guard hasSubstantialOnScreenFrame(w),
                  let physicalScreen = majorityOverlapScreen(w) else { continue }
            // skip if the window sits on a disabled monitor — handled elsewhere
            guard !workspaceManager.isMonitorDisabled(physicalScreen) else { continue }
            // on its way to the cursor's monitor: left alone until it is
            // mostly on its workspace's screen
            let physicalWs = workspaceManager.workspaceForScreen(physicalScreen)
            if driftExemptions[w.windowID] != nil {
                guard physicalWs == recordedWs
                        || workspaceManager.homeScreenForWorkspace(recordedWs) == physicalScreen else { continue }
                driftExemptions.removeValue(forKey: w.windowID)
            }
            guard physicalWs != recordedWs else { continue }
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
            if reopenedOntoHiddenWs { reopenedOntoHidden.insert(w.windowID) }
            hyprLog(.notice, .discovery, "drift: '\(w.title ?? "?")' (\(w.windowID)) ws\(recordedWs) → ws\(physicalWs) (now on \(physicalScreen.localizedName))\(reopenedOntoHiddenWs ? " [reopened onto hidden ws\(floating ? ", floating" : "")]" : "")")
        }
        return (drifts, reopenedOntoHidden)
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
