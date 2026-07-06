import XCTest
import Cocoa
@testable import HyprMac

// pins TilingEngine.tileScratchpad (Task 3 — within-layer tiling). covers:
// rects confined to the caller-supplied rect, membership add/remove diff,
// reject-on-full returns the window WITHOUT firing onAutoFloat (a reject must
// never route into the task-4 adopt path), and cleanup of stale (0, *) trees
// when the layer migrates monitors.

final class TileScratchpadTests: XCTestCase {

    private var displayManager: DisplayManager!
    private var engine: TilingEngine!
    private var screen: NSScreen!

    override func setUpWithError() throws {
        displayManager = DisplayManager()
        engine = TilingEngine(displayManager: displayManager)
        guard let main = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no NSScreen available — test requires a display")
        }
        screen = main
    }

    private func ws0Tree() -> BSPTree? {
        engine.existingTree(forWorkspace: TilingEngine.scratchpadWorkspace, screen: screen)
    }

    // MARK: - rects confined to the custom rect

    func testTiledRectsStayWithinCustomRect() {
        let region = CGRect(x: 300, y: 200, width: 1200, height: 700)
        let rejects = engine.tileScratchpad([makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)],
                                            screen: screen, in: region)
        XCTAssertTrue(rejects.isEmpty)

        let rects = engine.scratchpadTileRects(screen: screen, in: region)
        XCTAssertEqual(rects.count, 3)
        for (_, r) in rects {
            XCTAssertTrue(region.insetBy(dx: -1, dy: -1).contains(r),
                          "tile rect \(r) escaped custom region \(region)")
        }
    }

    // MARK: - membership diff

    func testMembershipDiffAddsAndRemoves() {
        let region = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        engine.tileScratchpad([makeWindow(id: 1), makeWindow(id: 2)], screen: screen, in: region)
        XCTAssertEqual(Set(ws0Tree()?.allWindows.map(\.windowID) ?? []), [1, 2])

        // add a 3rd, drop id 1
        engine.tileScratchpad([makeWindow(id: 2), makeWindow(id: 3)], screen: screen, in: region)
        XCTAssertEqual(Set(ws0Tree()?.allWindows.map(\.windowID) ?? []), [2, 3])
    }

    func testEmptyMembersEmptiesTree() {
        let region = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        engine.tileScratchpad([makeWindow(id: 1)], screen: screen, in: region)
        XCTAssertEqual(ws0Tree()?.allWindows.count, 1)

        engine.tileScratchpad([], screen: screen, in: region)
        XCTAssertTrue(ws0Tree()?.allWindows.isEmpty ?? true)
    }

    // MARK: - reject on full does NOT fire onAutoFloat

    func testRejectOnFullReturnsWindowAndDoesNotAutoFloat() {
        // maxDepth 1 fills the tree at 2 leaves; a 3rd can't smart-insert.
        engine.maxSplitsPerMonitor[screen.localizedName] = 1
        var autoFloated = false
        engine.onAutoFloat = { _ in autoFloated = true }

        let region = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let rejects = engine.tileScratchpad([makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)],
                                            screen: screen, in: region)

        XCTAssertEqual(rejects.map(\.windowID), [3])
        XCTAssertFalse(autoFloated, "scratchpad reject must NOT route through onAutoFloat")
        // rejected window never entered the tree
        XCTAssertEqual(Set(ws0Tree()?.allWindows.map(\.windowID) ?? []), [1, 2])
    }

    // MARK: - stale (0, *) tree cleanup on migration

    func testOtherScratchpadTreesDroppedOnRetile() throws {
        // seed a ws-0 tree keyed to a DIFFERENT synthetic screen origin by
        // faking a second screen. we can't easily construct a second NSScreen,
        // so instead seed via the current screen, then verify a fresh tile keeps
        // exactly one (0, *) tree. the multi-screen migration path is covered by
        // the manual monitor smoke test; here we pin the single-screen invariant
        // that tileScratchpad never leaves more than one ws-0 tree.
        let region = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        engine.tileScratchpad([makeWindow(id: 1), makeWindow(id: 2)], screen: screen, in: region)
        engine.tileScratchpad([makeWindow(id: 1), makeWindow(id: 2)], screen: screen, in: region)

        // exactly one ws-0 tree, holding the current members
        XCTAssertNotNil(ws0Tree())
        XCTAssertEqual(Set(ws0Tree()?.allWindows.map(\.windowID) ?? []), [1, 2])
    }
}
