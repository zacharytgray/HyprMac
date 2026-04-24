import Foundation

class BSPTree {
    var root: BSPNode = BSPNode()

    // insert a window. returns false if maxDepth would be exceeded.
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

    // smart dwindle insert: tries deepest-right first, backtracks to shallower
    // leaves if splitting would create children below minSlotDimension.
    // produces balanced layouts on constrained monitors (e.g. 2x2 grid on vertical).
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
                hyprLog("smart insert at depth \(leaf.depth) (\(Int(leafRect.width))x\(Int(leafRect.height)))")
                return true
            }
        }

        // no leaf meets the minimum — fall back to deepest-right anyway
        if let fallback = leaves.first(where: { $0.depth < maxDepth }) {
            fallback.insert(window)
            hyprLog("smart insert fallback — no slot met \(Int(minSlotDimension))px minimum")
            return true
        }

        return false
    }

    func remove(_ window: HyprWindow) {
        guard let node = root.find(window) else { return }

        if node === root {
            root = BSPNode()
            return
        }

        node.remove()
    }

    // rebuild tree so windows settle into deepest-possible dwindle positions.
    // called after removals — backtracked windows move deeper when slots free up.
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

    // swap two windows' positions in the tree (just swap refs, then retile)
    func swap(_ a: HyprWindow, _ b: HyprWindow) {
        guard let nodeA = root.find(a), let nodeB = root.find(b) else { return }
        nodeA.window = b
        nodeB.window = a
    }

    // toggle the split direction of the focused window's parent node
    // this is hyprland's "togglesplit" — flips the axis of the containing split
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

    // compute the rect a given node occupies in the layout
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

    // adjust split ratios to accommodate windows that can't shrink to their allocated size.
    // conflicts: [(window, actualSize)] where actualSize is what the app accepted after setFrame.
    // width and height are handled independently by walking to the nearest
    // matching-axis ancestor; the immediate parent may split the wrong axis.
    func adjustForMinSizes(_ conflicts: [(window: HyprWindow, actual: CGSize)],
                           in rect: CGRect, gap: CGFloat, padding: CGFloat) {
        let padded = rect.insetBy(dx: padding, dy: padding)

        for (window, actualSize) in conflicts {
            guard let leaf = root.find(window) else { continue }
            guard let leafRect = rectForNodeHelper(node: root, target: leaf, rect: padded, gap: gap) else { continue }

            if actualSize.width > leafRect.width + 5 {
                adjustAxisRatio(from: leaf, needed: actualSize.width,
                                axis: .horizontal, rect: padded, gap: gap,
                                windowTitle: window.title)
            }

            if actualSize.height > leafRect.height + 5 {
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
                clamped = min(raw, 0.85)
                if clamped > parent.splitRatio {
                    parent.splitRatio = clamped
                    hyprLog("adjusted \(axis == .horizontal ? "H" : "V") ratio → \(String(format: "%.2f", clamped)) for '\(windowTitle ?? "?")'")
                }
            } else {
                clamped = max(1.0 - raw, 0.15)
                if clamped < parent.splitRatio {
                    parent.splitRatio = clamped
                    hyprLog("adjusted \(axis == .horizontal ? "H" : "V") ratio → \(String(format: "%.2f", clamped)) for '\(windowTitle ?? "?")'")
                }
            }

            if raw <= 0.85 { return }
        }
    }

    // map a manual resize back to split ratio changes.
    // walks from the resized window's leaf up to root, adjusting each ancestor's
    // split ratio based on the new frame's edge position.
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
                let clamped = min(max(newRatio, 0.15), 0.85)
                if abs(clamped - parent.splitRatio) > 0.01 {
                    parent.splitRatio = clamped
                    parent.userSetRatio = true
                    hyprLog("manual resize: horizontal ratio → \(String(format: "%.2f", clamped))")
                }

            case .vertical:
                let splitY: CGFloat
                if isLeft {
                    splitY = newFrame.maxY + gap / 2
                } else {
                    splitY = newFrame.origin.y - gap / 2
                }
                let newRatio = (splitY - parentRect.origin.y) / parentRect.height
                let clamped = min(max(newRatio, 0.15), 0.85)
                if abs(clamped - parent.splitRatio) > 0.01 {
                    parent.splitRatio = clamped
                    parent.userSetRatio = true
                    hyprLog("manual resize: vertical ratio → \(String(format: "%.2f", clamped))")
                }
            }

            node = parent
        }
    }

    func layout(in rect: CGRect, gap: CGFloat, padding: CGFloat) -> [(HyprWindow, CGRect)] {
        let padded = rect.insetBy(dx: padding, dy: padding)
        return root.layout(in: padded, gap: gap)
    }

    var allWindows: [HyprWindow] {
        root.allWindows()
    }

    // the most recently inserted window (deepest-right leaf)
    func deepestRightLeafWindow() -> HyprWindow? {
        return deepestRightLeaf(root)?.window
    }

    private func deepestRightLeaf(_ node: BSPNode) -> BSPNode? {
        if node.isLeaf { return node }
        return deepestRightLeaf(node.right ?? node.left ?? node)
    }
}
