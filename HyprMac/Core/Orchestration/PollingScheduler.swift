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

    init(onPoll: @escaping () -> Void) {
        self.onPoll = onPoll
    }

    // start the periodic timer. caller is expected to have already done one
    // initial discovery pass synchronously so the first timer tick can't race
    // against startup tiling.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.periodicInterval, repeats: true) { [weak self] _ in
            self?.onPoll()
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
    func schedule(after delay: TimeInterval = 0.2) {
        guard !pendingPoll else { return }
        pendingPoll = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.pendingPoll = false
            self.onPoll()
        }
    }
}
