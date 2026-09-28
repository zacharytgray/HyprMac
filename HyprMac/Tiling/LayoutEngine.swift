// Pure-ish geometric helpers for the tiling subsystem. No AX, no
// animation, no persistent engine state — every input arrives as a
// parameter and every result is returned, so the math is unit-testable.

import Cocoa

/// Geometric helpers for the tiling subsystem.
///
/// Pure with respect to AX and animation. The only impure surface is
/// `fittingLeaf` / `smartInsertFitting`, which need to look up
/// min-sizes for windows already in the tree; callers pass that lookup
/// in as a closure so this type does not depend on `MinSizeMemory`.
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

    /// The individual checks behind `pairFits`, so a refusal can name the one
    /// that said no without keeping a second copy of the arithmetic.
    struct PairFit: Equatable {
        /// both minima plus the gap fit along the split axis.
        let sumOk: Bool
        /// each minimum fits across the split axis.
        let aCross: Bool
        let bCross: Bool
        /// neither minimum needs more than `maxRatio` of the split axis.
        let aInd: Bool
        let bInd: Bool
        let direction: SplitDirection

        var fits: Bool { sumOk && aCross && bCross && aInd && bInd }

        /// The axis the pair failed on, in `FrameReadbackPoller.axis`
        /// spelling. `none` when it fits.
        var refusedAxis: String {
            let split = !sumOk || !aInd || !bInd
            let cross = !aCross || !bCross
            switch direction {
            case .horizontal: return FrameReadbackPoller.axis(width: split, height: cross)
            case .vertical: return FrameReadbackPoller.axis(width: cross, height: split)
            }
        }
    }

    /// Can two leaves with these min-sizes fit as siblings under `parentRect`
    /// when split along `dir`? Caller is responsible for picking direction.
    /// Uses `TilingConfig.maxRatio` as the per-child upper bound on the split
    /// axis, plus 1px slack to absorb sub-pixel rounding.
    func pairFits(_ aMin: CGSize, _ bMin: CGSize,
                  in parentRect: CGRect, dir: SplitDirection) -> Bool {
        pairFit(aMin, bMin, in: parentRect, dir: dir).fits
    }

    /// `pairFits` with its working shown.
    func pairFit(_ aMin: CGSize, _ bMin: CGSize,
                 in parentRect: CGRect, dir: SplitDirection) -> PairFit {
        let slack = TilingConfig.rectComparisonSlackPx
        let indCap = TilingConfig.maxRatio
        switch dir {
        case .horizontal:
            return PairFit(
                sumOk: aMin.width + bMin.width + gapSize <= parentRect.width + slack,
                aCross: aMin.height <= parentRect.height + slack,
                bCross: bMin.height <= parentRect.height + slack,
                aInd: aMin.width <= parentRect.width * indCap + slack,
                bInd: bMin.width <= parentRect.width * indCap + slack,
                direction: dir)
        case .vertical:
            return PairFit(
                sumOk: aMin.height + bMin.height + gapSize <= parentRect.height + slack,
                aCross: aMin.width <= parentRect.width + slack,
                bCross: bMin.width <= parentRect.width + slack,
                aInd: aMin.height <= parentRect.height * indCap + slack,
                bInd: bMin.height <= parentRect.height * indCap + slack,
                direction: dir)
        }
    }

    /// One leaf's reason for not taking the incoming window, as the search
    /// tried it. Geometry only — where a minimum came from is the tiling
    /// engine's to say, because only it holds the provenance.
    struct SlotRefusal: Equatable {
        /// the leaf's current occupant. nil for an empty leaf.
        let tenantID: CGWindowID?
        /// the leaf rect the pair would have shared.
        let slot: CGSize
        let direction: SplitDirection
        /// the leaf is already as deep as the screen allows, so this is not a
        /// size question at all.
        let depthExhausted: Bool
        let axis: String
        let incomingMinimum: CGSize
        let tenantMinimum: CGSize
    }

    /// Find a leaf in `tree` where splitting will accommodate `window` plus
    /// the existing tenant. Two-pass search: pass 0 enforces
    /// `minSlotDimension` on child slots (preferred); pass 1 ignores the
    /// minimum (so we don't drop a window just because slots are tight).
    /// `minimumSize` returns the recorded min-size for any window — pass
    /// `.zero` when unknown.
    ///
    /// `noting` is called once per leaf that refused, on the second pass
    /// only: pass 0's `minSlotDimension` skip is a preference, not a refusal,
    /// and pass 1 revisits every leaf it skipped. Reporting changes nothing
    /// about which leaf is chosen.
    func fittingLeaf(for window: HyprWindow?,
                     in tree: BSPTree,
                     maxDepth: Int,
                     rect: CGRect,
                     minimumSize: (HyprWindow?) -> CGSize,
                     noting: ((SlotRefusal) -> Void)? = nil) -> BSPNode? {
        fittingPlacement(for: window, in: tree, maxDepth: maxDepth, rect: rect,
                         minimumSize: minimumSize, noting: noting)?.leaf
    }

    /// Find both the leaf and the split direction that makes the pair fit.
    /// A leaf with an explicit override keeps that direction. Otherwise the
    /// aspect-ratio direction is preferred, with the other axis as a bounded
    /// fallback when window constraints reject the preferred split.
    private func fittingPlacement(for window: HyprWindow?,
                                  in tree: BSPTree,
                                  maxDepth: Int,
                                  rect: CGRect,
                                  minimumSize: (HyprWindow?) -> CGSize,
                                  noting: ((SlotRefusal) -> Void)? = nil)
        -> (leaf: BSPNode, direction: SplitDirection)? {
        let leaves = tree.root.allLeavesRightToLeft()
        for pass in 0...1 {
            for leaf in leaves {
                guard leaf.depth < maxDepth else {
                    if pass == 1, let noting {
                        let leafRect = tree.rectForNode(leaf, in: rect, gap: gapSize, padding: outerPadding) ?? .zero
                        noting(SlotRefusal(tenantID: leaf.window?.windowID,
                                           slot: leafRect.size,
                                           direction: leaf.direction(for: leafRect),
                                           depthExhausted: true,
                                           axis: "depth",
                                           incomingMinimum: minimumSize(window),
                                           tenantMinimum: minimumSize(leaf.window)))
                    }
                    continue
                }
                guard let leafRect = tree.rectForNode(leaf, in: rect, gap: gapSize, padding: outerPadding) else { continue }
                let existingMin = minimumSize(leaf.window)
                let incomingMin = minimumSize(window)
                let preferred = leaf.savedSplitRatio == nil
                    ? leaf.direction(for: leafRect)
                    : (leaf.savedSplitOverride ?? leaf.direction(for: leafRect))
                let alternate: SplitDirection = preferred == .horizontal ? .vertical : .horizontal
                let canChooseAxis = leaf.splitOverride == nil && leaf.savedSplitRatio == nil
                let directions = canChooseAxis ? [preferred, alternate] : [preferred]
                var preferredFit: PairFit?

                for dir in directions {
                    if pass == 0 {
                        let (a, b) = splitRects(leafRect, dir: dir)
                        let childMin = min(min(a.width, a.height), min(b.width, b.height))
                        if childMin < minSlotDimension { continue }
                    }

                    let fit = pairFit(existingMin, incomingMin, in: leafRect, dir: dir)
                    if dir == preferred { preferredFit = fit }
                    if fit.fits { return (leaf, dir) }
                }

                if pass == 1, let noting {
                    let fit = preferredFit ?? pairFit(existingMin, incomingMin,
                                                      in: leafRect, dir: preferred)
                    noting(SlotRefusal(tenantID: leaf.window?.windowID,
                                       slot: leafRect.size,
                                       direction: preferred,
                                       depthExhausted: false,
                                       axis: fit.refusedAxis,
                                       incomingMinimum: incomingMin,
                                       tenantMinimum: existingMin))
                }
            }
        }
        return nil
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

        guard let placement = fittingPlacement(for: window, in: tree, maxDepth: maxDepth,
                                               rect: rect, minimumSize: minimumSize) else {
            return false
        }

        let leaf = placement.leaf
        leaf.insert(window)
        // the axis chosen now is the axis this split keeps. read off the
        // rect at every layout, a later ratio change or a constrained
        // neighbour flipped it and turned a stack into columns. a remembered
        // boundary brings its own axis back through applySavedRatios
        if leaf.splitOverride == nil {
            leaf.splitOverride = placement.direction
            leaf.splitOverrideIsAutomatic = true
        }
        if let leafRect = tree.rectForNode(leaf, in: rect, gap: gapSize, padding: outerPadding) {
            hyprLog(.debug, .lifecycle, "smart insert fit at depth \(leaf.depth) (\(Int(leafRect.width))x\(Int(leafRect.height)))")
        }
        return true
    }
}
