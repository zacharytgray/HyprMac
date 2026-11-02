// Decisions behind the display-change debounce. Pure; `WindowManager` keeps the
// timer, the suppressions and the reconcile.

import Foundation

enum DisplaySettle {
    static let normalStabilityWindow: TimeInterval = 2.0
    static let wakeSettleWindow: TimeInterval = 5.0
    static let recentWakeSpan: TimeInterval = 20.0

    /// A notification that changed nothing. `fingerprint` refreshes
    /// `DisplayManager`, so it stays unread while a transition is pending.
    static func isSpuriousNotification(transitionPending: Bool,
                                       fingerprint: @autoclosure () -> String,
                                       lastSettledFingerprint: String) -> Bool {
        !transitionPending && fingerprint() == lastSettledFingerprint
    }

    /// Only the first notification of a transition saves the departing layout.
    /// Later fires would file the piled-up state under the same key.
    static func savesDepartingLayout(transitionPending: Bool, settledKey: String) -> Bool {
        !transitionPending && !settledKey.isEmpty
    }

    /// After a wake the displays come back one at a time over several
    /// seconds, and a short beat would reconcile the one-screen desk in between.
    static func isRecentWake(sinceInterruption seconds: TimeInterval) -> Bool {
        seconds < recentWakeSpan
    }

    static func stabilityWindow(recentWake: Bool) -> TimeInterval {
        recentWake ? wakeSettleWindow : normalStabilityWindow
    }

    /// Once an interruption ends, a pending reconcile settles again from there.
    static func resettlesAfterInterruption(transitionPending: Bool,
                                           sessionInterrupted: @autoclosure () -> Bool) -> Bool {
        transitionPending && !sessionInterrupted()
    }

    /// Whether a settled display change should restore the saved layout.
    /// Only a different display set does: a Dock resize, an arrangement
    /// drag, or a primary-display change keeps the key, and restoring there
    /// would undo whatever the user arranged since the last save.
    static func restoresAfterSettle(from departedKey: String, to settledKey: String) -> Bool {
        departedKey != settledKey
    }

    enum TimerDecision: Equatable {
        /// A newer notification owns the debounce.
        case superseded
        /// The window list is partial while locked or asleep. Wait for the span to end.
        case deferredByInterruption
        /// Changed without a fresh notification. Keep waiting.
        case stillChanging
        /// Back to the last settled desk. Keys and homes are intact, but the
        /// windows are wherever macOS left them, so they only need a retile.
        case backAsItWas
        case reconcile(fingerprint: String)
    }

    /// What the stability timer does when it fires. Two inputs have side
    /// effects, so they are read only when reached: `sessionInterrupted` can end
    /// an interruption past its cap, and `currentFingerprint` refreshes
    /// `DisplayManager`.
    static func timerDecision(generationAtSchedule: Int,
                              currentGeneration: Int,
                              sessionInterrupted: @autoclosure () -> Bool,
                              fingerprintAtSchedule: String,
                              lastSettledFingerprint: String,
                              currentFingerprint: () -> String) -> TimerDecision {
        guard generationAtSchedule == currentGeneration else { return .superseded }
        if sessionInterrupted() { return .deferredByInterruption }
        let fingerprint = currentFingerprint()
        if fingerprint != fingerprintAtSchedule { return .stillChanging }
        if fingerprint == lastSettledFingerprint { return .backAsItWas }
        return .reconcile(fingerprint: fingerprint)
    }
}
