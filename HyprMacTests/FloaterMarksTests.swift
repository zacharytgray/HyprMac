import XCTest
import Cocoa
@testable import HyprMac

// floater outlines: which focus indicator choices draw one, the focus-mark
// color on a floater, and the shared corner geometry.

final class FloaterMarkStyleTests: XCTestCase {
    func testCornersAloneOutlinesFloaters() {
        XCTAssertEqual(FloaterMarkStyle.resolve(showFocusBorder: false, bracketStyle: .rounded), .outline)
    }

    func testWindowBordersOutlineFloaters() {
        XCTAssertEqual(FloaterMarkStyle.resolve(showFocusBorder: true, bracketStyle: .off), .outline)
    }

    func testBothOutlineFloaters() {
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

final class FloaterOutlineGeometryTests: XCTestCase {
    func testThePanelGrowsByTheGlowRoomAndTheOutlineStaysPut() {
        // 3 pt blur: 9 pt of room past the outline, plus half the stroke
        XCTAssertEqual(FloaterOutlineGeometry.glowRoom(glowRadius: 3), 9)
        XCTAssertEqual(FloaterOutlineGeometry.panelExpansion(borderWidth: 1.5, glowRadius: 3), 9.75)
        XCTAssertEqual(FocusBorder.floaterPanelExpansion, 9.75)

        // window at 100,100 400x300: the outline still reaches 0.75 pt past it
        let e = FocusBorder.floaterPanelExpansion
        let panel = CGRect(x: 0, y: 0, width: 400 + e * 2, height: 300 + e * 2)
        let outline = FloaterOutlineGeometry.outlineFrame(inPanelBounds: panel, glowRadius: 3)
        XCTAssertEqual(outline, CGRect(x: 9, y: 9, width: 401.5, height: 301.5))
    }

    func testTheGlowPathIsTheStrokesRing() {
        let bounds = CGRect(x: 0, y: 0, width: 401.5, height: 301.5)
        let ring = FloaterOutlineGeometry.ringPath(in: bounds, cornerRadius: 16.75, borderWidth: 1.5)
        let box = ring.boundingBoxOfPath
        XCTAssertEqual(box.minX, 0, accuracy: 0.01)
        XCTAssertEqual(box.maxX, 401.5, accuracy: 0.01)
        XCTAssertEqual(box.maxY, 301.5, accuracy: 0.01)
        XCTAssertTrue(ring.contains(CGPoint(x: 200, y: 0.75)), "on the stroke")
        XCTAssertFalse(ring.contains(CGPoint(x: 200, y: 150)), "the window inside is not filled")
        XCTAssertFalse(ring.contains(CGPoint(x: 1, y: 1)), "the rounded corner is cut")
    }

    func testATinyOrEmptyRectGetsNoRingAndNoCrash() {
        XCTAssertTrue(FloaterOutlineGeometry.ringPath(in: .zero, cornerRadius: 16, borderWidth: 1.5).isEmpty)
        let tiny = FloaterOutlineGeometry.ringPath(in: CGRect(x: 0, y: 0, width: 4, height: 4),
                                                   cornerRadius: 16, borderWidth: 1.5)
        XCTAssertFalse(tiny.isEmpty)
    }
}

final class FloaterOutlinePanelTests: XCTestCase {
    override func setUpWithError() throws {
        if ProcessInfo.processInfo.environment["HYPRMAC_HEADLESS_TESTS"] == "1" {
            throw XCTSkip("hostless run excludes tests that create AppKit panels")
        }
    }

    func testCornersModeOutlinesFloatersWithTheBorderOff() {
        let border = FocusBorder()
        border.primaryScreenHeight = 1080
        border.isEnabled = false
        border.setFloaterMarks(.outline)
        border.updateFloatingBorders([42: CGRect(x: 100, y: 100, width: 400, height: 300)],
                                     color: NSColor.systemPink.cgColor)

        XCTAssertEqual(border.currentFloaterOutlineWidth(for: 42), 1.5)
        XCTAssertNil(border.trackedWindowID, "floater outlines are not focus")

        border.setFloaterMarks(.none)
        XCTAssertNil(border.currentFloaterOutlineWidth(for: 42))
    }

    func testTheOutlineGlowsInItsColorWithRoomForTheBlur() throws {
        let border = FocusBorder()
        border.primaryScreenHeight = 1080
        border.setFloaterMarks(.outline)
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        border.updateFloatingBorders([42: window], color: NSColor.systemPink.cgColor)

        let o = try XCTUnwrap(border.currentFloaterOutline(for: 42))
        let e = FocusBorder.floaterPanelExpansion
        XCTAssertEqual(o.panel, NSRect(x: 100 - e, y: 1080 - 400 - e, width: 400 + e * 2, height: 300 + e * 2))
        // the stroke sits where it always did: 0.75 pt past the window edge
        XCTAssertEqual(o.outline, CGRect(x: 9, y: 9, width: 401.5, height: 301.5))
        XCTAssertEqual(o.cornerRadius, WindowCornerRadius.resolve(for: 42) + 0.75)
        XCTAssertEqual(o.glowRadius, 3)
        XCTAssertEqual(o.glowOpacity, 0.45)
        XCTAssertEqual(o.glowColor, NSColor.systemPink.cgColor)
        XCTAssertEqual(o.glowPath?.boundingBoxOfPath.width ?? 0, 401.5, accuracy: 0.01)

        // a new Floating color repaints the glow too
        border.refreshAppearance(focusColor: NSColor.blue.cgColor, floatingColor: NSColor.green.cgColor)
        XCTAssertEqual(border.currentFloaterOutline(for: 42)?.glowColor, NSColor.green.cgColor)

        border.hideFloatingBorder(for: 42)
        XCTAssertNil(border.currentFloaterOutline(for: 42), "the glow goes with the outline")
    }

    func testASwitchDropsTheOutgoingOutlinesAtOnceAndACloseStillFades() throws {
        let border = FocusBorder()
        border.primaryScreenHeight = 1080
        border.setFloaterMarks(.outline)
        let frames: [CGWindowID: CGRect] = [
            42: CGRect(x: 100, y: 100, width: 400, height: 300),
            43: CGRect(x: 600, y: 100, width: 400, height: 300),
        ]
        border.updateFloatingBorders(frames, color: NSColor.systemPink.cgColor)
        let outgoing = try XCTUnwrap(border.currentFloaterGlowLayer(for: 42))
        let closing = try XCTUnwrap(border.currentFloaterGlowLayer(for: 43))

        border.beginInstantSwitch(outgoing: [42])
        border.updateFloatingBorders([:], color: NSColor.systemPink.cgColor)
        border.endInstantSwitch()

        XCTAssertNil(border.currentFloaterOutline(for: 42))
        XCTAssertNil(outgoing.animation(forKey: "fade"), "the switch took it away, so it goes at once")
        XCTAssertNotNil(closing.animation(forKey: "fade"), "a floater outside the switch still fades")
    }

    func testANewOutlineIsOnScreenAtOnceWithNoFadeIn() throws {
        let border = FocusBorder()
        border.primaryScreenHeight = 1080
        border.setFloaterMarks(.outline)
        border.updateFloatingBorders([42: CGRect(x: 100, y: 100, width: 400, height: 300)],
                                     color: NSColor.systemPink.cgColor)
        let layer = try XCTUnwrap(border.currentFloaterGlowLayer(for: 42))
        XCTAssertEqual(layer.opacity, 1)
        XCTAssertNil(layer.animation(forKey: "fade"), "no fade in to wait through")
    }

    func testTheOutlineFollowsADragAndAStaleRefreshDoesNotPullItBack() throws {
        let border = FocusBorder()
        border.primaryScreenHeight = 1080
        border.setFloaterMarks(.outline)
        let start = CGRect(x: 100, y: 100, width: 400, height: 300)
        border.updateFloatingBorders([42: start], color: NSColor.systemPink.cgColor)
        border.applyOcclusion(focusedOccluders: [],
                              floaterOccluders: [42: [CGRect(x: 300, y: 100, width: 400, height: 300)]])
        XCTAssertNotNil(border.currentFloaterGlowLayer(for: 42)?.mask)

        let moved = start.offsetBy(dx: 250, dy: 40)
        border.followFloaterDrag(42, to: moved)
        let e = FocusBorder.floaterPanelExpansion
        let expected = NSRect(x: 350 - e, y: 1080 - 440 - e, width: 400 + e * 2, height: 300 + e * 2)
        XCTAssertEqual(border.currentFloaterOutline(for: 42)?.panel, expected)
        XCTAssertNil(border.currentFloaterGlowLayer(for: 42)?.mask, "the dragged floater is in front")

        // a refresh mid-drag reads the lagging frame
        border.updateFloatingBorders([42: start], color: NSColor.systemPink.cgColor)
        border.applyOcclusion(focusedOccluders: [],
                              floaterOccluders: [42: [CGRect(x: 300, y: 100, width: 400, height: 300)]])
        XCTAssertEqual(border.currentFloaterOutline(for: 42)?.panel, expected)
        XCTAssertNil(border.currentFloaterGlowLayer(for: 42)?.mask)

        // the drop: the next refresh lands on the settled frame
        border.endFloaterDrag()
        XCTAssertNil(border.currentFloaterDrag)
        border.updateFloatingBorders([42: moved.offsetBy(dx: 1, dy: 0)], color: NSColor.systemPink.cgColor)
        XCTAssertEqual(border.currentFloaterOutline(for: 42)?.panel, expected.offsetBy(dx: 1, dy: 0))
    }

    func testNoneDrawsNoFloaterOutline() {
        let border = FocusBorder()
        border.primaryScreenHeight = 1080
        border.setFloaterMarks(.none)
        border.updateFloatingBorders([42: CGRect(x: 100, y: 100, width: 400, height: 300)],
                                     color: NSColor.systemPink.cgColor)
        XCTAssertNil(border.currentFloaterOutlineWidth(for: 42))
    }
}

// the window border's focus flash: on by default, and off clears only the
// tint, never the border
final class FocusBorderFlashTests: XCTestCase {
    private let color = NSColor.systemBlue.cgColor

    func testFlashIsOnByDefault() {
        XCTAssertTrue(UserConfigDefaults.focusBorderFlash)
        XCTAssertTrue(FocusBorder().flashesOnFocus)
    }

    func testFlashOnTintsTheWindowFaintly() {
        let fill = FocusBorder.activeFill(for: color, flashesOnFocus: true)
        XCTAssertGreaterThan(fill.alpha, 0)
        XCTAssertLessThan(fill.alpha, 0.2)
    }

    func testFlashOffLeavesTheWindowUntinted() {
        XCTAssertEqual(FocusBorder.activeFill(for: color, flashesOnFocus: false).alpha, 0)
    }

    func testFocusBorderFlashDecodesTolerantly() throws {
        func decode(_ value: String?) throws -> SavedConfig {
            let extra = value.map { #","focusBorderFlash":\#($0)"# } ?? ""
            let json = #"{"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true\#(extra)}"#
            return try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
        }
        XCTAssertNil(try decode(nil).focusBorderFlash)
        XCTAssertEqual(try decode("false").focusBorderFlash, false)
        XCTAssertNil(try decode(#""yes""#).focusBorderFlash)
    }
}

// a tile attempt blocks the main thread while the window tries its slots.
// the outline has to be gone before that, so it is ordered out at once
final class FloaterOutlineDropTests: XCTestCase {
    func testDropOrdersTheOutlineOutAtOnce() {
        let border = FocusBorder()
        border.primaryScreenHeight = 1000
        border.setFloaterMarks(.outline)
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        border.updateFloatingBorders([7: frame, 8: frame.offsetBy(dx: 500, dy: 0)],
                                     color: NSColor.systemBlue.cgColor)
        XCTAssertEqual(border.visibleOwnedPanelCount, 2)

        border.dropFloatingBorder(for: 7)

        XCTAssertNil(border.currentFloaterOutline(for: 7))
        XCTAssertNotNil(border.currentFloaterOutline(for: 8))
        XCTAssertEqual(border.visibleOwnedPanelCount, 1, "no fade: the panel is out before the pass blocks")
    }
}

// the attempt moves the floater and the tiles around it while nothing can
// redraw, so every mark that sits on those frames goes before it
final class TileAttemptChromeTests: XCTestCase {
    func testTheOutlineAndTheDimGo() {
        let plan = TileAttemptChrome.clearing(7, borderTrackedID: nil, bracketsTrackedID: nil, scrimShowing: false)
        XCTAssertEqual(plan, TileAttemptChrome(outline: true, border: false, brackets: false, dim: true))
    }

    func testTheBorderAndBracketsGoOnlyWhenTheyMarkThatWindow() {
        let mine = TileAttemptChrome.clearing(7, borderTrackedID: 7, bracketsTrackedID: 7, scrimShowing: false)
        XCTAssertTrue(mine.border && mine.brackets)
        let other = TileAttemptChrome.clearing(7, borderTrackedID: 8, bracketsTrackedID: 8, scrimShowing: false)
        XCTAssertFalse(other.border || other.brackets)
    }

    // Hypr+T again while the last refusal's red flash is still up: the flash
    // would sit on the old spot while the window tries its slots
    func testARedFlashOnThatWindowGoesToo() {
        XCTAssertTrue(TileAttemptChrome.clearing(7, borderTrackedID: nil, bracketsTrackedID: nil,
                                                 errorFlashID: 7, scrimShowing: false).errorFlash)
        XCTAssertFalse(TileAttemptChrome.clearing(7, borderTrackedID: nil, bracketsTrackedID: nil,
                                                  errorFlashID: 8, scrimShowing: false).errorFlash)
    }

    // the scratchpad scrim covers the screen with no holes; nothing on it is stale
    func testTheScrimStays() {
        XCTAssertFalse(TileAttemptChrome.clearing(7, borderTrackedID: nil, bracketsTrackedID: nil,
                                                  scrimShowing: true).dim)
    }
}

// the red flash goes where the window server draws the window, and follows
// it while the window is still moving or resizing into place
final class ErrorFlashFollowTests: XCTestCase {
    private let start = CGRect(x: 100, y: 100, width: 400, height: 300)
    private let landed = CGRect(x: 160, y: 140, width: 380, height: 320)

    private func flashing() -> FocusBorder {
        let border = FocusBorder()
        border.primaryScreenHeight = 1000
        border.flashError(around: start, windowID: 7)
        return border
    }

    func testTheFlashNamesItsWindow() {
        let border = flashing()
        XCTAssertEqual(border.errorFeedbackTarget, 7)
        border.hide(fade: false)
        XCTAssertNil(border.errorFeedbackTarget)
    }

    func testTheFlashFollowsItsWindow() {
        let border = flashing()
        border.followErrorFlash(7, to: landed)
        XCTAssertEqual(border.frame, landed)
        XCTAssertTrue(border.isErrorFeedbackActive, "following does not end the flash")
        border.hide(fade: false)
    }

    func testAnotherWindowsMoveLeavesTheFlash() {
        let border = flashing()
        border.followErrorFlash(8, to: landed)
        XCTAssertEqual(border.frame, start)
        border.hide(fade: false)
    }
}
