import XCTest
import Cocoa
@testable import HyprMac

// HandleDisplayChangeTests cover the orphan-and-prune path of
// TilingEngine.handleDisplayChange. the migration path requires multiple live
// NSScreen instances and isn't exercised here — it's covered by the manual
// monitor-disconnect smoke test until we have a fake-display harness.
//
// see plan §4.2 (display lifecycle) + §11.

final class HandleDisplayChangeTests: XCTestCase {

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

    func testHandleDisplayChangePrunesOrphanedTrees() {
        // seed a tree
        engine.prepareTileLayout([makeWindow(id: 1), makeWindow(id: 2)],
                                 onWorkspace: 1, screen: screen)
        XCTAssertNotNil(engine.existingTree(forWorkspace: 1, screen: screen))

        // simulate the screen vanishing with no home-screen destination
        engine.handleDisplayChange(currentScreens: [], homeScreenForWorkspace: { _ in nil })

        // tree should be pruned
        XCTAssertNil(engine.existingTree(forWorkspace: 1, screen: screen))
    }

    func testHandleDisplayChangeIsNoopWhenAllScreensCurrent() {
        engine.prepareTileLayout([makeWindow(id: 1), makeWindow(id: 2)],
                                 onWorkspace: 1, screen: screen)
        let tree = engine.existingTree(forWorkspace: 1, screen: screen)
        XCTAssertNotNil(tree)
        let countBefore = tree?.allWindows.count

        engine.handleDisplayChange(currentScreens: [screen], homeScreenForWorkspace: { _ in nil })

        // tree untouched — no key vanished
        XCTAssertNotNil(engine.existingTree(forWorkspace: 1, screen: screen))
        XCTAssertEqual(engine.existingTree(forWorkspace: 1, screen: screen)?.allWindows.count, countBefore)
    }
}
