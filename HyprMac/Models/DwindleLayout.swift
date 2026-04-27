import CoreGraphics

// Pure rect math used by the Settings → Tiling dwindle preview.
// Lives in Models/ so it can be exercised by unit tests without
// importing SwiftUI. The real tiling engine has its own BSP layout
// path; this is a parallel approximation for visualizing settings.
enum DwindleLayout {
    // Recursive dwindle split: alternates horizontal/vertical based on
    // the current rect's aspect ratio. Each step carves off the first
    // window from the larger remaining slot, applying `gap` between
    // siblings. count == 0 returns []; count == 1 returns [bounds].
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

    // Scales a rect of the given aspect ratio to fit inside `container`,
    // leaving small margins (16px horizontal, 8px vertical). Used to
    // preview how a monitor's tile layout will look in the settings UI.
    static func fitSize(in container: CGSize, aspect: CGFloat) -> CGSize {
        let maxW = container.width - 16
        let maxH = container.height - 8
        let w = min(maxW, maxH * aspect)
        let h = w / aspect
        return CGSize(width: w, height: h)
    }
}
