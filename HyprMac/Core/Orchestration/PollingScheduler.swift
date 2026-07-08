// Slow reconcile timer plus the coalescing token that funnels
// event-driven polls down to one in-flight scheduled call.

import Foundation

/// Polling driver for `WindowDiscoveryService`.
///
/// Owns two scheduling primitives:
/// - A slow (10s) repeating timer that acts as a reconcile safety net —
///   it catches apps that refuse AX observers, notifications the observer
///   layer missed, and external moves nothing else reports. It is no
///   longer the primary discovery trigger.
/// - A `pendingPoll` flag that coalesces multiple event-driven
///   `schedule(after:)` requests in the same debounce window down to a
///   single fire. These come from `AXNotificationService` (window create /
///   destroy / miniaturize / focus) via `WindowManager` and are the
///   primary path — the timer only backstops them.
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

    /// Reconcile-timer interval. Slow safety net now that per-app
    /// AXObserver notifications drive discovery; was 1 Hz before the move
    /// to event-driven triggers.
    static let defaultReconcileInterval: TimeInterval = 10.0

    private let periodicInterval: TimeInterval
    private var timer: Timer?
    private var pendingPoll = false
    private let onPoll: () -> Void

    /// Optional suppression check. When the closure returns `true`, both
    /// timer ticks and scheduled fires are dropped. Used to hold polling
    /// off during cross-monitor drag-swap, where `crossSwapWindows` runs
    /// two back-to-back retile passes (≈ 720 ms of synchronous readback)
    /// and a poll firing mid-flight would race the in-progress mutation.
    /// Default returns `false`, so existing call sites are unaffected.
    var isSuppressed: () -> Bool = { false }

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
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: periodicInterval, repeats: true) { [weak self] _ in
            guard let self = self, !self.isSuppressed() else { return }
            self.onPoll()
        }
    }

    /// Stop the reconcile timer and clear any in-flight coalesced poll.
    func stop() {
        timer?.invalidate()
        timer = nil
        pendingPoll = false
    }

    /// Schedule a single coalesced poll `delay` seconds from now.
    ///
    /// If a poll is already pending, the new request is dropped — the
    /// pending one fires first and captures whatever changed. A fire that
    /// lands inside a suppression window is deferred (retried at 0.3s),
    /// not dropped: with event-driven triggers there is no 1 Hz timer
    /// behind us to catch a lost event, so dropping a suppressed poll
    /// would leave the change invisible until the 10s reconcile. Every
    /// suppression is time-bounded (≤4s), so the deferral terminates;
    /// `stop()` clears `pendingPoll`, which cancels a deferral in flight.
    func schedule(after delay: TimeInterval = 0.2) {
        guard !pendingPoll else { return }
        pendingPoll = true
        armFire(after: delay)
    }

    private func armFire(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.pendingPoll else { return }
            // suppression re-checked at every fire attempt — defer, don't drop.
            guard !self.isSuppressed() else {
                self.armFire(after: 0.3)
                return
            }
            self.pendingPoll = false
            self.onPoll()
        }
    }
}
