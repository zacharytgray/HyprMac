import XCTest
import Cocoa
@testable import HyprMac

final class RatioMemoryTests: XCTestCase {

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

    // MARK: - save and restore round-trip

    func testRatioRestoredAfterRemoveAndReinsert() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)

        let tree = engine.existingTree(forWorkspace: 1, screen: screen)!
        tree.root.splitRatio = 0.7
        tree.root.userSetRatio = true

        // remove window b — its ratio should be remembered
        engine.removeWindowID(b.windowID)
        XCTAssertEqual(tree.allWindows.count, 1)

        // re-add b — ratio should restore
        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)
        let tree2 = engine.existingTree(forWorkspace: 1, screen: screen)!
        XCTAssertEqual(tree2.root.splitRatio, 0.7, accuracy: 0.001,
                       "saved ratio should be restored after re-insert")
        XCTAssertTrue(tree2.root.userSetRatio)
    }

    // MARK: - default ratio is not saved

    func testDefaultRatioNotSaved() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)

        // leave ratio at default 0.5, userSetRatio = false
        let tree = engine.existingTree(forWorkspace: 1, screen: screen)!
        XCTAssertEqual(tree.root.splitRatio, 0.5, accuracy: 0.001)
        XCTAssertFalse(tree.root.userSetRatio)

        engine.removeWindowID(b.windowID)
        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)

        let tree2 = engine.existingTree(forWorkspace: 1, screen: screen)!
        // ratio should stay at default — nothing was saved
        XCTAssertEqual(tree2.root.splitRatio, 0.5, accuracy: 0.001)
    }

    // MARK: - forgetSavedRatio

    func testForgetSavedRatioPreventsRestore() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)

        let tree = engine.existingTree(forWorkspace: 1, screen: screen)!
        tree.root.splitRatio = 0.7
        tree.root.userSetRatio = true

        engine.removeWindowID(b.windowID)
        engine.forgetSavedRatio(windowID: b.windowID)

        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)
        let tree2 = engine.existingTree(forWorkspace: 1, screen: screen)!
        XCTAssertEqual(tree2.root.splitRatio, 0.5, accuracy: 0.001,
                       "forgotten ratio should not restore — should reset to default")
    }

    // MARK: - ratio re-saved on each removal

    func testRatioReSavedOnSubsequentRemoval() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)

        let tree = engine.existingTree(forWorkspace: 1, screen: screen)!
        tree.root.splitRatio = 0.65
        tree.root.userSetRatio = true

        engine.removeWindowID(b.windowID)

        // first re-insert restores 0.65
        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)
        let tree2 = engine.existingTree(forWorkspace: 1, screen: screen)!
        XCTAssertEqual(tree2.root.splitRatio, 0.65, accuracy: 0.001)

        // remove again — the restored ratio (0.65, userSetRatio=true) is
        // re-saved, so the next insert also gets 0.65
        engine.removeWindowID(b.windowID)
        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)
        let tree3 = engine.existingTree(forWorkspace: 1, screen: screen)!
        XCTAssertEqual(tree3.root.splitRatio, 0.65, accuracy: 0.001,
                       "ratio should be re-saved on each removal — survives multiple cycles")
    }

    // MARK: - userSetRatio at default is still saved

    func testUserSetRatioAtDefaultIsSaved() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)

        let tree = engine.existingTree(forWorkspace: 1, screen: screen)!
        // user manually set to 0.5 (same as default but flagged)
        tree.root.splitRatio = 0.5
        tree.root.userSetRatio = true

        engine.removeWindowID(b.windowID)
        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)

        let tree2 = engine.existingTree(forWorkspace: 1, screen: screen)!
        XCTAssertTrue(tree2.root.userSetRatio,
                      "userSetRatio flag should survive save/restore even at default ratio")
    }
}
