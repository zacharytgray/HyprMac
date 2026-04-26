import XCTest
@testable import HyprMac

// BSPTreeTests pin current behavior of BSPTree operations against the existing
// dwindle algorithm. all tests are expected green at Phase 0 baseline.

final class BSPTreeTests: XCTestCase {

    // MARK: - insert

    func testInsertIntoEmptyTree() {
        let tree = BSPTree()
        let w = makeWindow(id: 1)
        XCTAssertTrue(tree.insert(w))
        XCTAssertEqual(tree.allWindows.map(\.windowID), [1])
        XCTAssertTrue(tree.root.isLeaf)
    }

    func testInsertSplitsDeepestRightLeaf() {
        let tree = BSPTree()
        tree.insert(makeWindow(id: 1))
        tree.insert(makeWindow(id: 2))
        tree.insert(makeWindow(id: 3))

        // dwindle: spiral splits into right
        // root: nil; left: 1; right: (left: 2, right: 3)
        XCTAssertEqual(tree.allWindows.map(\.windowID), [1, 2, 3])
        XCTAssertEqual(tree.root.left?.window?.windowID, 1)
        XCTAssertEqual(tree.root.right?.left?.window?.windowID, 2)
        XCTAssertEqual(tree.root.right?.right?.window?.windowID, 3)
    }

    func testInsertRespectsMaxDepth() {
        let tree = BSPTree()
        // depth limits children — at depth d, children would be at d+1
        // insert(maxDepth: 2): allows splits up to depth-2 children, so root (0) → 1 → 2
        tree.insert(makeWindow(id: 1), maxDepth: 2)        // root
        XCTAssertTrue(tree.insert(makeWindow(id: 2), maxDepth: 2))   // depth-1 children
        XCTAssertTrue(tree.insert(makeWindow(id: 3), maxDepth: 2))   // depth-2 children
        // next insert would target the deepest-right leaf (depth 2),
        // splitting it would create depth-3 children → refused
        XCTAssertFalse(tree.insert(makeWindow(id: 4), maxDepth: 2))
        XCTAssertEqual(tree.allWindows.count, 3)
    }

    // MARK: - remove

    func testRemoveOnlyWindowResetsRoot() {
        let tree = BSPTree()
        let w = makeWindow(id: 1)
        tree.insert(w)
        tree.remove(w)
        XCTAssertTrue(tree.root.isEmpty)
        XCTAssertEqual(tree.allWindows.count, 0)
    }

    func testRemoveOneOfTwoPromotesSibling() {
        let tree = BSPTree()
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        tree.insert(a)
        tree.insert(b)

        tree.remove(b)
        XCTAssertEqual(tree.allWindows.map(\.windowID), [1])
        XCTAssertEqual(tree.root.window, a)
        XCTAssertTrue(tree.root.isLeaf)
    }

    func testRemoveMissingWindowIsNoop() {
        let tree = BSPTree()
        tree.insert(makeWindow(id: 1))
        tree.remove(makeWindow(id: 99))
        XCTAssertEqual(tree.allWindows.map(\.windowID), [1])
    }

    // MARK: - swap

    func testSwapExchangesPositions() {
        let tree = BSPTree()
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        tree.insert(a)
        tree.insert(b)

        tree.swap(a, b)
        XCTAssertEqual(tree.root.left?.window?.windowID, 2)
        XCTAssertEqual(tree.root.right?.window?.windowID, 1)
    }

    func testSwapWithMissingWindowIsNoop() {
        let tree = BSPTree()
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        let missing = makeWindow(id: 99)
        tree.insert(a)
        tree.insert(b)

        tree.swap(a, missing)
        XCTAssertEqual(tree.root.left?.window?.windowID, 1)
        XCTAssertEqual(tree.root.right?.window?.windowID, 2)
    }

    // MARK: - contains / find

    func testContainsAndFind() {
        let tree = BSPTree()
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        tree.insert(a)
        tree.insert(b)

        XCTAssertTrue(tree.contains(a))
        XCTAssertTrue(tree.contains(b))
        XCTAssertFalse(tree.contains(makeWindow(id: 99)))

        XCTAssertNotNil(tree.root.find(a))
        XCTAssertNotNil(tree.root.find(b))
        XCTAssertNil(tree.root.find(makeWindow(id: 99)))
    }

    // MARK: - smartInsert

    func testSmartInsertOnEmptyTreeFillsRoot() {
        let tree = BSPTree()
        let w = makeWindow(id: 1)
        XCTAssertTrue(tree.smartInsert(w, maxDepth: 3, in: defaultRect,
                                       gap: defaultGap, padding: defaultPadding,
                                       minSlotDimension: defaultMinSlot))
        XCTAssertEqual(tree.root.window, w)
    }

    func testSmartInsertUsesDeepestRightWhenSpaceAllows() {
        let tree = BSPTree()
        // wide screen (1920x1080) → multiple windows fit at depth-2 dwindle
        for i in 1...3 {
            tree.smartInsert(makeWindow(id: CGWindowID(i)), maxDepth: 3, in: defaultRect,
                             gap: defaultGap, padding: defaultPadding, minSlotDimension: defaultMinSlot)
        }
        // confirms standard dwindle layout when slots are large enough
        XCTAssertEqual(tree.allWindows.map(\.windowID), [1, 2, 3])
        XCTAssertEqual(tree.root.left?.window?.windowID, 1)
        XCTAssertEqual(tree.root.right?.left?.window?.windowID, 2)
        XCTAssertEqual(tree.root.right?.right?.window?.windowID, 3)
    }

    func testSmartInsertHonorsMinSlotOnUnconstrainedMonitor() {
        // wide screen (1920x1080) with minSlot=500 — first split makes 2x ~952w,
        // second creates ~952x528 vertical slots, third again ~952x528 horizontal
        // would yield childMin=472<500 so smartInsert backtracks to leaf #1.
        // pin: 3 windows still fit, but the layout should distribute via backtrack —
        // tree shape is left=w1, right=(w2|w3) (standard dwindle when slots fit).
        let tree = BSPTree()
        for i in 1...3 {
            tree.smartInsert(makeWindow(id: CGWindowID(i)), maxDepth: 3, in: defaultRect,
                             gap: defaultGap, padding: defaultPadding, minSlotDimension: defaultMinSlot)
        }
        XCTAssertEqual(tree.allWindows.count, 3)
        XCTAssertEqual(tree.allWindows.map(\.windowID), [1, 2, 3])
    }

    func testSmartInsertFallsBackOnConstrainedMonitor() {
        // narrow vertical (800x1600) — by the 3rd insert, no leaf meets minSlot=500.
        // pin current behavior: smartInsert still inserts via the fallback path
        // (at the deepest-right leaf, ignoring the minimum).
        let tree = BSPTree()
        for i in 1...3 {
            XCTAssertTrue(
                tree.smartInsert(makeWindow(id: CGWindowID(i)), maxDepth: 3, in: narrowRect,
                                 gap: defaultGap, padding: defaultPadding, minSlotDimension: defaultMinSlot)
            )
        }
        XCTAssertEqual(tree.allWindows.count, 3)
    }

    // MARK: - compact

    func testCompactRebuildsAfterRemoval() {
        let tree = BSPTree()
        for i in 1...4 {
            tree.smartInsert(makeWindow(id: CGWindowID(i)), maxDepth: 3, in: defaultRect,
                             gap: defaultGap, padding: defaultPadding, minSlotDimension: defaultMinSlot)
        }
        let toRemove = tree.allWindows.first { $0.windowID == 2 }!
        tree.remove(toRemove)
        tree.compact(maxDepth: 3, in: defaultRect, gap: defaultGap,
                     padding: defaultPadding, minSlotDimension: defaultMinSlot)

        // after compact, the surviving windows should still be in tree
        let ids = tree.allWindows.map(\.windowID).sorted()
        XCTAssertEqual(ids, [1, 3, 4])
    }

    func testCompactWithSingleWindowIsNoop() {
        let tree = BSPTree()
        let w = makeWindow(id: 1)
        tree.insert(w)
        let oldRoot = tree.root
        tree.compact(maxDepth: 3, in: defaultRect, gap: defaultGap,
                     padding: defaultPadding, minSlotDimension: defaultMinSlot)
        XCTAssertTrue(tree.root === oldRoot)
        XCTAssertEqual(tree.root.window, w)
    }

    // MARK: - rectForNode

    func testRectForNodeMatchesLayout() {
        let tree = BSPTree()
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        tree.insert(a)
        tree.insert(b)

        let leafA = tree.root.find(a)!
        let leafB = tree.root.find(b)!
        let rectA = tree.rectForNode(leafA, in: defaultRect, gap: defaultGap, padding: defaultPadding)
        let rectB = tree.rectForNode(leafB, in: defaultRect, gap: defaultGap, padding: defaultPadding)

        let layout = tree.layout(in: defaultRect, gap: defaultGap, padding: defaultPadding)
        let layoutA = layout.first(where: { $0.0 == a })?.1
        let layoutB = layout.first(where: { $0.0 == b })?.1

        XCTAssertEqual(rectA, layoutA)
        XCTAssertEqual(rectB, layoutB)
    }

    // MARK: - layout

    func testLayoutOnEmptyTreeIsEmpty() {
        let tree = BSPTree()
        XCTAssertTrue(tree.layout(in: defaultRect, gap: defaultGap, padding: defaultPadding).isEmpty)
    }

    func testLayoutAppliesPadding() {
        let tree = BSPTree()
        let w = makeWindow(id: 1)
        tree.insert(w)
        let result = tree.layout(in: defaultRect, gap: defaultGap, padding: defaultPadding)
        XCTAssertEqual(result.count, 1)
        let expected = defaultRect.insetBy(dx: defaultPadding, dy: defaultPadding)
        XCTAssertEqual(result[0].1, expected)
    }

    // MARK: - deepestRightLeafWindow

    func testDeepestRightLeafWindowEmpty() {
        let tree = BSPTree()
        XCTAssertNil(tree.deepestRightLeafWindow())
    }

    func testDeepestRightLeafWindowAfterInserts() {
        let tree = BSPTree()
        tree.insert(makeWindow(id: 1))
        tree.insert(makeWindow(id: 2))
        tree.insert(makeWindow(id: 3))
        XCTAssertEqual(tree.deepestRightLeafWindow()?.windowID, 3)
    }

    // MARK: - toggleSplit

    func testToggleSplitFlipsParentDirection() {
        let tree = BSPTree()
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        tree.insert(a)
        tree.insert(b)

        // wide rect → default direction is horizontal
        tree.toggleSplit(for: b, in: defaultRect, gap: defaultGap, padding: defaultPadding)
        XCTAssertEqual(tree.root.splitOverride, .vertical)

        tree.toggleSplit(for: b, in: defaultRect, gap: defaultGap, padding: defaultPadding)
        XCTAssertEqual(tree.root.splitOverride, .horizontal)
    }

    func testToggleSplitOnRootOnlyIsNoop() {
        let tree = BSPTree()
        let w = makeWindow(id: 1)
        tree.insert(w)
        tree.toggleSplit(for: w, in: defaultRect, gap: defaultGap, padding: defaultPadding)
        XCTAssertNil(tree.root.splitOverride)
    }

    // MARK: - adjustForMinSizes

    func testAdjustForMinSizesEnlargesConstrainedWindow() {
        let tree = BSPTree()
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        tree.insert(a)
        tree.insert(b)

        // wide split, gap 8, padding 8. allocated width per side ≈ (1920-16)/2 - 4 ≈ 948.
        // pretend window B insists on 1400 wide
        let conflicts: [(window: HyprWindow, actual: CGSize)] = [
            (b, CGSize(width: 1400, height: 1080))
        ]
        tree.adjustForMinSizes(conflicts, in: defaultRect, gap: defaultGap, padding: defaultPadding)

        // B is the right child → adjustment should reduce splitRatio (give B more space)
        XCTAssertLessThan(tree.root.splitRatio, 0.5)
        XCTAssertGreaterThanOrEqual(tree.root.splitRatio, 0.15)
    }

    func testAdjustForMinSizesClampsLeftChild() {
        let tree = BSPTree()
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        tree.insert(a)
        tree.insert(b)

        // A is left child — pretend it insists on most of the screen
        let conflicts: [(window: HyprWindow, actual: CGSize)] = [
            (a, CGSize(width: 5000, height: 1080))
        ]
        tree.adjustForMinSizes(conflicts, in: defaultRect, gap: defaultGap, padding: defaultPadding)

        // ratio raised toward 0.85 ceiling
        XCTAssertGreaterThan(tree.root.splitRatio, 0.5)
        XCTAssertLessThanOrEqual(tree.root.splitRatio, 0.85)
    }

    func testAdjustForMinSizesSkipsUserSetParents() {
        let tree = BSPTree()
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        tree.insert(a)
        tree.insert(b)
        tree.root.userSetRatio = true
        tree.root.splitRatio = 0.7

        let conflicts: [(window: HyprWindow, actual: CGSize)] = [
            (b, CGSize(width: 1400, height: 1080))
        ]
        tree.adjustForMinSizes(conflicts, in: defaultRect, gap: defaultGap, padding: defaultPadding)

        // userSetRatio parents are skipped — ratio stays at 0.7
        XCTAssertEqual(tree.root.splitRatio, 0.7)
    }

    func testAdjustForMinSizesIgnoresMissingWindow() {
        let tree = BSPTree()
        tree.insert(makeWindow(id: 1))

        let conflicts: [(window: HyprWindow, actual: CGSize)] = [
            (makeWindow(id: 99), CGSize(width: 5000, height: 5000))
        ]
        // should not crash or mutate
        tree.adjustForMinSizes(conflicts, in: defaultRect, gap: defaultGap, padding: defaultPadding)
        XCTAssertEqual(tree.root.splitRatio, 0.5)
    }
}
