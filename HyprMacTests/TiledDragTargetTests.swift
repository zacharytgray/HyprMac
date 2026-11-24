import XCTest
@testable import HyprMac

final class TiledDragTargetTests: XCTestCase {
    private let slots: [CGWindowID: CGRect] = [
        1: CGRect(x: 0, y: 0, width: 100, height: 80),
        2: CGRect(x: 110, y: 0, width: 100, height: 80),
        3: CGRect(x: 220, y: 0, width: 100, height: 80),
        4: CGRect(x: 330, y: 0, width: 100, height: 80)
    ]

    func testSelectsEachNormalizedNearestEdge() {
        XCTAssertEqual(resolve(CGPoint(x: 111, y: 40)), target(2, .left))
        XCTAssertEqual(resolve(CGPoint(x: 209, y: 40)), target(2, .right))
        XCTAssertEqual(resolve(CGPoint(x: 160, y: 1)), target(2, .top))
        XCTAssertEqual(resolve(CGPoint(x: 160, y: 79)), target(2, .bottom))
    }

    func testIncludesExactSlotEdges() {
        XCTAssertEqual(resolve(CGPoint(x: 110, y: 40)), target(2, .left))
        XCTAssertEqual(resolve(CGPoint(x: 210, y: 40)), target(2, .right))
        XCTAssertEqual(resolve(CGPoint(x: 160, y: 0)), target(2, .top))
        XCTAssertEqual(resolve(CGPoint(x: 160, y: 80)), target(2, .bottom))
    }

    func testTiesUseLeftRightTopBottomOrder() {
        XCTAssertEqual(resolve(CGPoint(x: 160, y: 40)), target(2, .left))
        XCTAssertEqual(resolve(CGPoint(x: 135, y: 40)), target(2, .left))
        XCTAssertEqual(resolve(CGPoint(x: 185, y: 40)), target(2, .right))
    }

    func testHitsEveryColumnByPointerLocation() {
        for id: CGWindowID in 1...4 {
            guard let frame = slots[id] else { return XCTFail("missing fixture slot") }
            XCTAssertEqual(resolve(CGPoint(x: frame.midX, y: 2), draggedID: 99)?.windowID, id)
        }
    }

    func testExcludesDraggedSlotAndDoesNotUseDraggedFinalCenter() {
        var candidates = slots
        candidates[9] = CGRect(x: 100, y: -10, width: 130, height: 100)
        XCTAssertEqual(resolve(CGPoint(x: 160, y: 2), draggedID: 9,
                               intendedSlots: candidates), target(2, .top))
    }

    func testOutsideAndNonFinitePointersHaveNoTarget() {
        XCTAssertNil(resolve(CGPoint(x: -1, y: 40)))
        XCTAssertNil(resolve(CGPoint(x: CGFloat.nan, y: 40)))
        XCTAssertNil(resolve(CGPoint(x: 160, y: CGFloat.infinity)))
    }

    func testAmbiguousOverlappingSlotsHaveNoTarget() {
        let overlapping: [CGWindowID: CGRect] = [
            2: CGRect(x: 0, y: 0, width: 100, height: 100),
            3: CGRect(x: 50, y: 0, width: 100, height: 100)
        ]
        XCTAssertNil(resolve(CGPoint(x: 75, y: 50), intendedSlots: overlapping))
    }

    // MARK: - nearest tile, for a release on another monitor

    func testNearestInsideATileUsesTheSameEdgeRule() {
        for point in [CGPoint(x: 111, y: 40), CGPoint(x: 209, y: 40),
                      CGPoint(x: 160, y: 1), CGPoint(x: 160, y: 79), CGPoint(x: 160, y: 40)] {
            XCTAssertEqual(nearest(point), resolve(point), "\(point)")
        }
    }

    func testNearestTakesTheClosestTileAcrossAGap() {
        // 1 ends at 100 and 2 starts at 110
        XCTAssertEqual(nearest(CGPoint(x: 103, y: 40)), target(1, .right))
        XCTAssertEqual(nearest(CGPoint(x: 108, y: 40)), target(2, .left))
        // the middle of the gap goes to the lower id
        XCTAssertEqual(nearest(CGPoint(x: 105, y: 40)), target(1, .right))
    }

    func testNearestReachesIntoThePadding() {
        XCTAssertEqual(nearest(CGPoint(x: -20, y: 40)), target(1, .left))
        XCTAssertEqual(nearest(CGPoint(x: 160, y: 95)), target(2, .bottom))
        XCTAssertEqual(nearest(CGPoint(x: 400, y: -30)), target(4, .top))
    }

    func testNearestWithoutTilesOrWithABadPointerHasNoTarget() {
        XCTAssertNil(TiledDragTargetResolver.nearest(pointer: .zero, slots: [:]))
        XCTAssertNil(nearest(CGPoint(x: CGFloat.nan, y: 40)))
    }

    func testNearestWithinABandNeedsOneTileInIt() {
        func near(_ x: CGFloat, _ y: CGFloat, band: CGFloat = 5) -> CGWindowID? {
            TiledDragTargetResolver.nearest(pointer: CGPoint(x: x, y: y), slots: slots, within: band)
        }
        XCTAssertEqual(near(102, 40), 1)
        XCTAssertEqual(near(107, 40), 2)
        XCTAssertEqual(near(50, 40), 1, "inside a tile")
        XCTAssertEqual(near(103, 83), 1, "a corner, by straight-line distance")
        XCTAssertNil(near(105, 40), "equally near")
        XCTAssertNil(near(50, 90), "beyond the band")
        XCTAssertNil(near(102, 40, band: 0), "no gap, no band")
    }

    func testTraceListsEveryTileWithItsDistanceAndEdgeFractions() {
        let trace = TiledDragTargetResolver.trace(
            pointer: CGPoint(x: 205, y: 40),
            slots: [2: CGRect(x: 110, y: 0, width: 100, height: 80),
                    1: CGRect(x: 0, y: 0, width: 100, height: 80)])
        XCTAssertEqual(trace,
                       "1 frame=(0,0,100,80) dist=105 l=1.000 r=0.000 t=0.500 b=0.500; "
                       + "2 frame=(110,0,100,80) dist=0 l=0.950 r=0.050 t=0.500 b=0.500")
    }

    // MARK: - the drop planner

    func testPlannerPrefersASourceTileThenAnotherMonitorThenNothing() {
        let sourceTiles = CGRect(x: 0, y: 0, width: 440, height: 100)
        let other: [CGWindowID: CGRect] = [10: CGRect(x: 1000, y: 0, width: 200, height: 100)]
        func plan(_ point: CGPoint, _ release: TiledDropRelease) -> TiledDropPlan {
            TiledDropPlanner.plan(pointer: point, draggedID: 1, sourceTiles: sourceTiles,
                                  sourceSlots: slots, release: release)
        }
        // a source tile wins, whatever display the release is filed under
        XCTAssertEqual(plan(CGPoint(x: 111, y: 40), .otherMonitor(slots: other)),
                       .sameTree(target(2, .left)))
        // a gap on the source takes nothing
        XCTAssertEqual(plan(CGPoint(x: 105, y: 40), .source), .none)
        // the dragged window's own slot is not a target
        XCTAssertEqual(plan(CGPoint(x: 50, y: 40), .source), .none)
        // another monitor: its nearest tile, from its padding too
        XCTAssertEqual(plan(CGPoint(x: 990, y: 50), .otherMonitor(slots: other)),
                       .otherMonitor(target(10, .left)))
        // an empty workspace takes the root; a declined one takes nothing
        XCTAssertEqual(plan(CGPoint(x: 990, y: 50), .otherMonitor(slots: [:])), .otherMonitor(nil))
        XCTAssertEqual(plan(CGPoint(x: 990, y: 50), .otherMonitor(slots: nil)), .none)
    }

    func testPlannerSlotsAreTheTreesOwnLayout() {
        let tree = BSPTree()
        [makeWindow(id: 10), makeWindow(id: 11)].forEach { _ = tree.insert($0, maxDepth: 3) }
        let rect = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let expected = Dictionary(uniqueKeysWithValues: tree.layout(in: rect, gap: 8, padding: 8)
            .map { ($0.0.windowID, $0.1) })
        XCTAssertEqual(TiledDropPlanner.slots(of: tree, in: rect, gap: 8, padding: 8), expected)
    }

    private func nearest(_ pointer: CGPoint) -> TiledDragTarget? {
        TiledDragTargetResolver.nearest(pointer: pointer, slots: slots)
    }

    private func resolve(_ pointer: CGPoint, draggedID: CGWindowID = 1,
                         intendedSlots: [CGWindowID: CGRect]? = nil) -> TiledDragTarget? {
        TiledDragTargetResolver.resolve(pointer: pointer, draggedID: draggedID,
                                        intendedSlots: intendedSlots ?? slots)
    }

    private func target(_ windowID: CGWindowID, _ edge: BSPTargetEdge) -> TiledDragTarget {
        TiledDragTarget(windowID: windowID, edge: edge)
    }
}
