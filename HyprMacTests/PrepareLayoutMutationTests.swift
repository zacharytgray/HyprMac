import XCTest
import Cocoa
@testable import HyprMac

// PrepareLayoutMutationTests pin the post-mutation tree shape and failure-path
// behavior for the three "prepare" methods on TilingEngine. These methods
// intentionally mutate the live BSP tree before returning a layout (animation
// callers need post-mutation geometry to interpolate toward) — the tests pin
// that contract so future refactors don't silently break it.
//
// see plan §4.2 + §8.2.

final class PrepareLayoutMutationTests: XCTestCase {

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

    private func tree() -> BSPTree? {
        engine.existingTree(forWorkspace: 1, screen: screen)
    }

    // MARK: - prepareTileLayout

    func testPrepareTileLayoutAddsMissingWindows() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)

        let layout = engine.prepareTileLayout([w1, w2], onWorkspace: 1, screen: screen)
        XCTAssertEqual(layout.count, 2)
        XCTAssertEqual(Set(tree()?.allWindows.map(\.windowID) ?? []), [1, 2])
    }

    func testPrepareTileLayoutRemovesGoneWindows() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.prepareTileLayout([w1, w2], onWorkspace: 1, screen: screen)
        XCTAssertEqual(tree()?.allWindows.count, 2)

        // call again with only w1 — w2 should be evicted
        engine.prepareTileLayout([w1], onWorkspace: 1, screen: screen)
        XCTAssertEqual(tree()?.allWindows.map(\.windowID), [1])
    }

    func testPrepareTileLayoutResetsNonUserSetRatios() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.prepareTileLayout([w1, w2], onWorkspace: 1, screen: screen)
        // mutate the parent ratio
        tree()?.root.splitRatio = 0.3
        XCTAssertEqual(tree()?.root.splitRatio, 0.3)

        // a fresh prepare with the same windows must reset the ratio.
        // userSetRatio is cleared by prepareTileLayout when there's a structural
        // change; but with no add/remove the flag is preserved. set userSetRatio
        // = false explicitly to confirm reset path.
        tree()?.root.userSetRatio = false
        engine.prepareTileLayout([w1, w2], onWorkspace: 1, screen: screen)
        XCTAssertEqual(tree()?.root.splitRatio, TilingConfig.defaultRatio)
    }

    func testPrepareTileLayoutAutoFloatsWhenInsertFails() {
        // shrink the depth ceiling so a 3rd window fails smartInsertFitting
        engine.maxSplitsPerMonitor[screen.localizedName] = 1

        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        var floated: [HyprWindow] = []
        engine.onAutoFloat = { floated.append($0) }

        engine.prepareTileLayout([w1, w2, w3], onWorkspace: 1, screen: screen)

        // w1 + w2 fill the tree; w3 fails to fit and is reported via onAutoFloat.
        XCTAssertEqual(Set(tree()?.allWindows.map(\.windowID) ?? []), [1, 2])
        XCTAssertEqual(floated.map(\.windowID), [3])
    }

    func testPrepareTileLayoutSkipsFloatingWindows() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        w2.isFloating = true

        let layout = engine.prepareTileLayout([w1, w2], onWorkspace: 1, screen: screen)
        XCTAssertEqual(layout.count, 1)
        XCTAssertEqual(tree()?.allWindows.map(\.windowID), [1])
    }

    // MARK: - prepareSwapLayout

    func testPrepareSwapLayoutSwapsLeafWindows() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.prepareTileLayout([w1, w2], onWorkspace: 1, screen: screen)
        XCTAssertEqual(tree()?.root.left?.window?.windowID, 1)
        XCTAssertEqual(tree()?.root.right?.window?.windowID, 2)

        let result = engine.prepareSwapLayout(w1, w2, onWorkspace: 1, screen: screen)
        XCTAssertNotNil(result)
        XCTAssertEqual(tree()?.root.left?.window?.windowID, 2)
        XCTAssertEqual(tree()?.root.right?.window?.windowID, 1)
    }

    func testPrepareSwapLayoutReturnsNilWhenWindowMissing() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let stranger = makeWindow(id: 99)
        engine.prepareTileLayout([w1, w2], onWorkspace: 1, screen: screen)

        // pre-swap snapshot
        let before = tree()?.allWindows.map(\.windowID) ?? []

        let result = engine.prepareSwapLayout(w1, stranger, onWorkspace: 1, screen: screen)
        XCTAssertNil(result)
        // tree shape unchanged when canSwapWindows fails before swap()
        XCTAssertEqual(tree()?.allWindows.map(\.windowID) ?? [], before)
    }

    func testPrepareSwapLayoutResetsNonUserSetRatios() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.prepareTileLayout([w1, w2], onWorkspace: 1, screen: screen)
        tree()?.root.splitRatio = 0.7
        tree()?.root.userSetRatio = false

        engine.prepareSwapLayout(w1, w2, onWorkspace: 1, screen: screen)
        XCTAssertEqual(tree()?.root.splitRatio, TilingConfig.defaultRatio)
    }

    // MARK: - prepareToggleSplitLayout

    func testPrepareToggleSplitLayoutFlipsParentDirection() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.prepareTileLayout([w1, w2], onWorkspace: 1, screen: screen)
        XCTAssertNil(tree()?.root.splitOverride)

        let layout = engine.prepareToggleSplitLayout(w2, onWorkspace: 1, screen: screen)
        XCTAssertNotNil(layout)
        XCTAssertNotNil(tree()?.root.splitOverride)
    }

    func testPrepareToggleSplitLayoutTwiceRevertsDirection() {
        // pins the mechanism the WindowManager.toggleSplit() fallthrough fix
        // (commit ee9e2df) protects against. two consecutive prepare calls
        // toggle the tree twice and end up at the original direction.
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.prepareTileLayout([w1, w2], onWorkspace: 1, screen: screen)

        engine.prepareToggleSplitLayout(w2, onWorkspace: 1, screen: screen)
        let firstOverride = tree()?.root.splitOverride

        engine.prepareToggleSplitLayout(w2, onWorkspace: 1, screen: screen)
        let secondOverride = tree()?.root.splitOverride

        XCTAssertNotNil(firstOverride)
        XCTAssertNotNil(secondOverride)
        XCTAssertNotEqual(firstOverride, secondOverride)
    }

    func testPrepareToggleSplitLayoutReturnsNilWhenWindowMissing() {
        let w1 = makeWindow(id: 1)
        let stranger = makeWindow(id: 99)
        engine.prepareTileLayout([w1], onWorkspace: 1, screen: screen)
        let beforeOverride = tree()?.root.splitOverride

        let result = engine.prepareToggleSplitLayout(stranger, onWorkspace: 1, screen: screen)
        XCTAssertNil(result)
        // tree state unchanged when window not present
        XCTAssertEqual(tree()?.root.splitOverride, beforeOverride)
    }
}
