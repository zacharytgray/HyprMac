// Slow reconcile timer plus the coalescing token that funnels
// event-driven polls down to one in-flight scheduled call.

import Foundation

/// What asked for a poll. Carried to the poll for its log lines.
enum PollTrigger: String {
    case event
    case reconcile
    case create
    case focus
    /// a focus or main-window event for an app with a window on screen that
    /// no poll has looked at yet
    case newWindow = "new-window"
    case followUp = "follow-up"
    case destroy
    case hold
    /// discovery's own look again: a window the walk saw but could not use
    /// yet (unbound, unreadable), a fixed-size re-check, or a stalled or
    /// skipped app's backoff running out. no event reports any of these
    case axRetry = "ax-retry"
    case recheck
    case activation
    case launch
    case terminate
    case visibility
    case park
    case reveal
    case drag

    /// polls that look for a window an app just announced. their deferrals
    /// log at notice, so a slow tile shows where the time went
    var looksForNewWindow: Bool {
        self == .create || self == .followUp || self == .newWindow
    }
}

/// Polling driver for `WindowDiscoveryService`.
///
/// Owns two scheduling primitives:
/// - A slow (10s) repeating timer that acts as a reconcile safety net —
///   it catches apps that refuse AX observers, notifications the observer
///   layer missed, and external moves nothing else reports. It is not the
///   primary discovery trigger.
/// - A `pendingPoll` flag that coalesces multiple event-driven
///   `schedule(after:)` requests in the same debounce window down to a
///   single fire. These come from `AXNotificationService` (window create /
///   destroy / miniaturize / focus) via `WindowManager` and are the
///   primary path — the timer only backstops them.
///
/// A trailing request (a window create) also keeps its own deadline when
/// an earlier pending poll would run first: that earlier poll can land
/// milliseconds after the create, before AX lists the window.
///
/// The discovery work itself is not in this class — the callback supplied
/// at construction (`onPoll`) does that. The `@objc` notification handlers
/// that trigger `schedule(after:)` stay on `WindowManager` because they
/// also do lifecycle cleanup (e.g. `appDidTerminate` calls `forgetApp`
/// before scheduling a poll).
///
/// Threading: main-thread only. The timer is scheduled on the main run
/// loop and `schedule(after:)` resolves on main via `asyncAfter`.
final class PollingScheduler {

    /// Reconcile-timer interval. A slow safety net: per-app AXObserver
    /// notifications drive discovery.
    static let defaultReconcileInterval: TimeInterval = 10.0
    /// How often a deferred fire asks the suppression again.
    static let deferStep: TimeInterval = 0.3
    /// A poll this close before a trailing deadline counts as that poll.
    static let trailingSlack: TimeInterval = 0.02

    /// The poll being run right now, read by `onPoll` for its log lines.
    struct Fire: Equatable {
        let triggers: [PollTrigger]
        /// ms from the first request this poll answers to its run
        let waitedMS: Int
        /// ms the poll spent deferred by a suppression
        let deferredMS: Int
        let deferredBy: String?

        var isReconcileOnly: Bool { triggers == [.reconcile] }

        var summary: String {
            var line = triggers.map(\.rawValue).joined(separator: "+") + ", waited \(waitedMS)ms"
            if let deferredBy, deferredMS > 0 { line += ", deferred \(deferredMS)ms by \(deferredBy)" }
            return line
        }
    }

    /// What a `schedule` call did, for the caller's log line.
    enum ScheduleOutcome: Equatable {
        /// a new poll, due in ms
        case armed(dueMS: Int)
        /// moved a pending poll up to this request's deadline
        case advanced(dueMS: Int)
        /// rides a pending poll; nil when that poll is deferred past its deadline
        case coalesced(pendingDueMS: Int?)
        /// a pending poll runs first and another is kept at this request's deadline
        case trailing(dueMS: Int, pendingDueMS: Int?)
        /// held until `start()`
        case beforeStart

        var description: String {
            func due(_ ms: Int?) -> String { ms.map { "due in \($0)ms" } ?? "deferred" }
            switch self {
            case .armed(let ms): return "poll due in \(ms)ms"
            case .advanced(let ms): return "pending poll moved up, due in \(ms)ms"
            case .coalesced(let ms): return "rides the pending poll (\(due(ms)))"
            case .trailing(let ms, let pending):
                return "pending poll (\(due(pending))) kept, trailing poll due in \(ms)ms"
            case .beforeStart: return "held until startup"
            }
        }
    }

    private let periodicInterval: TimeInterval
    private var timer: Timer?
    private var isStarted = false
    private var pendingPoll = false
    private var pendingDelay: TimeInterval?
    private var pendingDeadline: DispatchTime?
    private var pendingTriggers: [PollTrigger] = []
    private var pendingRequestedAt: DispatchTime?
    private var deferredSince: DispatchTime?
    private var deferredBy: String?
    private var trailingDeadline: DispatchTime?
    private var trailingTriggers: [PollTrigger] = []
    private var scheduleGeneration: UInt64 = 0
    private let onPoll: () -> Void

    /// The poll `onPoll` is running, nil outside it.
    private(set) var currentFire: Fire?

    /// Optional suppression check. When the closure returns `true`, timer
    /// ticks and scheduled fires defer until it lifts.
    var isSuppressed: () -> Bool = { false }
    /// What holds the polls off, for the deferral log line.
    var suppressionReason: () -> String = { "suppression" }
    /// Seconds until a timed suppression lifts, nil when none is timed. A
    /// deferred fire wakes then instead of on the next fixed step.
    var suppressionEndsIn: () -> TimeInterval? = { nil }

    // test seams: the clock and the main-queue delay
    var now: () -> DispatchTime = { .now() }
    var arm: (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
    }

    /// `periodicInterval` defaults to the 10s reconcile net; tests inject a
    /// short interval to exercise timer behavior without a 10s wait.
    init(periodicInterval: TimeInterval = PollingScheduler.defaultReconcileInterval,
         onPoll: @escaping () -> Void) {
        self.periodicInterval = periodicInterval
        self.onPoll = onPoll
    }

    /// Start the reconcile timer. The caller is expected to have already
    /// run one initial discovery pass synchronously so the first timer
    /// tick cannot race startup tiling. Idempotent.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        timer = Timer.scheduledTimer(withTimeInterval: periodicInterval, repeats: true) { [weak self] _ in
            self?.reconcileTick()
        }
        if pendingPoll, let delay = pendingDelay {
            pendingRequestedAt = now()
            pendingDeadline = now() + delay
            armFire(after: delay, generation: scheduleGeneration)
        }
    }

    /// One reconcile timer tick.
    func reconcileTick() {
        // a held button can swallow tick after tick, so the missed one
        // runs when suppression lifts instead of waiting for the next
        guard !isSuppressed() else {
            schedule(after: 0, trigger: .reconcile)
            return
        }
        run(Fire(triggers: [.reconcile], waitedMS: 0, deferredMS: 0, deferredBy: nil))
    }

    /// Stop the reconcile timer and clear any in-flight coalesced poll.
    func stop() {
        timer?.invalidate()
        timer = nil
        isStarted = false
        clearPending()
        scheduleGeneration &+= 1
    }

    /// Schedule a single coalesced poll `delay` seconds from now.
    ///
    /// If a poll is already pending, the new request is dropped — the
    /// pending one fires first and captures whatever changed — unless it
    /// asks for an earlier fire. Then the pending one is re-armed at the
    /// earlier deadline, so a long wait (a hold running out) never holds
    /// back an event poll. A `trailing` request that would be dropped keeps
    /// its own deadline instead: the pending poll runs first, and a second
    /// runs at the trailing deadline unless the first ran within
    /// `trailingSlack` of it.
    ///
    /// A fire that is requested before `start()` remains pending until
    /// startup finishes. This keeps launch notifications from racing the
    /// initial snapshot. A fire that lands inside a suppression window is
    /// deferred, not dropped: it asks again every `deferStep`, or when the
    /// timed suppression ends if that is sooner. With event-driven triggers
    /// there is no 1 Hz timer behind us to catch a lost event, so dropping a
    /// suppressed poll would leave the change invisible until the 10s
    /// reconcile. Registry suppressions are time-bounded (≤6s). A held
    /// mouse button or a finishing drag defers until it ends. `stop()`
    /// clears `pendingPoll`, which cancels a deferral in flight.
    @discardableResult
    func schedule(after delay: TimeInterval = 0.2, trigger: PollTrigger = .event,
                  trailing: Bool = false) -> ScheduleOutcome {
        guard isStarted else {
            if pendingPoll {
                add(trigger, to: &pendingTriggers)
                guard let pending = pendingDelay, delay < pending else { return .beforeStart }
            } else {
                pendingTriggers = [trigger]
            }
            pendingPoll = true
            pendingDelay = delay
            scheduleGeneration &+= 1
            return .beforeStart
        }
        let at = now()
        let deadline = at + delay
        if pendingPoll {
            // only a sooner request re-arms. a deferred fire's deadline is
            // already past, so it is never re-armed
            let sooner = pendingDeadline.map { deadline < $0 } ?? false
            if !sooner {
                let pendingDue = pendingDeadline.flatMap { Self.ms(from: at, to: $0) }
                if trailing, pendingDeadline.map({ deadline > $0 + Self.slack }) ?? true {
                    if trailingDeadline.map({ deadline > $0 }) ?? true { trailingDeadline = deadline }
                    add(trigger, to: &trailingTriggers)
                    return .trailing(dueMS: Self.ms(delay), pendingDueMS: pendingDue)
                }
                add(trigger, to: &pendingTriggers)
                return .coalesced(pendingDueMS: pendingDue)
            }
            add(trigger, to: &pendingTriggers)
        } else {
            pendingTriggers = [trigger]
            pendingRequestedAt = at
        }
        let advanced = pendingPoll
        pendingPoll = true
        pendingDelay = delay
        pendingDeadline = deadline
        scheduleGeneration &+= 1
        armFire(after: delay, generation: scheduleGeneration)
        return advanced ? .advanced(dueMS: Self.ms(delay)) : .armed(dueMS: Self.ms(delay))
    }

    private func armFire(after delay: TimeInterval, generation: UInt64) {
        arm(delay) { [weak self] in
            guard let self = self,
                  self.pendingPoll,
                  self.scheduleGeneration == generation else { return }
            // suppression re-checked at every fire attempt — defer, don't drop.
            guard !self.isSuppressed() else {
                self.noteDeferral()
                let step = self.suppressionEndsIn()
                    .map { min(Self.deferStep, max(0.02, $0 + 0.01)) } ?? Self.deferStep
                self.armFire(after: step, generation: generation)
                return
            }
            self.firePending()
        }
    }

    /// logs the first deferral of a pending poll only
    private func noteDeferral() {
        guard deferredSince == nil else { return }
        let reason = suppressionReason()
        deferredSince = now()
        deferredBy = reason
        let level: LogLevel = pendingTriggers.contains(where: \.looksForNewWindow) ? .notice : .debug
        let triggers = pendingTriggers.map(\.rawValue).joined(separator: "+")
        hyprLog(level, .discovery, "poll deferred: \(reason) (trigger \(triggers))")
    }

    private func firePending() {
        let at = now()
        var triggers = pendingTriggers
        var next: (deadline: DispatchTime, triggers: [PollTrigger])?
        if let trailing = trailingDeadline {
            if trailing > at + Self.slack {
                next = (trailing, trailingTriggers)
            } else {
                // this poll runs late enough to be the trailing one too
                for t in trailingTriggers { add(t, to: &triggers) }
            }
        }
        let fire = Fire(triggers: triggers,
                        waitedMS: pendingRequestedAt.flatMap { Self.ms(from: $0, to: at) } ?? 0,
                        deferredMS: deferredSince.flatMap { Self.ms(from: $0, to: at) } ?? 0,
                        deferredBy: deferredBy)
        clearPending()
        run(fire)
        // the poll may have asked for another; the trailing one coalesces with it
        if let next {
            let delay = Double(Self.ms(from: now(), to: next.deadline) ?? 0) / 1000
            for (i, t) in next.triggers.enumerated() {
                schedule(after: delay, trigger: t, trailing: i == 0)
            }
        }
    }

    private func run(_ fire: Fire) {
        currentFire = fire
        onPoll()
        currentFire = nil
    }

    private func clearPending() {
        pendingPoll = false
        pendingDelay = nil
        pendingDeadline = nil
        pendingTriggers = []
        pendingRequestedAt = nil
        deferredSince = nil
        deferredBy = nil
        trailingDeadline = nil
        trailingTriggers = []
    }

    private func add(_ trigger: PollTrigger, to list: inout [PollTrigger]) {
        if !list.contains(trigger) { list.append(trigger) }
    }

    private static let slack = DispatchTimeInterval.milliseconds(Int(trailingSlack * 1000))

    private static func ms(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }

    /// Milliseconds from `a` to `b`, nil when `b` is already past.
    private static func ms(from a: DispatchTime, to b: DispatchTime) -> Int? {
        guard b.uptimeNanoseconds >= a.uptimeNanoseconds else { return nil }
        return Int((b.uptimeNanoseconds - a.uptimeNanoseconds) / 1_000_000)
    }
}
