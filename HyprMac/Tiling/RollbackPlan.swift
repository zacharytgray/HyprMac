// Which windows a refused layout's rollback puts back. Pure.

import CoreGraphics

enum RollbackPlan: Equatable {
    /// An incumbent's original is not a restoration target, so nothing goes back.
    case refused(invalidOriginalID: CGWindowID)
    /// Everyone goes back except these newcomers.
    case restore(leavingInPlace: Set<CGWindowID>)

    // a newcomer whose original is off the restoration rect — it stood on
    // the screen it was moved from, or was parked — was never part of the
    // tree being rolled back. writing it back there would put an assigned
    // window on a screen that does not show its workspace, and a rollback
    // across displays is another scale hop that can land short itself.
    // it stays wherever the candidate left it: on this screen if its
    // writes went out, where it was if they never reached it. an
    // ordinary pass reports it stranded for the admission recovery;
    // other callers decide for themselves. the incumbents still go back.
    // an original is a restoration target when it lies within the
    // restoration rect by the same slack the rollback's own validation
    // grants its readback. a parked one is a sliver past the edge, and
    // one on another screen is not there at all; one a point over the
    // edge, a half-point rounding or a min-height window against the
    // Dock, is exactly where the window was and goes back there. strict
    // containment refused the rollback of the whole key for that point
    // and left the candidate frames on screen under the old tree
    static func make(originalFrames: [CGWindowID: CGRect], newcomerIDs: Set<CGWindowID>,
                     restorationFrame: CGRect, slack: CGFloat) -> RollbackPlan {
        let reach = restorationFrame.insetBy(dx: -slack, dy: -slack)
        let leftInPlace = newcomerIDs.filter { id in
            originalFrames[id].map { !reach.contains($0) } ?? false
        }
        if let invalidOriginalID = originalFrames.keys.sorted().first(where: { windowID in
            !leftInPlace.contains(windowID)
                && (originalFrames[windowID].map { !reach.contains($0) } ?? true)
        }) {
            return .refused(invalidOriginalID: invalidOriginalID)
        }
        return .restore(leavingInPlace: leftInPlace)
    }
}
