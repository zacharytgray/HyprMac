import Cocoa
import XCTest
@testable import HyprMac

final class NextEmptyWorkspaceTests: XCTestCase {
    func testSelectionStaysAnchoredAndWrapsPastOccupiedWorkspaces() {
        let left = TransferScreen(x: 0)
        let right = TransferScreen(x: 2000)
        let manager = WorkspaceManager(displayManager: DisplayManager(screenSource: { [left, right] }))
        manager.initializeMonitors()
        // left owns 1,3,5,7,9; reserve 3 and 5, so 7 is next after 1.
        manager.assignWindow(31, toWorkspace: 3)
        manager.assignWindow(51, toWorkspace: 5)
        XCTAssertEqual(manager.nextEmptyWorkspace(after: 1, on: left), 7)
        manager.assignWindow(71, toWorkspace: 7)
        manager.assignWindow(91, toWorkspace: 9)
        XCTAssertNil(manager.nextEmptyWorkspace(after: 1, on: left))
        _ = manager.switchWorkspace(10, cursorScreen: right)
        XCTAssertEqual(manager.nextEmptyWorkspace(after: 10, on: right), 2)
    }

    func testAnyAssignmentReservesDestination() {
        let screen = TransferScreen(x: 0)
        let manager = WorkspaceManager(displayManager: DisplayManager(screenSource: { [screen] }))
        manager.initializeMonitors()
        for workspace in 2..<Constants.workspaceCount {
            manager.assignWindow(CGWindowID(100 + workspace), toWorkspace: workspace)
        }
        XCTAssertEqual(manager.nextEmptyWorkspace(after: 1, on: screen), Constants.workspaceCount)
        manager.assignWindow(999, toWorkspace: Constants.workspaceCount)
        XCTAssertNil(manager.nextEmptyWorkspace(after: 1, on: screen))
    }

    func testCleanSingleDisplaySelectsWorkspaceTwo() {
        let screen = TransferScreen(x: 0)
        let manager = WorkspaceManager(displayManager: DisplayManager(screenSource: { [screen] }))
        manager.initializeMonitors()
        manager.assignWindow(11, toWorkspace: 1)
        XCTAssertEqual(manager.workspacesAnchoredTo(screen), Array(1...Constants.workspaceCount))
        XCTAssertEqual(manager.nextEmptyWorkspace(after: 1, on: screen), 2)
    }

    // disconnecting a display in the same process must re-anchor every
    // workspace to the survivor, not keep the old two-display stride.
    func testDisconnectToSingleDisplayReanchorsWithoutRestart() {
        let left = TransferScreen(x: -1600)
        let primary = TransferScreen(x: 0)
        let builtIn = TransferScreen(x: 0, width: 1512, height: 945)
        var provided = [left, primary]
        let display = DisplayManager(screenSource: { provided })
        let manager = WorkspaceManager(displayManager: display)
        manager.initializeMonitors()
        XCTAssertEqual(manager.nextEmptyWorkspace(after: 1, on: left), 3)

        provided = [builtIn]
        display.refresh()
        manager.initializeMonitors()
        _ = manager.switchWorkspace(1, cursorScreen: builtIn)

        XCTAssertEqual(manager.workspacesAnchoredTo(builtIn), Array(1...Constants.workspaceCount))
        XCTAssertEqual(manager.nextEmptyWorkspace(after: 1, on: builtIn), 2)
    }

    func testClosedGhostsDoNotReserveButLiveWindowsStillDo() {
        let screen = TransferScreen(x: 0)
        let manager = WorkspaceManager(displayManager: DisplayManager(screenSource: { [screen] }))
        manager.initializeMonitors()
        manager.assignWindow(21, toWorkspace: 2)
        manager.assignWindow(22, toWorkspace: 2)
        XCTAssertEqual(manager.nextEmptyWorkspace(after: 1, on: screen, ignoring: [21, 22]), 2)
        XCTAssertEqual(manager.nextEmptyWorkspace(after: 1, on: screen, ignoring: [21]), 3)
        XCTAssertEqual(manager.nextEmptyWorkspace(after: 1, on: screen), 3)
    }
}

final class SoleWindowTransferEngineTests: XCTestCase {
    func testStagePublishesDestinationWithoutTouchingSourceTree() throws {
        let screen = TransferScreen(x: 0)
        let display = DisplayManager(screenSource: { [screen] })
        let trace = TransferFrameTrace()
        let engine = TilingEngine(displayManager: display,
                                  frameSizingIOFactory: { _, generation in trace.io(generation) })
        let mover = makeWindow(id: 4101)
        let sibling = makeWindow(id: 4102)
        trace.frames[mover.windowID] = CGRect(x: 20, y: 20, width: 500, height: 500)
        trace.frames[sibling.windowID] = CGRect(x: 540, y: 20, width: 500, height: 500)
        engine.prepareTileLayout([mover, sibling], onWorkspace: 1, screen: screen)

        let result = engine.prepareSoleWindowTransfer(
            mover, sourceWindows: [mover, sibling], fromWorkspace: 1,
            toWorkspace: 2, screen: screen,
            restorationReach: display.cgRect(for: screen))

        guard case .prepared(let prepared) = result else { return XCTFail("expected prepared transfer") }
        XCTAssertEqual(Set(engine.existingTree(forWorkspace: 1, screen: screen)!.allWindows.map(\.windowID)),
                       [mover.windowID, sibling.windowID])
        XCTAssertNil(engine.existingTree(forWorkspace: 2, screen: screen))
        XCTAssertTrue(engine.commitPreparedSoleWindowTransfer(prepared))
        XCTAssertEqual(Set(engine.existingTree(forWorkspace: 2, screen: screen)!.allWindows.map(\.windowID)),
                       [mover.windowID])

        engine.removeWindowMembershipOnly(mover, fromWorkspace: 1)
        XCTAssertEqual(engine.existingTree(forWorkspace: 1, screen: screen)?.allWindows.map(\.windowID),
                       [sibling.windowID])
    }

    func testRejectedStageRestoresMoverAndPublishesNoDestination() {
        let screen = TransferScreen(x: 0)
        let display = DisplayManager(screenSource: { [screen] })
        let trace = TransferFrameTrace()
        trace.rejectNextCandidate = true
        let engine = TilingEngine(displayManager: display,
                                  frameSizingIOFactory: { _, generation in trace.io(generation) })
        let mover = makeWindow(id: 4201)
        let original = CGRect(x: 40, y: 50, width: 420, height: 320)
        trace.frames[mover.windowID] = original
        trace.originalPositions[mover.windowID] = original.origin

        let result = engine.prepareSoleWindowTransfer(
            mover, sourceWindows: [mover], fromWorkspace: 1,
            toWorkspace: 2, screen: screen,
            restorationReach: display.cgRect(for: screen))

        if case .prepared = result { XCTFail("failed layout must not stage") }
        XCTAssertNil(engine.existingTree(forWorkspace: 2, screen: screen))
        XCTAssertEqual(trace.frames[mover.windowID], original)
    }

    func testCaptureFailureMutatesNoTreeOrFrame() {
        let screen = TransferScreen(x: 0)
        let display = DisplayManager(screenSource: { [screen] })
        let trace = TransferFrameTrace()
        trace.failReads = true
        let engine = TilingEngine(displayManager: display,
                                  frameSizingIOFactory: { _, generation in trace.io(generation) })
        let mover = makeWindow(id: 4251)
        let original = CGRect(x: 40, y: 50, width: 420, height: 320)
        trace.frames[mover.windowID] = original

        let result = engine.prepareSoleWindowTransfer(
            mover, sourceWindows: [mover], fromWorkspace: 1,
            toWorkspace: 2, screen: screen,
            restorationReach: display.cgRect(for: screen))

        guard case .refusedRestored = result else {
            return XCTFail("capture failure must refuse without mutation")
        }
        XCTAssertNil(engine.existingTree(forWorkspace: 2, screen: screen))
        XCTAssertEqual(trace.frames[mover.windowID], original)
    }

    func testSupersededPreparationNeverPublishesDestination() {
        let screen = TransferScreen(x: 0)
        let display = DisplayManager(screenSource: { [screen] })
        let trace = TransferFrameTrace()
        var engine: TilingEngine!
        engine = TilingEngine(displayManager: display,
                              frameSizingIOFactory: { _, generation in trace.io(generation) })
        let mover = makeWindow(id: 4261)
        trace.frames[mover.windowID] = CGRect(x: 40, y: 50, width: 420, height: 320)
        trace.onWritePosition = { _ in
            trace.onWritePosition = nil
            _ = engine.beginLayoutGeneration()
        }

        let result = engine.prepareSoleWindowTransfer(
            mover, sourceWindows: [mover], fromWorkspace: 1,
            toWorkspace: 2, screen: screen,
            restorationReach: display.cgRect(for: screen))

        guard case .degraded(.superseded) = result else {
            return XCTFail("generation change must supersede preparation")
        }
        XCTAssertNil(engine.existingTree(forWorkspace: 2, screen: screen))
    }
}

final class FullscreenWorkspaceOrchestratorTests: XCTestCase {
    func testSoleAssignedWindowIsAlreadyDedicatedAndDoesNothing() {
        let screen = TransferScreen(x: 0)
        let display = DisplayManager(screenSource: { [screen] })
        let manager = WorkspaceManager(displayManager: display)
        manager.initializeMonitors()
        let state = WindowStateCache()
        let mover = TransferWindow(id: 4291, frame: CGRect(x: 80, y: 90, width: 600, height: 500))
        let source = manager.workspaceForScreen(screen)
        manager.assignWindow(mover.windowID, toWorkspace: source)
        state.cachedWindows[mover.windowID] = mover
        state.floatingWindowIDs.insert(mover.windowID)
        mover.isFloating = true
        let engine = TilingEngine(displayManager: display)
        let border = FocusBorder()
        let orchestrator = WorkspaceOrchestrator(
            workspaceManager: manager, tilingEngine: engine,
            accessibility: AccessibilityManager(), displayManager: display,
            cursorManager: CursorManager(), stateCache: state,
            focusController: FocusStateController(focusBorder: border), focusBorder: border,
            dimmingOverlay: DimmingOverlay(), suppressions: SuppressionRegistry(),
            revalidation: MinimaRevalidation())
        orchestrator.actualFocusedWindow = { mover }
        orchestrator.transferRejected = { _, _ in XCTFail("sole-window no-op must not reject") }
        var focused = false
        orchestrator.focusTransferredWindow = { _ in focused = true }

        orchestrator.moveToNextEmptyWorkspace()

        XCTAssertEqual(manager.workspaceFor(mover.windowID), source)
        XCTAssertEqual(manager.workspaceForScreen(screen), source)
        XCTAssertTrue(state.floatingWindowIDs.contains(mover.windowID))
        XCTAssertFalse(focused)
        XCTAssertNil(engine.existingTree(forWorkspace: 2, screen: screen))
    }

    func testFocusedFloaterMovesAndSwitchesOnlyAfterVerifiedPreparation() throws {
        let screen = TransferScreen(x: 0)
        let cursorScreen = TransferScreen(x: 2000)
        let display = DisplayManager(screenSource: { [screen, cursorScreen] })
        let manager = WorkspaceManager(displayManager: display)
        manager.initializeMonitors()
        let state = WindowStateCache()
        let mover = TransferWindow(id: 4301, frame: CGRect(x: 80, y: 90, width: 600, height: 500))
        let sibling = TransferWindow(id: 4302, frame: CGRect(x: 700, y: 90, width: 600, height: 500))
        sibling.parkingYOffset = -63
        let source = manager.workspaceForScreen(screen)
        let destination = try XCTUnwrap(manager.nextEmptyWorkspace(after: source, on: screen))
        for window in [mover, sibling] {
            manager.assignWindow(window.windowID, toWorkspace: source)
            state.cachedWindows[window.windowID] = window
        }
        state.floatingWindowIDs.insert(mover.windowID)
        mover.isFloating = true
        let engine = TilingEngine(displayManager: display)
        engine.prepareTileLayout([sibling], onWorkspace: source, screen: screen)
        let border = FocusBorder()
        let orchestrator = WorkspaceOrchestrator(
            workspaceManager: manager, tilingEngine: engine,
            accessibility: AccessibilityManager(), displayManager: display,
            cursorManager: CursorManager(), stateCache: state,
            focusController: FocusStateController(focusBorder: border), focusBorder: border,
            dimmingOverlay: DimmingOverlay(), suppressions: SuppressionRegistry(),
            revalidation: MinimaRevalidation())
        orchestrator.actualFocusedWindow = { mover }
        orchestrator.screenUnderCursor = { cursorScreen }
        orchestrator.allWindows = { [mover, sibling] }
        orchestrator.focusTransferredWindow = { _ in }
        orchestrator.warpToWindow = { _ in }
        orchestrator.updateFocusBorder = { _ in }
        orchestrator.updatePositionCache = { }
        orchestrator.transferRejected = { _, _ in XCTFail("unexpected rejection") }

        orchestrator.moveToNextEmptyWorkspace()

        XCTAssertEqual(manager.workspaceFor(mover.windowID), destination)
        XCTAssertEqual(manager.workspaceForScreen(screen), destination)
        XCTAssertFalse(state.floatingWindowIDs.contains(mover.windowID))
        XCTAssertEqual(engine.existingTree(forWorkspace: destination, screen: screen)?.allWindows.map(\.windowID),
                       [mover.windowID])
        XCTAssertEqual(state.originalFrames[mover.windowID], CGRect(x: 80, y: 90, width: 600, height: 500))
        XCTAssertEqual(sibling.sizeWriteCount, 0, "parking must be position-only")
        XCTAssertEqual(sibling.testFrame.origin.y, display.cgFullRect(for: cursorScreen).maxY - 1 - 63)
    }

    func testParkingPredicateAcceptsClampedSliverAndRejectsVisibleWindow() {
        let display = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        XCTAssertTrue(TilingEngine.isHiddenParkedFrame(
            CGRect(x: 1599, y: 930, width: 600, height: 500), on: [display]))
        XCTAssertFalse(TilingEngine.isHiddenParkedFrame(
            CGRect(x: 1500, y: 930, width: 600, height: 500), on: [display]))
    }

    func testParkingFailureRestoresFramesAndLeavesOwnershipUntouched() throws {
        let screen = TransferScreen(x: 0)
        let display = DisplayManager(screenSource: { [screen] })
        let manager = WorkspaceManager(displayManager: display)
        manager.initializeMonitors()
        let state = WindowStateCache()
        let moverFrame = CGRect(x: 80, y: 90, width: 600, height: 500)
        let siblingFrame = CGRect(x: 700, y: 90, width: 600, height: 500)
        let mover = TransferWindow(id: 4401, frame: moverFrame)
        let sibling = TransferWindow(id: 4402, frame: siblingFrame)
        sibling.rejectParking = true
        let source = manager.workspaceForScreen(screen)
        for window in [mover, sibling] {
            manager.assignWindow(window.windowID, toWorkspace: source)
            state.cachedWindows[window.windowID] = window
        }
        let engine = TilingEngine(displayManager: display)
        engine.prepareTileLayout([mover, sibling], onWorkspace: source, screen: screen)
        let border = FocusBorder()
        let orchestrator = WorkspaceOrchestrator(
            workspaceManager: manager, tilingEngine: engine,
            accessibility: AccessibilityManager(), displayManager: display,
            cursorManager: CursorManager(), stateCache: state,
            focusController: FocusStateController(focusBorder: border), focusBorder: border,
            dimmingOverlay: DimmingOverlay(), suppressions: SuppressionRegistry(),
            revalidation: MinimaRevalidation())
        orchestrator.actualFocusedWindow = { mover }
        orchestrator.allWindows = { [mover, sibling] }
        orchestrator.focusTransferredWindow = { _ in }
        orchestrator.warpToWindow = { _ in }
        orchestrator.updateFocusBorder = { _ in }
        orchestrator.transferRejected = { _, _ in }

        orchestrator.moveToNextEmptyWorkspace()

        XCTAssertEqual(manager.workspaceFor(mover.windowID), source)
        XCTAssertEqual(manager.workspaceForScreen(screen), source)
        XCTAssertEqual(mover.testFrame, moverFrame)
        XCTAssertEqual(sibling.testFrame, siblingFrame)
        XCTAssertNil(engine.existingTree(forWorkspace: 2, screen: screen))
    }

    func testDestinationMembershipChangeDuringParkingAbortsAndRestores() throws {
        let screen = TransferScreen(x: 0)
        let display = DisplayManager(screenSource: { [screen] })
        let manager = WorkspaceManager(displayManager: display)
        manager.initializeMonitors()
        let state = WindowStateCache()
        let moverFrame = CGRect(x: 80, y: 90, width: 600, height: 500)
        let siblingFrame = CGRect(x: 700, y: 90, width: 600, height: 500)
        let mover = TransferWindow(id: 4501, frame: moverFrame)
        let sibling = TransferWindow(id: 4502, frame: siblingFrame)
        let source = manager.workspaceForScreen(screen)
        let destination = try XCTUnwrap(manager.nextEmptyWorkspace(after: source, on: screen))
        for window in [mover, sibling] {
            manager.assignWindow(window.windowID, toWorkspace: source)
            state.cachedWindows[window.windowID] = window
        }
        sibling.onParkingWrite = { manager.assignWindow(4599, toWorkspace: destination) }
        let engine = TilingEngine(displayManager: display)
        engine.prepareTileLayout([mover, sibling], onWorkspace: source, screen: screen)
        let border = FocusBorder()
        let orchestrator = WorkspaceOrchestrator(
            workspaceManager: manager, tilingEngine: engine,
            accessibility: AccessibilityManager(), displayManager: display,
            cursorManager: CursorManager(), stateCache: state,
            focusController: FocusStateController(focusBorder: border), focusBorder: border,
            dimmingOverlay: DimmingOverlay(), suppressions: SuppressionRegistry(),
            revalidation: MinimaRevalidation())
        orchestrator.actualFocusedWindow = { mover }
        orchestrator.allWindows = { [mover, sibling] }
        orchestrator.focusTransferredWindow = { _ in }
        orchestrator.warpToWindow = { _ in }
        orchestrator.updateFocusBorder = { _ in }
        orchestrator.transferRejected = { _, _ in }

        orchestrator.moveToNextEmptyWorkspace()

        XCTAssertEqual(manager.workspaceFor(mover.windowID), source)
        XCTAssertEqual(mover.testFrame, moverFrame)
        XCTAssertEqual(sibling.testFrame, siblingFrame)
        XCTAssertEqual(manager.workspaceFor(4599), destination)
        XCTAssertNil(engine.existingTree(forWorkspace: destination, screen: screen))
    }

    func testTopologyChangeDuringParkingDoesNotRestoreOldCoordinates() throws {
        let screen = TransferScreen(x: 0)
        let replacement = TransferScreen(x: 3000)
        var provided = [screen]
        let display = DisplayManager(screenSource: { provided })
        let manager = WorkspaceManager(displayManager: display)
        manager.initializeMonitors()
        let state = WindowStateCache()
        let mover = TransferWindow(id: 4601, frame: CGRect(x: 80, y: 90, width: 600, height: 500))
        let sibling = TransferWindow(id: 4602, frame: CGRect(x: 700, y: 90, width: 600, height: 500))
        let source = manager.workspaceForScreen(screen)
        for window in [mover, sibling] {
            manager.assignWindow(window.windowID, toWorkspace: source)
            state.cachedWindows[window.windowID] = window
        }
        sibling.onParkingWrite = { provided = [replacement] }
        let engine = TilingEngine(displayManager: display)
        engine.prepareTileLayout([mover, sibling], onWorkspace: source, screen: screen)
        let border = FocusBorder()
        let orchestrator = WorkspaceOrchestrator(
            workspaceManager: manager, tilingEngine: engine,
            accessibility: AccessibilityManager(), displayManager: display,
            cursorManager: CursorManager(), stateCache: state,
            focusController: FocusStateController(focusBorder: border), focusBorder: border,
            dimmingOverlay: DimmingOverlay(), suppressions: SuppressionRegistry(),
            revalidation: MinimaRevalidation())
        orchestrator.actualFocusedWindow = { mover }
        orchestrator.allWindows = { [mover, sibling] }
        orchestrator.focusTransferredWindow = { _ in }
        orchestrator.warpToWindow = { _ in }
        orchestrator.updateFocusBorder = { _ in }
        orchestrator.transferRejected = { _, _ in }

        orchestrator.moveToNextEmptyWorkspace()

        XCTAssertEqual(manager.workspaceFor(mover.windowID), source)
        XCTAssertNotEqual(sibling.testFrame.origin, CGPoint(x: 700, y: 90),
                          "old-display coordinates must not be restored after topology changes")
        XCTAssertTrue(engine.unverifiedGeometryWindowIDs.contains(mover.windowID))
        XCTAssertTrue(engine.unverifiedGeometryWindowIDs.contains(sibling.windowID))
        XCTAssertNil(engine.existingTree(forWorkspace: 2, screen: screen))
    }

    // live repro 2026-09-18: two displays → built-in only, same process.
    // ws2 kept the external display's closed-but-app-alive windows, so the
    // menu bar showed it empty while Hypr+F skipped it and landed on ws3.
    func testAfterDisconnectClosedGhostsOnWorkspaceTwoDoNotBlockIt() throws {
        let left = TransferScreen(x: -1600)
        let primary = TransferScreen(x: 0)
        let builtIn = TransferScreen(x: 0, width: 1512, height: 945)
        var provided = [left, primary]
        let display = DisplayManager(screenSource: { provided })
        let manager = WorkspaceManager(displayManager: display)
        manager.initializeMonitors()
        XCTAssertEqual(manager.workspaceForScreen(primary), 2)
        let state = WindowStateCache()
        // closed on the external display while their apps kept running
        for ghost: CGWindowID in [4701, 4702, 4703] {
            manager.assignWindow(ghost, toWorkspace: 2)
            state.hiddenWindowIDs.insert(ghost)
        }
        let engine = TilingEngine(displayManager: display)

        provided = [builtIn]
        display.refresh()
        manager.initializeMonitors()
        engine.handleDisplayChange(currentScreens: display.screens,
                                   homeScreenForWorkspace: { manager.homeScreenForWorkspace($0) })
        _ = manager.switchWorkspace(1, cursorScreen: builtIn)

        let mover = TransferWindow(id: 4711, frame: CGRect(x: 8, y: 40, width: 740, height: 840))
        let sibling = TransferWindow(id: 4712, frame: CGRect(x: 760, y: 40, width: 740, height: 840))
        for window in [mover, sibling] {
            manager.assignWindow(window.windowID, toWorkspace: 1)
            state.cachedWindows[window.windowID] = window
        }
        engine.prepareTileLayout([mover, sibling], onWorkspace: 1, screen: builtIn)
        let orchestrator = makeOrchestrator(manager, engine, display, state)
        orchestrator.actualFocusedWindow = { mover }
        orchestrator.allWindows = { [mover, sibling] }
        orchestrator.transferRejected = { _, message in XCTFail("unexpected rejection: \(message)") }

        orchestrator.moveToNextEmptyWorkspace()

        XCTAssertEqual(manager.workspaceFor(mover.windowID), 2)
        XCTAssertEqual(manager.workspaceForScreen(builtIn), 2)
        XCTAssertEqual(engine.existingTree(forWorkspace: 2, screen: builtIn)?.allWindows.map(\.windowID),
                       [mover.windowID])
    }

    // nothing on screen means empty, the menu bar's rule. a live floater
    // still owns its workspace
    func testMinimizedAndClosedWindowsDoNotBlockButLiveFloaterDoes() throws {
        let screen = TransferScreen(x: 0)
        let display = DisplayManager(screenSource: { [screen] })
        let manager = WorkspaceManager(displayManager: display)
        manager.initializeMonitors()
        let state = WindowStateCache()
        // a live floater owns ws2
        manager.assignWindow(4802, toWorkspace: 2)
        state.floatingWindowIDs.insert(4802)
        // minimized (hidden + reserved) on ws3 does not own it
        manager.assignWindow(4801, toWorkspace: 3)
        state.hiddenWindowIDs.insert(4801)
        state.reservedHiddenWindowIDs.insert(4801)
        // a closed ghost on ws3 does not own it either
        manager.assignWindow(4803, toWorkspace: 3)
        state.hiddenWindowIDs.insert(4803)

        let mover = TransferWindow(id: 4811, frame: CGRect(x: 80, y: 90, width: 600, height: 500))
        let sibling = TransferWindow(id: 4812, frame: CGRect(x: 700, y: 90, width: 600, height: 500))
        for window in [mover, sibling] {
            manager.assignWindow(window.windowID, toWorkspace: 1)
            state.cachedWindows[window.windowID] = window
        }
        let engine = TilingEngine(displayManager: display)
        engine.prepareTileLayout([mover, sibling], onWorkspace: 1, screen: screen)
        let orchestrator = makeOrchestrator(manager, engine, display, state)
        orchestrator.actualFocusedWindow = { mover }
        orchestrator.allWindows = { [mover, sibling] }
        orchestrator.transferRejected = { _, message in XCTFail("unexpected rejection: \(message)") }

        orchestrator.moveToNextEmptyWorkspace()

        XCTAssertEqual(manager.workspaceFor(mover.windowID), 3)
        XCTAssertEqual(manager.workspaceFor(4802), 2)
        XCTAssertEqual(manager.workspaceFor(4801), 3)
        XCTAssertEqual(manager.workspaceFor(4803), 3)
    }

    private func makeOrchestrator(_ manager: WorkspaceManager, _ engine: TilingEngine,
                                  _ display: DisplayManager, _ state: WindowStateCache) -> WorkspaceOrchestrator {
        let border = FocusBorder()
        let orchestrator = WorkspaceOrchestrator(
            workspaceManager: manager, tilingEngine: engine,
            accessibility: AccessibilityManager(), displayManager: display,
            cursorManager: CursorManager(), stateCache: state,
            focusController: FocusStateController(focusBorder: border), focusBorder: border,
            dimmingOverlay: DimmingOverlay(), suppressions: SuppressionRegistry(),
            revalidation: MinimaRevalidation())
        orchestrator.focusTransferredWindow = { _ in }
        orchestrator.warpToWindow = { _ in }
        orchestrator.updateFocusBorder = { _ in }
        orchestrator.updatePositionCache = { }
        return orchestrator
    }
}

private final class TransferScreen: SyntheticScreen {
    private let bounds: CGRect
    init(x: CGFloat, width: CGFloat = 1600, height: CGFloat = 1000) {
        bounds = CGRect(x: x, y: 0, width: width, height: height)
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var frame: NSRect { bounds }
    override var visibleFrame: NSRect { bounds }
    override var localizedName: String { "transfer-\(Int(bounds.minX))" }
}

private final class TransferFrameTrace {
    var frames: [CGWindowID: CGRect] = [:]
    var rejectNextCandidate = false
    var failReads = false
    var originalPositions: [CGWindowID: CGPoint] = [:]
    var onWritePosition: ((CGPoint) -> Void)?
    private var now: TimeInterval = 0

    func io(_ generation: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { [self] id, size, _ in frames[id]?.size = size; return .success },
            writePosition: { [self] id, position, _ in
                onWritePosition?(position)
                let shouldReject = rejectNextCandidate && position != originalPositions[id]
                frames[id]?.origin = shouldReject ? CGPoint(x: position.x + 80, y: position.y) : position
                return .success
            },
            readPosition: { [self] id, _ in
                failReads ? (.cannotComplete, nil) : (.success, frames[id]?.origin)
            },
            readSize: { [self] id, _ in (.success, frames[id]?.size) },
            now: { [self] in now }, sleep: { [self] in now += $0 },
            currentGeneration: generation)
    }
}

private final class TransferWindow: HyprWindow {
    private var storedFrame: CGRect
    var rejectParking = false
    var parkingYOffset: CGFloat = 0
    var sizeWriteCount = 0
    var onParkingWrite: (() -> Void)?
    var testFrame: CGRect { storedFrame }
    init(id: CGWindowID, frame: CGRect) {
        storedFrame = frame
        super.init(element: AXUIElementCreateApplication(9876), windowID: id, ownerPID: 9876)
    }
    override var isFullscreen: Bool { false }
    override var isSizeSettable: Bool? { true }
    override func readPosition() -> (AXError, CGPoint?) { (.success, storedFrame.origin) }
    override func readSize() -> (AXError, CGSize?) { (.success, storedFrame.size) }
    override func writePosition(_ point: CGPoint) -> AXError {
        if point.x > 1500 { onParkingWrite?(); onParkingWrite = nil }
        if point.x > 1500 {
            storedFrame.origin = rejectParking
                ? CGPoint(x: point.x - 100, y: point.y)
                : CGPoint(x: point.x, y: point.y + parkingYOffset)
        } else {
            storedFrame.origin = point
        }
        return .success
    }
    override func writeSize(_ size: CGSize) -> AXError {
        sizeWriteCount += 1
        storedFrame.size = size
        return .success
    }
    override func setMessagingTimeout(_ timeout: TimeInterval) -> AXError { .success }
    override func beginFrameWrite(timeout: TimeInterval,
                                  checkpoint: () -> FrameSizingFailure?)
        -> AXFrameWriteBatch.BeginResult {
        .ready(.noop(windowID: windowID))
    }
}
