import XCTest
import Cocoa
@testable import HyprMac

// pins the tree shape after membership, swap and toggle changes on TilingEngine.

final class EngineTreeMutationTests: XCTestCase {

    private var displayManager: DisplayManager!
    private var engine: TilingEngine!
    private var screen: NSScreen!

    override func setUpWithError() throws {
        displayManager = DisplayManager()
        engine = TilingEngine(displayManager: displayManager,
                              frameSizingIOFactory: acceptingFrameSizingIOFactory())
        guard let main = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no NSScreen available — test requires a display")
        }
        screen = main
    }

    private func tree() -> BSPTree? {
        engine.existingTree(forWorkspace: 1, screen: screen)
    }

    // MARK: - seedTree

    func testSeedTreeAddsMissingWindows() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)

        let layout = engine.seedTree([w1, w2], onWorkspace: 1, screen: screen)
        XCTAssertEqual(layout.count, 2)
        XCTAssertEqual(Set(tree()?.allWindows.map(\.windowID) ?? []), [1, 2])
    }

    func testSeedTreeRemovesGoneWindows() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.seedTree([w1, w2], onWorkspace: 1, screen: screen)
        XCTAssertEqual(tree()?.allWindows.count, 2)

        // call again with only w1 — w2 should be evicted
        engine.seedTree([w1], onWorkspace: 1, screen: screen)
        XCTAssertEqual(tree()?.allWindows.map(\.windowID), [1])
    }

    func testSeedTreeKeepsRatiosUntilTheMembershipChanges() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.seedTree([w1, w2], onWorkspace: 1, screen: screen)
        // mutate the parent ratio
        tree()?.root.splitRatio = 0.3
        XCTAssertEqual(tree()?.root.splitRatio, 0.3)

        // a fresh prepare over the same members keeps the ratio: the last
        // accepted pass found it, and resetting it here probed every known
        // minimum again on every retile
        tree()?.root.userSetRatio = false
        engine.seedTree([w1, w2], onWorkspace: 1, screen: screen)
        XCTAssertEqual(tree()?.root.splitRatio, 0.3)

        // a membership change resets what the user did not set
        engine.seedTree([w1, w2, makeWindow(id: 3)], onWorkspace: 1, screen: screen)
        XCTAssertEqual(tree()?.root.splitRatio, TilingConfig.defaultRatio)
    }

    func testSeedTreeLeavesRefusedWindowUntouched() {
        // shrink the depth ceiling so a 3rd window fails smartInsertFitting
        engine.maxSplitsPerMonitor[screen.localizedName] = 1

        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)

        engine.seedTree([w1, w2, w3], onWorkspace: 1, screen: screen)

        // preparation has no recovery side effects.
        XCTAssertEqual(Set(tree()?.allWindows.map(\.windowID) ?? []), [1, 2])
        XCTAssertFalse(w3.isFloating)
    }

    func testSeedTreeSkipsFloatingWindows() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        w2.isFloating = true

        let layout = engine.seedTree([w1, w2], onWorkspace: 1, screen: screen)
        XCTAssertEqual(layout.count, 1)
        XCTAssertEqual(tree()?.allWindows.map(\.windowID), [1])
    }

    // MARK: - swapWindows

    func testSwapWindowsSwapsLeafWindows() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.seedTree([w1, w2], onWorkspace: 1, screen: screen)
        XCTAssertEqual(tree()?.root.left?.window?.windowID, 1)
        XCTAssertEqual(tree()?.root.right?.window?.windowID, 2)

        XCTAssertTrue(engine.swapWindows(w1, w2, onWorkspace: 1, screen: screen))
        XCTAssertEqual(tree()?.root.left?.window?.windowID, 2)
        XCTAssertEqual(tree()?.root.right?.window?.windowID, 1)
    }

    func testSwapWindowsRefusesAWindowNotInTheTree() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let stranger = makeWindow(id: 99)
        engine.seedTree([w1, w2], onWorkspace: 1, screen: screen)
        let before = tree()?.allWindows.map(\.windowID) ?? []

        XCTAssertFalse(engine.swapWindows(w1, stranger, onWorkspace: 1, screen: screen))
        XCTAssertEqual(tree()?.allWindows.map(\.windowID) ?? [], before)
    }

    // MARK: - toggleSplit

    func testToggleSplitFlipsParentDirection() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.seedTree([w1, w2], onWorkspace: 1, screen: screen)
        // the split is pinned to the axis smart insert chose
        let pinned = tree()?.root.splitOverride
        XCTAssertNotNil(pinned)
        XCTAssertEqual(tree()?.root.splitOverrideIsAutomatic, true)

        engine.toggleSplit(w2, onWorkspace: 1, screen: screen)
        XCTAssertNotNil(tree()?.root.splitOverride)
        XCTAssertNotEqual(tree()?.root.splitOverride, pinned)
        XCTAssertEqual(tree()?.root.splitOverrideIsAutomatic, false, "togglesplit is the user's")
    }

    func testToggleSplitTwiceRevertsDirection() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.seedTree([w1, w2], onWorkspace: 1, screen: screen)
        let original = tree()?.root.splitOverride

        engine.toggleSplit(w2, onWorkspace: 1, screen: screen)
        let toggled = tree()?.root.splitOverride
        engine.toggleSplit(w2, onWorkspace: 1, screen: screen)

        XCTAssertNotEqual(toggled, original)
        XCTAssertEqual(tree()?.root.splitOverride, original)
    }

    func testToggleSplitIgnoresAWindowNotInTheTree() {
        let w1 = makeWindow(id: 1)
        let stranger = makeWindow(id: 99)
        engine.seedTree([w1], onWorkspace: 1, screen: screen)
        let beforeOverride = tree()?.root.splitOverride

        engine.toggleSplit(stranger, onWorkspace: 1, screen: screen)
        XCTAssertEqual(tree()?.root.splitOverride, beforeOverride)
    }
}
