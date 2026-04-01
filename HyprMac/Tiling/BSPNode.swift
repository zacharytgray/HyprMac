import Foundation

enum SplitDirection {
    case horizontal // left | right
    case vertical   // top / bottom
}

class BSPNode {
    var parent: BSPNode?
    var splitRatio: CGFloat = 0.5

    // nil = compute from rect aspect ratio (dwindle default)
    // set = forced direction (from togglesplit)
    var splitOverride: SplitDirection?

    // leaf = has a window (or is empty), split = has children
    var window: HyprWindow?
    var left: BSPNode?
    var right: BSPNode?

    var isLeaf: Bool { window != nil || (left == nil && right == nil) }
    var isEmpty: Bool { window == nil && left == nil && right == nil }

    // depth from root (0 = root)
    var depth: Int {
        var d = 0
        var node = parent
        while node != nil { d += 1; node = node?.parent }
        return d
    }

    init(window: HyprWindow? = nil) {
        self.window = window
    }

    // split this leaf, existing window goes left, new goes right
    func insert(_ newWindow: HyprWindow) {
        guard isLeaf else { return }

        let existing = self.window
        self.window = nil
        self.splitRatio = 0.5
        self.splitOverride = nil

        self.left = BSPNode(window: existing)
        self.left?.parent = self

        self.right = BSPNode(window: newWindow)
        self.right?.parent = self
    }

    // remove this leaf, promote sibling into parent
    func remove() {
        guard let parent = parent else { return }

        let sibling = (parent.left === self) ? parent.right : parent.left

        parent.window = sibling?.window
        parent.left = sibling?.left
        parent.right = sibling?.right
        parent.splitRatio = sibling?.splitRatio ?? 0.5
        parent.splitOverride = sibling?.splitOverride

        parent.left?.parent = parent
        parent.right?.parent = parent
    }

    func find(_ target: HyprWindow) -> BSPNode? {
        if window == target { return self }
        return left?.find(target) ?? right?.find(target)
    }

    // reset all split ratios to default (for transient min-size adjustments)
    func resetSplitRatios() {
        if !isLeaf {
            splitRatio = 0.5
        }
        left?.resetSplitRatios()
        right?.resetSplitRatios()
    }

    func allWindows() -> [HyprWindow] {
        if let w = window { return [w] }
        return (left?.allWindows() ?? []) + (right?.allWindows() ?? [])
    }

    // collect leaf nodes right-to-left (deepest-right first, for backtrack order)
    func allLeavesRightToLeft() -> [BSPNode] {
        if isLeaf && window != nil { return [self] }
        return (right?.allLeavesRightToLeft() ?? []) + (left?.allLeavesRightToLeft() ?? [])
    }

    // resolve split direction: override if set, otherwise dwindle (longer axis)
    func direction(for rect: CGRect) -> SplitDirection {
        if let forced = splitOverride { return forced }
        return rect.width >= rect.height ? .horizontal : .vertical
    }

    func layout(in rect: CGRect, gap: CGFloat) -> [(HyprWindow, CGRect)] {
        if let w = window {
            return [(w, rect)]
        }

        guard let l = left, let r = right else {
            return []
        }

        let halfGap = gap / 2
        let dir = direction(for: rect)

        switch dir {
        case .horizontal:
            let mid = rect.origin.x + rect.width * splitRatio
            let leftRect = CGRect(
                x: rect.origin.x,
                y: rect.origin.y,
                width: mid - rect.origin.x - halfGap,
                height: rect.height
            )
            let rightRect = CGRect(
                x: mid + halfGap,
                y: rect.origin.y,
                width: rect.maxX - mid - halfGap,
                height: rect.height
            )
            return l.layout(in: leftRect, gap: gap) + r.layout(in: rightRect, gap: gap)

        case .vertical:
            let mid = rect.origin.y + rect.height * splitRatio
            let topRect = CGRect(
                x: rect.origin.x,
                y: rect.origin.y,
                width: rect.width,
                height: mid - rect.origin.y - halfGap
            )
            let bottomRect = CGRect(
                x: rect.origin.x,
                y: mid + halfGap,
                width: rect.width,
                height: rect.maxY - mid - halfGap
            )
            return l.layout(in: topRect, gap: gap) + r.layout(in: bottomRect, gap: gap)
        }
    }
}
