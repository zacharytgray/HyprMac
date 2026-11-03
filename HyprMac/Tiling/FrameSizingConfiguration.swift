// Tolerances, deadlines and budgets for a frame sizing attempt.

import Cocoa

struct FrameSizingConfiguration {
    /// A rollback puts a window back where it was, so it allows no more than
    /// the plain size tolerance and only checks correspondence.
    var restorationStrict: FrameSizingConfiguration {
        var strict = self
        strict.sizeOvershootTolerance = sizeTolerance
        strict.sizeUndershootTolerance = sizeTolerance
        strict.aggregateSafetySlack = sizeTolerance
        strict.correspondenceOnly = true
        return strict
    }

    var deadline: TimeInterval = 0.36
    var pollInterval: TimeInterval = 0.03
    var maximumAttempts: Int = 12
    var positionTolerance: CGFloat = 1
    var sizeTolerance: CGFloat = 1
    // cell-quantizing apps (terminals) round a target to whole character
    // cells, in either direction. restoration pins both back to sizeTolerance.
    var sizeOvershootTolerance: CGFloat = TilingConfig.frameToleranceXPx
    var sizeUndershootTolerance: CGFloat = TilingConfig.frameToleranceXPx
    /// How far the aggregate checks — actual overlap and escape past the
    /// far edges — bend, which is comparison slack for a readback that
    /// lands a fraction off, not room to round into. It is deliberately
    /// independent of the size tolerances: an app may round its own size to
    /// a whole cell, but two windows still may not sit on top of each other
    /// and no window may leave the screen.
    var aggregateSafetySlack: CGFloat = 1
    var stableTolerance: CGFloat = 0.01
    var requiredStableSamples: Int = 2
    var minimumMismatchSettle: TimeInterval = 0.24
    var perCallTimeout: TimeInterval = 0.1
    /// Windows that move before they are sized. The engine picks them: a
    /// parked window, or one whose target is bigger than the screen it
    /// stands on. A size written there would be clamped by that screen, and
    /// a parked window can stay constrained by its old display for a short
    /// time after it moves. Each waits for its position to settle, for at
    /// most `positionSettleBudget`, before it is sized. Every other window
    /// sizes first.
    var positionSettleWindowIDs: Set<CGWindowID> = []
    /// Position-first windows whose old size, put at their target origin,
    /// would hang off the destination screen. Each moves here first, where
    /// that old size stands on the screen, is sized, then moves to its
    /// target. Issue #43: a parked Ghostty window moved to a bottom slot hung
    /// below every screen and ignored both size writes.
    var stagingOrigins: [CGWindowID: CGPoint] = [:]
    /// Restoration only. A rollback asks every window to go back where it
    /// was, so the question is per-window correspondence, not whether the
    /// result is a valid tiled arrangement. Originals that overlapped each
    /// other before the candidate ran still overlap after it, and that is
    /// not a failed rollback — the overlap is reported on the result
    /// instead of rejecting it.
    var correspondenceOnly = false
    /// The budget for a pass that moves a window onto a screen with a
    /// different backing scale factor. The app redraws everything at the
    /// new scale while our AX calls wait behind it. On the MacBook's 2x
    /// panel the first write after a hop from a 1x external missed 0.36 s on
    /// every move, and the retry 250 ms later usually verified.
    var scaleChangeDeadline: TimeInterval = 1.0

    /// The most a position-first write waits for its position to settle.
    /// A move that never reads back on target used to poll out the whole
    /// deadline with no size written, so the attempt could only time out.
    /// Past this the size goes out anyway and the readback judges. A third
    /// of the deadline, so it grows with the scale-change budget; a
    /// deadline grown for the targets pins it instead, so each settle may
    /// spend exactly what was added for it and no more.
    var positionSettleBudget: TimeInterval { positionSettleBudgetOverride ?? deadline / 3 }
    var positionSettleBudgetOverride: TimeInterval?
    /// The most the deadline may grow to, by any budget: what is left of
    /// the attempt's whole budget when this pass starts. nil is no cap.
    var deadlineCap: TimeInterval?

    /// `deadline`, within the cap.
    func capped(_ deadline: TimeInterval) -> TimeInterval {
        deadlineCap.map { min(deadline, $0) } ?? deadline
    }

    /// This configuration with the scale-change budget. The sample limit
    /// grows with the deadline so the settle loop can use the extra time.
    var withScaleChangeBudget: FrameSizingConfiguration {
        var extended = self
        extended.deadline = capped(max(deadline, scaleChangeDeadline))
        extended.maximumAttempts = max(maximumAttempts,
                                       Int((extended.deadline / pollInterval).rounded(.up)))
        return extended
    }

    /// This configuration for the one retry an AX messaging timeout gets: a
    /// longer per-call timeout and deadline, never shorter than this one's.
    /// The verified layout's timeout recovery and the tiled drag both use it.
    var withTimeoutRecoveryBudget: FrameSizingConfiguration {
        var relaxed = self
        relaxed.deadline = capped(max(deadline, 0.75))
        relaxed.perCallTimeout = max(perCallTimeout, 0.25)
        return relaxed
    }
}
