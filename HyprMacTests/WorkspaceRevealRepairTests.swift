import Cocoa
import XCTest
@testable import HyprMac

// a switch reveals a parked floater from the handle its walk returned, or
// the visible-only window cache. when the floater's app fails the walk (a
// busy browser answering "back to tab" from picture in picture, err -25204)
// neither has it, and the floater used to stay in the hide corner on a
// visible workspace with nothing left to move it. the switch now asks for a
// repair poll, and the poll's reveal repair restores the saved frame.
//
// the fake window's frame writes go to a placeholder AX element, so what a
// test can see of a reveal is the saved frame being consumed.

final class WorkspaceRevealRepairTests: XCTestCase {
    private var screen: RevealScreen!
    private var workspaceManager: WorkspaceManager!
    private var stateCache: WindowStateCache!
    private var orchestrator: WorkspaceOrchestrator!
    private var revealMissed = 0
    private var visible: Int!
    private var hidden: Int!
    private let saved = CGRect(x: 100, y: 120, width: 600, height: 400)

    override func setUpWithError() throws {
        let screen = RevealScreen()
        self.screen = screen
        let display = DisplayManager(screenSource: { [screen] })
        workspaceManager = WorkspaceManager(displayManager: display)
        workspaceManager.initializeMonitors()
        stateCache = WindowStateCache()
        let border = FocusBorder()
        orchestrator = WorkspaceOrchestrator(
            workspaceManager: workspaceManager, tilingEngine: TilingEngine(displayManager: display),
            accessibility: AccessibilityManager(), displayManager: display,
            cursorManager: CursorManager(), stateCache: stateCache,
            focusController: FocusStateController(focusBorder: border), focusBorder: border,
            dimmingOverlay: DimmingOverlay(), suppressions: SuppressionRegistry(),
            revalidation: MinimaRevalidation())
        orchestrator.screenUnderCursor = { [unowned self] in self.screen }
        orchestrator.onRevealMissed = { [unowned self] in self.revealMissed += 1 }

        visible = workspaceManager.workspaceForScreen(screen)
        let others = workspaceManager.workspacesAnchoredTo(screen).filter { $0 != visible }.sorted()
        try XCTSkipIf(others.isEmpty, "needs another workspace anchored to this screen")
        hidden = others[0]
    }

    /// a floater parked on `workspace` with the frame its reveal restores
    private func parkedFloater(id: CGWindowID, on workspace: Int) -> RevealWindow {
        let window = RevealWindow(id: id, frame: CGRect(origin: workspaceManager.hidePosition(),
                                                       size: saved.size))
        workspaceManager.assignWindow(id, toWorkspace: workspace)
        workspaceManager.setSavedFloatingFrame(saved, for: id)
        stateCache.floatingWindowIDs.insert(id)
        window.isFloating = true
        return window
    }

    func testAFloaterTheSwitchCannotReadIsRevealedByTheNextPoll() {
        let floater = parkedFloater(id: 7301, on: hidden)
        // the app failed the switch's walk, and the cache holds only
        // windows that were visible, so the switch has no handle for it
        orchestrator.allWindows = { [] }

        orchestrator.switchWorkspace(hidden)

        XCTAssertEqual(revealMissed, 1, "the missed reveal asks for a repair poll")
        XCTAssertEqual(workspaceManager.savedFloatingFrame(for: floater.windowID), saved,
                       "nothing revealed it: still parked, saved frame kept")

        // the poll after the app answers again sees it
        orchestrator.repairUnrevealedFloaters([floater])

        XCTAssertNil(workspaceManager.savedFloatingFrame(for: floater.windowID),
                     "the reveal repair restored the saved frame")
    }

    func testAFloaterTheSwitchCanReadIsRevealedWithoutARepairPoll() {
        let floater = parkedFloater(id: 7302, on: hidden)
        orchestrator.allWindows = { [floater] }

        orchestrator.switchWorkspace(hidden)

        XCTAssertEqual(revealMissed, 0)
        XCTAssertNil(workspaceManager.savedFloatingFrame(for: floater.windowID))
    }

    func testTheRepairLeavesAFloaterThatReadsOnScreenAlone() {
        let floater = parkedFloater(id: 7303, on: visible)
        // the user has since moved it: the saved frame is stale
        floater.storedFrame = CGRect(x: 400, y: 300, width: 600, height: 400)

        orchestrator.repairUnrevealedFloaters([floater])

        XCTAssertEqual(workspaceManager.savedFloatingFrame(for: floater.windowID), saved)
    }

    func testTheRepairLeavesAFloaterOnAHiddenWorkspaceParked() {
        let floater = parkedFloater(id: 7304, on: hidden)

        orchestrator.repairUnrevealedFloaters([floater])

        XCTAssertEqual(workspaceManager.savedFloatingFrame(for: floater.windowID), saved)
    }
}

private final class RevealScreen: SyntheticScreen {
    override var frame: NSRect { CGRect(x: 0, y: 0, width: 1600, height: 1000) }
    override var visibleFrame: NSRect { frame }
}

private final class RevealWindow: HyprWindow {
    var storedFrame: CGRect
    init(id: CGWindowID, frame: CGRect) {
        storedFrame = frame
        super.init(element: AXUIElementCreateApplication(9877), windowID: id, ownerPID: 9877)
    }
    override func readPosition() -> (AXError, CGPoint?) { (.success, storedFrame.origin) }
    override func readSize() -> (AXError, CGSize?) { (.success, storedFrame.size) }
    override func writePosition(_ point: CGPoint) -> AXError {
        storedFrame.origin = point
        return .success
    }
}
