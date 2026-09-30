import XCTest
import Cocoa
@testable import HyprMac

// the scratchpad layer tiles into an inset region of its monitor. every
// engine path that re-lays its tree (swap, resize, split toggle, intended
// rects for directional picks) has to use that region, not the full screen.

private final class LayerScreen: SyntheticScreen {
    override func isEqual(_ object: Any?) -> Bool {
        guard let screen = object as? NSScreen else { return false }
        return self === screen
    }
    override var hash: Int { ObjectIdentifier(self).hashValue }
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 1600, height: 1000) }
    override var visibleFrame: NSRect { frame }
}

final class ScratchpadLayerLayoutTests: XCTestCase {
    private var screen: LayerScreen!
    private var engine: TilingEngine!
    private let region = CGRect(x: 200, y: 150, width: 1200, height: 700)
    private let layer = TilingEngine.scratchpadWorkspace

    override func setUp() {
        let screen = LayerScreen()
        self.screen = screen
        engine = TilingEngine(displayManager: DisplayManager(screenSource: { [screen] }),
                              frameSizingIOFactory: acceptingFrameSizingIOFactory())
    }

    private func tileTwo() -> (HyprWindow, HyprWindow) {
        let left = makeWindow(id: 1), right = makeWindow(id: 2)
        XCTAssertTrue(engine.tileScratchpad([left, right], screen: screen, in: region).isEmpty)
        return (left, right)
    }

    private func assertInsideRegion(_ rects: [CGWindowID: CGRect], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(rects.isEmpty, file: file, line: line)
        for (id, r) in rects {
            XCTAssertTrue(region.insetBy(dx: -1, dy: -1).contains(r),
                          "window \(id) at \(r) left the layer region \(region)", file: file, line: line)
        }
    }

    func testIntendedRectsForTheLayerUseItsRegion() {
        _ = tileTwo()
        let intended = engine.intendedTileRects()
        XCTAssertEqual(intended[1], engine.scratchpadTileRects(screen: screen, in: region)[1])
        XCTAssertEqual(intended[2], engine.scratchpadTileRects(screen: screen, in: region)[2])
        assertInsideRegion(intended)
    }

    func testSwapInsideTheLayerExchangesSlotsWithinItsRegion() {
        let (left, right) = tileTwo()
        let before = engine.scratchpadTileRects(screen: screen, in: region)

        XCTAssertTrue(engine.canSwapWindows(left, right, onWorkspace: layer, screen: screen))
        XCTAssertTrue(engine.swapWindows(left, right, onWorkspace: layer, screen: screen))

        let after = engine.intendedTileRects()
        XCTAssertEqual(after[1], before[2])
        XCTAssertEqual(after[2], before[1])
        assertInsideRegion(after)
    }

    func testTheWorkspaceUnderTheLayerCannotSwapItsMembers() {
        // what the dispatcher used to ask for: the screen's workspace, whose
        // tree doesn't hold the members, so the swap read as "no room"
        let (left, right) = tileTwo()
        XCTAssertFalse(engine.canSwapWindows(left, right, onWorkspace: 1, screen: screen))
    }

    func testResizeInsideTheLayerStaysInItsRegion() {
        let (left, _) = tileTwo()
        let before = engine.scratchpadTileRects(screen: screen, in: region)

        engine.resizeInDirection(left, direction: .right, onWorkspace: layer, screen: screen)

        let after = engine.intendedTileRects()
        XCTAssertGreaterThan(after[1]?.width ?? 0, before[1]?.width ?? 0)
        assertInsideRegion(after)
    }

    func testSplitToggleInsideTheLayerStaysInItsRegion() {
        let (left, _) = tileTwo()
        let before = engine.scratchpadTileRects(screen: screen, in: region)

        engine.toggleSplit(left, onWorkspace: layer, screen: screen)

        let after = engine.intendedTileRects()
        XCTAssertNotEqual(after[1], before[1], "the split turned")
        assertInsideRegion(after)
    }

    func testANewRegionReplacesTheOldOne() {
        _ = tileTwo()
        let smaller = region.insetBy(dx: 100, dy: 50)
        engine.tileScratchpad([makeWindow(id: 1), makeWindow(id: 2)], screen: screen, in: smaller)
        for (_, r) in engine.intendedTileRects() {
            XCTAssertTrue(smaller.insetBy(dx: -1, dy: -1).contains(r))
        }
    }
}
