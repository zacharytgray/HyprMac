import XCTest
import Cocoa
@testable import HyprMac

// RatioMemoryTests drives the tree directly. These go through
// prepareTileLayout instead, so updateTreeMembership runs for real:
// removals, smart insert, and both reset passes in the order the poll
// loop actually hits them.

final class RatioMemoryEngineTests: XCTestCase {

    private var displayManager: DisplayManager!
    private var engine: TilingEngine!
    private var screen: NSScreen!

    override func setUpWithError() throws {
        displayManager = DisplayManager()
        engine = TilingEngine(displayManager: displayManager)
        guard let main = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no NSScreen available, test requires a display")
        }
        screen = main
    }

    private func tree() -> BSPTree? {
        engine.existingTree(forWorkspace: 1, screen: screen)
    }

    private func tileTwoWithUserRatio(_ ratio: CGFloat) -> (HyprWindow, HyprWindow) {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.prepareTileLayout([w1, w2], onWorkspace: 1, screen: screen)
        tree()?.root.splitRatio = ratio
        tree()?.root.userSetRatio = true
        return (w1, w2)
    }

    // MARK: - one pass: the tab switch case

    func testTabSwitchInOnePassKeepsRatioAndSide() {
        let (w1, _) = tileTwoWithUserRatio(0.7)
        let w3 = makeWindow(id: 3)

        // native tab switch: w2 goes and w3 arrives in the same poll
        engine.prepareTileLayout([w1, w3], onWorkspace: 1, screen: screen)

        XCTAssertEqual(tree()?.root.splitRatio ?? 0, 0.7, accuracy: 0.001)
        XCTAssertEqual(tree()?.root.userSetRatio, true)
        XCTAssertEqual(tree()?.root.left?.window?.windowID, 1)
        XCTAssertEqual(tree()?.root.right?.window?.windowID, 3,
                       "w3 takes the slot w2 vacated")
    }

    func testTabSwitchOnTheLeftSlotPutsTheNewWindowOnTheLeft() {
        let (_, w2) = tileTwoWithUserRatio(0.7)
        let w3 = makeWindow(id: 3)

        // this time the left window leaves
        engine.prepareTileLayout([w2, w3], onWorkspace: 1, screen: screen)

        XCTAssertEqual(tree()?.root.splitRatio ?? 0, 0.7, accuracy: 0.001)
        XCTAssertEqual(tree()?.root.left?.window?.windowID, 3,
                       "w3 takes the vacated left slot")
        XCTAssertEqual(tree()?.root.right?.window?.windowID, 2)
    }

    // MARK: - two passes: Cmd-H, then unhide seconds later

    func testRatioSurvivesAnInterveningNoOpPass() {
        let (w1, _) = tileTwoWithUserRatio(0.7)

        // Cmd-H: w2 disappears on its own poll
        engine.prepareTileLayout([w1], onWorkspace: 1, screen: screen)
        XCTAssertEqual(tree()?.root.window?.windowID, 1)
        XCTAssertEqual(tree()?.root.savedSplitRatio ?? 0, 0.7, accuracy: 0.001,
                       "the promoted leaf remembers the boundary across polls")

        // a poll where nothing changed
        engine.prepareTileLayout([w1], onWorkspace: 1, screen: screen)

        // unhide, or any window landing in that slot
        let w3 = makeWindow(id: 3)
        engine.prepareTileLayout([w1, w3], onWorkspace: 1, screen: screen)

        XCTAssertEqual(tree()?.root.splitRatio ?? 0, 0.7, accuracy: 0.001)
        XCTAssertEqual(tree()?.root.userSetRatio, true)
        XCTAssertEqual(tree()?.root.right?.window?.windowID, 3)
    }

    // MARK: - transient ratios stay transient

    func testFudgedRatioIsNotRememberedThroughTheEngine() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.prepareTileLayout([w1, w2], onWorkspace: 1, screen: screen)

        // stand in for a min-size adjustment: ratio moved, flag untouched
        tree()?.root.splitRatio = 0.8
        XCTAssertEqual(tree()?.root.userSetRatio, false)

        let w3 = makeWindow(id: 3)
        engine.prepareTileLayout([w1, w3], onWorkspace: 1, screen: screen)

        XCTAssertEqual(tree()?.root.splitRatio ?? 0, TilingConfig.defaultRatio, accuracy: 0.001,
                       "0.8 was a fudge, not a resize")
        XCTAssertEqual(tree()?.root.userSetRatio, false,
                       "and it must not come back pinned")
    }
}
