import Foundation

// owns the periodic discovery timer and the coalescing token that funnels
// notification-driven polls down to one in-flight scheduled call.
//
// what lives here (per §5.5):
//   - the 1Hz repeating Timer that drives steady-state discovery
//   - the in-flight `pendingPoll` Bool — a same-frame coalescing token, not a
//     time gate. callers ask for a poll soon; the second through Nth caller
//     during the debounce window collapse into the first.
//
// what does NOT live here:
//   - the discovery work itself (callback) — discovery lives in
//     WindowDiscoveryService once that lands.
//   - SuppressionRegistry's date-gated keys (different concept; see §5.5).
//   - the @objc notification handlers that trigger schedule(after:) — they
//     stay on WindowManager because they also do lifecycle cleanup
//     (e.g., appDidTerminate calls forgetApp before scheduling a poll).
//
// main-thread is a precondition — the Timer is scheduled on the main run loop
// and the coalesce DispatchQueue.main.asyncAfter resolves on main.
final class PollingScheduler {

    // periodic discovery interval. matches v0.4.2 reference behavior.
    private static let periodicInterval: TimeInterval = 1.0

    private var timer: Timer?
    private var pendingPoll = false
    private let onPoll: () -> Void

    // optional suppression check. if set and returns true, both timer ticks AND
    // scheduled fires are dropped. used by Phase 4 step 5's cross-monitor drag-swap
    // stabilization to hold polling off while crossSwapWindows runs back-to-back
    // retile passes (~720ms total of Thread.sleep readback). default returns false
    // so existing call sites are unaffected.
    var isSuppressed: () -> Bool = { false }

    init(onPoll: @escaping () -> Void) {
        self.onPoll = onPoll
    }

    // start the periodic timer. caller is expected to have already done one
    // initial discovery pass synchronously so the first timer tick can't race
    // against startup tiling.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.periodicInterval, repeats: true) { [weak self] _ in
            guard let self = self, !self.isSuppressed() else { return }
            self.onPoll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pendingPoll = false
    }

    // schedule a single coalesced poll `delay` seconds from now.
    // if a poll is already in flight (scheduled but not yet fired), drop this
    // request — the in-flight one will run first and capture whatever changed.
    // if isSuppressed() is true at scheduling OR firing time, the request is
    // dropped (the suppressed period is the caller's responsibility to bound).
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
