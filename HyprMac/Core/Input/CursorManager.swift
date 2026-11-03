// Cursor warp helper. Wraps `CGWarpMouseCursorPosition` plus the
// disassociate/reassociate dance needed to keep the cursor pinned where
// it lands.

import Cocoa

/// Warps the cursor to a window's center or to a given point.
///
/// Threading: main-thread only.
class CursorManager {
    /// Move the cursor to the center of `window`.
    ///
    /// `CGWarpMouseCursorPosition` alone is not reliable: macOS keeps
    /// accumulating mouse deltas from physical motion that happened
    /// during the warp, and the cursor jumps back. Disassociating the
    /// mouse for 50 ms and re-associating after the warp lands stops
    /// the accumulation; the empirical 50 ms window matches what other
    /// apps use for the same pattern.
    func warpToCenter(of window: HyprWindow) {
        guard let center = window.center else { return }
        warp(to: center)
    }

    /// Move the cursor to `point` (CG coordinates), with the same
    /// disassociate dance as `warpToCenter`.
    func warp(to point: CGPoint) {
        mainThreadOnly()
        CGWarpMouseCursorPosition(point)
        // briefly disassociate mouse to prevent delta accumulation
        CGAssociateMouseAndMouseCursorPosition(0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }
}
