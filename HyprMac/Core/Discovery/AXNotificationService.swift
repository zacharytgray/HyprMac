// Per-app AXObserver fan-out: one observer per regular app, delivering
// window create / destroy / miniaturize / focus notifications on the main
// run loop. These are the primary discovery triggers — the polling
// scheduler's timer is a slow reconcile safety net (see PollingScheduler).

import Cocoa

/// which of one app's windows need their window-level AX notifications added.
///
/// a window id alone can't say a subscription is alive: Teams closes a window
/// by hiding it and shows it again under the same CGWindowID, and the
/// destroy notification only fires for the first close. so a window that was
/// away gets added again. adding one that is still registered is a no-op.
struct WindowSubscriptionLedger {
    /// failed adds in a row before a window is recorded as it stands. a
    /// window that refuses a notification for good would otherwise cost
    /// three AX calls on every poll
    static let maxFailedAdds = 5

    private(set) var subscribed: Set<CGWindowID> = []
    private var presentLastPass: Set<CGWindowID> = []
    private var failedAdds: [CGWindowID: Int] = [:]

    func needsAdd(_ id: CGWindowID) -> Bool {
        !subscribed.contains(id) || !presentLastPass.contains(id)
    }

    /// a failed add stays unrecorded, so the next poll tries it again, up
    /// to `maxFailedAdds` times in a row.
    /// - Returns: true when this failure was the last try
    @discardableResult
    mutating func noteAdd(_ id: CGWindowID, tookHold: Bool) -> Bool {
        if tookHold {
            subscribed.insert(id)
            failedAdds[id] = nil
            return false
        }
        let failures = (failedAdds[id] ?? 0) + 1
        if failures >= Self.maxFailedAdds {
            failedAdds[id] = nil
            subscribed.insert(id)
            return true
        }
        failedAdds[id] = failures
        subscribed.remove(id)
        return false
    }

    mutating func finishPass(present: Set<CGWindowID>) {
        presentLastPass = present
        // a window that left gets a fresh budget when it comes back
        failedAdds = failedAdds.filter { present.contains($0.key) }
    }

    /// the event doesn't say which window. the app can reopen it before the
    /// next poll sees it gone, so every window of the app is checked again.
    mutating func noteDestroyEvent() {
        presentLastPass.removeAll()
    }
}

/// The app-level notifications one app has not taken yet, and the tries
/// each has had. An app still launching can refuse some and take others,
/// and each is asked again on its own until it takes or runs out of tries.
struct AppSubscriptionRetry {
    static let maxAttempts = 5

    private(set) var attempts: [String: Int] = [:]

    /// Record one try. - Returns: true when this failure was the last try.
    @discardableResult
    mutating func note(_ name: String, tookHold: Bool) -> Bool {
        guard !tookHold else {
            attempts[name] = nil
            return false
        }
        let tries = (attempts[name] ?? 0) + 1
        attempts[name] = tries
        return tries == Self.maxAttempts
    }

    /// the names still owed a try, in a stable order
    var due: [String] { attempts.filter { $0.value < Self.maxAttempts }.keys.sorted() }

    /// names that ran out of tries
    var gaveUp: [String] { attempts.filter { $0.value >= Self.maxAttempts }.keys.sorted() }
}

/// Owns one `AXObserver` per regular running app and routes their AX
/// notifications into a single `onEvent` sink.
///
/// This is the event-driven front end for discovery. Rather than walking
/// the whole desktop on a fast timer, each app tells us when its windows appear,
/// vanish, minimize, or take focus; `WindowManager` funnels every event
/// into the existing coalescing `PollingScheduler.schedule(after:)` so the
/// real discovery diff (`getAllWindows` → `computeChanges` → `applyChanges`)
/// runs only when something actually changed. Same architecture as
/// yabai / AeroSpace.
///
/// App-level subscriptions (`kAXWindowCreated`, `kAXFocusedWindowChanged`,
/// `kAXMainWindowChanged`, `kAXWindowMoved`, `kAXWindowResized`) go on the
/// app element and cover the app's whole lifetime. Moves and resizes reach
/// `onFrameChange` only, so the chrome follows; they never schedule a poll. Window-level
/// subscriptions (`kAXUIElementDestroyed`, `kAXWindowMiniaturized`,
/// `kAXWindowDeminiaturized`) go on each window element and are attached
/// lazily via `ensureWindowSubscriptions(for:)` after every discovery pass,
/// deduped by `CGWindowID` until a window leaves the snapshot or its app
/// reports a destroy (`WindowSubscriptionLedger`).
///
/// Ownership: `AXObserver` and `AXUIElement` are CF types held by ARC in the
/// per-pid `Entry`, so dropping the entry on `detach` releases them; the run
/// loop source is removed explicitly first.
///
/// Threading: main-thread only. `AXObserverGetRunLoopSource` is added to the
/// main run loop, so every callback lands on main by construction.
final class AXNotificationService {

    static func activateInitialSubscriptions<Window>(
        initialWindows: [Window],
        attach: () -> Void,
        subscribe: ([Window]) -> Void
    ) {
        attach()
        subscribe(initialWindows)
    }

    /// `true` when the destroyed-notification subscription actually took
    /// hold. A failed add must not be recorded — the window would never
    /// report its close.
    static func subscriptionRecorded(destroyed error: AXError) -> Bool {
        registered(error)
    }

    /// `true` when an add took hold, now or earlier.
    static func registered(_ error: AXError) -> Bool {
        error == .success || error == .notificationAlreadyRegistered
    }

    /// A window is done once all three window-level adds took hold. A
    /// failed minimize or deminiaturize add is retried like a failed
    /// destroy add: without it a minimize, or the restore that brings the
    /// window back, waits for a focus event or the reconcile.
    static func windowSubscriptionsRecorded(destroyed: AXError, miniaturized: AXError,
                                            deminiaturized: AXError) -> Bool {
        registered(destroyed) && registered(miniaturized) && registered(deminiaturized)
    }

    /// The app-level notifications, each added on its own and retried on its own.
    static let appNotifications: [String] = [
        kAXWindowCreatedNotification as String,
        kAXFocusedWindowChangedNotification as String,
        // a window coming forward can bury a floater; only the stacking visuals use this
        kAXMainWindowChangedNotification as String,
        // any window of the app moved or resized, by the app, by another
        // tool, by a drag or by HyprMac. only the chrome uses these
        kAXWindowMovedNotification as String,
        kAXWindowResizedNotification as String,
    ]

    /// The AX notifications we translate and forward. Each maps to one or
    /// more `kAX…Notification` strings on the app or window element.
    enum Kind {
        case windowCreated
        case windowDestroyed
        case windowMiniaturized
        case windowDeminiaturized
        case focusedWindowChanged
        case mainWindowChanged
    }

    /// Sink for every translated notification. `pid` is the app the event
    /// belongs to (derived from the firing element). Set by `WindowManager`
    /// to route into the polling scheduler.
    var onEvent: ((Kind, pid_t) -> Void)?

    /// Sink for a window that moved or resized, by window id. Set by
    /// `WindowManager` so the chrome follows. A move never asks for a poll.
    var onFrameChange: ((CGWindowID) -> Void)?

    static func isFrameChange(_ notification: String) -> Bool {
        notification == kAXWindowMovedNotification as String
            || notification == kAXWindowResizedNotification as String
    }

    /// Pure routing seam for a move or resize, after the window id is read.
    func routeFrameChange(notification: String, windowID: CGWindowID) {
        guard Self.isFrameChange(notification), windowID != 0 else { return }
        onFrameChange?(windowID)
    }

    // per-pid observer + its window-level subscription bookkeeping.
    // the observer and app/window elements are CF types retained by ARC
    // through these stored properties; releasing the entry releases them.
    private final class Entry {
        let observer: AXObserver
        let appElement: AXUIElement
        var ledger = WindowSubscriptionLedger()
        var appRetry = AppSubscriptionRetry()
        // retain the window elements we subscribed to — HyprWindow may be
        // released between passes, but the observer needs a live element.
        var windowElements: [CGWindowID: AXUIElement] = [:]

        init(observer: AXObserver, appElement: AXUIElement) {
            self.observer = observer
            self.appElement = appElement
        }
    }

    private var entries: [pid_t: Entry] = [:]
    // pids whose observer could not be created yet, with the tries so far.
    // guards attach() against re-entry while a retry is pending; later
    // polls try again, up to AppSubscriptionRetry.maxAttempts.
    private var retrying: [pid_t: Int] = [:]

    // callbacks reach us through an unretained refcon — every run loop
    // source must be gone before this object is. WindowManager holds the
    // service for the app's lifetime, so this only backstops a future
    // teardown path that forgets detachAll().
    deinit {
        for entry in entries.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(entry.observer), .commonModes)
        }
    }

    private let selfPID = ProcessInfo.processInfo.processIdentifier

    // MARK: - attach / detach

    /// Attach an observer to every regular app currently running, skipping
    /// HyprMac itself. Idempotent per pid.
    func attachToRunningApps() {
        mainThreadOnly()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            attach(pid: app.processIdentifier)
        }
    }

    /// Attach an observer to `pid`. No-op if already attached or a retry is
    /// pending, or for HyprMac's own pid.
    func attach(pid: pid_t) {
        mainThreadOnly()
        guard pid != selfPID else { return }
        guard entries[pid] == nil, retrying[pid] == nil else { return }
        attemptAttach(pid: pid)
    }

    /// Detach `pid`: remove its run loop source and drop all bookkeeping.
    /// ARC releases the observer and retained elements.
    func detach(pid: pid_t) {
        mainThreadOnly()
        retrying[pid] = nil
        guard let entry = entries.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(entry.observer), .commonModes)
        hyprLog(.debug, .discovery, "AX observer detached pid=\(pid)")
    }

    /// Detach every observer. Called from `WindowManager.stop()`.
    func detachAll() {
        mainThreadOnly()
        for pid in Array(entries.keys) { detach(pid: pid) }
        retrying.removeAll()
    }

    /// Add window-level subscriptions (destroy / miniaturize / deminiaturize)
    /// for every window in `snapshot` whose app is attached and whose id we
    /// haven't subscribed yet. Called after each discovery pass with the
    /// fresh snapshot.
    ///
    /// Deduped by `CGWindowID`, but only once the destroy, miniaturize and
    /// deminiaturize subscriptions all took hold — a window recorded after a
    /// failed add would never report its close or its minimize, so a
    /// failure is left unrecorded and retried on the next polls, up to
    /// `WindowSubscriptionLedger.maxFailedAdds` in a row. Each poll also
    /// retries app-level adds an app refused and observers that could not
    /// be created, up to `AppSubscriptionRetry.maxAttempts`.
    /// A window that left the snapshot is added again when it returns, since
    /// its id may be back on a new AX element. Nothing is removed — a
    /// minimized window leaves the snapshot but must keep its deminiaturize
    /// subscription. `detach` prunes a pid's bookkeeping wholesale on quit.
    func ensureWindowSubscriptions(for snapshot: [HyprWindow]) {
        mainThreadOnly()
        // a poll is the next chance for an app-level add or an observer
        // that failed before
        retryAttaches()
        retryAppSubscriptions()
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for window in snapshot {
            guard let entry = entries[window.ownerPID] else { continue }
            let wid = window.windowID
            guard entry.ledger.needsAdd(wid) else { continue }

            let element = window.element
            let destroyedErr = AXObserverAddNotification(entry.observer, element, kAXUIElementDestroyedNotification as CFString, refcon)
            let miniErr = AXObserverAddNotification(entry.observer, element, kAXWindowMiniaturizedNotification as CFString, refcon)
            let deminiErr = AXObserverAddNotification(entry.observer, element, kAXWindowDeminiaturizedNotification as CFString, refcon)

            // retain the element either way — the miniaturize adds above may
            // have taken hold and need it alive; only all three landing
            // marks the window done. already-registered means the retained
            // element is the one the observer holds, so it stays.
            if destroyedErr != .notificationAlreadyRegistered || entry.windowElements[wid] == nil {
                entry.windowElements[wid] = element
            }
            let tookHold = Self.windowSubscriptionsRecorded(destroyed: destroyedErr, miniaturized: miniErr,
                                                            deminiaturized: deminiErr)
            let errors = "destroy err \(destroyedErr.rawValue), miniaturized err \(miniErr.rawValue),"
                + " deminiaturized err \(deminiErr.rawValue)"
            if entry.ledger.noteAdd(wid, tookHold: tookHold) {
                hyprLog(.notice, .discovery, "window \(wid) AX subscriptions incomplete after"
                        + " \(WindowSubscriptionLedger.maxFailedAdds) tries (\(errors)) — its close or"
                        + " minimize may wait for the reconcile poll")
            } else {
                hyprLog(.debug, .discovery, tookHold
                    ? "window subscriptions for window \(wid): \(errors)"
                    : "window subscriptions failed for window \(wid) (\(errors)) — retrying next poll")
            }
        }
        let presentByPID = Dictionary(grouping: snapshot, by: \.ownerPID)
        for (pid, entry) in entries {
            entry.ledger.finishPass(present: Set((presentByPID[pid] ?? []).map(\.windowID)))
        }
    }

    // MARK: - internals

    private func attemptAttach(pid: pid_t) {
        var observer: AXObserver?
        let createErr = AXObserverCreate(pid, axNotificationCallback, &observer)
        guard createErr == .success, let observer else {
            handleAttachFailure(pid: pid, err: createErr)
            return
        }

        let entry = Entry(observer: observer, appElement: AXUIElementCreateApplication(pid))
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        entries[pid] = entry
        retrying[pid] = nil
        // a newly launched app may not be AX-ready, and may take one add
        // and refuse another. each refused one is retried on its own
        addAppSubscriptions(Self.appNotifications, pid: pid, entry: entry)
        hyprLog(.debug, .discovery, "AX observer attached pid=\(pid)"
                + (entry.appRetry.due.isEmpty ? "" : ", still owed \(entry.appRetry.due)"))
        guard !entry.appRetry.due.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, let entry = self.entries[pid], !entry.appRetry.due.isEmpty else { return }
            self.addAppSubscriptions(entry.appRetry.due, pid: pid, entry: entry)
        }
    }

    /// Add `names` on the app element and record each result. One that
    /// runs out of tries logs at notice: without the window-created add a
    /// new window waits for a focus event or the reconcile poll.
    private func addAppSubscriptions(_ names: [String], pid: pid_t, entry: Entry) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in names {
            let err = AXObserverAddNotification(entry.observer, entry.appElement, name as CFString, refcon)
            let wasOwed = entry.appRetry.attempts[name] != nil
            let tookHold = Self.registered(err)
            if entry.appRetry.note(name, tookHold: tookHold) {
                let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
                let effect = name == kAXWindowCreatedNotification as String
                    ? "its new windows wait for a focus event or the reconcile poll"
                    : name == kAXFocusedWindowChangedNotification as String
                        ? "its focus changes wait for the next poll"
                        : Self.isFrameChange(name)
                            ? "the chrome follows its windows' moves only at the next refresh"
                            : "floater stacking may lag"
                hyprLog(.notice, .discovery, "AX observer for \(bundle) pid=\(pid) has no \(name) subscription"
                        + " after \(AppSubscriptionRetry.maxAttempts) tries (err \(err.rawValue)) — \(effect)")
            } else if tookHold && wasOwed {
                hyprLog(.debug, .discovery, "AX observer pid=\(pid): \(name) subscription took on retry")
            }
        }
    }

    /// One more try for every attached app's owed app-level adds.
    private func retryAppSubscriptions() {
        for (pid, entry) in entries where !entry.appRetry.due.isEmpty {
            addAppSubscriptions(entry.appRetry.due, pid: pid, entry: entry)
        }
    }

    /// One more try for every app whose observer could not be created.
    private func retryAttaches() {
        for pid in retrying.keys.sorted() where entries[pid] == nil {
            attemptAttach(pid: pid)
        }
    }

    private func handleAttachFailure(pid: pid_t, err: AXError) {
        let tries = (retrying[pid] ?? 0) + 1
        guard tries < AppSubscriptionRetry.maxAttempts else {
            // the 10s reconcile poll is the safety net for apps that refuse observers
            retrying[pid] = nil
            hyprLog(.notice, .discovery, "AX observer attach gave up for pid=\(pid) after \(tries) tries"
                    + " (create err \(err.rawValue)) — reconcile poll covers it")
            return
        }
        retrying[pid] = tries
        hyprLog(.debug, .discovery, "AX observer attach failed pid=\(pid) (create err \(err.rawValue))"
                + (tries == 1 ? " — retrying in 2s, then on later polls" : " — retrying on a later poll"))
        guard tries == 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            // app may have quit (detach cleared retrying) or attached since.
            guard self.retrying[pid] != nil, self.entries[pid] == nil else { return }
            self.attemptAttach(pid: pid)
        }
    }

    /// Route a raw AX notification (from the C callback) to `onEvent`, or a
    /// window move or resize to `onFrameChange` with the window's id. The
    /// firing element gives us the pid regardless of app- vs window-level.
    fileprivate func handle(notification: String, element: AXUIElement, observer: AXObserver) {
        if Self.isFrameChange(notification) {
            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(element, &wid) == .success else { return }
            routeFrameChange(notification: notification, windowID: wid)
            return
        }
        var pid: pid_t = 0
        let elementPID = AXUIElementGetPid(element, &pid) == .success ? pid : nil
        let observerPID = entries.first { CFEqual($0.value.observer, observer) }?.key
        route(notification: notification, elementPID: elementPID, observerPID: observerPID)
    }

    /// Pure routing seam used to pin event translation and unavailable AX
    /// metadata without constructing system-owned observer objects.
    func route(notification: String, elementPID: pid_t?, observerPID: pid_t?) {
        let kind: Kind
        switch notification {
        case kAXWindowCreatedNotification as String:        kind = .windowCreated
        case kAXUIElementDestroyedNotification as String:   kind = .windowDestroyed
        case kAXWindowMiniaturizedNotification as String:   kind = .windowMiniaturized
        case kAXWindowDeminiaturizedNotification as String: kind = .windowDeminiaturized
        case kAXFocusedWindowChangedNotification as String: kind = .focusedWindowChanged
        case kAXMainWindowChangedNotification as String:    kind = .mainWindowChanged
        default: return
        }
        guard let pid = elementPID ?? observerPID else { return }
        if kind == .windowDestroyed { entries[pid]?.ledger.noteDestroyEvent() }
        onEvent?(kind, pid)
    }
}

// non-capturing C callback — routes through the refcon back to the service.
// registered on the main run loop, so it fires on main.
private func axNotificationCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let service = Unmanaged<AXNotificationService>.fromOpaque(refcon).takeUnretainedValue()
    service.handle(notification: notification as String, element: element, observer: observer)
}
