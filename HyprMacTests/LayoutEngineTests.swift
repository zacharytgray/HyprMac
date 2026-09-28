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

    func testSmartInsertFittingUsesAlternateAxisForConstrainedPortraitBatch() {
        let tree = BSPTree()
        let rect = CGRect(x: 0, y: 0, width: 1080, height: 1890)
        let widths: [CGWindowID: CGFloat] = [1: 574, 2: 528, 3: 708, 4: 640]
        let windows = (1...4).map { makeWindow(id: CGWindowID($0)) }
        let mins: (HyprWindow?) -> CGSize = { window in
            CGSize(width: widths[window?.windowID ?? 0] ?? 0, height: 300)
        }

        for window in windows {
            XCTAssertTrue(layout.smartInsertFitting(window, into: tree, maxDepth: 2,
                                                    rect: rect, minimumSize: mins))
        }

        XCTAssertEqual(Set(tree.allWindows.map(\.windowID)), Set(widths.keys))
        XCTAssertEqual(tree.root.left?.splitOverride, .vertical)
        XCTAssertEqual(tree.root.right?.splitOverride, .vertical)
        let frames = tree.layout(in: rect, gap: layout.gapSize, padding: layout.outerPadding)
        XCTAssertEqual(frames.count, 4)
        XCTAssertTrue(frames.allSatisfy { $0.1.width == 1064 })
    }

    func testSmartInsertFittingKeepsPreferredAxisWhenBothAxesFit() {
        let tree = BSPTree()
        XCTAssertTrue(layout.smartInsertFitting(makeWindow(id: 1), into: tree, maxDepth: 3,
                                                rect: bigRect, minimumSize: zeroMins))
        XCTAssertTrue(layout.smartInsertFitting(makeWindow(id: 2), into: tree, maxDepth: 3,
                                                rect: bigRect, minimumSize: zeroMins))

        XCTAssertEqual(tree.root.direction(for: bigRect.insetBy(dx: 8, dy: 8)), .horizontal)
        // the preferred axis is pinned as such, so a later ratio change
        // cannot flip it; the pin is the automatic kind, not a togglesplit
        XCTAssertEqual(tree.root.splitOverride, .horizontal)
        XCTAssertTrue(tree.root.splitOverrideIsAutomatic)
    }

    func testSmartInsertFittingDoesNotReplaceASavedSplitDirection() {
        let tree = BSPTree()
        let tenant = makeWindow(id: 1)
        tree.root.window = tenant
        tree.root.savedSplitRatio = 0.5
        tree.root.savedChildWasLeft = false
        tree.root.savedSplitOverride = .horizontal
        let incoming = makeWindow(id: 2)
        let mins: (HyprWindow?) -> CGSize = { window in
            window === tenant ? CGSize(width: 574, height: 300)
                : CGSize(width: 640, height: 300)
        }

        XCTAssertFalse(layout.smartInsertFitting(incoming, into: tree, maxDepth: 2,
                                                 rect: CGRect(x: 0, y: 0, width: 1080, height: 950),
                                                 minimumSize: mins))
        XCTAssertEqual(tree.root.window?.windowID, tenant.windowID)
        XCTAssertEqual(tree.root.savedSplitOverride, .horizontal)
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

    // MARK: - refusal reporting

    func testPairFitNamesTheAxisTheSumOverflowed() {
        let wide = CGSize(width: 1000, height: 10)
        let fit = layout.pairFit(wide, wide, in: CGRect(x: 0, y: 0, width: 1200, height: 800),
                                 dir: .horizontal)
        XCTAssertFalse(fit.fits)
        XCTAssertFalse(fit.sumOk)
        XCTAssertEqual(fit.refusedAxis, "width")
    }

    func testPairFitNamesTheCrossAxisSeparately() {
        let tall = CGSize(width: 10, height: 2000)
        let fit = layout.pairFit(tall, .zero, in: CGRect(x: 0, y: 0, width: 1200, height: 800),
                                 dir: .horizontal)
        XCTAssertFalse(fit.aCross)
        XCTAssertEqual(fit.refusedAxis, "height")
    }

    func testPairFitNamesBothAxesWhenBothRefuse() {
        let huge = CGSize(width: 2000, height: 2000)
        let fit = layout.pairFit(huge, huge, in: CGRect(x: 0, y: 0, width: 1200, height: 800),
                                 dir: .horizontal)
        XCTAssertEqual(fit.refusedAxis, "width+height")
    }

    func testPairFitOnAFittingPairRefusesNoAxis() {
        let fit = layout.pairFit(.zero, .zero, in: bigRect, dir: .horizontal)
        XCTAssertTrue(fit.fits)
        XCTAssertEqual(fit.refusedAxis, "none")
    }

    func testFittingLeafReportsOneRefusalPerLeafWithTheSlotAndTheAxis() {
        let tree = BSPTree()
        let tenant = makeWindow(id: 1)
        layout.smartInsertFitting(tenant, into: tree, maxDepth: 3,
                                  rect: bigRect, minimumSize: zeroMins)
        let huge = makeWindow(id: 2)
        let mins: (HyprWindow?) -> CGSize = { w in
            w === huge ? CGSize(width: 100_000, height: 0) : .zero
        }

        var refusals: [LayoutEngine.SlotRefusal] = []
        let leaf = layout.fittingLeaf(for: huge, in: tree, maxDepth: 3, rect: bigRect,
                                      minimumSize: mins, noting: { refusals.append($0) })

        XCTAssertNil(leaf)
        XCTAssertEqual(refusals.count, 1, "one leaf, reported once — not once per pass")
        guard let only = refusals.first else { return }
        XCTAssertEqual(only.tenantID, 1)
        XCTAssertEqual(only.axis, "width")
        XCTAssertEqual(only.incomingMinimum, CGSize(width: 100_000, height: 0))
        XCTAssertEqual(only.tenantMinimum, .zero)
        XCTAssertFalse(only.depthExhausted)
        XCTAssertEqual(only.slot.width, bigRect.width - 2 * 8, accuracy: 0.001)
    }

    func testFittingLeafReportsOnceWhenBothAxesRefuse() {
        let tree = BSPTree()
        let tenant = makeWindow(id: 1)
        layout.smartInsertFitting(tenant, into: tree, maxDepth: 3,
                                  rect: bigRect, minimumSize: zeroMins)
        let incoming = makeWindow(id: 2)
        let mins: (HyprWindow?) -> CGSize = { window in
            window == nil ? .zero : CGSize(width: 2_000, height: 2_000)
        }
        var refusals: [LayoutEngine.SlotRefusal] = []

        let leaf = layout.fittingLeaf(for: incoming, in: tree, maxDepth: 3,
                                      rect: bigRect, minimumSize: mins,
                                      noting: { refusals.append($0) })

        XCTAssertNil(leaf)
        XCTAssertEqual(refusals.count, 1)
        XCTAssertEqual(tree.root.window?.windowID, tenant.windowID)
        XCTAssertNil(tree.root.splitOverride)
    }

    func testFittingLeafReportsNothingWhenALeafTakesTheWindow() {
        let tree = BSPTree()
        layout.smartInsertFitting(makeWindow(id: 1), into: tree, maxDepth: 3,
                                  rect: bigRect, minimumSize: zeroMins)
        var refusals: [LayoutEngine.SlotRefusal] = []

        let leaf = layout.fittingLeaf(for: makeWindow(id: 2), in: tree, maxDepth: 3,
                                      rect: bigRect, minimumSize: zeroMins,
                                      noting: { refusals.append($0) })

        XCTAssertNotNil(leaf)
        XCTAssertTrue(refusals.isEmpty)
    }

    func testFittingLeafReportsDepthExhaustionAsItsOwnRefusal() {
        let tree = BSPTree()
        layout.smartInsertFitting(makeWindow(id: 1), into: tree, maxDepth: 3,
                                  rect: bigRect, minimumSize: zeroMins)
        layout.smartInsertFitting(makeWindow(id: 2), into: tree, maxDepth: 3,
                                  rect: bigRect, minimumSize: zeroMins)
        var refusals: [LayoutEngine.SlotRefusal] = []

        let leaf = layout.fittingLeaf(for: makeWindow(id: 3), in: tree, maxDepth: 1,
                                      rect: bigRect, minimumSize: zeroMins,
                                      noting: { refusals.append($0) })

        XCTAssertNil(leaf)
        XCTAssertEqual(refusals.count, 2)
        XCTAssertTrue(refusals.allSatisfy { $0.depthExhausted })
        XCTAssertTrue(refusals.allSatisfy { $0.axis == "depth" })
        XCTAssertEqual(Set(refusals.compactMap(\.tenantID)), [1, 2])
    }

    func testReportingDoesNotChangeWhichLeafIsChosen() {
        let tree = BSPTree()
        layout.smartInsertFitting(makeWindow(id: 1), into: tree, maxDepth: 3,
                                  rect: narrowRect, minimumSize: zeroMins)
        layout.smartInsertFitting(makeWindow(id: 2), into: tree, maxDepth: 3,
                                  rect: narrowRect, minimumSize: zeroMins)
        let incoming = makeWindow(id: 3)

        let quiet = layout.fittingLeaf(for: incoming, in: tree, maxDepth: 3,
                                       rect: narrowRect, minimumSize: zeroMins)
        let loud = layout.fittingLeaf(for: incoming, in: tree, maxDepth: 3,
                                      rect: narrowRect, minimumSize: zeroMins, noting: { _ in })

        XCTAssertTrue(quiet === loud)
    }
}
