// CG ↔ NS coordinate conversion seam. CG uses a top-left origin; NS
// uses bottom-left. Conversion anchors on the primary screen height
// (`NSScreen.screens.first?.frame.height`).

import Foundation
import AppKit

/// Conversion namespace for CG ↔ NS coordinate work.
enum CoordinateSpace {
    /// A top-left CG rect as a bottom-left NS rect. A screen left of or above
    /// the primary has negative coordinates in both, and this one formula
    /// covers it.
    static func nsRect(fromCG rect: CGRect, primaryHeight: CGFloat) -> NSRect {
        NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

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
