// Per-app AXObserver fan-out: one observer per regular app, delivering
// window create / destroy / miniaturize / focus notifications on the main
// run loop. These are the primary discovery triggers now — the polling
// scheduler's timer is a slow reconcile safety net (see PollingScheduler).

import Cocoa

/// Owns one `AXObserver` per regular running app and routes their AX
/// notifications into a single `onEvent` sink.
///
/// This is the event-driven front end for discovery. Instead of a 1 Hz
/// full-desktop AX walk, each app tells us when its windows appear,
/// vanish, minimize, or take focus; `WindowManager` funnels every event
/// into the existing coalescing `PollingScheduler.schedule(after:)` so the
/// real discovery diff (`getAllWindows` → `computeChanges` → `applyChanges`)
/// runs only when something actually changed. Same architecture as
/// yabai / AeroSpace.
///
/// App-level subscriptions (`kAXWindowCreated`, `kAXFocusedWindowChanged`)
/// go on the app element and cover the app's whole lifetime. Window-level
/// subscriptions (`kAXUIElementDestroyed`, `kAXWindowMiniaturized`,
/// `kAXWindowDeminiaturized`) go on each window element and are attached
/// lazily via `ensureWindowSubscriptions(for:)` after every discovery pass,
/// deduped by `CGWindowID`.
///
/// Ownership: `AXObserver` and `AXUIElement` are CF types held by ARC in the
/// per-pid `Entry`, so dropping the entry on `detach` releases them; the run
/// loop source is removed explicitly first.
///
/// Threading: main-thread only. `AXObserverGetRunLoopSource` is added to the
/// main run loop, so every callback lands on main by construction.
final class AXNotificationService {

    /// The AX notifications we translate and forward. Each maps to one or
    /// more `kAX…Notification` strings on the app or window element.
    enum Kind {
        case windowCreated
        case windowDestroyed
        case windowMiniaturized
        case windowDeminiaturized
        case focusedWindowChanged
    }

    /// Sink for every translated notification. `pid` is the app the event
    /// belongs to (derived from the firing element). Set by `WindowManager`
    /// to route into the polling scheduler.
    var onEvent: ((Kind, pid_t) -> Void)?

    // per-pid observer + its window-level subscription bookkeeping.
    // the observer and app/window elements are CF types retained by ARC
    // through these stored properties; releasing the entry releases them.
    private final class Entry {
        let observer: AXObserver
        let appElement: AXUIElement
        // window ids we've already subscribed at the window level, deduped.
        var subscribedWindowIDs: Set<CGWindowID> = []
        // retain the window elements we subscribed to — HyprWindow may be
        // released between passes, but the observer needs a live element.
        var windowElements: [CGWindowID: AXUIElement] = [:]

        init(observer: AXObserver, appElement: AXUIElement) {
            self.observer = observer
            self.appElement = appElement
        }
    }

    private var entries: [pid_t: Entry] = [:]
    // pids whose first attach failed and are waiting on their single retry.
    // guards attach() against re-entry while the retry is pending.
    private var retrying: Set<pid_t> = []

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
        guard entries[pid] == nil, !retrying.contains(pid) else { return }
        attemptAttach(pid: pid)
    }

    /// Detach `pid`: remove its run loop source and drop all bookkeeping.
    /// ARC releases the observer and retained elements.
    func detach(pid: pid_t) {
        mainThreadOnly()
        retrying.remove(pid)
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
    /// Deduped by `CGWindowID`. Stale ids (windows since closed) are not
    /// pruned here — a minimized window legitimately leaves the snapshot but
    /// must keep its deminiaturize subscription, so snapshot presence can't
    /// gate removal. `detach` prunes a pid's bookkeeping wholesale on quit.
    func ensureWindowSubscriptions(for snapshot: [HyprWindow]) {
        mainThreadOnly()
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for window in snapshot {
            guard let entry = entries[window.ownerPID] else { continue }
            let wid = window.windowID
            guard !entry.subscribedWindowIDs.contains(wid) else { continue }

            let element = window.element
            AXObserverAddNotification(entry.observer, element, kAXUIElementDestroyedNotification as CFString, refcon)
            AXObserverAddNotification(entry.observer, element, kAXWindowMiniaturizedNotification as CFString, refcon)
            AXObserverAddNotification(entry.observer, element, kAXWindowDeminiaturizedNotification as CFString, refcon)

            entry.subscribedWindowIDs.insert(wid)
            entry.windowElements[wid] = element
        }
    }

    // MARK: - internals

    private func attemptAttach(pid: pid_t) {
        var observer: AXObserver?
        let createErr = AXObserverCreate(pid, axNotificationCallback, &observer)
        guard createErr == .success, let observer else {
            handleAttachFailure(pid: pid, stage: "create", err: createErr)
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let createdErr = AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, refcon)
        let focusedErr = AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)

        // a newly launched app may not be AX-ready — treat "subscribed to
        // nothing" as a failure and let the retry catch it once.
        guard createdErr == .success || focusedErr == .success else {
            handleAttachFailure(pid: pid, stage: "add", err: createdErr == .success ? focusedErr : createdErr)
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        entries[pid] = Entry(observer: observer, appElement: appElement)
        retrying.remove(pid)
        hyprLog(.debug, .discovery, "AX observer attached pid=\(pid)")
    }

    private func handleAttachFailure(pid: pid_t, stage: String, err: AXError) {
        if retrying.contains(pid) {
            // already retried once — give up quietly. the 10s reconcile poll
            // is the safety net for apps that refuse observers.
            retrying.remove(pid)
            hyprLog(.notice, .discovery, "AX observer attach gave up for pid=\(pid) after retry (\(stage) err \(err.rawValue)) — reconcile poll covers it")
            return
        }
        retrying.insert(pid)
        hyprLog(.debug, .discovery, "AX observer attach failed pid=\(pid) (\(stage) err \(err.rawValue)) — retrying in 2s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            // app may have quit (detach cleared retrying) or attached since.
            guard self.retrying.contains(pid), self.entries[pid] == nil else { return }
            self.attemptAttach(pid: pid)
        }
    }

    /// Route a raw AX notification (from the C callback) to `onEvent`. The
    /// firing element gives us the pid regardless of app- vs window-level.
    fileprivate func handle(notification: String, element: AXUIElement) {
        let kind: Kind
        switch notification {
        case kAXWindowCreatedNotification as String:        kind = .windowCreated
        case kAXUIElementDestroyedNotification as String:   kind = .windowDestroyed
        case kAXWindowMiniaturizedNotification as String:   kind = .windowMiniaturized
        case kAXWindowDeminiaturizedNotification as String: kind = .windowDeminiaturized
        case kAXFocusedWindowChangedNotification as String: kind = .focusedWindowChanged
        default: return
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return }
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
    service.handle(notification: notification as String, element: element)
}
