// Named, time-bounded suppression flags. Each key carries an expiry date;
// callers ask "is this suppressed?" before doing reactive work.

import Foundation

/// Date-gated suppression registry shared by orchestration code paths.
///
/// Owns time-bounded "should I skip this because something just happened"
/// flags. Two keys are in active use:
///
/// - `"activation-switch"` — gates the dock-click workspace switch in
///   `appDidActivate` after a programmatic focus or raise (≈ 0.5 s).
/// - `"mouse-focus"` — gates focus-follows-mouse after a keyboard action,
///   workspace switch, drag, or floater raise (0.15–0.3 s).
/// - `"cross-swap-in-flight"` — registered by `DragSwapHandler` for the
///   ≈ 800 ms duration of a cross-monitor drag-swap; honored by
///   `PollingScheduler` so timer and notification triggers do not race
///   the swap's two synchronous retiles.
///
/// Reentrancy guards (e.g. `FloatingWindowController.isRaisingFloaters`)
/// and in-flight scheduling tokens (e.g. `PollingScheduler`'s coalesce
/// flag) intentionally do not live here — those are not time gates.
///
/// Threading: main-thread only. No synchronization.
final class SuppressionRegistry {
    private var until: [String: Date] = [:]

    /// Suppress `key` for `duration` seconds from now.
    ///
    /// Extends an existing suppression if the new expiry is later; never
    /// shortens. `reason`, when supplied, logs at `.notice` so the
    /// suppression is greppable in Console.
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

    /// `true` while `key`'s expiry is still in the future. Lazily reaps
    /// expired entries on read.
    func isSuppressed(_ key: String) -> Bool {
        guard let expiry = until[key] else { return false }
        if Date() >= expiry {
            until.removeValue(forKey: key)
            return false
        }
        return true
    }

    /// Drop `key` immediately, regardless of its expiry.
    func clear(_ key: String) {
        until.removeValue(forKey: key)
    }

    /// Drop every active suppression. Used on `WindowManager.stop()` to
    /// reset state for a clean restart.
    func clearAll() {
        until.removeAll()
    }
}
