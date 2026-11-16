// When a brand-new window may be admitted while a workspace switch's
// transition hold still defers polls.

import CoreGraphics

/// A workspace switch holds discovery polls for `SuppressionDelay.transition`
/// because a mid-switch walk reads stale frames of the windows it parks and
/// reveals. A window opened right after the switch does not need that wait:
/// it has no frame the switch wrote. The admit-only pass tiles such a window
/// once the switch is done, and leaves everything else to the full poll
/// after the hold.
enum SwitchHoldAdmission {
    /// Whether the admit-only pass may run now. Only a finished switch's
    /// own hold allows it. A wake, a display change, a move, the scratchpad,
    /// a held button or a finishing drag keep every new window waiting, as
    /// before.
    static func allows(heldOnlyBySwitch: Bool, switchSettled: Bool, mouseButtonDown: Bool,
                       finishingDrag: Bool, displayTransitionPending: Bool,
                       sessionInterrupted: Bool) -> Bool {
        heldOnlyBySwitch && switchSettled && !mouseButtonDown && !finishingDrag
            && !displayTransitionPending && !sessionInterrupted
    }

    /// Tiled members of the visible workspaces that the walk did not list
    /// and no hold keeps. The pass's retile lays out every visible
    /// workspace from its walk, and a member missing from it would leave
    /// its tree. Whether it closed is the full poll's call, so the pass
    /// waits for that poll when this is not empty.
    static func missingTiledMembers(_ members: Set<CGWindowID>, listed: Set<CGWindowID>,
                                    held: Set<CGWindowID>) -> Set<CGWindowID> {
        members.subtracting(listed).subtracting(held)
    }
}
