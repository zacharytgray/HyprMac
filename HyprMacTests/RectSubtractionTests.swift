import XCTest
@testable import HyprMac

// WindowStacking and FocusBorder each carry a rect subtraction. they emit the
// strips in a different order, so compare as sets.
final class RectSubtractionTests: XCTestCase {
    private let rect = CGRect(x: 100, y: 100, width: 400, height: 300)

    private func strips(_ hole: CGRect) -> Set<[CGFloat]> {
        Set(WindowStacking.subtract(hole, from: rect).map {
            [$0.minX, $0.minY, $0.width, $0.height]
        })
    }

    private func assertStrips(_ hole: CGRect, _ expected: [[CGFloat]],
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(strips(hole), Set(expected), file: file, line: line)
        let border = Set(FocusBorder.subtract(hole, from: rect).map {
            [$0.minX, $0.minY, $0.width, $0.height]
        })
        XCTAssertEqual(border, Set(expected), "FocusBorder", file: file, line: line)
    }

    func testHoleOutsideLeavesTheRect() {
        assertStrips(CGRect(x: 600, y: 600, width: 10, height: 10), [[100, 100, 400, 300]])
    }

    func testHoleTouchingAnEdgeLeavesTheRect() {
        assertStrips(CGRect(x: 500, y: 100, width: 50, height: 300), [[100, 100, 400, 300]])
    }

    // the one place they differ. FocusBorder splits around an empty hole, and
    // its strips still cover the whole rect, so the mask comes out the same.
    func testEmptyHoleCoversTheWholeRect() {
        let hole = CGRect(x: 200, y: 200, width: 0, height: 50)
        XCTAssertEqual(strips(hole), [[100, 100, 400, 300]])
        let border = FocusBorder.subtract(hole, from: rect)
        XCTAssertEqual(border.count, 4)
        XCTAssertEqual(border.map { $0.width * $0.height }.reduce(0, +), rect.width * rect.height)
    }

    func testHoleCoveringEverythingLeavesNothing() {
        assertStrips(CGRect(x: 0, y: 0, width: 1000, height: 1000), [])
        assertStrips(rect, [])
    }

    func testHoleInTheMiddleLeavesFourStrips() {
        assertStrips(CGRect(x: 200, y: 200, width: 100, height: 50), [
            [100, 100, 400, 100], // low y
            [100, 250, 400, 150], // high y
            [100, 200, 100, 50], // left
            [300, 200, 200, 50], // right
        ])
    }

    func testHoleOverACornerLeavesTwoStrips() {
        assertStrips(CGRect(x: 400, y: 50, width: 200, height: 150), [
            [100, 200, 400, 200],
            [100, 100, 300, 100],
        ])
    }

    func testHoleAcrossTheWidthLeavesTwoStrips() {
        assertStrips(CGRect(x: 0, y: 200, width: 1000, height: 50), [
            [100, 100, 400, 100],
            [100, 250, 400, 150],
        ])
    }
}
