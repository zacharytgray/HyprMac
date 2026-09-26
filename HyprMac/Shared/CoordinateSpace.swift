// CG ↔ NS coordinate conversion seam. CG uses a top-left origin; NS
// uses bottom-left. Conversion anchors on the primary screen height
// (`NSScreen.screens.first?.frame.height`).

import Foundation
import AppKit

/// Conversion namespace for CG ↔ NS coordinate work.
///
/// Today the active conversions live inline in the call sites
/// (`MouseTrackingManager`, `FocusBorder`, `DimmingOverlay`,
/// `DisplayManager`). This enum is the agreed home for the next
/// shared helper if a third caller appears or if the conversion
/// pattern grows beyond `primaryScreenHeight - y`.
enum CoordinateSpace {}

extension CGRect {
    /// `true` when at least `threshold` of this rect's area overlaps
    /// `screenRect`. The shared "is this frame a real on-screen position
    /// or a hide-corner sliver?" test used by snapshot capture,
    /// discovery, float-toggle restore, and floating-frame saves.
    func isSubstantiallyVisible(on screenRect: CGRect, threshold: CGFloat = 0.25) -> Bool {
        let overlap = intersection(screenRect)
        guard !overlap.isNull else { return false }
        let area = width * height
        guard area > 0 else { return false }
        return (overlap.width * overlap.height) / area > threshold
    }

    /// This rect shrunk to fit `bounds` and then moved the least distance
    /// that puts all of it inside. Unchanged when it already fits.
    func clamped(into bounds: CGRect) -> CGRect {
        let width = min(self.width, bounds.width)
        let height = min(self.height, bounds.height)
        let x = max(bounds.minX, min(minX, bounds.maxX - width))
        let y = max(bounds.minY, min(minY, bounds.maxY - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
