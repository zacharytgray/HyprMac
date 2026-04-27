// One node in the binary space partition tree used for tiling. Pure
// geometry — no AppKit, no AX. All geometry flows in via parameters
// (rect, gap) so layout is unit-testable.

import Foundation

/// Direction in which a node's children divide its rect.
enum SplitDirection {
    /// Left | right.
    case horizontal
    /// Top / bottom.
    case vertical
}

/// One node in the BSP tree.
///
/// Invariants (enforced by construction; pinned by `BSPNodeTests`):
/// - leaf = `window != nil` or both children are `nil`.
/// - internal = both children are non-nil.
/// - Empty leaves are a transient state used during compact / prune.
/// - `splitRatio` is clamped to `[TilingConfig.minRatio,
///   TilingConfig.maxRatio]` by the property setter — direct writes
///   cannot escape these bounds.
class BSPNode {
    var parent: BSPNode?

    private var _splitRatio: CGFloat = TilingConfig.defaultRatio

    /// Fraction of the parent rect occupied by the left/top child.
    /// Clamped to `[TilingConfig.minRatio, TilingConfig.maxRatio]` on
    /// every write — out-of-bounds ratios would put the layout math
    /// into states it is not designed for.
    var splitRatio: CGFloat {
        get { _splitRatio }
        set { _splitRatio = max(TilingConfig.minRatio, min(TilingConfig.maxRatio, newValue)) }
    }

    /// Sticky flag preserved across `resetSplitRatios` so a user
    /// manual-resize survives a retile. Cleared by
    /// `clearUserSetRatios` on structural changes.
    var userSetRatio: Bool = false

    /// Forced split direction from `togglesplit`. `nil` lets dwindle
    /// pick from the rect aspect ratio. Survives until a sibling
    /// restructure (insert / remove on this node) clears it.
    var splitOverride: SplitDirection?

    var window: HyprWindow?
    var left: BSPNode?
    var right: BSPNode?

    /// `true` for terminal nodes — see file-level invariants.
    var isLeaf: Bool { window != nil || (left == nil && right == nil) }

    /// `true` for transient empty leaves used during compact / prune.
    var isEmpty: Bool { window == nil && left == nil && right == nil }

    /// Distance from root (`0` at root).
    var depth: Int {
        var d = 0
        var node = parent
        while node != nil { d += 1; node = node?.parent }
        return d
    }

    init(window: HyprWindow? = nil) {
        self.window = window
    }

    /// Split this leaf into two children. The existing window (if
    /// any) goes left/top; `newWindow` goes right/bottom. Resets
    /// `splitRatio`, `splitOverride`, and `userSetRatio` to defaults
    /// so the freshly-promoted internal node does not inherit stale
    /// knobs. No-op on internal nodes.
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

    /// Remove this leaf and promote its sibling into the parent slot.
    ///
    /// The sibling's subtree, ratio, override, and user-set flag all
    /// carry upward — the parent effectively becomes the sibling.
    /// No-op on the root; `BSPTree.remove` handles root replacement.
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

    /// Recursive lookup — returns the leaf carrying `target`, or
    /// `nil` when not present.
    func find(_ target: HyprWindow) -> BSPNode? {
        if window == target { return self }
        return left?.find(target) ?? right?.find(target)
    }

    /// Reset every internal node's `splitRatio` to the default, except
    /// nodes flagged `userSetRatio`. Called between layout passes so
    /// transient ratio adjustments (from a previous min-size
    /// conflict) do not accumulate, while genuine user resizes are
    /// preserved.
    func resetSplitRatios() {
        if !isLeaf && !userSetRatio {
            splitRatio = TilingConfig.defaultRatio
        }
        left?.resetSplitRatios()
        right?.resetSplitRatios()
    }

    /// Clear every `userSetRatio` flag in the subtree. Called on
    /// structural changes (add / remove) so a fresh layout starts
    /// from defaults.
    func clearUserSetRatios() {
        userSetRatio = false
        left?.clearUserSetRatios()
        right?.clearUserSetRatios()
    }

    /// Every window in the subtree, in left-to-right traversal order.
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

    /// Leaves in deepest-right-first order.
    ///
    /// Used by smart insert: the dwindle default is to split the
    /// deepest-right leaf, but on constrained monitors the algorithm
    /// walks back through this list to find a shallower leaf with
    /// enough room (see `BSPTree.smartInsert`).
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

    /// Drop empty leaves and promote single surviving children of
    /// internal nodes. Returns `true` when this node is now empty and
    /// should be removed by its parent.
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

    /// Split direction for `rect`. `splitOverride` wins when set;
    /// otherwise dwindle picks the longer axis. The `>=` biases
    /// horizontal on exact squares.
    func direction(for rect: CGRect) -> SplitDirection {
        if let forced = splitOverride { return forced }
        return rect.width >= rect.height ? .horizontal : .vertical
    }

    /// Recursively lay this subtree into `rect`, returning
    /// `(window, frame)` pairs ready to apply.
    ///
    /// Gaps are split evenly on both sides of every boundary so two
    /// adjacent slots see exactly `gap` of empty space between them.
    /// The caller is responsible for outer padding — `BSPTree.layout`
    /// applies that before recursing.
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
