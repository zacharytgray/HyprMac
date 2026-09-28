// Owning container for one binary space partition tree. `TilingEngine`
// keeps one per `(workspace, screen)` pair; this type is agnostic to
// that mapping. Pure with respect to AX and AppKit — geometry is all
// `CGRect` / `CGSize`, so the type is directly unit-testable.

import Foundation

enum BSPTargetEdge: CaseIterable, Equatable {
    case left
    case right
    case top
    case bottom
}

/// Owns a BSP tree's root node and exposes the structural and layout
/// API the tiling engine drives.
///
/// Default insert places the new window at the deepest-right leaf,
/// matching the dwindle convention. `smartInsert` refines this by
/// backtracking to shallower leaves when a child would fall below
/// `TilingConfig.minSlotDimension` on a constrained monitor (typical
/// vertical displays). Long-form algorithm walkthroughs live in
/// `docs/tiling-algorithm.md`.
class BSPTree {
    struct StructuralFingerprint: Equatable {
        struct Node: Equatable {
            let path: String
            let windowID: CGWindowID?
            let splitRatio: CGFloat
            let userSetRatio: Bool
            let splitOverride: SplitDirection?
            let savedSplitRatio: CGFloat?
            let savedChildWasLeft: Bool?
            let savedSplitOverride: SplitDirection?
            let pendingSplitRatio: CGFloat?
            let pendingSplitOverride: SplitDirection?
        }

        let nodes: [Node]
    }

    var root: BSPNode = BSPNode()

    func structuralFingerprint() -> StructuralFingerprint {
        var nodes: [StructuralFingerprint.Node] = []
        func walk(_ node: BSPNode, path: String) {
            nodes.append(StructuralFingerprint.Node(
                path: path,
                windowID: node.window?.windowID,
                splitRatio: node.splitRatio,
                userSetRatio: node.userSetRatio,
                splitOverride: node.splitOverride,
                savedSplitRatio: node.savedSplitRatio,
                savedChildWasLeft: node.savedChildWasLeft,
                savedSplitOverride: node.savedSplitOverride,
                pendingSplitRatio: node.pendingSplitRatio,
                pendingSplitOverride: node.pendingSplitOverride
            ))
            if let left = node.left { walk(left, path: path + "L") }
            if let right = node.right { walk(right, path: path + "R") }
        }
        walk(root, path: "")
        return StructuralFingerprint(nodes: nodes)
    }

    func deepClone() -> BSPTree {
        func clone(_ source: BSPNode, parent: BSPNode?) -> BSPNode {
            let copy = BSPNode(window: source.window)
            copy.parent = parent
            copy.splitRatio = source.splitRatio
            copy.userSetRatio = source.userSetRatio
            copy.splitOverride = source.splitOverride
            copy.splitOverrideIsAutomatic = source.splitOverrideIsAutomatic
            copy.savedSplitRatio = source.savedSplitRatio
            copy.savedChildWasLeft = source.savedChildWasLeft
            copy.savedSplitOverride = source.savedSplitOverride
            copy.pendingSplitRatio = source.pendingSplitRatio
            copy.pendingSplitOverride = source.pendingSplitOverride
            if let left = source.left { copy.left = clone(left, parent: copy) }
            if let right = source.right { copy.right = clone(right, parent: copy) }
            return copy
        }
        let tree = BSPTree()
        tree.root = clone(root, parent: nil)
        return tree
    }

    func candidateTree(draggedID: CGWindowID, targetID: CGWindowID,
                       edge: BSPTargetEdge, maxDepth: Int) -> BSPTree? {
        guard draggedID != targetID,
              let dragged = allWindows.first(where: { $0.windowID == draggedID }),
              allWindows.contains(where: { $0.windowID == targetID }) else { return nil }
        let originalIDs = allWindows.map(\.windowID)
        let candidate = deepClone()
        candidate.remove(dragged)
        guard let targetWindow = candidate.allWindows.first(where: { $0.windowID == targetID }),
              let target = candidate.root.find(targetWindow), target.isLeaf,
              target.depth < maxDepth else { return nil }

        Self.split(target, adding: dragged, edge: edge)

        let candidateIDs = candidate.allWindows.map(\.windowID)
        guard candidate.root.allLeavesRightToLeft().allSatisfy({ $0.depth <= maxDepth }),
              candidateIDs.count == originalIDs.count,
              Set(candidateIDs) == Set(originalIDs),
              candidateIDs.count == Set(candidateIDs).count else { return nil }
        return candidate
    }

    // MARK: - cross-tree candidates

    /// A clone without `windowID`, for a window leaving this tree for
    /// another screen's. The sibling is promoted as on a close. nil when the
    /// window is not here.
    func candidateTree(removing windowID: CGWindowID) -> BSPTree? {
        guard let window = allWindows.first(where: { $0.windowID == windowID }) else { return nil }
        let candidate = deepClone()
        candidate.remove(window)
        candidate.root.pruneEmptyNodes()
        return candidate
    }

    /// A clone with `window` split in beside `targetID` on `edge`, for a
    /// window arriving from another screen's tree. The same split a
    /// same-tree drop makes. nil when the target is missing, the window is
    /// already here, or the split would pass `maxDepth`.
    func candidateTree(inserting window: HyprWindow, beside targetID: CGWindowID,
                       edge: BSPTargetEdge, maxDepth: Int) -> BSPTree? {
        let originalIDs = allWindows.map(\.windowID)
        guard !originalIDs.contains(window.windowID),
              let targetWindow = allWindows.first(where: { $0.windowID == targetID }) else { return nil }
        let candidate = deepClone()
        guard let target = candidate.root.find(targetWindow), target.isLeaf,
              target.depth < maxDepth else { return nil }

        Self.split(target, adding: window, edge: edge)

        let candidateIDs = candidate.allWindows.map(\.windowID)
        guard candidate.root.allLeavesRightToLeft().allSatisfy({ $0.depth <= maxDepth }),
              candidateIDs.count == originalIDs.count + 1,
              Set(candidateIDs) == Set(originalIDs + [window.windowID]) else { return nil }
        return candidate
    }

    /// A tree holding only `window` at its root, for a window arriving on a
    /// workspace with no tiles. nil when this tree has any.
    func candidateTree(rootedAt window: HyprWindow) -> BSPTree? {
        guard allWindows.isEmpty else { return nil }
        let candidate = BSPTree()
        candidate.root.window = window
        return candidate
    }

    /// A clone with `replacement` in `windowID`'s leaf, topology and ratios
    /// untouched, for a swap across trees. nil when the window is not here
    /// or the replacement already is.
    func candidateTree(replacing windowID: CGWindowID, with replacement: HyprWindow) -> BSPTree? {
        guard !allWindows.contains(where: { $0.windowID == replacement.windowID }),
              let window = allWindows.first(where: { $0.windowID == windowID }) else { return nil }
        let candidate = deepClone()
        guard let leaf = candidate.root.find(window) else { return nil }
        leaf.window = replacement
        return candidate
    }

    /// Split leaf `target` in two on `edge`: `window` on that side, the
    /// tenant on the other. Horizontal for left/right, vertical for
    /// top/bottom, at the default ratio with the ratio memory cleared.
    private static func split(_ target: BSPNode, adding window: HyprWindow, edge: BSPTargetEdge) {
        let existing = target.window
        let addedNode = BSPNode(window: window)
        let targetNode = BSPNode(window: existing)
        let addedFirst = edge == .left || edge == .top
        target.window = nil
        target.left = addedFirst ? addedNode : targetNode
        target.right = addedFirst ? targetNode : addedNode
        target.left?.parent = target
        target.right?.parent = target
        target.splitRatio = TilingConfig.defaultRatio
        target.userSetRatio = false
        target.splitOverride = (edge == .left || edge == .right) ? .horizontal : .vertical
        target.splitOverrideIsAutomatic = false
        target.savedSplitRatio = nil
        target.savedChildWasLeft = nil
        target.savedSplitOverride = nil
        target.pendingSplitRatio = nil
        target.pendingSplitOverride = nil
    }

    /// Split `target`, a leaf or a whole subtree, with `window` on the side
    /// it left from, on the axis and at the ratio the split had: a member
    /// coming back to the slot it was taken out of. The tenant moves down
    /// into a child, so `target` keeps its place under its parent.
    func insert(_ window: HyprWindow, beside target: BSPNode, onLeft: Bool,
                direction: SplitDirection, ratio: CGFloat, userSet: Bool) {
        let tenant = BSPNode(window: target.window)
        tenant.left = target.left
        tenant.right = target.right
        tenant.left?.parent = tenant
        tenant.right?.parent = tenant
        tenant.splitRatio = target.splitRatio
        tenant.userSetRatio = target.userSetRatio
        tenant.splitOverride = target.splitOverride
        tenant.splitOverrideIsAutomatic = target.splitOverrideIsAutomatic
        tenant.savedSplitRatio = target.savedSplitRatio
        tenant.savedChildWasLeft = target.savedChildWasLeft
        tenant.savedSplitOverride = target.savedSplitOverride
        tenant.pendingSplitRatio = target.pendingSplitRatio
        tenant.pendingSplitOverride = target.pendingSplitOverride

        let added = BSPNode(window: window)
        target.window = nil
        target.left = onLeft ? added : tenant
        target.right = onLeft ? tenant : added
        target.left?.parent = target
        target.right?.parent = target
        target.splitRatio = ratio
        target.userSetRatio = userSet
        target.splitOverride = direction
        target.splitOverrideIsAutomatic = true
        target.savedSplitRatio = nil
        target.savedChildWasLeft = nil
        target.savedSplitOverride = nil
        target.pendingSplitRatio = nil
        target.pendingSplitOverride = nil
    }

    /// The node whose subtree holds exactly `ids`, or nil when those
    /// windows no longer form one.
    func node(holdingExactly ids: Set<CGWindowID>) -> BSPNode? {
        guard let first = ids.first,
              let start = allWindows.first(where: { $0.windowID == first }),
              var node = root.find(start) else { return nil }
        while true {
            let held = Set(node.allWindows().map(\.windowID))
            if held == ids { return node }
            guard held.isStrictSubset(of: ids), let parent = node.parent else { return nil }
            node = parent
        }
    }

    /// Drop the automatic axis pins when the root's disagrees with `rect`.
    /// The tree was laid out for a screen of the other orientation, and
    /// the axes chosen there would stack a landscape layout on a portrait
    /// monitor. Pins from `togglesplit` stay.
    func dropAutomaticSplitOverrides(ifPinnedAgainst rect: CGRect) {
        guard root.splitOverrideIsAutomatic, let pinned = root.splitOverride,
              pinned != (rect.width >= rect.height ? .horizontal : .vertical) else { return }
        root.clearAutomaticSplitOverrides()
    }

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
    /// No longer called on removal — sibling promotion in `BSPNode.remove`
    /// preserves the surviving arrangement, and rebuilding here reshuffled
    /// unrelated windows on every close/hide. Kept for explicit rebuilds
    /// (tests, potential future Retile All hook). All split overrides and
    /// user-set ratios are dropped — a structural rebuild voids both.
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
        parent.splitOverrideIsAutomatic = false
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
    /// `givingWayOnUserSet` lets a split the user set by hand move when no
    /// other ancestor on the axis can make room. The verified pass asks for
    /// that after a real refusal: the alternative is a layout that is
    /// refused, rolled back and refused again on every retile. Fit checks
    /// never ask, so a hand-set ratio still refuses a swap or an arrival
    /// up front.
    func adjustForMinSizes(_ conflicts: [(window: HyprWindow, actual: CGSize)],
                           in rect: CGRect, gap: CGFloat, padding: CGFloat,
                           givingWayOnUserSet: Bool = false) {
        let padded = rect.insetBy(dx: padding, dy: padding)

        for (window, actualSize) in conflicts {
            guard let leaf = root.find(window) else { continue }
            guard let leafRect = rectForNodeHelper(node: root, target: leaf, rect: padded, gap: gap) else { continue }

            if actualSize.width > leafRect.width + TilingConfig.minSizeConflictSlackPx,
               !adjustAxisRatio(from: leaf, needed: actualSize.width,
                                axis: .horizontal, rect: padded, gap: gap,
                                windowTitle: window.title, allowUserSet: false),
               givingWayOnUserSet {
                _ = adjustAxisRatio(from: leaf, needed: actualSize.width,
                                    axis: .horizontal, rect: padded, gap: gap,
                                    windowTitle: window.title, allowUserSet: true)
            }

            if actualSize.height > leafRect.height + TilingConfig.minSizeConflictSlackPx,
               !adjustAxisRatio(from: leaf, needed: actualSize.height,
                                axis: .vertical, rect: padded, gap: gap,
                                windowTitle: window.title, allowUserSet: false),
               givingWayOnUserSet {
                _ = adjustAxisRatio(from: leaf, needed: actualSize.height,
                                    axis: .vertical, rect: padded, gap: gap,
                                    windowTitle: window.title, allowUserSet: true)
            }
        }
    }

    /// `true` when an ancestor on `axis` was found to tune (whether or not
    /// its ratio needed to move); `false` when every one was skipped.
    @discardableResult
    private func adjustAxisRatio(from leaf: BSPNode, needed: CGFloat,
                                 axis: SplitDirection, rect: CGRect, gap: CGFloat,
                                 windowTitle: String?, allowUserSet: Bool) -> Bool {
        let halfGap = gap / 2
        var node: BSPNode = leaf

        while let parent = node.parent {
            defer { node = parent }
            if parent.userSetRatio && !allowUserSet { continue }
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
            return true
        }
        return false
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

    // MARK: - snapshot / restore

    /// Opaque snapshot of every per-node knob (window, splitRatio, userSetRatio,
    /// splitOverride, and both halves of the ratio memory: the saved boundary a
    /// leaf carries and the pending restore a fresh split is waiting on).
    /// Pair with `restore(_:)` to scope a speculative mutation —
    /// e.g., `canSwapWindows` mutates the tree to test a hypothetical layout
    /// and rewinds via the snapshot.
    ///
    /// Topology (left/right pointers) is **not** captured. Speculative paths
    /// that need topology rewind must restore that themselves; in practice the
    /// only current caller (canSwapWindows) only mutates window references and
    /// ratios, not topology.
    struct Snapshot {
        fileprivate let states: [NodeState]
        fileprivate struct NodeState {
            let node: BSPNode
            let splitRatio: CGFloat
            let userSetRatio: Bool
            let splitOverride: SplitDirection?
            let splitOverrideIsAutomatic: Bool
            let window: HyprWindow?
            let savedSplitRatio: CGFloat?
            let savedChildWasLeft: Bool?
            let savedSplitOverride: SplitDirection?
            let pendingSplitRatio: CGFloat?
            let pendingSplitOverride: SplitDirection?
        }
    }

    func snapshot() -> Snapshot {
        var states: [Snapshot.NodeState] = []
        func walk(_ node: BSPNode) {
            states.append(Snapshot.NodeState(node: node,
                                             splitRatio: node.splitRatio,
                                             userSetRatio: node.userSetRatio,
                                             splitOverride: node.splitOverride,
                                             splitOverrideIsAutomatic: node.splitOverrideIsAutomatic,
                                             window: node.window,
                                             savedSplitRatio: node.savedSplitRatio,
                                             savedChildWasLeft: node.savedChildWasLeft,
                                             savedSplitOverride: node.savedSplitOverride,
                                             pendingSplitRatio: node.pendingSplitRatio,
                                             pendingSplitOverride: node.pendingSplitOverride))
            if let left = node.left { walk(left) }
            if let right = node.right { walk(right) }
        }
        walk(root)
        return Snapshot(states: states)
    }

    func restore(_ snapshot: Snapshot) {
        for state in snapshot.states {
            state.node.splitRatio = state.splitRatio
            state.node.userSetRatio = state.userSetRatio
            state.node.splitOverride = state.splitOverride
            state.node.splitOverrideIsAutomatic = state.splitOverrideIsAutomatic
            state.node.window = state.window
            state.node.savedSplitRatio = state.savedSplitRatio
            state.node.savedChildWasLeft = state.savedChildWasLeft
            state.node.savedSplitOverride = state.savedSplitOverride
            state.node.pendingSplitRatio = state.pendingSplitRatio
            state.node.pendingSplitOverride = state.pendingSplitOverride
        }
    }
}
