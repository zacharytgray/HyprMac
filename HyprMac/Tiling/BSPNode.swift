// BSPNode — a single node in the binary space partition tree used for tiling.
//
// invariants (enforced by construction; tests pin them in BSPNodeTests):
//   - leaf      = window != nil  ||  (left == nil && right == nil)
//   - internal  = left != nil    &&  right != nil
//   - empty leaf is a transient state used during compact/prune; outside those
//     paths every populated tree has window-bearing leaves.
//   - splitRatio is clamped to [TilingConfig.minRatio, TilingConfig.maxRatio]
//     by the property setter — direct writes can't escape these bounds.
//
// the file is intentionally Foundation-only — no AppKit, no AX. all geometry
// flows in via parameters (rect, gap) so layout is unit-testable in isolation.
import Foundation

enum SplitDirection {
    case horizontal // left | right
    case vertical   // top / bottom
}

class BSPNode {
    var parent: BSPNode?

    // clamped to [TilingConfig.minRatio, TilingConfig.maxRatio] on every write.
    // shared bounds with pairFits and adjustForMinSizes; out-of-bounds ratios
    // would put the layout math into states it isn't designed for.
    private var _splitRatio: CGFloat = TilingConfig.defaultRatio
    var splitRatio: CGFloat {
        get { _splitRatio }
        set { _splitRatio = max(TilingConfig.minRatio, min(TilingConfig.maxRatio, newValue)) }
    }

    // sticky once set — preserved across resetSplitRatios so user-driven manual
    // resizes survive a retile (cleared explicitly by clearUserSetRatios on
    // structural changes).
    var userSetRatio: Bool = false

    // nil = compute from rect aspect ratio (dwindle default).
    // set = forced direction from togglesplit; survives until a sibling
    // restructure (insert/remove on this node, which resets all three knobs).
    var splitOverride: SplitDirection?

    var window: HyprWindow?
    var left: BSPNode?
    var right: BSPNode?

    // see invariants at top of file.
    var isLeaf: Bool { window != nil || (left == nil && right == nil) }
    var isEmpty: Bool { window == nil && left == nil && right == nil }

    // depth from root (0 = root).
    var depth: Int {
        var d = 0
        var node = parent
        while node != nil { d += 1; node = node?.parent }
        return d
    }

    init(window: HyprWindow? = nil) {
        self.window = window
    }

    // split this leaf into two children. the existing window (if any) goes
    // left, the new window goes right. resets splitRatio / splitOverride /
    // userSetRatio to defaults so a freshly-inserted parent doesn't inherit
    // stale knobs from before. no-op on internal nodes.
    func insert(_ newWindow: HyprWindow) {
        guard isLeaf else { return }

        let existing = self.window
        self.window = nil
        self.splitRatio = TilingConfig.defaultRatio
        self.userSetRatio = false
        self.splitOverride = nil

        self.left = BSPNode(window: existing)
        self.left?.parent = self

        self.right = BSPNode(window: newWindow)
        self.right?.parent = self
    }

    // remove this leaf and promote its sibling into the parent slot. the
    // sibling's subtree, ratio, splitOverride, and userSetRatio all carry
    // upward — the parent effectively becomes the sibling. no-op on root
    // (parent is nil); BSPTree.remove handles root replacement separately.
    func remove() {
        guard let parent = parent else { return }

        let sibling = (parent.left === self) ? parent.right : parent.left

        parent.window = sibling?.window
        parent.left = sibling?.left
        parent.right = sibling?.right
        parent.splitRatio = sibling?.splitRatio ?? TilingConfig.defaultRatio
        parent.userSetRatio = sibling?.userSetRatio ?? false
        parent.splitOverride = sibling?.splitOverride

        parent.left?.parent = parent
        parent.right?.parent = parent
    }

    // recursive lookup — returns the leaf carrying `target` or nil if absent.
    func find(_ target: HyprWindow) -> BSPNode? {
        if window == target { return self }
        return left?.find(target) ?? right?.find(target)
    }

    // reset every internal node's splitRatio to TilingConfig.defaultRatio,
    // skipping nodes flagged userSetRatio. called between layout passes so
    // transient ratio adjustments (from a previous min-size conflict) don't
    // accumulate, while genuine user resizes are preserved.
    func resetSplitRatios() {
        if !isLeaf && !userSetRatio {
            splitRatio = TilingConfig.defaultRatio
        }
        left?.resetSplitRatios()
        right?.resetSplitRatios()
    }

    // clear all user-set ratio flags (on structural changes like add/remove)
    func clearUserSetRatios() {
        userSetRatio = false
        left?.clearUserSetRatios()
        right?.clearUserSetRatios()
    }

    func allWindows() -> [HyprWindow] {
        var result: [HyprWindow] = []
        collectWindows(into: &result)
        return result
    }

    private func collectWindows(into result: inout [HyprWindow]) {
        if let w = window { result.append(w); return }
        left?.collectWindows(into: &result)
        right?.collectWindows(into: &result)
    }

    // leaves in deepest-right-first order. used by smart insert backtracking:
    // the dwindle default is to split the deepest-right leaf, but on
    // constrained monitors the algorithm walks back through this list to find
    // a shallower leaf with enough room (see BSPTree.smartInsert).
    func allLeavesRightToLeft() -> [BSPNode] {
        var result: [BSPNode] = []
        collectLeavesRightToLeft(into: &result)
        return result
    }

    private func collectLeavesRightToLeft(into result: inout [BSPNode]) {
        if isLeaf && window != nil { result.append(self); return }
        right?.collectLeavesRightToLeft(into: &result)
        left?.collectLeavesRightToLeft(into: &result)
    }

    // prune empty leaves and internal nodes with missing children.
    // returns true if this node is now empty and should be removed by its parent.
    @discardableResult
    func pruneEmptyNodes() -> Bool {
        left?.pruneEmptyNodes() == true ? (left = nil) : ()
        right?.pruneEmptyNodes() == true ? (right = nil) : ()

        // internal node lost a child — promote the surviving one
        if !isLeaf {
            if left == nil, let r = right {
                window = r.window; left = r.left; right = r.right
                left?.parent = self; right?.parent = self
                return pruneEmptyNodes()
            }
            if right == nil, let l = left {
                window = l.window; left = l.left; right = l.right
                left?.parent = self; right?.parent = self
                return pruneEmptyNodes()
            }
        }

        return isEmpty
    }

    // splitOverride wins when set; otherwise dwindle picks the longer axis
    // (>= biases to horizontal on exact squares, matching pre-refactor behavior).
    func direction(for rect: CGRect) -> SplitDirection {
        if let forced = splitOverride { return forced }
        return rect.width >= rect.height ? .horizontal : .vertical
    }

    // recursively layout this subtree into `rect`, returning [(window, frame)]
    // pairs ready to be applied. gaps are split equally on both sides of every
    // boundary so two adjacent slots see exactly `gap` of empty space between
    // them. caller is responsible for outer padding (already applied by
    // BSPTree.layout before recursing).
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
