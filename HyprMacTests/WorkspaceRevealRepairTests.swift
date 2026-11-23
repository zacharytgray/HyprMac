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
//
// a tile its app did not answer for is held by the switch's tile pass: it
// keeps its leaf and gets no frame, so it stays parked on the workspace now
// showing. the same retry asks its app and, once the app answers, retiles
// from a walk that reads it. those tests see the engine's frame writes.

final class WorkspaceRevealRepairTests: XCTestCase {
    private var screen: RevealScreen!
    private var workspaceManager: WorkspaceManager!
    private var stateCache: WindowStateCache!
    private var orchestrator: WorkspaceOrchestrator!
    private var revealMissed = 0
    /// what the reveal told the chrome to mark, per call
    private var marked: [[CGWindowID]] = []
    /// the next scheduled reveal retry, stepped by hand
    private var retries: [() -> Void] = []
    /// whether the floaters' app answers its window list, and how often it was asked
    private var appAnswers = false
    private var appAsks = 0
    private var parked: [CGWindowID: RevealWindow] = [:]
    private var visible: Int!
    private var hidden: Int!
    private var display: DisplayManager!
    private var suppressions: SuppressionRegistry!
    private var engine: TilingEngine!
    private let tileWrites = TileWrites()
    private let saved = CGRect(x: 100, y: 120, width: 600, height: 400)

    override func setUpWithError() throws {
        let screen = RevealScreen()
        self.screen = screen
        let display = DisplayManager(screenSource: { [screen] })
        self.display = display
        suppressions = SuppressionRegistry()
        workspaceManager = WorkspaceManager(displayManager: display)
        workspaceManager.initializeMonitors()
        stateCache = WindowStateCache()
        let border = FocusBorder()
        engine = TilingEngine(displayManager: display,
                              frameSizingIOFactory: { [tileWrites] _, generation in tileWrites.io(generation) })
        orchestrator = WorkspaceOrchestrator(
            workspaceManager: workspaceManager, tilingEngine: engine,
            accessibility: AccessibilityManager(), displayManager: display,
            cursorManager: CursorManager(), stateCache: stateCache,
            focusController: FocusStateController(focusBorder: border), focusBorder: border,
            dimmingOverlay: DimmingOverlay(), suppressions: suppressions,
            revalidation: MinimaRevalidation())
        orchestrator.screenUnderCursor = { [unowned self] in self.screen }
        orchestrator.onRevealMissed = { [unowned self] in self.revealMissed += 1 }
        orchestrator.onFloatersRevealed = { [unowned self] in self.marked.append($0.map(\.windowID)) }
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
        XCTAssertEqual(marked, [[floater.windowID]], "outlined the moment it came back")
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
        XCTAssertTrue(marked.isEmpty, "nothing revealed, nothing to mark")
        XCTAssertEqual(revealMissed, 2, "the repair poll was asked for all along, and again on giving up")
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

    // closed while parked, app still running: it keeps its workspace and
    // saved frame, but its app will never list it again
    func testAGhostFloaterStartsNoRetry() {
        let floater = parkedFloater(id: 7315, on: hidden)
        stateCache.hiddenWindowIDs.insert(floater.windowID)
        orchestrator.allWindows = { [] }

        orchestrator.switchWorkspace(hidden)

        XCTAssertEqual(revealMissed, 0)
        XCTAssertTrue(retries.isEmpty)
    }

    // minimized or Cmd-H'd while parked can come back, so it still retries
    func testAReservedHiddenFloaterStillRetries() {
        let floater = parkedFloater(id: 7316, on: hidden)
        stateCache.hiddenWindowIDs.insert(floater.windowID)
        stateCache.reservedHiddenWindowIDs.insert(floater.windowID)
        orchestrator.allWindows = { [] }

        orchestrator.switchWorkspace(hidden)

        XCTAssertEqual(revealMissed, 1)
        XCTAssertEqual(retries.count, 1)
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
        XCTAssertEqual(marked, [[floater.windowID]], "outlined by the poll that revealed it")
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
        XCTAssertTrue(marked.isEmpty)
    }

    // MARK: - when the switch is done, for the admit-only pass

    func testTheSwitchIsNotSettledWhileItsRetileRuns() {
        var settledDuringRetile: Bool?
        orchestrator.tileAllVisibleSpaces = { [unowned self] _ in
            settledDuringRetile = self.orchestrator.isSwitchSettled
        }
        XCTAssertTrue(orchestrator.isSwitchSettled)

        orchestrator.switchWorkspace(hidden)

        XCTAssertEqual(settledDuringRetile, false)
        XCTAssertTrue(orchestrator.isSwitchSettled)
        XCTAssertTrue(suppressions.isHeldOnlyByWorkspaceSwitch(.workspaceTransition),
                      "the switch's hold is its own")
    }

    func testTheSwitchIsNotSettledWhileAFloaterRevealIsRetried() {
        _ = parkedFloater(id: 7320, on: hidden)
        orchestrator.allWindows = { [] }

        orchestrator.switchWorkspace(hidden)

        XCTAssertFalse(orchestrator.isSwitchSettled, "the retry still writes a frame")
        appAnswers = true
        stepRetry()
        XCTAssertTrue(orchestrator.isSwitchSettled)
    }

    // Hypr+2, then Cmd-N: the create lands under the switch's 1.5 s hold.
    // the newcomer is tiled once the switch is done, before the hold ends,
    // and the window the switch revealed is left exactly as it was
    func testACreateDuringTheSwitchHoldIsAdmittedAfterTheSwitchAndBeforeTheHoldEnds() {
        let floater = parkedFloater(id: 7321, on: hidden)
        stateCache.knownWindowIDs.insert(floater.windowID)
        orchestrator.allWindows = { [] }
        let discovery = WindowDiscoveryService(
            stateCache: stateCache, accessibility: AccessibilityManager(), displayManager: display,
            workspaceManager: workspaceManager, bundleIDForPID: { _ in nil }, isWindowSizeSettable: { _ in true })
        let clock = StepClock()
        var polls = 0
        var admitted: [CGWindowID] = []
        let scheduler = PollingScheduler(periodicInterval: 1000) { polls += 1 }
        clock.install(on: scheduler)
        scheduler.isSuppressed = { [unowned self] in self.suppressions.isSuppressed(.workspaceTransition) }
        scheduler.admitsNewWindowsDuringHold = { [unowned self] in
            SwitchHoldAdmission.allows(
                heldOnlyBySwitch: self.suppressions.isHeldOnlyByWorkspaceSwitch(.workspaceTransition),
                switchSettled: self.orchestrator.isSwitchSettled, mouseButtonDown: false,
                finishingDrag: false, displayTransitionPending: false, sessionInterrupted: false)
        }
        // the walk still reads the floater in the hide corner
        let newcomer = makeWindow(id: 8101, pid: 9877)
        scheduler.onAdmitDuringHold = {
            let changes = discovery.computeAdmissions(snapshot: [floater, newcomer], excludedBundleIDs: [])
            admitted += changes.newWindows.map(\.windowID)
        }
        scheduler.start()
        defer { scheduler.stop() }

        orchestrator.switchWorkspace(hidden)
        scheduler.schedule(after: 0.2, trigger: .create, trailing: true)
        clock.advance(by: 0.6)
        XCTAssertTrue(admitted.isEmpty, "the switch is still revealing a floater")

        appAnswers = true
        stepRetry()
        clock.advance(by: 0.3)

        XCTAssertEqual(admitted, [8101])
        XCTAssertTrue(suppressions.isSuppressed(.workspaceTransition), "before the hold ended")
        XCTAssertEqual(polls, 0, "the full poll still waits out the hold")
        XCTAssertEqual(workspaceManager.workspaceFor(floater.windowID), hidden)
        XCTAssertEqual(stateCache.knownWindowIDs, [floater.windowID, 8101])
        XCTAssertTrue(stateCache.hiddenWindowIDs.isEmpty)

        suppressions.clear(.workspaceTransition)
        clock.advance(by: 0.4)
        XCTAssertEqual(polls, 1, "the full poll runs once the hold ends")
        XCTAssertEqual(admitted, [8101])
    }

    // MARK: - held tiles

    /// two tiles on the hidden workspace, tiled while both answered. the
    /// second one's app (Messages, busy with its own Dock activation) does
    /// not answer the switch's walk while `appAnswers` is false
    private func heldTileSetup(walkReadsHeld: @escaping () -> Bool = { true })
        -> (answering: RevealWindow, busy: RevealWindow) {
        let answering = RevealWindow(id: 7401, frame: CGRect(origin: workspaceManager.hidePosition(),
                                                             size: saved.size))
        let busy = RevealWindow(id: 7402, frame: CGRect(origin: workspaceManager.hidePosition(),
                                                        size: saved.size))
        for w in [answering, busy] {
            workspaceManager.assignWindow(w.windowID, toWorkspace: hidden)
            stateCache.windowOwners[w.windowID] = w.ownerPID
            tileWrites.frames[w.windowID] = w.storedFrame
        }
        parked[busy.windowID] = busy
        XCTAssertTrue(engine.tileWindows([answering, busy], onWorkspace: hidden, screen: screen).published)
        // then parked by the switch away, off their slots
        for w in [answering, busy] { tileWrites.frames[w.windowID] = w.storedFrame }
        tileWrites.written = []

        let readsBusy = { [unowned self] in self.appAnswers && walkReadsHeld() }
        orchestrator.allWindows = { readsBusy() ? [answering, busy] : [answering] }
        orchestrator.unreadableWindowIDs = { readsBusy() ? [] : [busy.windowID] }
        // wired as WindowManager wires it: hidden windows are never held
        engine.heldWindowIDsSource = { [unowned self] in
            self.orchestrator.unreadableWindowIDs().subtracting(self.stateCache.hiddenWindowIDs)
        }
        orchestrator.tileAllVisibleSpaces = { [unowned self] walk in
            let ws = self.workspaceManager.workspaceForScreen(self.screen)
            let ids = self.workspaceManager.windowIDs(onWorkspace: ws)
            self.engine.tileWindows((walk ?? []).filter { ids.contains($0.windowID) },
                                    onWorkspace: ws, screen: self.screen)
        }
        orchestrator.keepsCursorOnSwitch = { true }
        return (answering, busy)
    }

    func testAHeldTileIsRetiledOnTheFirstAttemptItsAppAnswers() {
        let (answering, busy) = heldTileSetup()

        orchestrator.switchWorkspace(hidden)

        XCTAssertEqual(tileWrites.written, [answering.windowID], "the busy app's tile got no frame")
        XCTAssertEqual(engine.heldMembers(onWorkspace: hidden), [busy.windowID])
        XCTAssertEqual(revealMissed, 1, "the repair poll is asked for")
        XCTAssertFalse(orchestrator.isSwitchSettled, "the retry still writes a frame")
        tileWrites.written = []

        appAnswers = true
        stepRetry()

        XCTAssertEqual(appAsks, 1)
        XCTAssertTrue(tileWrites.written.contains(busy.windowID), "the engine gave it its frame")
        XCTAssertTrue(engine.heldMembers(onWorkspace: hidden).isEmpty, "the hold is released")
        XCTAssertTrue(retries.isEmpty, "nothing left to retry")
        XCTAssertTrue(orchestrator.isSwitchSettled)
        XCTAssertTrue(marked.isEmpty, "only floaters are marked")
    }

    func testAHeldTileWaitsOutABusyAppThenIsRetiled() {
        let (_, busy) = heldTileSetup()
        orchestrator.switchWorkspace(hidden)
        tileWrites.written = []

        for _ in 0..<3 { stepRetry() }
        XCTAssertEqual(appAsks, 3)
        XCTAssertTrue(tileWrites.written.isEmpty, "nothing written while its app is busy")
        XCTAssertEqual(engine.heldMembers(onWorkspace: hidden), [busy.windowID])

        appAnswers = true
        stepRetry()

        XCTAssertEqual(appAsks, 4)
        XCTAssertTrue(tileWrites.written.contains(busy.windowID))
        XCTAssertTrue(engine.heldMembers(onWorkspace: hidden).isEmpty)
        XCTAssertTrue(retries.isEmpty)
        XCTAssertEqual(revealMissed, 1, "no second poll request when the retry succeeds")
    }

    // the app listed it, then did not answer the walk: still held, asked again
    func testAHeldTileTheWalkStillCannotReadStaysPending() {
        var walkReads = false
        let (_, busy) = heldTileSetup(walkReadsHeld: { walkReads })
        orchestrator.switchWorkspace(hidden)
        tileWrites.written = []

        appAnswers = true
        stepRetry()

        XCTAssertFalse(tileWrites.written.contains(busy.windowID))
        XCTAssertEqual(engine.heldMembers(onWorkspace: hidden), [busy.windowID])
        XCTAssertEqual(retries.count, 1, "asked again")

        walkReads = true
        stepRetry()

        XCTAssertTrue(tileWrites.written.contains(busy.windowID))
        XCTAssertTrue(retries.isEmpty)
    }

    func testAHeldTileRetryGivesUpAndRequestsThePoll() {
        let (_, busy) = heldTileSetup()
        orchestrator.switchWorkspace(hidden)
        tileWrites.written = []

        for _ in 0..<WorkspaceOrchestrator.revealRetryAttempts { stepRetry() }

        XCTAssertEqual(appAsks, WorkspaceOrchestrator.revealRetryAttempts)
        XCTAssertTrue(retries.isEmpty, "gave up")
        XCTAssertEqual(revealMissed, 2, "a poll is asked for again on giving up")
        XCTAssertTrue(tileWrites.written.isEmpty)
        XCTAssertEqual(engine.heldMembers(onWorkspace: hidden), [busy.windowID],
                       "still held, for the poll that reads it to release")
        XCTAssertTrue(orchestrator.isSwitchSettled)
    }

    func testSwitchingAwayCancelsAHeldTileRetry() {
        let (_, busy) = heldTileSetup()
        orchestrator.switchWorkspace(hidden)

        // switched back before Messages answered: its tile belongs parked
        orchestrator.switchWorkspace(visible)
        tileWrites.written = []
        appAnswers = true
        stepRetry()

        XCTAssertEqual(appAsks, 0, "its app is not asked")
        XCTAssertTrue(retries.isEmpty)
        XCTAssertFalse(tileWrites.written.contains(busy.windowID), "not revealed onto a hidden workspace")
    }

    // closed while its app runs: the app will never list it again
    func testAGhostTileStartsNoRetry() {
        let (_, busy) = heldTileSetup()
        stateCache.hiddenWindowIDs.insert(busy.windowID)

        orchestrator.switchWorkspace(hidden)

        XCTAssertEqual(revealMissed, 0)
        XCTAssertTrue(retries.isEmpty)
    }

    // a tile held as off on another Space: its app answers, so the retry
    // would only walk for nothing
    func testAHeldTileWhoseAppAnsweredTheWalkStartsNoRetry() {
        let (_, busy) = heldTileSetup()
        engine.heldWindowIDsSource = { [busy.windowID] }
        orchestrator.unreadableWindowIDs = { [] }

        orchestrator.switchWorkspace(hidden)

        XCTAssertEqual(engine.heldMembers(onWorkspace: hidden), [busy.windowID])
        XCTAssertEqual(revealMissed, 0)
        XCTAssertTrue(retries.isEmpty)
    }

    func testAFloaterAndAHeldTileOfTheSameSwitchShareOneRetry() {
        let (_, busy) = heldTileSetup()
        let floater = parkedFloater(id: 7403, on: hidden)
        orchestrator.switchWorkspace(hidden)
        tileWrites.written = []

        appAnswers = true
        stepRetry()

        XCTAssertEqual(appAsks, 1, "one read for the app of both")
        XCTAssertNil(workspaceManager.savedFloatingFrame(for: floater.windowID))
        XCTAssertTrue(tileWrites.written.contains(busy.windowID))
        XCTAssertTrue(retries.isEmpty)
    }

    // MARK: - reveal before park (#101)

    // parking is one position write per window and lands at once, while the
    // reveal moves, resizes and verifies each window in turn. parked first,
    // the screen showed only the wallpaper for the whole reveal. the outgoing
    // windows now stay up as the backdrop until the incoming ones are placed

    /// a window on screen, on `workspace`, that records when it is parked
    private func onScreenWindow(id: CGWindowID, on workspace: Int, floating: Bool = false) -> RevealWindow {
        let window = RevealWindow(id: id, frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        workspaceManager.assignWindow(id, toWorkspace: workspace)
        stateCache.windowOwners[id] = window.ownerPID
        if floating {
            stateCache.floatingWindowIDs.insert(id)
            window.isFloating = true
        }
        window.onWritePosition = { [unowned self] point in
            if point == self.workspaceManager.hidePosition() { self.order.append("park:\(id)") }
        }
        return window
    }

    private var order: [String] = []

    func testTheIncomingWorkspaceIsTiledBeforeTheOutgoingOneIsParked() {
        let outgoing = onScreenWindow(id: 7401, on: visible)
        let incoming = RevealWindow(id: 7402, frame: CGRect(origin: workspaceManager.hidePosition(),
                                                            size: CGSize(width: 800, height: 1000)))
        workspaceManager.assignWindow(incoming.windowID, toWorkspace: hidden)
        orchestrator.allWindows = { [outgoing, incoming] }
        orchestrator.tileAllVisibleSpaces = { [unowned self] _ in self.order.append("retile") }
        orchestrator.windowsParked = { [unowned self] in self.order.append("list dropped") }

        orchestrator.switchWorkspace(hidden)

        XCTAssertEqual(order, ["retile", "park:7401", "list dropped"],
                       "the outgoing window is the backdrop until the incoming one is placed")
        XCTAssertEqual(outgoing.storedFrame.origin, workspaceManager.hidePosition(), "parked all the same")
    }

    func testAnIncomingFloaterIsRestoredBeforeTheOutgoingFloaterIsParked() {
        let outgoing = onScreenWindow(id: 7403, on: visible, floating: true)
        let incoming = parkedFloater(id: 7404, on: hidden)
        orchestrator.allWindows = { [outgoing, incoming] }
        var incomingRestoredAtPark: Bool?
        outgoing.onWritePosition = { [unowned self] point in
            guard point == self.workspaceManager.hidePosition() else { return }
            incomingRestoredAtPark = self.workspaceManager.savedFloatingFrame(for: incoming.windowID) == nil
        }

        orchestrator.switchWorkspace(hidden)

        XCTAssertEqual(incomingRestoredAtPark, true)
        XCTAssertEqual(workspaceManager.savedFloatingFrame(for: outgoing.windowID),
                       CGRect(x: 0, y: 0, width: 800, height: 1000),
                       "the outgoing floater's frame was saved before it was parked")
    }

    // nothing to put on screen, so nothing to wait for: the outgoing windows
    // go at once, as they always did
    func testSwitchingToAnEmptyWorkspaceParksBeforeTheRetile() {
        let outgoing = onScreenWindow(id: 7405, on: visible)
        orchestrator.allWindows = { [outgoing] }
        orchestrator.tileAllVisibleSpaces = { [unowned self] _ in self.order.append("retile") }
        orchestrator.windowsParked = { [unowned self] in self.order.append("list dropped") }

        orchestrator.switchWorkspace(hidden)

        XCTAssertEqual(order, ["park:7405", "list dropped", "retile"])
    }

    // the outgoing floater's app missed the switch's walk, so only the
    // window cache has its handle. the retile rebuilds that cache from the
    // walk with the now-visible windows only, so the park after it found no
    // handle: the floater stayed on screen, the park repair later parked it
    // without saving its frame, and it never came back from the corner
    func testAnOutgoingFloaterTheWalkMissedIsStillParkedAndComesBack() {
        let original = CGRect(x: 0, y: 0, width: 800, height: 1000)
        let floater = onScreenWindow(id: 7408, on: visible, floating: true)
        stateCache.cachedWindows[floater.windowID] = floater
        let incoming = RevealWindow(id: 7409, frame: CGRect(origin: workspaceManager.hidePosition(),
                                                            size: CGSize(width: 800, height: 1000)))
        workspaceManager.assignWindow(incoming.windowID, toWorkspace: hidden)
        orchestrator.allWindows = { [incoming] }
        // what updatePositionCache does to the cache
        orchestrator.tileAllVisibleSpaces = { [unowned self] walk in
            self.order.append("retile")
            self.stateCache.cachedWindows.removeAll()
            for w in walk ?? [] where self.workspaceManager.isWindowVisible(w.windowID) {
                self.stateCache.cachedWindows[w.windowID] = w
            }
        }

        orchestrator.switchWorkspace(hidden)

        XCTAssertEqual(order, ["retile", "park:7408"], "parked after the retile all the same")
        XCTAssertEqual(floater.storedFrame.origin, workspaceManager.hidePosition())
        XCTAssertEqual(workspaceManager.savedFloatingFrame(for: floater.windowID), original)

        // back again: the app answers this walk
        orchestrator.allWindows = { [floater, incoming] }
        orchestrator.switchWorkspace(visible)

        XCTAssertNil(workspaceManager.savedFloatingFrame(for: floater.windowID), "restored")
    }

    // a workspace holding only a closed-but-alive window shows nothing
    func testAWorkspaceWithOnlyHiddenWindowsCountsAsEmpty() {
        let outgoing = onScreenWindow(id: 7406, on: visible)
        workspaceManager.assignWindow(7407, toWorkspace: hidden)
        stateCache.hiddenWindowIDs.insert(7407)
        orchestrator.allWindows = { [outgoing] }
        orchestrator.tileAllVisibleSpaces = { [unowned self] _ in self.order.append("retile") }

        orchestrator.switchWorkspace(hidden)

        XCTAssertEqual(order, ["park:7406", "retile"])
    }

    func testTheRepairLeavesAFloaterOnAHiddenWorkspaceParked() {
        let floater = parkedFloater(id: 7304, on: hidden)

        orchestrator.repairUnrevealedFloaters([floater])

        XCTAssertEqual(workspaceManager.savedFloatingFrame(for: floater.windowID), saved)
    }
}

/// the scheduler's clock and main-queue delay, stepped by hand
private final class StepClock {
    private var nowNS: UInt64 = 1_000_000_000
    private var queue: [(at: UInt64, seq: Int, block: () -> Void)] = []
    private var seq = 0

    func install(on scheduler: PollingScheduler) {
        scheduler.now = { [unowned self] in DispatchTime(uptimeNanoseconds: self.nowNS) }
        scheduler.arm = { [unowned self] delay, block in
            self.seq += 1
            self.queue.append((self.nowNS + UInt64((delay * 1e9).rounded()), self.seq, block))
        }
    }

    func advance(by seconds: TimeInterval) {
        let end = nowNS + UInt64((seconds * 1e9).rounded())
        while let next = queue.enumerated()
            .filter({ $0.element.at <= end })
            .min(by: { ($0.element.at, $0.element.seq) < ($1.element.at, $1.element.seq) }) {
            queue.remove(at: next.offset)
            nowNS = max(nowNS, next.element.at)
            next.element.block()
        }
        nowNS = end
    }
}

/// the engine's frame writes, and the frames it reads back
private final class TileWrites {
    var frames: [CGWindowID: CGRect] = [:]
    var written: Set<CGWindowID> = []

    func io(_ generation: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { [self] id, size, _ in
                written.insert(id); frames[id, default: .zero].size = size; return .success
            },
            writePosition: { [self] id, position, _ in
                written.insert(id); frames[id, default: .zero].origin = position; return .success
            },
            readPosition: { [self] id, _ in (.success, frames[id]?.origin) },
            readSize: { [self] id, _ in (.success, frames[id]?.size) },
            now: { 0 }, sleep: { _ in }, currentGeneration: generation)
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
    var onWritePosition: (CGPoint) -> Void = { _ in }
    override func writePosition(_ point: CGPoint) -> AXError {
        storedFrame.origin = point
        onWritePosition(point)
        return .success
    }
}
