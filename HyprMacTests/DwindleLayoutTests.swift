import XCTest
@testable import HyprMac

// Pin the dwindle preview math used by Settings → Tiling. Pure
// CGRect computation; no SwiftUI involved.

final class DwindleLayoutTests: XCTestCase {

    // MARK: - rects(count:in:gap:)

    func testEmptyCountReturnsEmpty() {
        let rects = DwindleLayout.rects(
            count: 0,
            in: CGRect(x: 0, y: 0, width: 1000, height: 800),
            gap: 8
        )
        XCTAssertEqual(rects, [])
    }

    func testSingleWindowFillsBounds() {
        let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
        let rects = DwindleLayout.rects(count: 1, in: bounds, gap: 8)
        XCTAssertEqual(rects, [bounds])
    }

    func testTwoWindowsHorizontalSplitWideBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let rects = DwindleLayout.rects(count: 2, in: bounds, gap: 10)
        XCTAssertEqual(rects.count, 2)
        // first at left, half width minus halfGap
        XCTAssertEqual(rects[0], CGRect(x: 0, y: 0, width: 495, height: 500))
        // second at right, complementary slot
        XCTAssertEqual(rects[1], CGRect(x: 505, y: 0, width: 495, height: 500))
    }

    func testTwoWindowsVerticalSplitTallBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 1000)
        let rects = DwindleLayout.rects(count: 2, in: bounds, gap: 10)
        XCTAssertEqual(rects.count, 2)
        XCTAssertEqual(rects[0], CGRect(x: 0, y: 0,   width: 400, height: 495))
        XCTAssertEqual(rects[1], CGRect(x: 0, y: 505, width: 400, height: 495))
    }

    func testThreeWindowsDwindleAlternatesSplitDirection() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let rects = DwindleLayout.rects(count: 3, in: bounds, gap: 0)
        XCTAssertEqual(rects.count, 3)
        // first split horizontal: left half is window 0
        XCTAssertEqual(rects[0], CGRect(x: 0, y: 0, width: 500, height: 500))
        // right half is now 500x500 (square) — recursion uses width >= height
        // (still horizontal). second split: left of right half.
        XCTAssertEqual(rects[1], CGRect(x: 500, y: 0, width: 250, height: 500))
        // last fills remainder.
        XCTAssertEqual(rects[2], CGRect(x: 750, y: 0, width: 250, height: 500))
    }

    func testGapAppliedToSiblingsNotOuterEdges() {
        let bounds = CGRect(x: 100, y: 200, width: 800, height: 400)
        let rects = DwindleLayout.rects(count: 2, in: bounds, gap: 20)
        // outer edges preserved.
        XCTAssertEqual(rects[0].minX, 100)
        XCTAssertEqual(rects[1].maxX, 900)
        // gap straddles the midpoint — 10px on each side.
        XCTAssertEqual(rects[0].maxX, 490) // 100 + 400 - 10
        XCTAssertEqual(rects[1].minX, 510) // 100 + 400 + 10
    }

    // MARK: - fitSize(in:aspect:)

    func testFitSizePreservesAspect() {
        let size = DwindleLayout.fitSize(
            in: CGSize(width: 200, height: 120),
            aspect: 16.0 / 9.0
        )
        XCTAssertEqual(size.width / size.height, 16.0 / 9.0, accuracy: 0.0001)
    }

    func testFitSizeWidthLimitedByContainerMargin() {
        // wide container, 1:1 aspect — height (minus 8px) caps the size.
        let size = DwindleLayout.fitSize(
            in: CGSize(width: 1000, height: 100),
            aspect: 1.0
        )
        // maxH = 92, maxW = 984, w = min(984, 92*1) = 92
        XCTAssertEqual(size.width, 92)
        XCTAssertEqual(size.height, 92)
    }

    func testFitSizeHeightLimitedByContainerMargin() {
        // tall container, 1:1 aspect — width (minus 16px) caps the size.
        let size = DwindleLayout.fitSize(
            in: CGSize(width: 100, height: 1000),
            aspect: 1.0
        )
        // maxW = 84, maxH = 992, w = min(84, 992) = 84
        XCTAssertEqual(size.width, 84)
        XCTAssertEqual(size.height, 84)
    }
}
