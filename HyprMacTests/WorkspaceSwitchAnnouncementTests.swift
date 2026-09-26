import XCTest
import Cocoa
@testable import HyprMac

// pins when WorkspaceOrchestrator announces a switch. the switch HUD hangs off
// onWillSwitch, so the announcement has to leave before the hide/retile/focus
// pass, not after it — off onDidSwitch the panel cannot paint until the main
// thread stops writing AX, which is most of a second on Tahoe. the AX sweep
// is not recorded here, so what these tests can pin is the announcement's
// position among the seams that surround it: after the cursor screen is read,
// before the retile, and with the same screen onDidSwitch will report.
//
// driving a real switch warps the cursor to the middle of the screen, since
// no seeded window is ever visible to AX here. harmless on a test host.

final class WorkspaceSwitchAnnouncementTests: XCTestCase {

    private var displayManager: DisplayManager!
    private var workspaceManager: WorkspaceManager!
    private var orchestrator: WorkspaceOrchestrator!
    private var screen: NSScreen!
    private var events: [String] = []
    private var willScreen: NSScreen?
    private var didScreen: NSScreen?
    private var visible: Int!
    private var hidden: Int!

    override func setUpWithError() throws {
        let dm = DisplayManager()
        guard let primary = dm.screens.first else {
            throw XCTSkip("no NSScreen available — test requires a display")
        }
        screen = primary
        displayManager = dm
        workspaceManager = WorkspaceManager(displayManager: displayManager)
        let focusBorder = FocusBorder()
        orchestrator = WorkspaceOrchestrator(
            workspaceManager: workspaceManager,
            tilingEngine: TilingEngine(displayManager: displayManager),
            accessibility: AccessibilityManager(),
            displayManager: displayManager,
            cursorManager: CursorManager(),
            stateCache: WindowStateCache(),
            focusController: FocusStateController(focusBorder: focusBorder),
            focusBorder: focusBorder,
            dimmingOverlay: DimmingOverlay(),
            suppressions: SuppressionRegistry(),
            revalidation: MinimaRevalidation())
        orchestrator.screenUnderCursor = { [weak self] in
            self?.events.append("cursor-screen")
            return self?.screen ?? NSScreen.main!
        }
        orchestrator.tileAllVisibleSpaces = { [weak self] in self?.events.append("retile") }
        orchestrator.onWillSwitch = { [weak self] workspace, screen in
            self?.events.append("will:\(workspace)")
            self?.willScreen = screen
        }
        orchestrator.onDidSwitch = { [weak self] workspace, screen in
            self?.events.append("did:\(workspace)")
            self?.didScreen = screen
        }

        visible = workspaceManager.workspaceForScreen(screen)
        let others = workspaceManager.workspacesAnchoredTo(screen).filter { $0 != visible }.sorted()
        try XCTSkipIf(others.isEmpty, "needs another workspace anchored to this screen")
        hidden = others[0]
    }

    func testTheSwitchIsAnnouncedBeforeTheRetile() throws {
        orchestrator.switchWorkspace(hidden)

        XCTAssertEqual(events, ["cursor-screen", "will:\(hidden!)", "retile", "did:\(hidden!)"],
                       "the announcement leaves before the pass that hides and retiles")
        XCTAssertTrue(willScreen === workspaceManager.homeScreenForWorkspace(hidden),
                      "the destination's home screen, resolved without reading AX")
        XCTAssertTrue(willScreen === didScreen,
                      "the early announcement names the screen the switch lands on")
    }

    func testSwitchingToTheWorkspaceAlreadyUpStillAnnouncesIt() throws {
        orchestrator.switchWorkspace(visible)

        // pressing the chord for the workspace already showing hides and
        // retiles nothing, but it still announces — the flash is the answer
        // to "which workspace am I on", and it has always answered here.
        XCTAssertEqual(events, ["cursor-screen", "will:\(visible!)", "did:\(visible!)"])
        XCTAssertTrue(willScreen === didScreen)
    }

    func testAWorkspaceOutOfRangeIsAnnouncedOnTheCursorScreen() throws {
        let outOfRange = (Constants.workspaceRange.upperBound + 1)

        orchestrator.switchWorkspace(outOfRange)

        XCTAssertEqual(events.first, "cursor-screen")
        XCTAssertEqual(events.filter { $0.hasPrefix("will:") }, ["will:\(outOfRange)"])
        XCTAssertNil(workspaceManager.homeScreenForWorkspace(outOfRange))
        XCTAssertTrue(willScreen === screen, "no home screen to fall back from, so the cursor's")
        XCTAssertTrue(willScreen === didScreen)
    }
}
