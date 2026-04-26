import Foundation

// named, time-bounded suppression flags.
// owns date-gated suppressions only — the kind where some other code path checks
// "should i skip this work because something just happened?" and the answer
// expires after a short interval.
//
// what lives here:
//   - "activation-switch" — gates appDidActivate's workspace-switch reaction
//     after we just programmatically focused/raised something. duration ~0.5s.
//   - "mouse-focus" — gates focus-follows-mouse after a keyboard action,
//     workspace switch, drag, or floater raise. duration 0.15–0.3s.
//
// what does NOT live here (per §5.5):
//   - PollingScheduler's coalescing token (in-flight scheduling state, not a
//     time gate — moves to PollingScheduler in Phase 3).
//   - FloatingWindowController.isRaisingFloaters (same-stack reentrancy guard,
//     paired with `defer`, not time-based — stays inline).
//
// main-thread is a precondition. no synchronization beyond that.
final class SuppressionRegistry {
    private var until: [String: Date] = [:]

    // suppress `key` for `duration` seconds from now. extends an existing
    // suppression if the new expiry is later; never shortens.
    // `reason` is logged at .notice for debuggability.
    func suppress(_ key: String, for duration: TimeInterval, reason: String? = nil) {
        let newExpiry = Date().addingTimeInterval(duration)
        if let existing = until[key], existing > newExpiry {
            return
        }
        until[key] = newExpiry
        if let reason = reason {
            hyprLog(.notice, .state, "suppress \(key) for \(duration)s — \(reason)")
        } else {
            hyprLog(.debug, .state, "suppress \(key) for \(duration)s")
        }
    }

    func isSuppressed(_ key: String) -> Bool {
        guard let expiry = until[key] else { return false }
        if Date() >= expiry {
            until.removeValue(forKey: key)
            return false
        }
        return true
    }

    func clear(_ key: String) {
        until.removeValue(forKey: key)
    }

    func clearAll() {
        until.removeAll()
    }
}
