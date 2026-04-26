import XCTest
@testable import HyprMac

// LayoutEngineTests cover the pure-ish geometric helpers extracted from
// TilingEngine into Tiling/LayoutEngine.swift. these don't touch AX, animation,
// or NSScreen — they're testable directly on fixture trees and rects.
//
// see plan §4.2 + §8.2.

final class LayoutEngineTests: XCTestCase {

    private let layout = LayoutEngine(gapSize: 8, outerPadding: 8, minSlotDimension: 500)
    private let bigRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let narrowRect = CGRect(x: 0, y: 0, width: 800, height: 1600)

    // MARK: - splitRects

    func testSplitRectsHorizontalDividesAtMidpoint() {
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let (a, b) = layout.splitRects(rect, dir: .horizontal)
        XCTAssertEqual(a, CGRect(x: 0, y: 0, width: 496, height: 500))
        XCTAssertEqual(b, CGRect(x: 504, y: 0, width: 496, height: 500))
    }

    func testSplitRectsVerticalDividesAtMidpoint() {
        let rect = CGRect(x: 0, y: 0, width: 500, height: 1000)
        let (a, b) = layout.splitRects(rect, dir: .vertical)
        XCTAssertEqual(a, CGRect(x: 0, y: 0, width: 500, height: 496))
        XCTAssertEqual(b, CGRect(x: 0, y: 504, width: 500, height: 496))
    }

    func testSplitRectsRespectsGap() {
        // gap=8 → halfGap=4 → two children separated by 8px in the middle
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let (a, b) = layout.splitRects(rect, dir: .horizontal)
        XCTAssertEqual(b.minX - a.maxX, 8)
    }

    // MARK: - pairFits

    func testPairFitsWhenWindowsFitInRect() {
        let parent = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let aMin = CGSize(width: 300, height: 300)
        let bMin = CGSize(width: 300, height: 300)
        XCTAssertTrue(layout.pairFits(aMin, bMin, in: parent, dir: .horizontal))
    }

    func testPairFitsFailsOnSumOverflow() {
        // 600 + 600 + 8(gap) = 1208 > 1000 → fail
        let parent = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let big = CGSize(width: 600, height: 100)
        XCTAssertFalse(layout.pairFits(big, big, in: parent, dir: .horizontal))
    }

    func testPairFitsFailsOnCrossAxisOverflow() {
        // height 800 > parent.height 500 — even though widths fit
        let parent = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let aMin = CGSize(width: 300, height: 800)
        let bMin = CGSize(width: 300, height: 300)
        XCTAssertFalse(layout.pairFits(aMin, bMin, in: parent, dir: .horizontal))
    }

    func testPairFitsFailsOnIndividualCap() {
        // individual cap = parentRect.width * maxRatio = 1000 * 0.85 = 850
        // single window wider than 850 fails the per-child cap, even with gap room.
        let parent = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let huge = CGSize(width: 900, height: 100)
        let small = CGSize(width: 50, height: 100)
        XCTAssertFalse(layout.pairFits(huge, small, in: parent, dir: .horizontal))
    }

    func testPairFitsZeroMinSizesAlwaysOK() {
        let parent = CGRect(x: 0, y: 0, width: 1000, height: 500)
        XCTAssertTrue(layout.pairFits(.zero, .zero, in: parent, dir: .horizontal))
        XCTAssertTrue(layout.pairFits(.zero, .zero, in: parent, dir: .vertical))
    }

    // MARK: - fittingLeaf / smartInsertFitting

    private func zeroMins(_ window: HyprWindow?) -> CGSize { .zero }

    func testSmartInsertFittingFillsEmptyTreeAtRoot() {
        let tree = BSPTree()
        let w = makeWindow(id: 1)
        let ok = layout.smartInsertFitting(w, into: tree, maxDepth: 3,
                                           rect: bigRect, minimumSize: zeroMins)
        XCTAssertTrue(ok)
        XCTAssertEqual(tree.root.window?.windowID, 1)
    }

    func testSmartInsertFittingPicksDeepestRightWhenSpaceAllows() {
        let tree = BSPTree()
        for i in 1...3 {
            layout.smartInsertFitting(makeWindow(id: CGWindowID(i)), into: tree,
                                      maxDepth: 3, rect: bigRect, minimumSize: zeroMins)
        }
        // standard dwindle: root: nil, left=w1, right=(left=w2, right=w3)
        XCTAssertEqual(tree.root.left?.window?.windowID, 1)
        XCTAssertEqual(tree.root.right?.left?.window?.windowID, 2)
        XCTAssertEqual(tree.root.right?.right?.window?.windowID, 3)
    }

    func testSmartInsertFittingFailsAtMaxDepth() {
        let tree = BSPTree()
        // fill a maxDepth=1 tree (2 leaves at depth 1)
        layout.smartInsertFitting(makeWindow(id: 1), into: tree, maxDepth: 1,
                                  rect: bigRect, minimumSize: zeroMins)
        layout.smartInsertFitting(makeWindow(id: 2), into: tree, maxDepth: 1,
                                  rect: bigRect, minimumSize: zeroMins)
        // 3rd insert with depth ceiling — no leaf at depth < 1 → fail
        let ok = layout.smartInsertFitting(makeWindow(id: 3), into: tree, maxDepth: 1,
                                           rect: bigRect, minimumSize: zeroMins)
        XCTAssertFalse(ok)
        XCTAssertEqual(tree.allWindows.count, 2)
    }

    func testFittingLeafReturnsNilOnEmptyTree() {
        let tree = BSPTree()
        let leaf = layout.fittingLeaf(for: makeWindow(id: 1), in: tree,
                                      maxDepth: 3, rect: bigRect, minimumSize: zeroMins)
        XCTAssertNil(leaf)
    }

    func testFittingLeafRespectsMinSlotInPass0() {
        // narrow rect — at depth 1, splitting again yields childMin < 500.
        // pass-0 should reject; pass-1 (without slot check) accepts.
        let tree = BSPTree()
        layout.smartInsertFitting(makeWindow(id: 1), into: tree, maxDepth: 3,
                                  rect: narrowRect, minimumSize: zeroMins)
        layout.smartInsertFitting(makeWindow(id: 2), into: tree, maxDepth: 3,
                                  rect: narrowRect, minimumSize: zeroMins)
        let leaf = layout.fittingLeaf(for: makeWindow(id: 3), in: tree,
                                      maxDepth: 3, rect: narrowRect, minimumSize: zeroMins)
        // pass-1 fallback finds a leaf (one of the depth-1 leaves)
        XCTAssertNotNil(leaf)
    }

    func testFittingLeafRejectsWhenMinSizesDontFit() {
        // hand a window so large that no leaf can take it via pairFits
        let tree = BSPTree()
        layout.smartInsertFitting(makeWindow(id: 1), into: tree, maxDepth: 3,
                                  rect: bigRect, minimumSize: zeroMins)

        let huge = makeWindow(id: 2)
        let mins: (HyprWindow?) -> CGSize = { w in
            w === huge ? CGSize(width: 100_000, height: 100_000) : .zero
        }
        let leaf = layout.fittingLeaf(for: huge, in: tree, maxDepth: 3,
                                      rect: bigRect, minimumSize: mins)
        XCTAssertNil(leaf)
    }
}
