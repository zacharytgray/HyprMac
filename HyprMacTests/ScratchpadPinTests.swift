import Cocoa
import XCTest
@testable import HyprMac

// an app pinned to the scratchpad: its open windows park in the layer with the
// layer down. bringing the layer up needs live AX, so that half is checked live.

private final class PinScreen: NSScreen {
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 2400, height: 1600) }
    override var visibleFrame: NSRect { frame }
    override var localizedName: String { "Pin" }
}

private final class PinWindow: HyprWindow {
    init(id: CGWindowID) {
        let pid = pid_t(96000 + Int(id))
        super.init(element: AXUIElementCreateApplication(pid), windowID: id, ownerPID: pid)
    }

    override var frame: CGRect? { CGRect(x: 100, y: 100, width: 800, height: 600) }
}

final class ScratchpadPinTests: XCTestCase {
    private var screen: PinScreen!
    private var workspaces: WorkspaceManager!
    private var cache: WindowStateCache!
    private var engine: TilingEngine!
    private var scratchpad: ScratchpadController!

    override func setUp() {
        super.setUp()
        let screen = PinScreen()
        self.screen = screen
        let display = DisplayManager(screenSource: { [screen] })
        workspaces = WorkspaceManager(displayManager: display)
        workspaces.initializeMonitors()
        cache = WindowStateCache()
        engine = TilingEngine(displayManager: display)
        let border = FocusBorder()
        scratchpad = ScratchpadController(
            workspaceManager: workspaces, stateCache: cache, accessibility: AccessibilityManager(),
            displayManager: display, tilingEngine: engine,
            focusController: FocusStateController(focusBorder: border), focusBorder: border,
            suppressions: SuppressionRegistry())
    }

    func testAnOpenTiledWindowLeavesItsTreeAndParksAsATiledMember() {
        let window = PinWindow(id: 1), other = PinWindow(id: 2)
        let workspace = workspaces.workspaceForScreen(screen)
        workspaces.assignWindow(window.windowID, toWorkspace: workspace)
        workspaces.assignWindow(other.windowID, toWorkspace: workspace)
        engine.seedTree([window, other], onWorkspace: workspace, screen: screen)

        scratchpad.adoptPinned(window, summon: false)

        XCTAssertEqual(workspaces.workspaceFor(window.windowID), ScratchpadController.workspace)
        XCTAssertTrue(scratchpad.contains(window.windowID))
        XCTAssertFalse(scratchpad.isVisible)
        XCTAssertFalse(cache.floatingWindowIDs.contains(window.windowID))
        XCTAssertEqual(engine.windowIDs(inTreeForWorkspace: workspace, screen: screen), [other.windowID])
        XCTAssertNotNil(workspaces.savedFloatingFrame(for: window.windowID))
    }

    func testANeverTileAppParksAsAFloatingMember() {
        let window = PinWindow(id: 3)
        scratchpad.isNeverTile = { _ in true }
        scratchpad.adoptPinned(window, summon: false)
        XCTAssertTrue(scratchpad.contains(window.windowID))
        XCTAssertTrue(cache.floatingWindowIDs.contains(window.windowID))
    }

    func testAnExistingMemberIsLeftAlone() {
        let window = PinWindow(id: 4)
        cache.setFloating(true, window: window)
        workspaces.assignWindow(window.windowID, toWorkspace: ScratchpadController.workspace)
        scratchpad.tileNewMembers = true
        scratchpad.adoptPinned(window, summon: false)
        XCTAssertTrue(cache.floatingWindowIDs.contains(window.windowID), "a floating member stays floating")
    }
}
