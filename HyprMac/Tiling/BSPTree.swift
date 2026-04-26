// BSPTree — owning container for one binary space partition tree.
//
// the tiling engine keeps one tree per (workspace, screen) pair; this type is
// agnostic to that mapping. every public method is pure with respect to the
// tree (no AX, no AppKit) so it's directly unit-testable. layout math runs
// entirely through CGRect / CGSize.
//
// dwindle layout: each split picks the longer axis of the parent rect; the new
// window goes on the right/bottom by default. smartInsert refines this by
// backtracking to shallower leaves when slots would fall below
// TilingConfig.minSlotDimension on constrained monitors.
//
// see also: BSPNode (per-node invariants), TilingConfig (bounds + tolerances),
// docs/tiling-algorithm.md (long-form, lands in Phase 8).
import Foundation

class BSPTree {
    var root: BSPNode = BSPNode()

    /// Insert a window via plain dwindle: split the deepest-right leaf.
    ///
    /// Used as a fallback path when smart-insert isn't applicable (empty tree,
    /// forceInsertWindow path-B reinsert) or when the caller has already
    /// validated geometry. Most production callers should use ``smartInsert``.
    ///
    /// - Returns: `false` if splitting the deepest-right leaf would exceed
    ///   `maxDepth`; `true` otherwise. On false, the tree is unchanged.
    @discardableResult
    func insert(_ window: HyprWindow, maxDepth: Int = Int.max) -> Bool {
        if root.isEmpty {
            root.window = window
            return true
        }

        guard let target = deepestRightLeaf(root) else { return false }

        // splitting this leaf creates children at depth+1
        // if that exceeds maxDepth, refuse the insert
        if target.depth >= maxDepth {
            return false
        }

        target.insert(window)
        return true
    }

    /// Dwindle insert with backtracking on constrained monitors.
    ///
    /// Walks leaves deepest-right first; the first leaf whose split would
    /// produce children at or above `minSlotDimension` on both axes wins.
    /// If no leaf meets the minimum, falls back to the deepest-right leaf
    /// regardless — the new window will be smaller than the floor, but no
    /// window is dropped. Backtracking is what produces balanced 2×2 grids
    /// on vertical monitors instead of dwindle's deeper spiral.
    ///
    /// - Returns: `true` if the window was inserted (always succeeds when
    ///   any leaf has `depth < maxDepth`); `false` only if every leaf is
    ///   already at the depth ceiling.
    @discardableResult
    func smartInsert(_ window: HyprWindow, maxDepth: Int, in rect: CGRect,
                     gap: CGFloat, padding: CGFloat, minSlotDimension: CGFloat) -> Bool {
        if root.isEmpty {
            root.window = window
            return true
        }

        let padded = rect.insetBy(dx: padding, dy: padding)
        let leaves = root.allLeavesRightToLeft()

        for leaf in leaves {
            guard leaf.depth < maxDepth else { continue }
            guard let leafRect = rectForNodeHelper(node: root, target: leaf, rect: padded, gap: gap) else { continue }

            let dir = leaf.direction(for: leafRect)
            let childMin: CGFloat
            switch dir {
            case .horizontal:
                childMin = min((leafRect.width - gap) / 2, leafRect.height)
            case .vertical:
                childMin = min(leafRect.width, (leafRect.height - gap) / 2)
            }

            if childMin >= minSlotDimension {
                leaf.insert(window)
                hyprLog(.debug, .lifecycle, "smart insert at depth \(leaf.depth) (\(Int(leafRect.width))x\(Int(leafRect.height)))")
                return true
            }
        }

        // no leaf meets the minimum — fall back to deepest-right anyway
        if let fallback = leaves.first(where: { $0.depth < maxDepth }) {
            fallback.insert(window)
            hyprLog(.debug, .lifecycle, "smart insert fallback — no slot met \(Int(minSlotDimension))px minimum")
            return true
        }

        return false
    }

    /// Remove `window` from the tree. No-op if `window` isn't present.
    /// Replaces the root with a fresh empty node when removing the last
    /// window — callers don't need to special-case the empty case.
    func remove(_ window: HyprWindow) {
        guard let node = root.find(window) else { return }

        if node === root {
            root = BSPNode()
            return
        }

        node.remove()
    }

    /// Rebuild the tree from scratch in left-to-right window order.
    ///
    /// Called after a removal where the surviving windows might now fit at
    /// deeper dwindle positions than they currently occupy (e.g., a 2×2 grid
    /// produced by smart-insert backtracking can collapse back to a normal
    /// dwindle spiral once the constraint is gone). All split overrides and
    /// user-set ratios are dropped — this is intentional, since a structural
    /// rebuild voids both.
    func compact(maxDepth: Int, in rect: CGRect, gap: CGFloat, padding: CGFloat, minSlotDimension: CGFloat) {
        let windows = allWindows // left-to-right preserves insertion order
        guard windows.count > 1 else { return }

        root = BSPNode()
        for w in windows {
            smartInsert(w, maxDepth: maxDepth, in: rect, gap: gap,
                        padding: padding, minSlotDimension: minSlotDimension)
        }
    }

    func contains(_ window: HyprWindow) -> Bool {
        root.find(window) != nil
    }

    /// Swap the windows occupying two leaves. Topology and ratios are
    /// preserved — only the window references change. No-op if either window
    /// isn't in the tree (callers handle cross-tree swaps separately).
    func swap(_ a: HyprWindow, _ b: HyprWindow) {
        guard let nodeA = root.find(a), let nodeB = root.find(b) else { return }
        nodeA.window = b
        nodeB.window = a
    }

    /// Hyprland-style togglesplit. Flips the parent node's split direction
    /// (horizontal ↔ vertical) regardless of what dwindle would have picked
    /// from rect aspect ratio. Sets `splitOverride` so the choice survives
    /// retiles. No-op if `window` is the root (no parent to flip).
    func toggleSplit(for window: HyprWindow, in rect: CGRect, gap: CGFloat, padding: CGFloat) {
        guard let leaf = root.find(window), let parent = leaf.parent else { return }

        // figure out what direction this parent would normally use
        // we need to compute the rect this parent occupies to know the default direction
        let paddedRect = rect.insetBy(dx: padding, dy: padding)
        let currentDir = resolveDirection(of: parent, in: paddedRect, gap: gap)

        // flip it
        let newDir: SplitDirection = (currentDir == .horizontal) ? .vertical : .horizontal
        parent.splitOverride = newDir
    }

    // walk the tree to find what rect a given node occupies, then get its direction
    private func resolveDirection(of target: BSPNode, in rect: CGRect, gap: CGFloat) -> SplitDirection {
        return resolveDirectionHelper(node: root, target: target, rect: rect, gap: gap) ?? .horizontal
    }

    private func resolveDirectionHelper(node: BSPNode, target: BSPNode, rect: CGRect, gap: CGFloat) -> SplitDirection? {
        if node === target {
            if let forced = node.splitOverride { return forced }
            return rect.width >= rect.height ? .horizontal : .vertical
        }

        guard let l = node.left, let r = node.right else { return nil }

        let dir: SplitDirection
        if let forced = node.splitOverride { dir = forced }
        else { dir = rect.width >= rect.height ? .horizontal : .vertical }

        let halfGap = gap / 2

        switch dir {
        case .horizontal:
            let mid = rect.origin.x + rect.width * node.splitRatio
            let leftRect = CGRect(x: rect.origin.x, y: rect.origin.y,
                                  width: mid - rect.origin.x - halfGap, height: rect.height)
            let rightRect = CGRect(x: mid + halfGap, y: rect.origin.y,
                                   width: rect.maxX - mid - halfGap, height: rect.height)
            return resolveDirectionHelper(node: l, target: target, rect: leftRect, gap: gap)
                ?? resolveDirectionHelper(node: r, target: target, rect: rightRect, gap: gap)

        case .vertical:
            let mid = rect.origin.y + rect.height * node.splitRatio
            let topRect = CGRect(x: rect.origin.x, y: rect.origin.y,
                                 width: rect.width, height: mid - rect.origin.y - halfGap)
            let bottomRect = CGRect(x: rect.origin.x, y: mid + halfGap,
                                    width: rect.width, height: rect.maxY - mid - halfGap)
            return resolveDirectionHelper(node: l, target: target, rect: topRect, gap: gap)
                ?? resolveDirectionHelper(node: r, target: target, rect: bottomRect, gap: gap)
        }
    }

    /// Locate the rect that `target` occupies in the laid-out tree.
    /// Returns nil if `target` isn't reachable from `root`. Used by smart-insert
    /// backtracking and adjustForMinSizes to query post-layout geometry without
    /// re-running the full layout pass.
    func rectForNode(_ target: BSPNode, in rect: CGRect, gap: CGFloat, padding: CGFloat) -> CGRect? {
        let padded = rect.insetBy(dx: padding, dy: padding)
        return rectForNodeHelper(node: root, target: target, rect: padded, gap: gap)
    }

    private func rectForNodeHelper(node: BSPNode, target: BSPNode, rect: CGRect, gap: CGFloat) -> CGRect? {
        if node === target { return rect }
        guard let l = node.left, let r = node.right else { return nil }

        let dir = node.direction(for: rect)
        let halfGap = gap / 2

        switch dir {
        case .horizontal:
            let mid = rect.origin.x + rect.width * node.splitRatio
            let leftRect = CGRect(x: rect.origin.x, y: rect.origin.y,
                                  width: mid - rect.origin.x - halfGap, height: rect.height)
            let rightRect = CGRect(x: mid + halfGap, y: rect.origin.y,
                                   width: rect.maxX - mid - halfGap, height: rect.height)
            return rectForNodeHelper(node: l, target: target, rect: leftRect, gap: gap)
                ?? rectForNodeHelper(node: r, target: target, rect: rightRect, gap: gap)

        case .vertical:
            let mid = rect.origin.y + rect.height * node.splitRatio
            let topRect = CGRect(x: rect.origin.x, y: rect.origin.y,
                                 width: rect.width, height: mid - rect.origin.y - halfGap)
            let bottomRect = CGRect(x: rect.origin.x, y: mid + halfGap,
                                    width: rect.width, height: rect.maxY - mid - halfGap)
            return rectForNodeHelper(node: l, target: target, rect: topRect, gap: gap)
                ?? rectForNodeHelper(node: r, target: target, rect: bottomRect, gap: gap)
        }
    }

    /// Pass-2 ratio redistribution after a min-size conflict.
    ///
    /// Each `(window, actualSize)` describes a leaf where the app refused to
    /// shrink to its allocated rect — `actualSize` is what setFrame readback
    /// observed. For each conflict the algorithm walks up from the leaf to
    /// the nearest matching-axis ancestor and biases its splitRatio toward
    /// the conflicted child (clamped to [minRatio, maxRatio]).
    ///
    /// Width and height conflicts are processed independently because the
    /// immediate parent often splits the wrong axis.
    ///
    /// - Important: Adjustment is bounded to **one** ancestor per axis. This
    ///   is intentional (see `adjustAxisRatio`): cascading 0.85/0.15 ratios
    ///   through multiple ancestors produces effective 1/16 slots that defeat
    ///   the depth ceiling. One window's min-size conflict will not push
    ///   another window outside its slot.
    func adjustForMinSizes(_ conflicts: [(window: HyprWindow, actual: CGSize)],
                           in rect: CGRect, gap: CGFloat, padding: CGFloat) {
        let padded = rect.insetBy(dx: padding, dy: padding)

        for (window, actualSize) in conflicts {
            guard let leaf = root.find(window) else { continue }
            guard let leafRect = rectForNodeHelper(node: root, target: leaf, rect: padded, gap: gap) else { continue }

            if actualSize.width > leafRect.width + TilingConfig.minSizeConflictSlackPx {
                adjustAxisRatio(from: leaf, needed: actualSize.width,
                                axis: .horizontal, rect: padded, gap: gap,
                                windowTitle: window.title)
            }

            if actualSize.height > leafRect.height + TilingConfig.minSizeConflictSlackPx {
                adjustAxisRatio(from: leaf, needed: actualSize.height,
                                axis: .vertical, rect: padded, gap: gap,
                                windowTitle: window.title)
            }
        }
    }

    private func adjustAxisRatio(from leaf: BSPNode, needed: CGFloat,
                                 axis: SplitDirection, rect: CGRect, gap: CGFloat,
                                 windowTitle: String?) {
        let halfGap = gap / 2
        var node: BSPNode = leaf

        while let parent = node.parent {
            defer { node = parent }
            if parent.userSetRatio { continue }
            guard let parentRect = rectForNodeHelper(node: root, target: parent, rect: rect, gap: gap) else { continue }
            guard parent.direction(for: parentRect) == axis else { continue }

            let isLeft = parent.left === node
            let extent = axis == .horizontal ? parentRect.width : parentRect.height
            guard extent > 0 else { continue }

            let raw = (needed + halfGap) / extent
            let clamped: CGFloat
            if isLeft {
                clamped = min(raw, TilingConfig.maxRatio)
                if clamped > parent.splitRatio {
                    parent.splitRatio = clamped
                    hyprLog(.debug, .lifecycle, "adjusted \(axis == .horizontal ? "H" : "V") ratio → \(String(format: "%.2f", clamped)) for '\(windowTitle ?? "?")'")
                }
            } else {
                clamped = max(1.0 - raw, TilingConfig.minRatio)
                if clamped < parent.splitRatio {
                    parent.splitRatio = clamped
                    hyprLog(.debug, .lifecycle, "adjusted \(axis == .horizontal ? "H" : "V") ratio → \(String(format: "%.2f", clamped)) for '\(windowTitle ?? "?")'")
                }
            }

            // see adjustForMinSizes doc comment: one conflict tunes one
            // ancestor on this axis. stacking 0.15/0.85 across multiple
            // ancestors creates effective 1/16 slots even with depth respected.
            return
        }
    }

    /// Convert a manual user resize back into split-ratio updates.
    ///
    /// Walks from the resized leaf upward, recomputing each ancestor's
    /// splitRatio from the new frame's edge position. Touched ancestors are
    /// flagged `userSetRatio = true` so subsequent retiles preserve them.
    /// Sub-pixel changes below `TilingConfig.manualResizeRatioTolerance` are
    /// skipped to avoid AX writes from drag jitter.
    func applyResizeDelta(for window: HyprWindow, newFrame: CGRect,
                          in rect: CGRect, gap: CGFloat, padding: CGFloat) {
        let padded = rect.insetBy(dx: padding, dy: padding)
        guard let leaf = root.find(window) else { return }

        var node = leaf
        while let parent = node.parent {
            guard let parentRect = rectForNodeHelper(node: root, target: parent, rect: padded, gap: gap) else {
                node = parent
                continue
            }

            let isLeft = parent.left === node
            let dir = parent.direction(for: parentRect)

            switch dir {
            case .horizontal:
                // the shared edge is at: origin.x + width * ratio
                // if this node is the left child, its right edge = the split line
                // if right child, its left edge = the split line
                let splitX: CGFloat
                if isLeft {
                    splitX = newFrame.maxX + gap / 2
                } else {
                    splitX = newFrame.origin.x - gap / 2
                }
                let newRatio = (splitX - parentRect.origin.x) / parentRect.width
                let clamped = min(max(newRatio, TilingConfig.minRatio), TilingConfig.maxRatio)
                if abs(clamped - parent.splitRatio) > TilingConfig.manualResizeRatioTolerance {
                    parent.splitRatio = clamped
                    parent.userSetRatio = true
                    hyprLog(.debug, .lifecycle, "manual resize: horizontal ratio → \(String(format: "%.2f", clamped))")
                }

            case .vertical:
                let splitY: CGFloat
                if isLeft {
                    splitY = newFrame.maxY + gap / 2
                } else {
                    splitY = newFrame.origin.y - gap / 2
                }
                let newRatio = (splitY - parentRect.origin.y) / parentRect.height
                let clamped = min(max(newRatio, TilingConfig.minRatio), TilingConfig.maxRatio)
                if abs(clamped - parent.splitRatio) > TilingConfig.manualResizeRatioTolerance {
                    parent.splitRatio = clamped
                    parent.userSetRatio = true
                    hyprLog(.debug, .lifecycle, "manual resize: vertical ratio → \(String(format: "%.2f", clamped))")
                }
            }

            node = parent
        }
    }

    /// Compute layout rects for every window in the tree, with outer padding
    /// applied. Output is in tree iteration order (left-to-right). Pure
    /// function — no side effects on the tree.
    func layout(in rect: CGRect, gap: CGFloat, padding: CGFloat) -> [(HyprWindow, CGRect)] {
        let padded = rect.insetBy(dx: padding, dy: padding)
        return root.layout(in: padded, gap: gap)
    }

    var allWindows: [HyprWindow] {
        root.allWindows()
    }

    /// The most recently inserted window — i.e., the dwindle spiral's tip.
    /// Used by forceInsertWindow for eviction selection.
    func deepestRightLeafWindow() -> HyprWindow? {
        return deepestRightLeaf(root)?.window
    }

    private func deepestRightLeaf(_ node: BSPNode) -> BSPNode? {
        if node.isLeaf { return node }
        return deepestRightLeaf(node.right ?? node.left ?? node)
    }
}
