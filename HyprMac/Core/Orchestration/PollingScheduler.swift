// Periodic discovery timer plus the coalescing token that funnels
// notification-driven polls down to one in-flight scheduled call.

import Foundation

/// Polling driver for `WindowDiscoveryService`.
///
/// Owns two scheduling primitives:
/// - A 1 Hz repeating timer that drives steady-state discovery.
/// - A `pendingPoll` flag that coalesces multiple notification-driven
///   `schedule(after:)` requests in the same debounce window down to a
///   single fire.
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

    /// Periodic discovery interval. Matches v0.4.2 reference behavior.
    private static let periodicInterval: TimeInterval = 1.0

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

    init(onPoll: @escaping () -> Void) {
        self.onPoll = onPoll
    }

    /// Start the periodic timer. The caller is expected to have already
    /// run one initial discovery pass synchronously so the first timer
    /// tick cannot race startup tiling. Idempotent.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.periodicInterval, repeats: true) { [weak self] _ in
            guard let self = self, !self.isSuppressed() else { return }
            self.onPoll()
        }
    }

    /// Stop the periodic timer and clear any in-flight coalesced poll.
    func stop() {
        timer?.invalidate()
        timer = nil
        pendingPoll = false
    }

    /// Schedule a single coalesced poll `delay` seconds from now.
    ///
    /// If a poll is already in flight (scheduled but not yet fired), the
    /// new request is dropped — the in-flight one will fire first and
    /// capture whatever changed. Suppression is checked twice: at
    /// scheduling time and again at firing time, so a suppression that
    /// starts mid-`asyncAfter` still cancels the pending fire.
    func schedule(after delay: TimeInterval = 0.2) {
        guard !isSuppressed() else { return }
        guard !pendingPoll else { return }
        pendingPoll = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.pendingPoll = false
            // re-check at fire time — suppression may have started AFTER scheduling.
            guard !self.isSuppressed() else { return }
            self.onPoll()
        }
    }
}
