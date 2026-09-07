import XCTest
@testable import HyprMac

final class RatioMemoryTests: XCTestCase {

    private func insertAndApply(_ window: HyprWindow, into tree: BSPTree) {
        tree.insert(window)
        tree.root.applySavedRatios()
    }

    // MARK: - right child removed

    func testRemoveRightChildPreservesRatioOnReinsert() {
        let tree = BSPTree()
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        tree.insert(a)
        tree.insert(b)

        tree.root.splitRatio = 0.7
        tree.root.userSetRatio = true

        tree.remove(b)
        XCTAssertEqual(tree.root.window, a)

        insertAndApply(makeWindow(id: 3), into: tree)

        XCTAssertEqual(tree.root.splitRatio, 0.7, accuracy: 0.001,
                       "ratio should survive right-child removal + reinsert")
        XCTAssertTrue(tree.root.userSetRatio)
    }

    // MARK: - left child removed (new window takes the vacated left slot)

    func testRemoveLeftChildPreservesRatioOnReinsert() {
        let tree = BSPTree()
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        tree.insert(a)
        tree.insert(b)

        tree.root.splitRatio = 0.7
        tree.root.userSetRatio = true

        tree.remove(a)
        XCTAssertEqual(tree.root.window, b)

        insertAndApply(makeWindow(id: 3), into: tree)

        XCTAssertEqual(tree.root.splitRatio, 0.7, accuracy: 0.001,
                       "left-child removal: new window takes the left slot, ratio preserved")
        XCTAssertTrue(tree.root.userSetRatio)
    }

    // MARK: - default ratio is not saved

    func testDefaultRatioNotSaved() {
        let tree = BSPTree()
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        tree.insert(a)
        tree.insert(b)

        tree.remove(b)
        insertAndApply(makeWindow(id: 3), into: tree)

        XCTAssertEqual(tree.root.splitRatio, TilingConfig.defaultRatio, accuracy: 0.001,
                       "default 50/50 ratio should not be saved")
        XCTAssertFalse(tree.root.userSetRatio)
    }

    // MARK: - memory consumed after apply

    func testSavedRatioClearedAfterApply() {
        let tree = BSPTree()
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        tree.insert(a)
        tree.insert(b)
        tree.root.splitRatio = 0.7
        tree.root.userSetRatio = true

        tree.remove(b)
        insertAndApply(makeWindow(id: 3), into: tree)

        XCTAssertNil(tree.root.savedSplitRatio,
                     "saved ratio should be consumed on apply, not linger")
        XCTAssertNil(tree.root.pendingSplitRatio,
                     "pending restore should be consumed on apply, not linger")
    }

    // MARK: - single window removal (root)

    func testRemoveOnlyWindowDoesNotCrash() {
        let tree = BSPTree()
        let a = makeWindow(id: 1)
        tree.insert(a)
        tree.root.splitRatio = 0.7
        tree.root.userSetRatio = true

        tree.remove(a)
        XCTAssertTrue(tree.root.isEmpty)

        insertAndApply(makeWindow(id: 2), into: tree)
        XCTAssertEqual(tree.root.splitRatio, TilingConfig.defaultRatio, accuracy: 0.001)
    }

    // MARK: - deeper tree

    func testRatioMemoryWorksAtDepth() {
        let tree = BSPTree()
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        let c = makeWindow(id: 3)
        tree.insert(a)
        tree.insert(b)
        tree.insert(c)

        let sub = tree.root.right!
        sub.splitRatio = 0.6
        sub.userSetRatio = true

        tree.remove(c)
        XCTAssertEqual(tree.root.right?.window, b)

        let d = makeWindow(id: 4)
        tree.root.right?.insert(d)
        tree.root.applySavedRatios()

        XCTAssertEqual(tree.root.right?.splitRatio ?? 0, 0.6, accuracy: 0.001,
                       "ratio at depth should survive removal + reinsert")
    }

    // MARK: - ratio survives multiple cycles

    func testRatioSurvivesMultipleCycles() {
        let tree = BSPTree()
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        tree.insert(a)
        tree.insert(b)
        tree.root.splitRatio = 0.65
        tree.root.userSetRatio = true

        tree.remove(b)
        insertAndApply(makeWindow(id: 3), into: tree)
        XCTAssertEqual(tree.root.splitRatio, 0.65, accuracy: 0.001)

        tree.remove(tree.root.right!.window!)
        insertAndApply(makeWindow(id: 4), into: tree)
        XCTAssertEqual(tree.root.splitRatio, 0.65, accuracy: 0.001,
                       "ratio should survive multiple remove/reinsert cycles")
    }

    // MARK: - the memory belongs to leaves only

    func testPromotedSubtreeKeepsItsOwnInnerSplit() {
        let tree = BSPTree()
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        let c = makeWindow(id: 3)
        tree.insert(a)
        tree.insert(b)
        tree.insert(c)
        // root(a | inner(b, c))

        tree.root.splitRatio = 0.7
        tree.root.userSetRatio = true
        let inner = tree.root.right!
        inner.splitRatio = 0.6
        inner.userSetRatio = true

        tree.remove(a)
        tree.root.applySavedRatios()

        XCTAssertEqual(tree.root.left?.window, b)
        XCTAssertEqual(tree.root.right?.window, c)
        XCTAssertEqual(tree.root.splitRatio, 0.6, accuracy: 0.001,
                       "the promoted b|c split keeps its own boundary, not the outer 0.7")
        XCTAssertNil(tree.root.savedSplitRatio,
                     "an internal sibling never picks up the vanishing ratio")
        XCTAssertNil(tree.root.pendingSplitRatio)
    }

    func testBothChildrenOfOneSplitRemovedDoesNotLeakOuterRatio() {
        let tree = BSPTree()
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        let c = makeWindow(id: 3)
        let d = makeWindow(id: 4)
        tree.insert(a)
        tree.insert(b)
        tree.root.left?.insert(c)
        tree.root.right?.insert(d)
        // root(P(a, c) | Q(b, d))

        tree.root.splitRatio = 0.7
        tree.root.userSetRatio = true

        // Cmd-H on a two-window app: both of P's leaves go in one pass
        tree.remove(a)
        tree.remove(c)
        tree.root.applySavedRatios()

        XCTAssertEqual(tree.root.left?.window, b)
        XCTAssertEqual(tree.root.right?.window, d)
        XCTAssertEqual(tree.root.splitRatio, TilingConfig.defaultRatio, accuracy: 0.001,
                       "Q's own split must not inherit the outer 0.7")
        XCTAssertFalse(tree.root.userSetRatio,
                       "and must not be pinned as a user resize")
    }

    // MARK: - only user-set boundaries are remembered

    func testTransientRatioIsNotRemembered() {
        let tree = BSPTree()
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        tree.insert(a)
        tree.insert(b)

        // a min-size fudge from adjustAxisRatio never sets userSetRatio
        tree.root.splitRatio = 0.8
        XCTAssertFalse(tree.root.userSetRatio)

        tree.remove(b)
        XCTAssertNil(tree.root.savedSplitRatio, "a transient ratio is not worth remembering")

        insertAndApply(makeWindow(id: 3), into: tree)

        XCTAssertEqual(tree.root.splitRatio, TilingConfig.defaultRatio, accuracy: 0.001)
        XCTAssertFalse(tree.root.userSetRatio,
                       "a fudged ratio must not come back pinned as a user resize")
    }

    // MARK: - dwindle default without a memory

    func testNewWindowStaysOnTheRightWithoutAMemory() {
        let tree = BSPTree()
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        tree.insert(a)
        tree.insert(b)

        // no user ratio, so removing the left child saves nothing
        tree.remove(a)
        XCTAssertEqual(tree.root.window, b)

        let c = makeWindow(id: 3)
        insertAndApply(c, into: tree)

        XCTAssertEqual(tree.root.left?.window, b)
        XCTAssertEqual(tree.root.right?.window, c,
                       "with nothing saved the new window keeps the dwindle default")
    }

    // MARK: - split override rides along with the ratio

    func testSplitOverrideSurvivesRemoveAndResplit() {
        let tree = BSPTree()
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        tree.insert(a)
        tree.insert(b)

        tree.root.splitRatio = 0.7
        tree.root.userSetRatio = true
        tree.root.splitOverride = .vertical

        tree.remove(b)
        XCTAssertNil(tree.root.splitOverride, "the promoted leaf has no split of its own")
        XCTAssertEqual(tree.root.savedSplitOverride, .vertical)

        insertAndApply(makeWindow(id: 3), into: tree)

        XCTAssertEqual(tree.root.splitOverride, .vertical,
                       "a togglesplit'd split comes back on the same axis")
        XCTAssertEqual(tree.root.splitRatio, 0.7, accuracy: 0.001)
    }
}
