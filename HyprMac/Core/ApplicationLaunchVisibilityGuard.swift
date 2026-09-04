// Independent, bounded cleanup for an application launched with `hides=true`.

import AppKit
import Foundation

protocol ApplicationLaunchVisibilityProtecting: AnyObject {
    func applicationOpened(pid: pid_t)
    func finish()
    func disarmAfterObservedReveal()
}

/// Small process boundary so cleanup can be tested without manipulating apps.
protocol ApplicationLaunchVisibilityProcess: AnyObject {
    var bundleIdentifier: String? { get }
    var isTerminated: Bool { get }
    var isHidden: Bool { get }
    func unhide() -> Bool
    func isSameProcess(as other: ApplicationLaunchVisibilityProcess) -> Bool
}

extension NSRunningApplication: ApplicationLaunchVisibilityProcess {
    func isSameProcess(as other: ApplicationLaunchVisibilityProcess) -> Bool {
        guard let other = other as? NSRunningApplication else { return false }
        return isEqual(other)
    }
}

/// Sends only public unhide requests; it never activates, minimizes, or hides.
///
/// The coordinator's main queue can be busy in synchronous AX calls. This
/// small backstop therefore owns a separate serial queue and uses the public,
/// thread-safe `NSRunningApplication` API, not off-main AX/AppKit view access.
/// Apple documents that its changing properties are main-run-loop snapshots:
/// a successful request is not proof of visibility, and this is best-effort
/// cleanup, not a compositor guarantee or protection against process death.
/// An already-sent OS request cannot be recalled atomically by disarming.
///
/// Once the coordinator has observed a reveal, disarming is irreversible so
/// later Cmd-H is respected. A cancelled request with no PID remains eligible
/// for its late Launch Services completion, without polling indefinitely.
final class ApplicationLaunchVisibilityGuard: ApplicationLaunchVisibilityProtecting, @unchecked Sendable {
    struct Environment {
        // The inventory is read once at initialization and then on the
        // guard's serial queue; injected implementations must be thread-safe.
        var runningApplications: (String) -> [ApplicationLaunchVisibilityProcess]
        var applicationForPID: (pid_t) -> ApplicationLaunchVisibilityProcess?

        static let live = Environment(
            runningApplications: { NSRunningApplication.runningApplications(withBundleIdentifier: $0) },
            applicationForPID: { NSRunningApplication(processIdentifier: $0) }
        )
    }

    private let bundleID: String
    private let initialApplications: [ApplicationLaunchVisibilityProcess]
    private let environment: Environment
    private let queue: DispatchQueue
    private let maximumAttempts: Int
    private let retryInterval: TimeInterval
    private let revealLock = NSLock()
    private var observedReveal = false

    // Everything below is accessed only on `queue`.
    private var application: ApplicationLaunchVisibilityProcess?
    private var cleanupRequested = false
    private var terminal = false
    private var attempts = 0
    private var requestedUnhide = false
    private var deadlineTask: DispatchWorkItem?
    private var retryTask: DispatchWorkItem?

    init(bundleID: String, timeout: TimeInterval,
         environment: Environment = .live,
         queue: DispatchQueue = DispatchQueue(label: "com.zachgray.HyprMac.launch-visibility", qos: .userInitiated),
         maximumAttempts: Int = 8, retryInterval: TimeInterval = 0.15) {
        self.bundleID = bundleID
        self.environment = environment
        self.queue = queue
        self.maximumAttempts = max(1, maximumAttempts)
        self.retryInterval = retryInterval.isFinite ? max(0.001, retryInterval) : 0.15
        // Retain process identities, not just PIDs: a recycled PID must not
        // make cleanup operate on an unrelated pre-existing application.
        initialApplications = environment.runningApplications(bundleID)
        let delay = timeout.isFinite ? max(0, timeout) : 0
        let task = DispatchWorkItem { [self] in
            deadlineTask = nil
            // Early cancellation may have exhausted its discovery batch
            // before the launch exists. Keep this independent deadline too.
            if cleanupRequested, application == nil, !isDisarmed, !terminal {
                attempts = 0
                retryTask?.cancel()
                retryTask = nil
                attemptCleanup()
            } else {
                beginCleanup()
            }
        }
        deadlineTask = task
        queue.asyncAfter(deadline: .now() + delay, execute: task)
    }

    func applicationOpened(pid: pid_t) {
        queue.async { [self] in
            guard !isDisarmed, !terminal else { return }
            guard let opened = environment.applicationForPID(pid),
                  opened.bundleIdentifier == bundleID,
                  !initialApplications.contains(where: { $0.isSameProcess(as: opened) }) else { return }
            if let application, !application.isSameProcess(as: opened) { return }
            let wasUnresolved = application == nil
            application = opened
            // A late callback gets a fresh bounded cleanup budget only when
            // no process could be found during the previous attempt batch.
            if cleanupRequested, wasUnresolved {
                attempts = 0
                retryTask?.cancel()
                retryTask = nil
                attemptCleanup()
            }
        }
    }

    /// End the controlled phase, including cancellation and supersession.
    /// No foreground activation is performed when another user action won.
    func finish() {
        queue.async { [self] in
            guard !isDisarmed, !terminal else { return }
            beginCleanup()
        }
    }

    /// The main coordinator supplies the authoritative successful-reveal
    /// observation. Publish it synchronously before cancelling queued work.
    func disarmAfterObservedReveal() {
        revealLock.lock()
        observedReveal = true
        revealLock.unlock()
        queue.async { [self] in stopTasks() }
    }

    private var isDisarmed: Bool {
        revealLock.lock()
        defer { revealLock.unlock() }
        return observedReveal
    }

    private func beginCleanup() {
        guard !isDisarmed, !terminal, !cleanupRequested else { return }
        cleanupRequested = true
        attemptCleanup()
    }

    private func attemptCleanup() {
        guard !isDisarmed, !terminal else {
            stopTasks()
            return
        }
        attempts += 1
        if application == nil {
            let candidates = environment.runningApplications(bundleID)
                .filter { candidate in
                    !candidate.isTerminated
                        && !initialApplications.contains(where: { $0.isSameProcess(as: candidate) })
                }
            // Do not guess between concurrent instances. The exact open
            // completion can identify the intended process later.
            if candidates.count == 1 { application = candidates[0] }
        }

        if let application {
            if application.isTerminated {
                terminal = true
                stopTasks()
                return
            }
            if requestedUnhide && !application.isHidden {
                disarmAfterObservedReveal()
                return
            }
            guard !isDisarmed else { return }
            // NSRunningApplication is Sendable and documented thread-safe.
            // `unhide` sends a request and does not grant foreground focus.
            _ = application.unhide()
            requestedUnhide = true
        }

        guard attempts < maximumAttempts else {
            // With no process, retain only the ability to handle a late open
            // callback. With a known process, stop rather than fighting a
            // future manual hide after this bounded rescue window.
            terminal = application != nil
            retryTask = nil
            return
        }
        let task = DispatchWorkItem { [self] in
            retryTask = nil
            attemptCleanup()
        }
        retryTask = task
        queue.asyncAfter(deadline: .now() + retryInterval, execute: task)
    }

    private func stopTasks() {
        deadlineTask?.cancel()
        deadlineTask = nil
        retryTask?.cancel()
        retryTask = nil
    }
}
