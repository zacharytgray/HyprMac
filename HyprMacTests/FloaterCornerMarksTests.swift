import XCTest
import Cocoa
@testable import HyprMac

// floater marks in Corners mode: which mark each focus indicator choice
// draws, the focus-mark color on a floater, and the shared corner geometry.

final class FloaterMarkStyleTests: XCTestCase {
    func testCornersAloneDrawsQuietCorners() {
        XCTAssertEqual(FloaterMarkStyle.resolve(showFocusBorder: false, bracketStyle: .rounded), .corners)
    }

    func testWindowBordersKeepTheOutline() {
        XCTAssertEqual(FloaterMarkStyle.resolve(showFocusBorder: true, bracketStyle: .off), .outline)
    }

    func testBothKeepsTheOutlineWithoutCornersOnTop() {
        XCTAssertEqual(FloaterMarkStyle.resolve(showFocusBorder: true, bracketStyle: .rounded), .outline)
    }

    func testNoneDrawsNothing() {
        XCTAssertEqual(FloaterMarkStyle.resolve(showFocusBorder: false, bracketStyle: .off), .none)
    }
}

final class FocusMarkColorTests: XCTestCase {
    private let mark = NSColor.black.cgColor
    private let floating = NSColor.systemPink.cgColor

    func testFloatingFocusTakesTheFloatingColor() {
        XCTAssertEqual(FocusMarkColor.resolve(focusedIsFloating: true, markColor: mark,
                                              floatingColor: floating), floating)
    }

    func testTiledFocusKeepsTheMarkColor() {
        XCTAssertEqual(FocusMarkColor.resolve(focusedIsFloating: false, markColor: mark,
                                              floatingColor: floating), mark)
    }
}

final class CornerMarkGeometryTests: XCTestCase {
    // NS coordinates, y up. inset 14, radius 20, 10 pt legs: each corner
    // spans inset .. inset + radius + leg on both axes
    private let frame = CGRect(x: 0, y: 0, width: 400, height: 300)

    func testFourCornersWithTenPointLegsAndTheMarkRadius() {
        let paths = CornerMarkGeometry.paths(in: frame, inset: 14, radius: 20, legLength: 10)
        XCTAssertEqual(paths.count, 4)
        let expected = [
            CGRect(x: 14, y: 256, width: 30, height: 30),  // TL
            CGRect(x: 356, y: 256, width: 30, height: 30), // TR
            CGRect(x: 14, y: 14, width: 30, height: 30),   // BL
            CGRect(x: 356, y: 14, width: 30, height: 30),  // BR
        ]
        for (path, box) in zip(paths, expected) {
            assertRect(path.boundingBoxOfPath, box)
        }
    }

    func testLegsStartAndEndTangentToTheInsetEdges() {
        let tl = CornerMarkGeometry.paths(in: frame, inset: 14, radius: 20, legLength: 10)[0]
        let points = endpoints(of: tl)
        // starts 10 pt along the top edge past the arc, ends 10 pt down the left edge
        assertPoint(points.first, CGPoint(x: 44, y: 286))
        assertPoint(points.last, CGPoint(x: 14, y: 256))
    }

    func testSquareMarksAreJustTheLegs() {
        let tl = CornerMarkGeometry.paths(in: frame, inset: 14, radius: 0, legLength: 10)[0]
        assertRect(tl.boundingBoxOfPath, CGRect(x: 14, y: 276, width: 10, height: 10))
    }

    func testCombinedPathCoversAllFourCorners() {
        let path = CornerMarkGeometry.combinedPath(in: frame, inset: 14, radius: 20, legLength: 10)
        assertRect(path.boundingBoxOfPath, CGRect(x: 14, y: 14, width: 372, height: 272))
    }

    func testOffsetFrameMovesTheMarks() {
        let moved = frame.offsetBy(dx: 0.75, dy: 0.75)
        let tl = CornerMarkGeometry.paths(in: moved, inset: 14, radius: 20, legLength: 10)[0]
        assertRect(tl.boundingBoxOfPath, CGRect(x: 14.75, y: 256.75, width: 30, height: 30))
    }

    private func endpoints(of path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint, .addLineToPoint: points.append(e.points[0])
            case .addQuadCurveToPoint: points.append(e.points[1])
            case .addCurveToPoint: points.append(e.points[2])
            default: break
            }
        }
        return points
    }

    private func assertPoint(_ p: CGPoint?, _ q: CGPoint, line: UInt = #line) {
        guard let p else { return XCTFail("no point", line: line) }
        XCTAssertEqual(p.x, q.x, accuracy: 0.001, line: line)
        XCTAssertEqual(p.y, q.y, accuracy: 0.001, line: line)
    }

    private func assertRect(_ r: CGRect, _ q: CGRect, line: UInt = #line) {
        XCTAssertEqual(r.minX, q.minX, accuracy: 0.001, line: line)
        XCTAssertEqual(r.minY, q.minY, accuracy: 0.001, line: line)
        XCTAssertEqual(r.width, q.width, accuracy: 0.001, line: line)
        XCTAssertEqual(r.height, q.height, accuracy: 0.001, line: line)
    }
}

final class FloaterCornerPanelTests: XCTestCase {
    override func setUpWithError() throws {
        if ProcessInfo.processInfo.environment["HYPRMAC_HEADLESS_TESTS"] == "1" {
            throw XCTSkip("hostless run excludes tests that create AppKit panels")
        }
    }

    func testCornersModeMarksFloatersWithTheBorderOff() throws {
        let border = FocusBorder()
        border.primaryScreenHeight = 1080
        border.isEnabled = false
        border.setFloaterMarks(.corners, cornerRadius: 20)
        border.updateFloatingBorders([42: CGRect(x: 100, y: 100, width: 400, height: 300)],
                                     color: NSColor.systemPink.cgColor)

        let mark = try XCTUnwrap(border.currentFloaterMark(for: 42))
        XCTAssertEqual(mark.outlineWidth, 0)
        XCTAssertNotNil(mark.cornerPath)
        XCTAssertNil(border.trackedWindowID, "floater marks are not focus")

        border.setFloaterMarks(.none, cornerRadius: 20)
        XCTAssertNil(border.currentFloaterMark(for: 42))
    }

    func testOutlineModeRestylesCornerPanelsInPlace() throws {
        let border = FocusBorder()
        border.primaryScreenHeight = 1080
        let frames: [CGWindowID: CGRect] = [42: CGRect(x: 100, y: 100, width: 400, height: 300)]
        border.setFloaterMarks(.corners, cornerRadius: 20)
        border.updateFloatingBorders(frames, color: NSColor.systemPink.cgColor)
        border.setFloaterMarks(.outline, cornerRadius: 20)
        border.updateFloatingBorders(frames, color: NSColor.systemPink.cgColor)

        let mark = try XCTUnwrap(border.currentFloaterMark(for: 42))
        XCTAssertEqual(mark.outlineWidth, 1.5)
        XCTAssertNil(mark.cornerPath)
        border.isEnabled = false
    }
}
