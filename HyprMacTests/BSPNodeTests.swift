import XCTest
@testable import HyprMac

// BSPNodeTests pin current behavior of BSPNode primitives.
// Phase 0: no red baseline — every assertion below reflects what BSPNode does today.
// invariants/clamping that the plan introduces in Phase 1 are NOT tested here yet.

final class BSPNodeTests: XCTestCase {

    // MARK: - leaf semantics

    func testEmptyNodeIsLeaf() {
        let node = BSPNode()
        XCTAssertTrue(node.isLeaf)
        XCTAssertTrue(node.isEmpty)
    }

    func testLeafWithWindow() {
        let node = BSPNode(window: makeWindow(id: 1))
        XCTAssertTrue(node.isLeaf)
        XCTAssertFalse(node.isEmpty)
    }

    func testInternalNodeIsNotLeaf() {
        let node = BSPNode(window: makeWindow(id: 1))
        node.insert(makeWindow(id: 2))
        XCTAssertFalse(node.isLeaf)
        XCTAssertFalse(node.isEmpty)
        XCTAssertNotNil(node.left)
        XCTAssertNotNil(node.right)
    }

    // MARK: - insert

    func testInsertOnEmptyLeafIsNoop() {
        // current behavior: insert requires an existing window in the leaf;
        // calling insert on a node that has no window splits nothing
        let node = BSPNode()
        node.insert(makeWindow(id: 1))
        // existing was nil, so left.window is nil and right.window is the new one
        XCTAssertNil(node.window)
        XCTAssertNotNil(node.left)
        XCTAssertNotNil(node.right)
        XCTAssertNil(node.left?.window)
        XCTAssertEqual(node.right?.window?.windowID, 1)
    }

    func testInsertSplitsLeaf() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        let node = BSPNode(window: a)
        node.insert(b)

        XCTAssertNil(node.window)
        XCTAssertEqual(node.left?.window, a)
        XCTAssertEqual(node.right?.window, b)
        XCTAssertEqual(node.splitRatio, 0.5)
        XCTAssertFalse(node.userSetRatio)
        XCTAssertNil(node.splitOverride)
        XCTAssertTrue(node.left?.parent === node)
        XCTAssertTrue(node.right?.parent === node)
    }

    func testInsertResetsSplitOverride() {
        let node = BSPNode(window: makeWindow(id: 1))
        node.splitOverride = .vertical
        node.userSetRatio = true
        node.splitRatio = 0.75

        node.insert(makeWindow(id: 2))

        XCTAssertNil(node.splitOverride)
        XCTAssertFalse(node.userSetRatio)
        XCTAssertEqual(node.splitRatio, 0.5)
    }

    func testInsertOnNonLeafIsRefused() {
        let node = BSPNode(window: makeWindow(id: 1))
        node.insert(makeWindow(id: 2))

        let oldLeft = node.left
        let oldRight = node.right
        node.insert(makeWindow(id: 99))

        XCTAssertTrue(node.left === oldLeft)
        XCTAssertTrue(node.right === oldRight)
    }

    // MARK: - depth

    func testDepthOfRootIsZero() {
        let node = BSPNode()
        XCTAssertEqual(node.depth, 0)
    }

    func testDepthIncreasesWithNesting() {
        let root = BSPNode(window: makeWindow(id: 1))
        root.insert(makeWindow(id: 2))
        root.right?.insert(makeWindow(id: 3))

        XCTAssertEqual(root.depth, 0)
        XCTAssertEqual(root.left?.depth, 1)
        XCTAssertEqual(root.right?.depth, 1)
        XCTAssertEqual(root.right?.left?.depth, 2)
        XCTAssertEqual(root.right?.right?.depth, 2)
    }

    // MARK: - ratio (current behavior — uncapped via direct assignment)

    func testSplitRatioAcceptsValuesAsAssigned() {
        // pin current behavior: splitRatio is a plain stored property, NOT clamped.
        // Phase 1 will introduce property-setter clamping; that test belongs there.
        let node = BSPNode()
        node.splitRatio = 0.9
        XCTAssertEqual(node.splitRatio, 0.9)
        node.splitRatio = -0.5
        XCTAssertEqual(node.splitRatio, -0.5)
    }

    // MARK: - direction

    func testDirectionFromAspectRatio() {
        let node = BSPNode()
        let wide = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let tall = CGRect(x: 0, y: 0, width: 500, height: 1000)
        let square = CGRect(x: 0, y: 0, width: 800, height: 800)

        XCTAssertEqual(node.direction(for: wide), .horizontal)
        XCTAssertEqual(node.direction(for: tall), .vertical)
        // square: width >= height, so horizontal
        XCTAssertEqual(node.direction(for: square), .horizontal)
    }

    func testDirectionRespectsOverride() {
        let node = BSPNode()
        node.splitOverride = .vertical
        let wide = CGRect(x: 0, y: 0, width: 1000, height: 500)
        XCTAssertEqual(node.direction(for: wide), .vertical)

        node.splitOverride = .horizontal
        let tall = CGRect(x: 0, y: 0, width: 500, height: 1000)
        XCTAssertEqual(node.direction(for: tall), .horizontal)
    }

    // MARK: - find

    func testFindReturnsSelfForLeaf() {
        let w = makeWindow(id: 7)
        let node = BSPNode(window: w)
        XCTAssertTrue(node.find(w) === node)
    }

    func testFindReturnsNilForMissing() {
        let node = BSPNode(window: makeWindow(id: 1))
        XCTAssertNil(node.find(makeWindow(id: 99)))
    }

    func testFindWalksChildren() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        let node = BSPNode(window: a)
        node.insert(b)

        XCTAssertTrue(node.find(a) === node.left)
        XCTAssertTrue(node.find(b) === node.right)
    }

    // MARK: - remove

    func testRemovePromotesSibling() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        let root = BSPNode(window: a)
        root.insert(b)

        root.right?.remove()
        XCTAssertEqual(root.window, a)
        XCTAssertNil(root.left)
        XCTAssertNil(root.right)
    }

    func testRemoveOnRootIsNoop() {
        // BSPNode.remove uses parent — root has no parent, so it's a no-op.
        // BSPTree.remove handles root replacement separately.
        let a = makeWindow(id: 1)
        let root = BSPNode(window: a)
        root.remove()
        XCTAssertEqual(root.window, a)
    }

    func testRemoveCarriesSiblingSubtree() {
        // grandchild promotion: A | (B | C) → after removing A, root holds (B | C)
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        let c = makeWindow(id: 3)
        let root = BSPNode(window: a)
        root.insert(b)              // root: nil; left: A; right: B
        root.right?.insert(c)       // root: nil; left: A; right: (left=B, right=C)

        root.left?.remove()         // remove A → root takes right's structure

        XCTAssertNil(root.window)
        XCTAssertEqual(root.left?.window, b)
        XCTAssertEqual(root.right?.window, c)
    }

    // MARK: - allWindows + allLeavesRightToLeft

    func testAllWindowsReturnsLeftToRight() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        let c = makeWindow(id: 3)
        let root = BSPNode(window: a)
        root.insert(b)
        root.right?.insert(c)

        XCTAssertEqual(root.allWindows().map(\.windowID), [1, 2, 3])
    }

    func testAllLeavesRightToLeftOrder() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        let c = makeWindow(id: 3)
        let root = BSPNode(window: a)
        root.insert(b)
        root.right?.insert(c)

        // deepest-right first: C, B, A
        let leaves = root.allLeavesRightToLeft()
        XCTAssertEqual(leaves.map { $0.window?.windowID }, [3, 2, 1])
    }

    // MARK: - resetSplitRatios

    func testResetSplitRatiosPreservesUserSet() {
        let root = BSPNode(window: makeWindow(id: 1))
        root.insert(makeWindow(id: 2))
        root.splitRatio = 0.7
        root.userSetRatio = true

        root.resetSplitRatios()
        XCTAssertEqual(root.splitRatio, 0.7)
    }

    func testResetSplitRatiosClearsNonUserSet() {
        let root = BSPNode(window: makeWindow(id: 1))
        root.insert(makeWindow(id: 2))
        root.splitRatio = 0.3
        root.userSetRatio = false

        root.resetSplitRatios()
        XCTAssertEqual(root.splitRatio, 0.5)
    }

    func testClearUserSetRatiosWipesAll() {
        let root = BSPNode(window: makeWindow(id: 1))
        root.insert(makeWindow(id: 2))
        root.userSetRatio = true
        root.right?.userSetRatio = true

        root.clearUserSetRatios()
        XCTAssertFalse(root.userSetRatio)
        XCTAssertFalse(root.right?.userSetRatio ?? true)
    }

    // MARK: - layout

    func testLayoutOfSingleLeafFillsRect() {
        let w = makeWindow(id: 1)
        let node = BSPNode(window: w)
        let rect = CGRect(x: 100, y: 200, width: 800, height: 600)

        let result = node.layout(in: rect, gap: 10)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].0, w)
        XCTAssertEqual(result[0].1, rect)
    }

    func testLayoutHorizontalSplit() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        let root = BSPNode(window: a)
        root.insert(b)

        // 1000x500 wide → horizontal split, ratio 0.5, gap 10 → halfGap 5
        // left: x=0, w=500-5=495 ; right: x=505, w=1000-505=495
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let result = root.layout(in: rect, gap: 10)

        XCTAssertEqual(result.count, 2)
        let leftRect = result.first(where: { $0.0 == a })?.1
        let rightRect = result.first(where: { $0.0 == b })?.1
        XCTAssertEqual(leftRect, CGRect(x: 0, y: 0, width: 495, height: 500))
        XCTAssertEqual(rightRect, CGRect(x: 505, y: 0, width: 495, height: 500))
    }

    func testLayoutVerticalSplit() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        let root = BSPNode(window: a)
        root.insert(b)

        // 500x1000 tall → vertical split
        let rect = CGRect(x: 0, y: 0, width: 500, height: 1000)
        let result = root.layout(in: rect, gap: 10)

        XCTAssertEqual(result.count, 2)
        let topRect = result.first(where: { $0.0 == a })?.1
        let bottomRect = result.first(where: { $0.0 == b })?.1
        XCTAssertEqual(topRect, CGRect(x: 0, y: 0, width: 500, height: 495))
        XCTAssertEqual(bottomRect, CGRect(x: 0, y: 505, width: 500, height: 495))
    }

    // MARK: - pruneEmptyNodes

    func testPruneEmptyNodesRemovesEmptyLeaf() {
        let root = BSPNode()
        XCTAssertTrue(root.pruneEmptyNodes())
    }

    func testPruneEmptyNodesPromotesLoneChild() {
        // construct: root has one empty child and one populated child
        let root = BSPNode()
        root.left = BSPNode()                       // empty
        root.right = BSPNode(window: makeWindow(id: 1))
        root.left?.parent = root
        root.right?.parent = root

        let isEmpty = root.pruneEmptyNodes()
        XCTAssertFalse(isEmpty)
        XCTAssertEqual(root.window?.windowID, 1)
        XCTAssertNil(root.left)
        XCTAssertNil(root.right)
    }
}
