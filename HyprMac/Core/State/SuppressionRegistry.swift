// Named, time-bounded suppression flags. Each key carries an expiry date;
// callers ask "is this suppressed?" before doing reactive work.

import Foundation

enum SuppressionKey: String {
    /// Gates the dock-click workspace switch in `appDidActivate` after a
    /// programmatic focus or raise.
    case activationSwitch = "activation-switch"
    /// Gates focus-follows-mouse after a keyboard action, workspace switch,
    /// drag, or floater raise.
    case mouseFocus = "mouse-focus"
    /// Holds polls and drift through switches, moves, the scratchpad, display
    /// settle and wake.
    case workspaceTransition = "workspace-transition"
}

/// How long each kind of event holds a key. The settle windows in
/// `DisplaySettle` add to these. `docs/architecture.md` has the table.
enum SuppressionDelay {
    static let activationSwitch: TimeInterval = 0.5
    static let mouseFocus: TimeInterval = 0.15
    /// A workspace switch, move or scratchpad change.
    static let transition: TimeInterval = 1.5
    /// A reconcile or retile that moves every window, plus a settle tail.
    static let displaySettle: TimeInterval = 3.0
    /// Sleep, wake, lock and unlock.
    static let systemInterruption: TimeInterval = 4.0
}

/// Date-gated suppression registry shared by orchestration code paths.
///
/// Owns time-bounded "should I skip this because something just happened"
/// flags, one per `SuppressionKey`.
///
/// Reentrancy guards (e.g. `FloatingWindowController.isRaising`)
/// and in-flight scheduling tokens (e.g. `PollingScheduler`'s coalesce
/// flag) intentionally do not live here — those are not time gates.
///
/// Threading: main-thread only. No synchronization.
final class SuppressionRegistry {
    private var until: [SuppressionKey: Date] = [:]

    /// Suppress `key` for `duration` seconds from now.
    ///
    /// Extends an existing suppression if the new expiry is later; never
    /// shortens. `reason`, when supplied, logs at `.notice` so the
    /// suppression is greppable in Console.
    func suppress(_ key: SuppressionKey, for duration: TimeInterval, reason: String? = nil) {
        let newExpiry = Date().addingTimeInterval(duration)
        if let existing = until[key], existing > newExpiry {
            return
        }
        until[key] = newExpiry
        if let reason = reason {
            hyprLog(.notice, .state, "suppress \(key.rawValue) for \(duration)s — \(reason)")
        } else {
            hyprLog(.debug, .state, "suppress \(key.rawValue) for \(duration)s")
        }
    }

    /// `true` while `key`'s expiry is still in the future. Lazily reaps
    /// expired entries on read.
    func isSuppressed(_ key: SuppressionKey) -> Bool {
        guard let expiry = until[key] else { return false }
        if Date() >= expiry {
            until.removeValue(forKey: key)
            return false
        }
        return true
    }

    /// Drop `key` immediately, regardless of its expiry.
    func clear(_ key: SuppressionKey) {
        until.removeValue(forKey: key)
    }

    /// Drop every active suppression.
    func clearAll() {
        until.removeAll()
        expectedActivations.removeAll()
    }

    // MARK: - expected activations

    private var expectedActivations: [pid_t: Date] = [:]
    /// The app in front right now. A focus or raise of one of its windows
    /// activates nothing, so no note is kept for it: a note nothing
    /// consumes outlives the press that made it, and the user's own Dock
    /// click on that app five seconds later was taken for HyprMac's.
    var frontmostPID: () -> pid_t? = { nil }

    /// Note that HyprMac is about to focus or raise a window of `pid`, so
    /// the app activation that follows is HyprMac's doing and not the
    /// user's. Unlike a timed suppression the note waits for that
    /// notification however long the main thread takes to reach it: a
    /// retile that ran past the half-second window used to let the
    /// activation through and switch workspaces under the user. It expires
    /// after `ttl` only so an activation that never comes leaves nothing
    /// behind.
    func expectActivation(of pid: pid_t, ttl: TimeInterval = 5) {
        guard pid != frontmostPID() else { return }
        expectedActivations[pid] = Date().addingTimeInterval(ttl)
    }

    /// Consume the note for `pid`. `true` when HyprMac caused this
    /// activation; the note is spent either way.
    func consumeExpectedActivation(of pid: pid_t) -> Bool {
        guard let expiry = expectedActivations.removeValue(forKey: pid) else { return false }
        return Date() < expiry
    }
}
