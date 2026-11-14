import Cocoa
import XCTest
@testable import HyprMac

// a switch reveals a parked floater from the handle its walk returned, or
// the visible-only window cache. when the floater's app fails the walk (a
// busy browser answering "back to tab" from picture in picture, err -25204)
// neither has it, and the floater used to stay in the hide corner on a
// visible workspace with nothing left to move it. the switch now asks that
// app again every 100 ms for a bounded number of tries and reveals the
// floater when it answers, and asks for a repair poll as the safety net, whose
// reveal repair restores the saved frame.
//
// the fake window's frame writes go to a placeholder AX element, so what a
// test can see of a reveal is the saved frame being consumed.

final class WorkspaceRevealRepairTests: XCTestCase {
    private var screen: RevealScreen!
    private var workspaceManager: WorkspaceManager!
    private var stateCache: WindowStateCache!
    private var orchestrator: WorkspaceOrchestrator!
    private var revealMissed = 0
    /// the next scheduled reveal retry, stepped by hand
    private var retries: [() -> Void] = []
    /// whether the floaters' app answers its window list, and how often it was asked
    private var appAnswers = false
    private var appAsks = 0
    private var parked: [CGWindowID: RevealWindow] = [:]
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
        orchestrator.scheduleRevealRetry = { [unowned self] _, retry in self.retries.append(retry) }
        orchestrator.revealRetryWindows = { [unowned self] ids, _ in
            self.appAsks += 1
            return self.appAnswers ? ids.compactMap { self.parked[$0] } : nil
        }

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
        stateCache.windowOwners[id] = window.ownerPID
        window.isFloating = true
        parked[id] = window
        return window
    }

    /// run the one pending retry; it schedules the next itself
    private func stepRetry(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(retries.count, 1, "one retry pending", file: file, line: line)
        retries.removeFirst()()
    }

    func testAFloaterTheSwitchCannotReadIsRevealedOnceItsAppAnswers() {
        let floater = parkedFloater(id: 7311, on: hidden)
        orchestrator.allWindows = { [] }

        orchestrator.switchWorkspace(hidden)

        XCTAssertEqual(appAsks, 0, "the walk that just failed is not repeated inside the switch")
        stepRetry()
        XCTAssertEqual(appAsks, 1)
        XCTAssertEqual(workspaceManager.savedFloatingFrame(for: floater.windowID), saved, "still busy")

        appAnswers = true
        stepRetry()

        XCTAssertNil(workspaceManager.savedFloatingFrame(for: floater.windowID),
                     "revealed on the first retry its app answered")
        XCTAssertTrue(retries.isEmpty, "nothing left to retry")
    }

    // the app answered its window list a moment ago and may be busy again:
    // every further read of the window costs up to the process-wide 1 s
    // timeout on the main thread, so the retry reads nothing it doesn't need
    func testTheRetryDoesNotReadTheTitleOfTheWindowItReveals() {
        let floater = parkedFloater(id: 7314, on: hidden)
        orchestrator.allWindows = { [] }
        orchestrator.switchWorkspace(hidden)

        appAnswers = true
        stepRetry()

        XCTAssertNil(workspaceManager.savedFloatingFrame(for: floater.windowID))
        XCTAssertEqual(floater.titleReads, 0)
    }

    func testTheRetryIsBoundedAndLeavesTheRestToTheRepairPoll() {
        let floater = parkedFloater(id: 7312, on: hidden)
        orchestrator.allWindows = { [] }

        orchestrator.switchWorkspace(hidden)
        for _ in 0..<WorkspaceOrchestrator.revealRetryAttempts { stepRetry() }

        XCTAssertEqual(appAsks, WorkspaceOrchestrator.revealRetryAttempts)
        XCTAssertTrue(retries.isEmpty, "gave up")
        XCTAssertEqual(revealMissed, 1, "the repair poll was asked for all along")
        XCTAssertEqual(workspaceManager.savedFloatingFrame(for: floater.windowID), saved)
    }

    func testTheRetryDropsAFloaterWhoseWorkspaceWasHiddenAgain() {
        let floater = parkedFloater(id: 7313, on: hidden)
        orchestrator.allWindows = { [] }
        orchestrator.switchWorkspace(hidden)

        // switched back before the app answered: the floater is parked
        // where it belongs again, nothing to reveal
        orchestrator.switchWorkspace(visible)
        appAnswers = true
        stepRetry()

        XCTAssertEqual(appAsks, 0, "its app is not asked")
        XCTAssertTrue(retries.isEmpty)
        XCTAssertEqual(workspaceManager.savedFloatingFrame(for: floater.windowID), saved)
    }

    func testAFloaterTheSwitchCannotReadIsRevealedByTheNextPoll() {
        appAnswers = false
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
        XCTAssertTrue(retries.isEmpty, "no retry for a floater the switch revealed")
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
    var titleReads = 0
    init(id: CGWindowID, frame: CGRect) {
        storedFrame = frame
        super.init(element: AXUIElementCreateApplication(9877), windowID: id, ownerPID: 9877)
    }
    override var title: String? {
        titleReads += 1
        return "reveal"
    }
    override func readPosition() -> (AXError, CGPoint?) { (.success, storedFrame.origin) }
    override func readSize() -> (AXError, CGSize?) { (.success, storedFrame.size) }
    override func writePosition(_ point: CGPoint) -> AXError {
        storedFrame.origin = point
        return .success
    }
}
