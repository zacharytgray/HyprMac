// One request-scoped application activation pipeline shared by app-launch
// hotkeys and the Spotlight App Intent. It chooses one concrete window,
// prepares restorable windows before revealing them where macOS permits,
// and treats all asynchronous workspace/AX callbacks as hints rather than
// assuming they arrive in a particular order.

import Cocoa

enum ApplicationActivationSource: Equatable {
    case hotkey
    case spotlight
}

enum ApplicationActivationResult: Equatable {
    case activated(windowID: CGWindowID)
    case openedWithoutWindow
    case unavailable
    case timedOut
    case failed(String)
    case cancelled
}

/// Cancellation returned to async callers such as App Intents. Dropping a
/// handle does not cancel the request; cancellation must be explicit.
final class ApplicationActivationHandle {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?

    init(cancellation: @escaping () -> Void = {}) {
        self.cancellation = cancellation
    }

    func cancel() {
        lock.lock()
        let action = cancellation
        cancellation = nil
        lock.unlock()
        action?()
    }
}

protocol ApplicationActivating: AnyObject {
    @discardableResult
    func activate(bundleID: String,
                  source: ApplicationActivationSource,
                  completion: @escaping (ApplicationActivationResult) -> Void)
        -> ApplicationActivationHandle
}

protocol ApplicationActivationScheduledTask: AnyObject {
    func cancel()
}

private final class DispatchActivationTask: ApplicationActivationScheduledTask {
    private let item: DispatchWorkItem

    init(item: DispatchWorkItem) {
        self.item = item
    }

    func cancel() {
        item.cancel()
    }
}

struct ApplicationProcessSnapshot: Equatable {
    let pid: pid_t
    let isHidden: Bool
    let isActive: Bool
}

enum ApplicationOpenResult: Equatable {
    case opened(pid: pid_t)
    case failed(String)
}

/// All operating-system effects are injected. Besides keeping the coordinator
/// testable, this makes the safety boundary explicit: only bundle identifiers
/// resolved by Launch Services can be opened, and no shell/private launch hook
/// is involved.
struct ApplicationActivationEnvironment {
    var now: () -> TimeInterval
    var application: (_ bundleID: String, _ preferredPID: pid_t?) -> ApplicationProcessSnapshot?
    var applicationURL: (_ bundleID: String) -> URL?
    var inventory: (_ pid: pid_t) -> ApplicationWindowInventory
    var openApplication: (_ url: URL, _ hidden: Bool,
                          _ completion: @escaping (ApplicationOpenResult) -> Void) -> Void
    var unhide: (_ pid: pid_t) -> Bool
    var unminimize: (_ pid: pid_t, _ windowID: CGWindowID) -> Bool
    var activate: (_ pid: pid_t) -> Bool
    var protectHiddenLaunch: (_ bundleID: String, _ timeout: TimeInterval)
        -> ApplicationLaunchVisibilityProtecting
    var schedule: (_ delay: TimeInterval, _ block: @escaping () -> Void)
        -> ApplicationActivationScheduledTask

    static func live(accessibility: AccessibilityManager,
                     workspace: NSWorkspace = .shared) -> Self {
        Self(
            now: { ProcessInfo.processInfo.systemUptime },
            application: { bundleID, preferredPID in
                let apps = NSRunningApplication.runningApplications(
                    withBundleIdentifier: bundleID
                ).filter { !$0.isTerminated }
                let selected: NSRunningApplication?
                if let preferredPID {
                    // Once a request owns a process, never silently migrate
                    // to a second instance of the same application.
                    selected = apps.first { $0.processIdentifier == preferredPID }
                } else {
                    selected = apps.sorted {
                        if $0.isActive != $1.isActive { return $0.isActive }
                        if $0.isHidden != $1.isHidden { return !$0.isHidden }
                        return $0.processIdentifier < $1.processIdentifier
                    }.first
                }
                guard let selected else { return nil }
                return ApplicationProcessSnapshot(
                    pid: selected.processIdentifier,
                    isHidden: selected.isHidden,
                    isActive: selected.isActive
                )
            },
            applicationURL: { workspace.urlForApplication(withBundleIdentifier: $0) },
            inventory: { accessibility.activationWindowInventory(for: $0) },
            openApplication: { url, hidden, completion in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = !hidden
                configuration.hides = hidden
                // Keep the safe defaults: never create a second app instance,
                // never hide other apps, and prompt if macOS requires consent.
                workspace.openApplication(at: url, configuration: configuration) { app, error in
                    DispatchQueue.main.async {
                        if let error {
                            completion(.failed(error.localizedDescription))
                        } else if let app {
                            completion(.opened(pid: app.processIdentifier))
                        } else {
                            completion(.failed("Launch Services returned no application"))
                        }
                    }
                }
            },
            unhide: { NSRunningApplication(processIdentifier: $0)?.unhide() ?? false },
            unminimize: { pid, windowID in
                guard let window = accessibility.activationWindows(
                    for: pid, matching: [windowID]
                ).first else { return false }
                return AXUIElementSetAttributeValue(
                    window.element,
                    kAXMinimizedAttribute as CFString,
                    kCFBooleanFalse
                ) == .success
            },
            activate: { pid in
                NSRunningApplication(processIdentifier: pid)?
                    .activate(options: [.activateIgnoringOtherApps]) ?? false
            },
            protectHiddenLaunch: { bundleID, timeout in
                ApplicationLaunchVisibilityGuard(bundleID: bundleID, timeout: timeout)
            },
            schedule: { delay, block in
                let item = DispatchWorkItem(block: block)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
                return DispatchActivationTask(item: item)
            }
        )
    }
}

enum ApplicationActivationClaim: Equatable {
    /// The activation belongs to the in-flight request (or its short focus
    /// tail), so WindowManager must skip the ordinary Dock-workspace path.
    case claimed
    /// A different app became active. The
    /// request was cancelled, and the event should continue normally.
    case cancelledForUserOverride
    case unrelated
}

/// Serializes foreground ownership into one cancellable workflow.
///
/// macOS does not expose a public pre-map hook for other applications. The
/// cold-launch path therefore uses `NSWorkspace.OpenConfiguration.hides` as
/// a best-effort preparation window, validates through AX, and always fails
/// open with an independent visibility backstop. Existing visible
/// applications are never hidden.
final class ApplicationActivationCoordinator: ApplicationActivating {
    enum Phase: String {
        case reservingSpace
        case waitingForProcess
        case waitingForWindows
        case settlingWindows
        case preparingWindows
        case waitingForDiscovery
        case routingWindow
    }

    private final class Request {
        let id: UInt64
        let bundleID: String
        let source: ApplicationActivationSource
        let startedAt: TimeInterval
        var coldLaunch: Bool
        var phase: Phase
        var pid: pid_t?
        var selectedWindowID: CGWindowID?
        var subscribers: [UUID: (ApplicationActivationResult) -> Void]
        var openIssued = false
        var restoreIssued = false
        var processSeenAt: TimeInterval?
        var reopenIssuedAt: TimeInterval?
        var firstWindowAt: TimeInterval?
        var lastDiscoveryRequestAt: TimeInterval = -.infinity
        var visibilityGuard: ApplicationLaunchVisibilityProtecting?
        var probeTask: ApplicationActivationScheduledTask?
        var settleTask: ApplicationActivationScheduledTask?
        var timeoutTask: ApplicationActivationScheduledTask?

        init(id: UInt64,
             bundleID: String,
             source: ApplicationActivationSource,
             startedAt: TimeInterval,
             coldLaunch: Bool,
             subscriberID: UUID,
             completion: @escaping (ApplicationActivationResult) -> Void) {
            self.id = id
            self.bundleID = bundleID
            self.source = source
            self.startedAt = startedAt
            self.coldLaunch = coldLaunch
            self.phase = coldLaunch ? .waitingForProcess : .waitingForWindows
            self.subscribers = [subscriberID: completion]
        }
    }

    private struct FocusClaim {
        let requestID: UInt64
        let pid: pid_t
        let startedAt: TimeInterval
        let expiresAt: TimeInterval
    }

    private let environment: ApplicationActivationEnvironment
    private let hardTimeout: TimeInterval
    private let windowQuietPeriod: TimeInterval
    private let windowBurstCap: TimeInterval
    private let noWindowGrace: TimeInterval
    private var nextRequestID: UInt64 = 0
    private var current: Request?
    private var focusClaim: FocusClaim?

    /// Runs the ordinary discovery/apply/tiling path with the selected app's
    /// currently non-visible windows included. Returns true only when every
    /// requested addressable window could be represented and safely laid out.
    var prepareWindowsForReveal: (_ pid: pid_t, _ windowIDs: Set<CGWindowID>,
                                  _ selectedWindowID: CGWindowID) -> Bool = { _, _, _ in false }

    /// Reserve one predicted tile and let existing siblings accept their
    /// new frames before Launch Services sees the cold-launch request.
    /// Completion is bounded by the coordinator's overall timeout.
    var reserveSpaceBeforeLaunch: (_ bundleID: String, _ requestID: UInt64,
                                   _ completion: @escaping () -> Void) -> Void = { _, _, done in done() }

    /// Release the speculative gap on every terminal path. The layout owner
    /// reflows current state, never restores an obsolete workspace snapshot.
    var finishLaunchReservation: (_ requestID: UInt64,
                                  _ result: ApplicationActivationResult) -> Void = { _, _ in }

    /// Route one exact, already prepared window through workspace/scratchpad
    /// ownership and focus. `requestID` guards HyprWindow's delayed focus
    /// reassertion against a later user override.
    var routeWindow: (_ pid: pid_t, _ windowID: CGWindowID, _ requestID: UInt64) -> Bool = { _, _, _ in false }

    /// Request a normal coalesced discovery pass after restore/reveal events.
    var requestDiscovery: (_ delay: TimeInterval) -> Void = { _ in }

    /// HyprMac's own focus history breaks AX main/focused ties without using
    /// unstable enumeration order.
    var lastFocusedWindowID: () -> CGWindowID = { 0 }

    /// Prevents an App Intent from launching anything while HyprMac is
    /// disabled, stopping, or still waiting for Accessibility permission.
    var isAvailable: () -> Bool = { true }

    init(environment: ApplicationActivationEnvironment,
         hardTimeout: TimeInterval = 3.0,
         windowQuietPeriod: TimeInterval = 0.12,
         windowBurstCap: TimeInterval = 0.55,
         noWindowGrace: TimeInterval = 0.6) {
        self.environment = environment
        self.hardTimeout = hardTimeout
        self.windowQuietPeriod = windowQuietPeriod
        self.windowBurstCap = windowBurstCap
        self.noWindowGrace = noWindowGrace
    }

    convenience init(accessibility: AccessibilityManager) {
        self.init(environment: .live(accessibility: accessibility))
    }

    @discardableResult
    func activate(bundleID: String,
                  source: ApplicationActivationSource,
                  completion: @escaping (ApplicationActivationResult) -> Void)
        -> ApplicationActivationHandle {
        mainThreadOnly()

        let normalized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let subscriberID = UUID()
        guard isAvailable(), !normalized.isEmpty, normalized.utf8.count <= 1024,
              let url = environment.applicationURL(normalized) else {
            // A newer user request supersedes the previous focus intent
            // even when its saved application has since been uninstalled.
            finishCurrent(with: .cancelled)
            focusClaim = nil
            completion(.unavailable)
            return ApplicationActivationHandle()
        }

        if let request = current, request.bundleID == normalized {
            request.subscribers[subscriberID] = completion
            if request.phase != .reservingSpace { scheduleProbe(for: request, after: 0) }
            return handle(for: request.id, subscriberID: subscriberID)
        }

        finishCurrent(with: .cancelled)
        focusClaim = nil
        nextRequestID &+= 1

        let process = environment.application(normalized, nil)
        let request = Request(
            id: nextRequestID,
            bundleID: normalized,
            source: source,
            startedAt: environment.now(),
            coldLaunch: process == nil,
            subscriberID: subscriberID,
            completion: completion
        )
        request.pid = process?.pid
        request.processSeenAt = process == nil ? nil : environment.now()
        current = request
        let requestID = request.id
        request.timeoutTask = environment.schedule(hardTimeout) { [weak self] in
            self?.timeout(requestID: requestID)
        }

        if process == nil {
            request.phase = .reservingSpace
            reserveSpaceBeforeLaunch(normalized, request.id) { [weak self, weak request] in
                guard let self, let request,
                      self.current === request, !request.openIssued else { return }
                // Let already-queued user input cancel after preflow and
                // before the irreversible request to start another app.
                request.probeTask = self.environment.schedule(0) { [weak self, weak request] in
                    guard let self, let request else { return }
                    self.beginColdLaunch(request, url: url)
                }
            }
        } else {
            progress(request)
        }

        return handle(for: request.id, subscriberID: subscriberID)
    }

    /// Called before WindowManager applies its ordinary activation affordance.
    @discardableResult
    func noteApplicationActivated(bundleID: String?, pid: pid_t) -> ApplicationActivationClaim {
        mainThreadOnly()
        let now = environment.now()

        if let request = current {
            if matches(request, bundleID: bundleID, pid: pid) {
                request.pid = pid
                request.processSeenAt = request.processSeenAt ?? now
                if request.phase != .reservingSpace { scheduleProbe(for: request, after: 0) }
                return .claimed
            }

            finish(request, with: .cancelled, keepFocusClaim: false)
            return .cancelledForUserOverride
        }

        if let claim = focusClaim {
            if now > claim.expiresAt {
                focusClaim = nil
            } else if pid == claim.pid {
                return .claimed
            } else {
                focusClaim = nil
            }
        }
        return .unrelated
    }

    func noteApplicationLaunched(bundleID: String?, pid: pid_t) {
        mainThreadOnly()
        guard let request = current,
              matches(request, bundleID: bundleID, pid: pid) else { return }
        request.pid = pid
        request.processSeenAt = request.processSeenAt ?? environment.now()
        requestDiscovery(0)
        if request.phase != .reservingSpace { scheduleProbe(for: request, after: 0) }
    }

    func noteApplicationTerminated(bundleID: String?, pid: pid_t) {
        mainThreadOnly()
        guard let request = current,
              matches(request, bundleID: bundleID, pid: pid) else { return }
        finish(request, with: .failed("The application quit while opening"), keepFocusClaim: false)
    }

    func noteAXEvent(pid: pid_t) {
        mainThreadOnly()
        guard let request = current, request.pid == pid,
              request.phase != .reservingSpace else { return }
        requestDiscovery(0)
        scheduleProbe(for: request, after: 0.03)
    }

    /// Called after discovery has updated workspace and cache ownership.
    func noteDiscoveryCompleted() {
        mainThreadOnly()
        guard let request = current, request.phase == .waitingForDiscovery else { return }
        // A failed route must not make poll -> probe -> poll a zero-delay
        // loop while CG/AX still reports a restored window as off-screen.
        scheduleProbe(for: request, after: 0.04)
    }

    /// Explicit user input invalidates both the in-flight request and the
    /// delayed focus reassertion tail of a completed request.
    func cancelForUserOverride(eventTimestamp: TimeInterval? = nil) {
        mainThreadOnly()
        // The Return/click that triggered a Spotlight intent may reach our
        // main queue after that intent. Its original uptime timestamp keeps
        // that older input from cancelling the action it just requested.
        if let eventTimestamp, eventTimestamp > 0,
           let startedAt = current?.startedAt ?? focusClaim?.startedAt,
           eventTimestamp < startedAt { return }
        focusClaim = nil
        finishCurrent(with: .cancelled)
    }

    func stop() {
        mainThreadOnly()
        focusClaim = nil
        finishCurrent(with: .cancelled)
    }

    func allowsFocusReassertion(for requestID: UInt64) -> Bool {
        mainThreadOnly()
        if current?.id == requestID { return true }
        guard let claim = focusClaim, claim.requestID == requestID else { return false }
        if environment.now() <= claim.expiresAt { return true }
        focusClaim = nil
        return false
    }

    // MARK: - state progression

    private func beginColdLaunch(_ request: Request, url: URL) {
        guard current === request, !request.openIssued else { return }
        request.phase = .waitingForProcess
        // The user/system may have started the same app during preflow.
        // Never apply the hidden-launch configuration to an existing app.
        if let process = environment.application(request.bundleID, request.pid) {
            request.coldLaunch = false
            request.pid = process.pid
            request.processSeenAt = request.processSeenAt ?? environment.now()
            finishLaunchReservation(request.id, .openedWithoutWindow)
            progress(request)
            return
        }

        request.openIssued = true
        let remaining = max(0, hardTimeout - (environment.now() - request.startedAt))
        let visibilityGuard = environment.protectHiddenLaunch(request.bundleID, remaining)
        request.visibilityGuard = visibilityGuard
        environment.openApplication(url, true) { [weak self] result in
            // Cleanup outlives cancellation and the coordinator itself.
            if case .opened(let pid) = result { visibilityGuard.applicationOpened(pid: pid) }
            self?.handleOpenResult(result, request: request)
        }
    }

    private func progress(_ request: Request) {
        guard current === request, request.phase != .reservingSpace else { return }
        guard let process = environment.application(request.bundleID, request.pid) else {
            request.phase = .waitingForProcess
            scheduleProbe(for: request, after: 0.05)
            return
        }
        request.pid = process.pid
        request.processSeenAt = request.processSeenAt ?? environment.now()
        relinquishVisibilityProtectionIfRevealed(request, process: process)

        switch environment.inventory(process.pid) {
        case .unavailable:
            // Unknown is not empty. For an existing app, fail safely by
            // activating it; for a deliberately hidden cold launch, keep
            // probing until the fail-open watchdog reveals it.
            if request.coldLaunch && process.isHidden {
                request.phase = .waitingForWindows
                scheduleProbe(for: request, after: 0.06)
            } else {
                if process.isHidden { _ = environment.unhide(process.pid) }
                _ = environment.activate(process.pid)
                finish(request, with: .openedWithoutWindow)
            }

        case .available(let windows, let hasUnaddressableWindows):
            if hasUnaddressableWindows {
                // Let the app itself choose its modal/utility window. A
                // standard document must not be raised over a dialog.
                failOpen(request, process: process, result: .openedWithoutWindow)
                return
            }
            if windows.isEmpty {
                handleConfirmedNoWindows(request, process: process)
                return
            }

            let selected = selectedWindow(for: request, from: windows)

            if request.coldLaunch, !process.isHidden, !request.restoreIssued {
                // Some apps ignore hides=true. Release the gap and let the
                // normal visible discovery path take over; never hide again.
                finishLaunchReservation(request.id, .openedWithoutWindow)
            }

            if request.coldLaunch && process.isHidden && !request.restoreIssued {
                settleColdLaunch(request, windows: windows)
            } else if process.isHidden || selected.isMinimized {
                restoreExisting(request, process: process, windows: windows, selected: selected)
            } else {
                route(request, process: process, windowID: selected.windowID)
            }
        }
    }

    private func handleConfirmedNoWindows(_ request: Request,
                                          process: ApplicationProcessSnapshot) {
        if request.coldLaunch {
            // The process exists but may not have completed restoration yet.
            if environment.now() - (request.processSeenAt ?? environment.now()) < noWindowGrace {
                request.phase = .waitingForWindows
                scheduleProbe(for: request, after: 0.06)
            } else {
                failOpen(request, process: process, result: .openedWithoutWindow)
            }
            return
        }

        if !request.openIssued {
            guard let url = environment.applicationURL(request.bundleID) else {
                finish(request, with: .unavailable, keepFocusClaim: false)
                return
            }
            request.openIssued = true
            request.reopenIssuedAt = environment.now()
            request.phase = .waitingForWindows
            environment.openApplication(url, false) { [weak self] result in
                self?.handleOpenResult(result, request: request)
            }
            return
        }

        if environment.now() - (request.reopenIssuedAt ?? request.startedAt) >= noWindowGrace {
            _ = environment.activate(process.pid)
            finish(request, with: .openedWithoutWindow)
        } else {
            scheduleProbe(for: request, after: 0.06)
        }
    }

    private func settleColdLaunch(_ request: Request,
                                  windows: [ApplicationWindowCandidate]) {
        let now = environment.now()
        if request.firstWindowAt == nil { request.firstWindowAt = now }
        request.phase = .settlingWindows
        request.settleTask?.cancel()

        let elapsed = now - (request.firstWindowAt ?? now)
        let delay = elapsed >= windowBurstCap ? 0 : windowQuietPeriod
        request.settleTask = environment.schedule(delay) { [weak self, weak request] in
            guard let self, let request, self.current === request else { return }
            guard let process = self.environment.application(request.bundleID, request.pid) else {
                self.scheduleProbe(for: request, after: 0.05)
                return
            }
            switch self.environment.inventory(process.pid) {
            case .unavailable:
                self.scheduleProbe(for: request, after: 0.05)
            case .available(let latest, let hasUnaddressable):
                guard !latest.isEmpty, !hasUnaddressable else {
                    self.failOpen(request, process: process, result: .openedWithoutWindow)
                    return
                }
                self.prepareAndReveal(request, process: process, windows: latest)
            }
        }
        _ = windows // the latest inventory is intentionally reread after quiet.
    }

    private func prepareAndReveal(_ request: Request,
                                  process: ApplicationProcessSnapshot,
                                  windows: [ApplicationWindowCandidate]) {
        guard current === request else { return }
        request.phase = .preparingWindows
        let selected = selectedWindow(for: request, from: windows)
        let ids = revealWindowIDs(windows, selectedWindowID: selected.windowID)

        // Preparation is best-effort. Even when an app rejects geometry,
        // reveal it and continue to exact-window routing, never strand it.
        if !prepareWindowsForReveal(process.pid, ids, selected.windowID) {
            finishLaunchReservation(request.id, .openedWithoutWindow)
        }

        // The app is allowed to ignore the initial hide request. Never fight
        // it by hiding again; simply fall back to the visible path.
        let latest = environment.application(request.bundleID, process.pid) ?? process
        relinquishVisibilityProtectionIfRevealed(request, process: latest)
        if latest.isHidden {
            _ = environment.unhide(process.pid)
        }
        if selected.isMinimized {
            _ = environment.unminimize(process.pid, selected.windowID)
        }
        request.restoreIssued = true
        request.phase = .waitingForDiscovery
        requestDiscovery(0)
        scheduleProbe(for: request, after: 0.04)
    }

    private func restoreExisting(_ request: Request,
                                 process: ApplicationProcessSnapshot,
                                 windows: [ApplicationWindowCandidate],
                                 selected: ApplicationWindowCandidate) {
        guard !request.restoreIssued else {
            // AX state changes are asynchronous. Do not focus a window while
            // it is still reported hidden/minimized; the hard deadline remains
            // the fail-open backstop if an app ignores the restore request.
            request.phase = .waitingForDiscovery
            scheduleProbe(for: request, after: 0.05)
            return
        }
        request.restoreIssued = true

        // A hidden app reveals all its windows, so prepare every addressable
        // one. A visible app with one minimized target prepares only that one
        // and never disturbs its other windows.
        let ids: Set<CGWindowID> = process.isHidden
            ? revealWindowIDs(windows, selectedWindowID: selected.windowID)
            : [selected.windowID]
        _ = prepareWindowsForReveal(process.pid, ids, selected.windowID)
        if process.isHidden { _ = environment.unhide(process.pid) }
        if selected.isMinimized { _ = environment.unminimize(process.pid, selected.windowID) }
        request.phase = .waitingForDiscovery
        requestDiscovery(0)
        scheduleProbe(for: request, after: 0.04)
    }

    private func route(_ request: Request,
                       process: ApplicationProcessSnapshot,
                       windowID: CGWindowID) {
        guard current === request else { return }
        request.phase = .routingWindow
        guard routeWindow(process.pid, windowID, request.id) else {
            request.phase = .waitingForDiscovery
            if environment.now() - request.lastDiscoveryRequestAt >= 0.12 {
                request.lastDiscoveryRequestAt = environment.now()
                requestDiscovery(0.06)
            }
            scheduleProbe(for: request, after: 0.08)
            return
        }
        finish(request, with: .activated(windowID: windowID))
    }

    private func failOpen(_ request: Request,
                          process: ApplicationProcessSnapshot,
                          result: ApplicationActivationResult) {
        guard current === request else { return }
        if process.isHidden { _ = environment.unhide(process.pid) }
        _ = environment.activate(process.pid)
        requestDiscovery(0)
        finish(request, with: result)
    }

    private func selectedWindow(for request: Request,
                                from windows: [ApplicationWindowCandidate])
        -> ApplicationWindowCandidate {
        if let selectedID = request.selectedWindowID,
           let selected = windows.first(where: { $0.windowID == selectedID }) {
            return selected
        }
        let lastFocused = lastFocusedWindowID()
        let selected = windows.min { lhs, rhs in
            let left = (
                lhs.isMinimized ? 1 : 0,
                lhs.windowID == lastFocused ? 0 : 1,
                lhs.isFocused ? 0 : 1,
                lhs.isMain ? 0 : 1,
                lhs.windowID
            )
            let right = (
                rhs.isMinimized ? 1 : 0,
                rhs.windowID == lastFocused ? 0 : 1,
                rhs.isFocused ? 0 : 1,
                rhs.isMain ? 0 : 1,
                rhs.windowID
            )
            return left < right
        }!
        request.selectedWindowID = selected.windowID
        return selected
    }

    private func revealWindowIDs(_ windows: [ApplicationWindowCandidate],
                                 selectedWindowID: CGWindowID) -> Set<CGWindowID> {
        // Cmd-H reveals the app's non-minimized windows, not every document
        // in its Dock stack. Only the chosen minimized window gets a slot.
        Set(windows.lazy.filter { !$0.isMinimized || $0.windowID == selectedWindowID }.map(\.windowID))
    }

    private func matches(_ request: Request, bundleID: String?, pid: pid_t) -> Bool {
        if let expectedPID = request.pid { return pid == expectedPID }
        return bundleID == request.bundleID
    }

    private func relinquishVisibilityProtectionIfRevealed(
        _ request: Request, process: ApplicationProcessSnapshot
    ) {
        guard !process.isHidden else { return }
        // Once visible, ownership is permanently released. A late launch
        // callback must not undo a subsequent deliberate Cmd-H by the user.
        request.visibilityGuard?.disarmAfterObservedReveal()
        request.visibilityGuard = nil
    }

    private func handleOpenResult(_ result: ApplicationOpenResult, request: Request) {
        mainThreadOnly()
        guard current === request else {
            // Never activate a stale launch: the user may already be typing
            // in a different app. Only undo our own hidden-launch request.
            request.visibilityGuard?.finish()
            if request.visibilityGuard != nil, case .opened(let pid) = result {
                _ = environment.unhide(pid)
            }
            return
        }
        switch result {
        case .opened(let pid):
            if let expectedPID = request.pid, expectedPID != pid {
                if request.visibilityGuard != nil { _ = environment.unhide(pid) }
                finish(request, with: .failed("Launch Services returned a different application process"),
                       keepFocusClaim: false)
                return
            }
            request.pid = pid
            request.processSeenAt = request.processSeenAt ?? environment.now()
            requestDiscovery(0)
            scheduleProbe(for: request, after: 0)
        case .failed(let message):
            finish(request, with: .failed(message), keepFocusClaim: false)
        }
    }

    private func scheduleProbe(for request: Request, after delay: TimeInterval) {
        guard current === request else { return }
        request.probeTask?.cancel()
        request.probeTask = environment.schedule(delay) { [weak self, weak request] in
            guard let self, let request, self.current === request else { return }
            request.probeTask = nil
            self.progress(request)
        }
    }

    private func timeout(requestID: UInt64) {
        mainThreadOnly()
        guard let request = current, request.id == requestID else { return }
        if request.phase != .reservingSpace,
           let process = environment.application(request.bundleID, request.pid) {
            request.pid = process.pid
            if process.isHidden { _ = environment.unhide(process.pid) }
            _ = environment.activate(process.pid)
            requestDiscovery(0)
        }
        finish(request, with: .timedOut, keepFocusClaim: false)
    }

    private func handle(for requestID: UInt64, subscriberID: UUID)
        -> ApplicationActivationHandle {
        ApplicationActivationHandle { [weak self] in
            let cancel: () -> Void = { [weak self] in
                self?.cancelSubscriber(requestID: requestID, subscriberID: subscriberID)
            }
            if Thread.isMainThread { cancel() } else { DispatchQueue.main.async(execute: cancel) }
        }
    }

    private func cancelSubscriber(requestID: UInt64, subscriberID: UUID) {
        mainThreadOnly()
        guard let request = current, request.id == requestID,
              let completion = request.subscribers.removeValue(forKey: subscriberID) else { return }
        if request.subscribers.isEmpty {
            finish(request, with: .cancelled, keepFocusClaim: false)
        }
        deliver([completion], result: .cancelled)
    }

    private func finishCurrent(with result: ApplicationActivationResult) {
        guard let request = current else { return }
        finish(request, with: result, keepFocusClaim: false)
    }

    private func finish(_ request: Request,
                        with result: ApplicationActivationResult,
                        keepFocusClaim: Bool = true) {
        guard current === request else { return }
        current = nil
        request.probeTask?.cancel()
        request.settleTask?.cancel()
        request.timeoutTask?.cancel()
        // Release completed scheduling state on every exit. Timer closures
        // also hold the request weakly if the coordinator is torn down early.
        request.probeTask = nil
        request.settleTask = nil
        request.timeoutTask = nil
        if let process = environment.application(request.bundleID, request.pid) {
            relinquishVisibilityProtectionIfRevealed(request, process: process)
            if request.visibilityGuard != nil, process.isHidden {
                _ = environment.unhide(process.pid)
            }
        }
        request.visibilityGuard?.finish()
        finishLaunchReservation(request.id, result)

        if keepFocusClaim, let pid = request.pid {
            focusClaim = FocusClaim(
                requestID: request.id,
                pid: pid,
                startedAt: request.startedAt,
                expiresAt: environment.now() + 0.35
            )
        } else {
            focusClaim = nil
        }

        let completions = Array(request.subscribers.values)
        request.subscribers.removeAll()
        deliver(completions, result: result)
    }

    private func deliver(_ completions: [(ApplicationActivationResult) -> Void],
                         result: ApplicationActivationResult) {
        guard !completions.isEmpty else { return }
        // State transitions commit before client callbacks run. A callback
        // may start another activation without orphaning its request.
        _ = environment.schedule(0) { completions.forEach { $0(result) } }
    }
}
