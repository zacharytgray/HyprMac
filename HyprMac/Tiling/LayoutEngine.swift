// Pure-ish geometric helpers for the tiling subsystem. No AX, no
// animation, no persistent engine state — every input arrives as a
// parameter and every result is returned, so the math is unit-testable.

import Cocoa

/// A temporary layout proposal; no placeholder window enters the BSP tree.
struct LaunchLayoutPlan {
    let siblingLayouts: [(HyprWindow, CGRect)]
    let reservedFrame: CGRect
}

/// Geometric helpers for the tiling subsystem.
///
/// Pure with respect to AX and animation. Callers supply minimum-size
/// lookups so this type does not depend on `MinSizeMemory`. Smart insertion
/// changes the tree; reservation planning temporarily normalizes its knobs
/// and restores them before returning. Both run synchronously on the tree
/// owner's queue, with no concurrent tree readers or mutations.
struct LayoutEngine {
    let gapSize: CGFloat
    let outerPadding: CGFloat
    let minSlotDimension: CGFloat

    /// Split `rect` along `dir` at the midpoint, leaving `gap` of empty space
    /// in the middle.
    func splitRects(_ rect: CGRect, dir: SplitDirection) -> (CGRect, CGRect) {
        let halfGap = gapSize / 2
        switch dir {
        case .horizontal:
            let mid = rect.origin.x + rect.width * 0.5
            return (
                CGRect(x: rect.origin.x, y: rect.origin.y,
                       width: mid - rect.origin.x - halfGap, height: rect.height),
                CGRect(x: mid + halfGap, y: rect.origin.y,
                       width: rect.maxX - mid - halfGap, height: rect.height)
            )
        case .vertical:
            let mid = rect.origin.y + rect.height * 0.5
            return (
                CGRect(x: rect.origin.x, y: rect.origin.y,
                       width: rect.width, height: mid - rect.origin.y - halfGap),
                CGRect(x: rect.origin.x, y: mid + halfGap,
                       width: rect.width, height: rect.maxY - mid - halfGap)
            )
        }
    }

    /// Can two leaves with these min-sizes fit as siblings under `parentRect`
    /// when split along `dir`? Caller is responsible for picking direction.
    /// Uses `TilingConfig.maxRatio` as the per-child upper bound on the split
    /// axis, plus 1px slack to absorb sub-pixel rounding.
    func pairFits(_ aMin: CGSize, _ bMin: CGSize,
                  in parentRect: CGRect, dir: SplitDirection) -> Bool {
        let slack = TilingConfig.rectComparisonSlackPx
        let indCap = TilingConfig.maxRatio
        switch dir {
        case .horizontal:
            let sumOk = aMin.width + bMin.width + gapSize <= parentRect.width + slack
            let aCross = aMin.height <= parentRect.height + slack
            let bCross = bMin.height <= parentRect.height + slack
            let aInd = aMin.width <= parentRect.width * indCap + slack
            let bInd = bMin.width <= parentRect.width * indCap + slack
            return sumOk && aCross && bCross && aInd && bInd
        case .vertical:
            let sumOk = aMin.height + bMin.height + gapSize <= parentRect.height + slack
            let aCross = aMin.width <= parentRect.width + slack
            let bCross = bMin.width <= parentRect.width + slack
            let aInd = aMin.height <= parentRect.height * indCap + slack
            let bInd = bMin.height <= parentRect.height * indCap + slack
            return sumOk && aCross && bCross && aInd && bInd
        }
    }

    /// Find a leaf in `tree` where splitting will accommodate `window` plus
    /// the existing tenant. Two-pass search: pass 0 enforces
    /// `minSlotDimension` on child slots (preferred); pass 1 ignores the
    /// minimum (so we don't drop a window just because slots are tight).
    /// `minimumSize` returns the recorded min-size for any window — pass
    /// `.zero` when unknown.
    func fittingLeaf(for window: HyprWindow?,
                     in tree: BSPTree,
                     maxDepth: Int,
                     rect: CGRect,
                     minimumSize: (HyprWindow?) -> CGSize) -> BSPNode? {
        let leaves = tree.root.allLeavesRightToLeft()
        for pass in 0...1 {
            for leaf in leaves {
                guard leaf.depth < maxDepth else { continue }
                guard let leafRect = tree.rectForNode(leaf, in: rect, gap: gapSize, padding: outerPadding) else { continue }
                let dir = leaf.direction(for: leafRect)

                if pass == 0 {
                    let (a, b) = splitRects(leafRect, dir: dir)
                    let childMin = min(min(a.width, a.height), min(b.width, b.height))
                    if childMin < minSlotDimension { continue }
                }

                let existingMin = minimumSize(leaf.window)
                let incomingMin = minimumSize(window)
                if pairFits(existingMin, incomingMin, in: leafRect, dir: dir) {
                    return leaf
                }
            }
        }
        return nil
    }

    /// Preview a cold-launch insertion before a real window exists. The
    /// caller may move siblings, but must still validate the actual window's
    /// minimum size and membership before revealing it. This conservative
    /// midpoint proposal is not a promise of the final adaptive layout.
    func planLaunchReservation(in tree: BSPTree,
                               maxDepth: Int,
                               rect: CGRect,
                               incomingMinimumSize: CGSize,
                               minimumSize: (HyprWindow?) -> CGSize) -> LaunchLayoutPlan? {
        let slack = TilingConfig.rectComparisonSlackPx
        func fits(_ size: CGSize, in frame: CGRect) -> Bool {
            size.width.isFinite && size.height.isFinite
                && size.width >= 0 && size.height >= 0
                && frame.origin.x.isFinite && frame.origin.y.isFinite
                && frame.width.isFinite && frame.height.isFinite
                && frame.width > 0 && frame.height > 0
                && size.width <= frame.width + slack
                && size.height <= frame.height + slack
        }

        guard gapSize.isFinite, gapSize >= 0,
              outerPadding.isFinite, outerPadding >= 0,
              rect.width > 2 * outerPadding,
              rect.height > 2 * outerPadding else { return nil }
        let padded = rect.insetBy(dx: outerPadding, dy: outerPadding)
        guard fits(incomingMinimumSize, in: padded) else { return nil }
        if tree.root.isEmpty {
            return LaunchLayoutPlan(siblingLayouts: [], reservedFrame: padded)
        }

        // Structural insertion clears user ratios, then starts its layout at
        // default ratios. Reuse the tree's reversible knob snapshot without
        // creating windows, making AX calls, or changing topology.
        let saved = tree.snapshot()
        defer { tree.restore(saved) }
        tree.root.clearUserSetRatios()
        tree.root.resetSplitRatios()
        // insert() clears the selected leaf's override. Ignore stale leaf
        // overrides during selection as well; internal overrides survive.
        for leaf in tree.root.allLeavesRightToLeft() {
            leaf.splitOverride = nil
        }

        let proposedMinimum: (HyprWindow?) -> CGSize = { window in
            window == nil ? incomingMinimumSize : minimumSize(window)
        }
        guard let leaf = fittingLeaf(for: nil, in: tree, maxDepth: maxDepth,
                                     rect: rect, minimumSize: proposedMinimum),
              let tenant = leaf.window,
              let leafRect = tree.rectForNode(leaf, in: rect, gap: gapSize, padding: outerPadding)
        else { return nil }
        let direction: SplitDirection = leafRect.width >= leafRect.height ? .horizontal : .vertical
        let (tenantFrame, reservedFrame) = splitRects(leafRect, dir: direction)
        guard fits(incomingMinimumSize, in: reservedFrame) else { return nil }

        let siblings = tree.layout(in: rect, gap: gapSize, padding: outerPadding).map { window, frame in
            (window, window === tenant ? tenantFrame : frame)
        }
        // pairFits permits unequal ratios; a reservation promises the exact
        // midpoint rectangles, so validate every sibling after normalization.
        guard siblings.allSatisfy({ fits(minimumSize($0.0), in: $0.1) }) else { return nil }
        return LaunchLayoutPlan(siblingLayouts: siblings, reservedFrame: reservedFrame)
    }

    /// Smart-insert via `fittingLeaf`. Returns false if no leaf accepts the
    /// pair (caller usually auto-floats in that case).
    @discardableResult
    func smartInsertFitting(_ window: HyprWindow,
                            into tree: BSPTree,
                            maxDepth: Int,
                            rect: CGRect,
                            minimumSize: (HyprWindow?) -> CGSize) -> Bool {
        if tree.root.isEmpty {
            tree.root.window = window
            return true
        }

        guard let leaf = fittingLeaf(for: window, in: tree, maxDepth: maxDepth,
                                     rect: rect, minimumSize: minimumSize) else {
            return false
        }

        leaf.insert(window)
        if let leafRect = tree.rectForNode(leaf, in: rect, gap: gapSize, padding: outerPadding) {
            hyprLog(.debug, .lifecycle, "smart insert fit at depth \(leaf.depth) (\(Int(leafRect.width))x\(Int(leafRect.height)))")
        }
        return true
    }
}
