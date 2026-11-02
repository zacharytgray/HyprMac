import XCTest
@testable import HyprMac

// strip order matters: exposedPoint breaks ties on it
final class RectSubtractionTests: XCTestCase {
    private let rect = CGRect(x: 100, y: 100, width: 400, height: 300)

    private func assertStrips(_ hole: CGRect, _ expected: [CGRect],
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(WindowStacking.subtract(hole, from: rect), expected, file: file, line: line)
    }

    func testHoleOutsideLeavesTheRect() {
        assertStrips(CGRect(x: 600, y: 600, width: 10, height: 10), [rect])
    }

    func testHoleTouchingAnEdgeLeavesTheRect() {
        assertStrips(CGRect(x: 500, y: 100, width: 50, height: 300), [rect])
    }

    func testEmptyHoleLeavesTheRect() {
        assertStrips(CGRect(x: 200, y: 200, width: 0, height: 50), [rect])
    }

    func testHoleCoveringEverythingLeavesNothing() {
        assertStrips(CGRect(x: 0, y: 0, width: 1000, height: 1000), [])
        assertStrips(rect, [])
    }

    func testHoleInTheMiddleLeavesFourStripsInOrder() {
        assertStrips(CGRect(x: 200, y: 200, width: 100, height: 50), [
            CGRect(x: 100, y: 100, width: 400, height: 100),
            CGRect(x: 100, y: 250, width: 400, height: 150),
            CGRect(x: 100, y: 200, width: 100, height: 50),
            CGRect(x: 300, y: 200, width: 200, height: 50),
        ])
    }

    func testHoleOverACornerLeavesTwoStrips() {
        assertStrips(CGRect(x: 400, y: 50, width: 200, height: 150), [
            CGRect(x: 100, y: 200, width: 400, height: 200),
            CGRect(x: 100, y: 100, width: 300, height: 100),
        ])
    }

    func testHoleAcrossTheWidthLeavesTwoStrips() {
        assertStrips(CGRect(x: 0, y: 200, width: 1000, height: 50), [
            CGRect(x: 100, y: 100, width: 400, height: 100),
            CGRect(x: 100, y: 250, width: 400, height: 150),
        ])
    }
}
