// Pure rect math driving the Settings → Tiling dwindle preview.
// Parallel to the real BSP layout but specifically a visualization
// path — kept in Models/ so it is testable without SwiftUI.

import CoreGraphics

/// Visualization helpers for the dwindle preview in
/// `TilingSettingsView`.
enum DwindleLayout {
    /// Recursive dwindle split for `count` windows inside `bounds`.
    ///
    /// Alternates horizontal / vertical based on the current rect's
    /// aspect ratio; carves off the first slot, recurses on the rest
    /// with `gap` between siblings. `count == 0` returns `[]`;
    /// `count == 1` returns `[bounds]`.
    static func rects(count: Int, in bounds: CGRect, gap: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        if count == 1 { return [bounds] }

        let halfGap = gap / 2
        let horizontal = bounds.width >= bounds.height

        let first: CGRect
        let rest: CGRect

        if horizontal {
            let splitX = bounds.width * 0.5
            first = CGRect(x: bounds.minX, y: bounds.minY,
                           width: splitX - halfGap, height: bounds.height)
            rest = CGRect(x: bounds.minX + splitX + halfGap, y: bounds.minY,
                          width: bounds.width - splitX - halfGap, height: bounds.height)
        } else {
            let splitY = bounds.height * 0.5
            first = CGRect(x: bounds.minX, y: bounds.minY,
                           width: bounds.width, height: splitY - halfGap)
            rest = CGRect(x: bounds.minX, y: bounds.minY + splitY + halfGap,
                          width: bounds.width, height: bounds.height - splitY - halfGap)
        }

        return [first] + rects(count: count - 1, in: rest, gap: gap)
    }

    /// Fit a rect of `aspect` inside `container`, leaving small
    /// margins (16 px horizontal, 8 px vertical). Used to preview a
    /// monitor's tile layout in the settings UI without distorting
    /// its shape.
    static func fitSize(in container: CGSize, aspect: CGFloat) -> CGSize {
        let maxW = container.width - 16
        let maxH = container.height - 8
        let w = min(maxW, maxH * aspect)
        let h = w / aspect
        return CGSize(width: w, height: h)
    }
}
