import XCTest
import Cocoa
@testable import HyprMac

// the bounded admission recovery: one retry through an injected scheduler,
// then an explicit float in place. every context check and every
// cancellation case is driven through the seams, so no wall clock and no
// live AX are involved.

final class AdmissionRecoveryTests: XCTestCase {

    private var screen: NSScreen!
    private var other: NSScreen!
    private var recovery: AdmissionRecovery!
    private var harness: RecoveryHarness!

    override func setUpWithError() throws {
        screen = NSScreen.main ?? NSScreen.screens.first ?? PrimaryRecoveryScreen()
        other = OtherRecoveryScreen()
        recovery = AdmissionRecovery()
        harness = RecoveryHarness(screen: screen)
        harness.install(on: recovery)
    }

    private func failedAdmission(_ ids: Set<CGWindowID>, workspace: Int = 2,
                                 published: Set<CGWindowID> = [11],
                                 generation: UInt64 = 7,
                                 failure: FrameSizingFailure? = .geometryMismatch(11),
                                 restored: Set<CGWindowID> = [11],
                                 refused: Set<CGWindowID> = []) -> TilingEngine.AdmissionResult {
        TilingEngine.AdmissionResult(workspace: workspace, screen: screen, generation: generation,
                                     insertedIDs: ids, publishedIDs: published,
                                     failure: failure, restoredIDs: restored, refusedIDs: refused)
    }

    // MARK: - the identity of the newcomer

    func testStrandedNewcomerIsTrackedNotTheWindowTheFailureNamed() {
        // the failure names 11, an incumbent that refused its frame; 26 is
        // the window that was new
        recovery.note(failedAdmission([26]))
        XCTAssertEqual(recovery.pendingWindowIDs, [26])
    }

    func testAcceptedAdmissionTracksNothing() {
        recovery.note(TilingEngine.AdmissionResult(
            workspace: 2, screen: screen, generation: 7, insertedIDs: [26],
            publishedIDs: [11, 26], failure: nil, restoredIDs: [], refusedIDs: []))
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertEqual(harness.scheduled.count, 0)
    }

    func testAWindowABypassedPassRefusedOutrightIsStrandedToo() {
        // nothing routed it: routing inside a bypassed pass would pick its
        // next workspace with the very bounds that pass is ignoring
        recovery.note(failedAdmission([], published: [11], failure: nil, restored: [],
                                      refused: [26]))
        XCTAssertEqual(recovery.pendingWindowIDs, [26])
        XCTAssertEqual(harness.scheduled.count, 1)
    }

    func testPreflightRefusalFloatsWithoutAnotherSizingAttempt() throws {
        recovery.note(failedAdmission([], published: [11], failure: nil, restored: [], refused: [26]))
        harness.fire()
        XCTAssertTrue(harness.attempts.isEmpty)
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
    }

    // MARK: - which key presses cancel

    func testShowingAnotherWorkspaceDoesNotCancelAPendingRetry() {
        XCTAssertFalse(WindowManager.cancelsPendingRecovery(.switchWorkspace(3)))
        XCTAssertFalse(WindowManager.cancelsPendingRecovery(.cycleWorkspace(1)))
    }

    func testFocusAndOverlayActionsKeepPendingRecovery() {
        for action: Action in [.focusDirection(.left), .focusFloating, .focusMenuBar,
                               .showKeybinds, .launchApp(bundleID: "com.apple.Safari"),
                               .runCommand(label: "x", command: "/usr/bin/true")] {
            XCTAssertFalse(WindowManager.cancelsPendingRecovery(action), "\(action)")
        }
    }

    func testInTreeGeometryActionsKeepPendingRecovery() {
        // they only rework the live tree, which never holds the stranded
        // window, so cancelling here left it with nothing scheduled
        for action: Action in [.resizeDirection(.up), .swapDirection(.left), .toggleSplit] {
            XCTAssertFalse(WindowManager.cancelsPendingRecovery(action), "\(action)")
        }
    }

    func testMembershipActionsCancelAPendingRetry() {
        XCTAssertTrue(WindowManager.cancelsPendingRecovery(.moveToWorkspace(3)))
        XCTAssertTrue(WindowManager.cancelsPendingRecovery(.toggleFloating))
        XCTAssertTrue(WindowManager.cancelsPendingRecovery(.moveToNextEmptyWorkspace))
    }

    // MARK: - the one retry

    func testSuccessfulRetryTilesTheNewcomerAndClearsPending() throws {
        harness.place = [26]
        recovery.note(failedAdmission([26]))
        XCTAssertEqual(recovery.phase(of: 26), .awaitingRetry)

        harness.fire()

        XCTAssertEqual(harness.attempts.count, 1)
        XCTAssertEqual(try XCTUnwrap(harness.attempts.first).newcomers, [26])
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertTrue(harness.floated.isEmpty)
        XCTAssertTrue(harness.clearedUnverified.isEmpty)
    }

    func testRetryRunsAtTheConfiguredDelay() {
        recovery.retryDelay = 0.25
        recovery.note(failedAdmission([26]))
        XCTAssertEqual(harness.scheduled.map(\.delay), [0.25])
    }

    func testRetryCarriesItsAdmissionGenerationAsTheBypassBound() throws {
        recovery.note(failedAdmission([26], generation: 42))
        harness.fire()
        let attempt = try XCTUnwrap(harness.attempts.first)
        XCTAssertEqual(attempt.bypass, [26: 42])
    }

    func testEachNewcomerCarriesOnlyItsOwnAdmissionGeneration() throws {
        recovery.note(failedAdmission([26], generation: 40))
        // a later pass strands 27 while 26 is still pending and still not in
        // the published tree
        recovery.note(failedAdmission([27], generation: 55))
        harness.fire()

        // both are retried together and neither inherits the other's reach
        XCTAssertEqual(try XCTUnwrap(harness.attempts.first).bypass, [26: 40, 27: 55])
    }

    // MARK: - final policy

    func testTheOutcomePolicyDefaultsToFloatingInPlace() {
        XCTAssertEqual(AdmissionRecovery().outcome, .floatInPlace)
    }

    func testTheUnwiredRoutingOutcomeStillFloatsTheWindow() {
        recovery.outcome = .routeToFittingWorkspace
        recovery.note(failedAdmission([26]))
        harness.fire()

        XCTAssertEqual(harness.floated.map(\.id), [26],
                       "no router exists, so the window is never left untracked")
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
    }

    func testRepeatedGeometryFailureFloatsTheNewcomerInPlace() {
        harness.failure = .geometryMismatch(11)
        recovery.note(failedAdmission([26], failure: .geometryMismatch(11)))
        harness.fire()

        XCTAssertEqual(harness.floated.map(\.id), [26])
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
    }

    func testRepeatedIOFailureFloatsTheNewcomerInPlace() {
        // an i/o error that is not a timeout. `cannotComplete` is what an AX
        // messaging timeout returns, so it counts as a timeout below
        harness.failure = .readFailed(26, .failure)
        recovery.note(failedAdmission([26], failure: .writeFailed(11, .failure)))
        harness.fire()

        XCTAssertEqual(harness.floated.map(\.id), [26])
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
    }

    // MARK: - timeouts are not refusals

    func testTimeoutsAreTheFailuresNobodyRefused() {
        let timeouts: [FrameSizingFailure] = [
            .deadlineExceeded, .attemptsExhausted,
            .readFailed(26, .cannotComplete), .writeFailed(26, .cannotComplete),
            .cleanupFailed(26, primary: .deadlineExceeded, error: .failure),
            .cleanupFailed(26, primary: nil, error: .cannotComplete)
        ]
        let refusals: [FrameSizingFailure] = [
            .geometryMismatch(26), .outsideUsableFrame(26), .overlap(26, 11),
            .gapViolation(26, 11), .noFittingSlot(26), .readFailed(26, .failure),
            .writeFailed(26, .failure), .windowUnavailable(26), .invalidFrame(26),
            .superseded, .cleanupFailed(26, primary: .writeFailed(26, .failure), error: .cannotComplete)
        ]
        for failure in timeouts { XCTAssertTrue(failure.isTimeout, "\(failure)") }
        for failure in refusals { XCTAssertFalse(failure.isTimeout, "\(failure)") }
    }

    func testTwoTimeoutsBackOffInsteadOfFloating() throws {
        // the MacBook case: the move's own layout and the 250 ms retry both
        // ran out of time with nothing read back
        harness.failure = .deadlineExceeded
        recovery.note(failedAdmission([26], failure: .deadlineExceeded))
        harness.fire()

        XCTAssertTrue(harness.floated.isEmpty, "a timeout is not a refusal")
        XCTAssertEqual(recovery.pendingWindowIDs, [26], "still tracked, not orphaned")
        XCTAssertEqual(recovery.phase(of: 26), .awaitingRetry)
        XCTAssertEqual(harness.scheduled.map(\.delay), [0.25, 0.5], "the next retry waits longer")
        XCTAssertEqual(try XCTUnwrap(harness.attempts.first).keepOnTimeout, false)
        XCTAssertTrue(harness.clearedUnverified.isEmpty)
    }

    func testRetriesThatKeepTimingOutEndTiledAndUnverifiedNeverFloated() {
        harness.failure = .deadlineExceeded
        recovery.note(failedAdmission([26], failure: .deadlineExceeded))
        for _ in 0...recovery.timeoutRetryDelays.count { harness.fire() }

        XCTAssertEqual(harness.attempts.map(\.keepOnTimeout), [false, false, true],
                       "only the last retry the bound allows keeps a timeout")
        XCTAssertEqual(harness.attempts.map(\.bypass), [[26: 7], [26: 7], [26: 7]],
                       "every retry still reaches back to the admission's own generation")
        XCTAssertEqual(harness.scheduled.map(\.delay), [0.25, 0.5, 1.0])
        XCTAssertTrue(harness.floated.isEmpty)
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty, "the engine kept it tiled")
        XCTAssertFalse(harness.calls.contains("clearUnverified"),
                       "the key stays marked until a layout is accepted")
        XCTAssertFalse(harness.calls.contains("retileAfterFallback"))

        harness.fire()
        XCTAssertEqual(harness.attempts.count, 3, "bounded: nothing re-arms after the keep")
    }

    func testAnAXMessagingTimeoutBacksOffToo() {
        harness.failure = .readFailed(26, .cannotComplete)
        recovery.note(failedAdmission([26], failure: .deadlineExceeded))
        harness.fire()

        XCTAssertTrue(harness.floated.isEmpty)
        XCTAssertEqual(recovery.phase(of: 26), .awaitingRetry)
    }

    func testARefusalAfterATimeoutStillFloats() {
        harness.failures = [.deadlineExceeded, .geometryMismatch(26)]
        recovery.note(failedAdmission([26], failure: .deadlineExceeded))
        harness.fire()
        XCTAssertTrue(harness.floated.isEmpty)

        harness.fire()

        XCTAssertEqual(harness.floated.map(\.id), [26], "the app answered, and it said no")
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertEqual(harness.calls,
                       ["attempt", "attempt", "floatInPlace", "clearUnverified", "retileAfterFallback"])
    }

    func testAGeometryRefusalAfterATimedOutAdmissionStillFloats() {
        // the refusal policy is unchanged whatever the admission ran into
        harness.failure = .geometryMismatch(26)
        recovery.note(failedAdmission([26], failure: .deadlineExceeded))
        harness.fire()

        XCTAssertEqual(harness.floated.map(\.id), [26])
        XCTAssertEqual(harness.scheduled.count, 1, "no backoff for a refusal")
    }

    func testALastTimeoutWithNothingWrittenIsHeldNotFloated() {
        // the engine keeps only a pass that sent every window its frame. one
        // that timed out before that has no tile to keep, and a timeout still
        // floats nothing
        harness.failure = .deadlineExceeded
        harness.keepsTimeouts = false
        recovery.note(failedAdmission([26], failure: .deadlineExceeded))
        for _ in 0...recovery.timeoutRetryDelays.count { harness.fire() }

        XCTAssertTrue(harness.floated.isEmpty)
        XCTAssertEqual(recovery.pendingWindowIDs, [26], "tracked: in no tree, but not orphaned")
        XCTAssertEqual(recovery.phase(of: 26), .held)

        harness.fire()
        recovery.noteEvidence(for: 26)
        XCTAssertEqual(harness.attempts.count, 3, "held means no timer and no attempt of its own")

        recovery.note(TilingEngine.AdmissionResult(
            workspace: 2, screen: screen, generation: 30, insertedIDs: [26],
            publishedIDs: [11, 26], failure: nil, restoredIDs: [], refusedIDs: []))
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty, "a layout that tiles it releases it")
    }

    func testAUserFloatDuringTheBackoffCancelsIt() {
        harness.failure = .deadlineExceeded
        recovery.note(failedAdmission([26], failure: .deadlineExceeded))
        harness.fire()
        harness.floatingIDs.insert(26)

        harness.fire()

        XCTAssertEqual(harness.attempts.count, 1)
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertTrue(harness.floated.isEmpty, "the user already floated it")
    }

    func testTheFallbackAsksTheEngineToClearTheMark() {
        recovery.note(failedAdmission([26]))
        harness.fire()
        // whether it actually clears is the engine's call — it saw every
        // attempt that marked the key, and this recovery saw two of them.
        // TilingEngineMembershipTransactionTests pins the refusal.
        XCTAssertEqual(harness.clearedUnverified.map(\.workspace), [2])
    }

    func testTheFallbackDoesNothingBesidesAttemptFloatClearAndRetile() {
        recovery.note(failedAdmission([26]))
        harness.fire()

        XCTAssertEqual(harness.calls,
                       ["attempt", "floatInPlace", "clearUnverified", "retileAfterFallback"],
                       "no routing, no workspace move, no second attempt")
    }

    // MARK: - the incumbents a refused pass left out of the tree

    func testTheFallbackRetilesTheKeyOnceSoIncumbentsAreAdmittedAlone() {
        // a returned incumbent's node was pruned while it was hidden, and the
        // pass that would have put it back was refused. one ordinary retile
        // with the newcomer now floating is what puts it in a tree.
        recovery.note(failedAdmission([26]))
        harness.fire()

        XCTAssertEqual(harness.floated.map(\.id), [26])
        XCTAssertEqual(harness.retiles.map(\.workspace), [2])
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty, "the retile tiled the incumbent")
    }

    func testAnIncumbentTheFallbackRetileCannotTileIsHeldNotFloated() {
        harness.leftovers = [11]
        recovery.note(failedAdmission([26]))
        harness.fire()

        XCTAssertEqual(recovery.pendingWindowIDs, [11])
        XCTAssertEqual(recovery.phase(of: 11), .held)
        XCTAssertEqual(harness.floated.map(\.id), [26], "the incumbent is not floated")
        XCTAssertEqual(harness.scheduled.count, 1, "no second timer")
        XCTAssertEqual(harness.retiles.count, 1, "one retile, not a loop")
    }

    func testAHeldIncumbentGetsNoAttemptOfItsOwn() {
        harness.leftovers = [11]
        recovery.note(failedAdmission([26]))
        harness.fire()
        let attempts = harness.attempts.count

        recovery.noteEvidence(for: 11)
        harness.fire()

        XCTAssertEqual(harness.attempts.count, attempts)
        XCTAssertEqual(recovery.phase(of: 11), .held)
    }

    func testAPublishedLayoutReleasesAHeldIncumbent() {
        harness.leftovers = [11]
        recovery.note(failedAdmission([26]))
        harness.fire()
        XCTAssertEqual(recovery.pendingWindowIDs, [11])

        recovery.note(TilingEngine.AdmissionResult(
            workspace: 2, screen: screen, generation: 9, insertedIDs: [],
            publishedIDs: [11], failure: nil, restoredIDs: [], refusedIDs: []))

        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
    }

    func testAnExplicitRemovalReleasesAHeldIncumbent() {
        harness.leftovers = [11]
        recovery.note(failedAdmission([26]))
        harness.fire()

        recovery.cancel(11, reason: "user floated it")

        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
    }

    // MARK: - what the log says happens next

    func testAPreflightRefusalIsNotLoggedAsAScheduledRetry() {
        let judged = AdmissionRecovery.strandedLog(ids: [26], workspace: 2,
                                                   retryIn: nil, cause: nil)
        XCTAssertTrue(judged.hasPrefix("admission refusal judged: ids=[26] ws2"), judged)
        XCTAssertFalse(judged.contains("retry scheduled"), judged)
        XCTAssertFalse(judged.contains("ms"), judged)

        let scheduled = AdmissionRecovery.strandedLog(ids: [27], workspace: 2,
                                                      retryIn: 250, cause: nil)
        XCTAssertTrue(scheduled.hasPrefix("admission retry scheduled: ids=[27] ws2 in 250ms"),
                      scheduled)
    }

    func testTheRetryCannotReArmItself() {
        recovery.note(failedAdmission([26]))
        harness.fire()
        XCTAssertEqual(harness.scheduled.count, 1)
        XCTAssertEqual(harness.attempts.count, 1)
    }

    func testASecondFailedAdmissionForAPendingWindowDoesNotGiveItAnotherRetry() {
        recovery.note(failedAdmission([26]))
        recovery.note(failedAdmission([26]))
        XCTAssertEqual(harness.scheduled.count, 1)
    }

    // MARK: - multiple newcomers

    func testOneFailingNewcomerDoesNotFloatTheOthers() throws {
        harness.place = [26]
        recovery.note(failedAdmission([26, 27], published: [11]))
        XCTAssertEqual(recovery.pendingWindowIDs, [26, 27])

        harness.fire()

        XCTAssertEqual(try XCTUnwrap(harness.attempts.first).newcomers, [26, 27])
        XCTAssertEqual(harness.floated.map(\.id), [27])
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
    }

    // MARK: - unreadable newcomer

    func testUnreadableNewcomerStaysPendingWithNoSecondTimer() {
        harness.readable.remove(26)
        recovery.note(failedAdmission([26]))
        harness.fire()

        XCTAssertEqual(recovery.pendingWindowIDs, [26])
        XCTAssertEqual(recovery.phase(of: 26), .awaitingEvidence)
        XCTAssertEqual(harness.scheduled.count, 1, "no renewed timer")
        XCTAssertTrue(harness.attempts.isEmpty, "nothing is attempted on a window we cannot read")
        XCTAssertTrue(harness.floated.isEmpty, "no frame is invented for it")
    }

    func testEvidenceGivesAnUnreadableNewcomerItsOneAttempt() {
        harness.readable.remove(26)
        recovery.note(failedAdmission([26]))
        harness.fire()

        harness.readable.insert(26)
        harness.place = [26]
        recovery.noteEvidence(for: 26)

        XCTAssertEqual(harness.attempts.count, 1)
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertEqual(harness.scheduled.count, 1, "evidence is not a new timer")
    }

    func testEvidenceOnAStillUnreadableNewcomerChangesNothing() {
        harness.readable.remove(26)
        recovery.note(failedAdmission([26]))
        harness.fire()
        recovery.noteEvidence(for: 26)
        recovery.noteEvidence(for: 26)

        XCTAssertEqual(recovery.pendingWindowIDs, [26])
        XCTAssertTrue(harness.attempts.isEmpty)
        XCTAssertEqual(harness.scheduled.count, 1)
    }

    // MARK: - hidden workspace

    func testHiddenWorkspaceRevealGivesOneAttemptThenTheSamePolicy() {
        harness.visibleWorkspaces = []
        recovery.note(failedAdmission([26]))
        harness.fire()
        XCTAssertEqual(recovery.phase(of: 26), .awaitingEvidence)
        XCTAssertTrue(harness.attempts.isEmpty)

        harness.visibleWorkspaces = [2]
        recovery.noteEvidence(for: 26)

        XCTAssertEqual(harness.attempts.count, 1)
        XCTAssertEqual(harness.floated.map(\.id), [26])
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
    }

    // MARK: - scratchpad

    func testScratchpadAdmissionIsNeverTracked() {
        recovery.note(failedAdmission([26], workspace: TilingEngine.scratchpadWorkspace))
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertTrue(harness.scheduled.isEmpty)
    }

    // MARK: - cancellation

    func testACloseCancelsTheRetry() {
        recovery.note(failedAdmission([26]))
        harness.alive.remove(26)
        recovery.forget(26)
        harness.fire()

        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertTrue(harness.attempts.isEmpty)
    }

    func testAVanishedWindowIsDroppedWhenTheRetryFires() {
        recovery.note(failedAdmission([26]))
        harness.alive.remove(26)
        harness.fire()

        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertTrue(harness.attempts.isEmpty)
        XCTAssertTrue(harness.floated.isEmpty)
    }

    func testStopCancelsTheRetry() {
        recovery.note(failedAdmission([26]))
        recovery.cancelAll(reason: "stop")
        harness.fire()
        XCTAssertTrue(harness.attempts.isEmpty)
    }

    func testALaterPressCancelsTheRetry() {
        recovery.note(failedAdmission([26]))
        recovery.cancelAll(reason: "later press")
        harness.fire()
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertTrue(harness.attempts.isEmpty)
    }

    func testAPendingDisplayTransitionHoldsTheRetryInsteadOfTilingMidReconfigure() {
        harness.displayTransitionPending = true
        recovery.note(failedAdmission([26]))
        harness.fire()

        XCTAssertTrue(harness.attempts.isEmpty, "nothing is tiled while the screens are moving")
        XCTAssertEqual(recovery.phase(of: 26), .awaitingEvidence)
        XCTAssertEqual(harness.scheduled.count, 1, "and no new timer")
    }

    func testALockBeforeTheRetryComesDueKeepsItForTheFirstPollAfterUnlock() throws {
        // a cross-monitor move whose first layout failed, then a lock inside
        // the 250 ms. the attempt would read the lock screen's partial list
        recovery.note(failedAdmission([26], generation: 42))
        harness.sessionInterrupted = true
        harness.fire()

        XCTAssertTrue(harness.attempts.isEmpty, "no attempt from the partial list")
        XCTAssertEqual(recovery.pendingWindowIDs, [26], "not dropped")
        XCTAssertEqual(recovery.phase(of: 26), .awaitingEvidence)
        XCTAssertEqual(harness.scheduled.count, 1, "and no new timer")

        // polls inside the span offer evidence too; they change nothing
        recovery.noteEvidence(for: 26)
        XCTAssertTrue(harness.attempts.isEmpty)

        harness.sessionInterrupted = false
        harness.place = [26]
        recovery.noteEvidence(for: 26)

        XCTAssertEqual(harness.attempts.count, 1, "its one attempt, after the span")
        XCTAssertEqual(try XCTUnwrap(harness.attempts.first).bypass, [26: 42])
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertTrue(harness.floated.isEmpty)
    }

    func testALockHoldsAJudgedRefusalInsteadOfFloatingAndRetilingFromIt() {
        // the fallback's retile would read the same partial list
        recovery.note(failedAdmission([], published: [11], failure: nil, restored: [],
                                      refused: [26]))
        harness.sessionInterrupted = true
        harness.fire()

        XCTAssertTrue(harness.floated.isEmpty)
        XCTAssertTrue(harness.retiles.isEmpty)
        XCTAssertEqual(recovery.phase(of: 26), .awaitingEvidence)

        harness.sessionInterrupted = false
        recovery.noteEvidence(for: 26)

        XCTAssertTrue(harness.attempts.isEmpty, "its attempt was already spent")
        XCTAssertEqual(harness.floated.map(\.id), [26])
        XCTAssertEqual(harness.retiles.count, 1)
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
    }

    func testADisplayChangeCancelsTheRetry() {
        recovery.note(failedAdmission([26]))
        recovery.cancelAll(reason: "display change")
        harness.fire()
        XCTAssertTrue(harness.attempts.isEmpty)
    }

    func testAUserFloatCancelsTheRetry() {
        recovery.note(failedAdmission([26]))
        harness.floatingIDs.insert(26)
        harness.fire()

        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertTrue(harness.attempts.isEmpty)
        XCTAssertTrue(harness.floated.isEmpty, "the user already floated it")
    }

    func testAWorkspaceMoveCancelsTheRetry() {
        recovery.note(failedAdmission([26]))
        harness.workspaces[26] = 3
        harness.fire()
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertTrue(harness.attempts.isEmpty)
    }

    func testAScreenChangeCancelsTheRetry() {
        recovery.note(failedAdmission([26]))
        harness.homeScreen = other
        harness.fire()
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertTrue(harness.attempts.isEmpty)
    }

    func testANewerLayoutThatTilesTheNewcomerResolvesIt() {
        recovery.note(failedAdmission([26]))
        recovery.note(TilingEngine.AdmissionResult(
            workspace: 2, screen: screen, generation: 9, insertedIDs: [],
            publishedIDs: [11, 26], failure: nil, restoredIDs: [], refusedIDs: []))

        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        harness.fire()
        XCTAssertTrue(harness.attempts.isEmpty)
    }

    func testCancellingOneWindowLeavesTheOtherItsRetry() throws {
        recovery.note(failedAdmission([26, 27], published: [11]))
        recovery.cancel(26, reason: "user floated it")
        harness.place = [27]
        harness.fire()

        XCTAssertEqual(harness.attempts.count, 1)
        XCTAssertEqual(try XCTUnwrap(harness.attempts.first).newcomers, [27])
    }

    // MARK: - click focus ordering

    func testAClickPrefersARecoveryNewcomerOverTheTiledIncumbentUnderIt() {
        let overlap = CGRect(x: 100, y: 100, width: 400, height: 300)
        let target = WindowManager.clickFocusTarget(
            at: CGPoint(x: 200, y: 200),
            overlayFrames: [(id: 26, frame: overlap)],
            tiledPositions: [11: CGRect(x: 0, y: 0, width: 800, height: 600)])

        XCTAssertEqual(target?.id, 26)
        XCTAssertEqual(target?.reason, "syncTracker-floating")
    }

    func testARecoveryNewcomerSaysSoInsteadOfClaimingToBeFloating() {
        let overlap = CGRect(x: 100, y: 100, width: 400, height: 300)
        let target = WindowManager.clickFocusTarget(
            at: CGPoint(x: 200, y: 200),
            overlayFrames: [(id: 26, frame: overlap)],
            tiledPositions: [11: CGRect(x: 0, y: 0, width: 800, height: 600)],
            recoveryIDs: [26])

        XCTAssertEqual(target?.id, 26)
        XCTAssertEqual(target?.reason, "syncTracker-recovery",
                       "it is in no tree and not floating either; the log should not say floating")
    }

    func testTheWindowListBeatsTheFrameOfAFloaterATileBuried() {
        // the floater's frame covers the point, but the tile is on top there
        let target = WindowManager.clickFocusTarget(
            at: CGPoint(x: 200, y: 200),
            overlayFrames: [(id: 12, frame: CGRect(x: 100, y: 100, width: 400, height: 300))],
            tiledPositions: [11: CGRect(x: 0, y: 0, width: 800, height: 600)],
            stackHit: 11)

        XCTAssertEqual(target?.id, 11)
        XCTAssertEqual(target?.reason, "syncTracker-tiled")
    }

    func testAnUnknownWindowListHitFallsBackToTheFrames() {
        let target = WindowManager.clickFocusTarget(
            at: CGPoint(x: 200, y: 200),
            overlayFrames: [(id: 26, frame: CGRect(x: 100, y: 100, width: 400, height: 300))],
            tiledPositions: [11: CGRect(x: 0, y: 0, width: 800, height: 600)],
            recoveryIDs: [26],
            stackHit: 999)

        XCTAssertEqual(target?.id, 26)
        XCTAssertEqual(target?.reason, "syncTracker-recovery")
    }

    func testAClickOutsideEveryOverlayStillPicksTheTile() {
        let target = WindowManager.clickFocusTarget(
            at: CGPoint(x: 20, y: 20),
            overlayFrames: [(id: 26, frame: CGRect(x: 100, y: 100, width: 400, height: 300))],
            tiledPositions: [11: CGRect(x: 0, y: 0, width: 800, height: 600)])

        XCTAssertEqual(target?.id, 11)
        XCTAssertEqual(target?.reason, "syncTracker-tiled")
    }

    // MARK: - the bookkeeping every pass owes

    /// The drift monitor's re-apply runs the same pass the ordinary retile
    /// does, so a window it strands has to reach the recovery either way.
    func testAnAdmissionPassReportsWhatItStrandedWhoeverRanIt() throws {
        let passScreen = PrimaryRecoveryScreen()
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { [passScreen] }),
                                  frameSizingIOFactory: acceptingFrameSizingIOFactory())
        let revalidation = MinimaRevalidation()
        let pass = AdmissionPass(engine: engine, revalidation: revalidation, recovery: recovery)
        let incumbent = makeWindow(id: 61)
        let newcomer = makeWindow(id: 62)
        XCTAssertEqual(engine.forceInsertWindow(incumbent, toWorkspace: 4, on: passScreen),
                       .inserted)
        newcomer.observedMinSize = CGSize(width: 100_000, height: 100_000)

        let result = pass.run([incumbent, newcomer], onWorkspace: 4, screen: passScreen)

        XCTAssertEqual(result.strandedIDs, [62])
        XCTAssertEqual(recovery.pendingWindowIDs, [62], "the pass told the recovery")
    }

    func testAnAdmissionPassSpendsTheRevalidationMarkerItConsumed() throws {
        let passScreen = PrimaryRecoveryScreen()
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { [passScreen] }),
                                  frameSizingIOFactory: acceptingFrameSizingIOFactory())
        let revalidation = MinimaRevalidation()
        revalidation.workspaceFor = { _ in 5 }
        let pass = AdmissionPass(engine: engine, revalidation: revalidation, recovery: recovery)
        let parked = makeWindow(id: 63)
        revalidation.park(63, toWorkspace: 5, screen: passScreen,
                          sourceWorkspace: 4, sourceScreen: passScreen)
        XCTAssertEqual(revalidation.pendingWindowIDs, [63])

        _ = pass.run([parked], onWorkspace: 5, screen: passScreen)

        XCTAssertTrue(revalidation.pendingWindowIDs.isEmpty, "the marker is spent on the reveal")
    }
}

/// Drives every seam `AdmissionRecovery` has, and records what it asked for.
private final class RecoveryHarness {
    struct Attempt {
        let workspace: Int
        let bypass: [CGWindowID: UInt64]
        var keepOnTimeout = false
        var newcomers: Set<CGWindowID> { Set(bypass.keys) }
    }

    let screen: NSScreen
    var homeScreen: NSScreen
    var visibleWorkspaces: Set<Int> = [2]
    var workspaces: [CGWindowID: Int] = [26: 2, 27: 2, 11: 2]
    var floatingIDs: Set<CGWindowID> = []
    var alive: Set<CGWindowID> = [11, 26, 27]
    var readable: Set<CGWindowID> = [11, 26, 27]

    /// ids the next attempt manages to tile
    var place: Set<CGWindowID> = []
    /// failures for the next attempts, in order; `failure` once it runs out
    var failures: [FrameSizingFailure?] = []
    /// the engine keeping a timed-out tile: a keepOnTimeout attempt that
    /// times out places every newcomer it was given
    var keepsTimeouts = true
    /// ids the fallback retile leaves visible, nonfloating and in no tree
    var leftovers: Set<CGWindowID> = []
    var failure: FrameSizingFailure? = .geometryMismatch(11)
    var displayTransitionPending = false
    var sessionInterrupted = false

    private(set) var scheduled: [(delay: TimeInterval, body: () -> Void)] = []
    private(set) var attempts: [Attempt] = []
    private(set) var floated: [(id: CGWindowID, reason: String)] = []
    private(set) var clearedUnverified: [(workspace: Int, screen: NSScreen)] = []
    private(set) var retiles: [(workspace: Int, screen: NSScreen)] = []
    /// every action seam the recovery invoked, in order
    private(set) var calls: [String] = []
    private var windows: [CGWindowID: HyprWindow] = [:]

    init(screen: NSScreen) {
        self.screen = screen
        self.homeScreen = screen
        for id in [CGWindowID(11), 26, 27] { windows[id] = makeWindow(id: id) }
    }

    func install(on recovery: AdmissionRecovery) {
        recovery.schedule = { [weak self] delay, body in self?.scheduled.append((delay, body)) }
        recovery.workspaceFor = { [weak self] id in self?.workspaces[id] }
        recovery.homeScreenForWorkspace = { [weak self] _ in self?.homeScreen }
        recovery.isWorkspaceVisible = { [weak self] ws in self?.visibleWorkspaces.contains(ws) ?? false }
        recovery.isFloating = { [weak self] id in self?.floatingIDs.contains(id) ?? false }
        recovery.liveWindow = { [weak self] id in
            guard let self, self.alive.contains(id) else { return nil }
            return self.windows[id]
        }
        recovery.isReadable = { [weak self] window in
            self?.readable.contains(window.windowID) ?? false
        }
        recovery.isDisplayTransitionPending = { [weak self] in
            self?.displayTransitionPending ?? false
        }
        recovery.isSessionInterrupted = { [weak self] in
            self?.sessionInterrupted ?? false
        }
        recovery.attempt = { [weak self] workspace, _, bypass, keepOnTimeout in
            guard let self else { return AdmissionRecovery.AttemptResult() }
            self.calls.append("attempt")
            self.attempts.append(Attempt(workspace: workspace, bypass: bypass,
                                         keepOnTimeout: keepOnTimeout))
            let failure = self.failures.isEmpty ? self.failure : self.failures.removeFirst()
            if keepOnTimeout, self.keepsTimeouts, let failure, failure.isTimeout {
                return AdmissionRecovery.AttemptResult(placed: Set(bypass.keys), failure: failure)
            }
            return AdmissionRecovery.AttemptResult(placed: self.place, failure: failure)
        }
        recovery.floatInPlace = { [weak self] window, reason in
            self?.calls.append("floatInPlace")
            self?.floated.append((window.windowID, reason))
        }
        recovery.clearUnverified = { [weak self] workspace, screen in
            self?.calls.append("clearUnverified")
            self?.clearedUnverified.append((workspace, screen))
        }
        recovery.retileAfterFallback = { [weak self] workspace, screen in
            guard let self else { return [] }
            self.calls.append("retileAfterFallback")
            self.retiles.append((workspace, screen))
            return self.leftovers
        }
    }

    /// Run every timer armed so far, once.
    func fire() {
        let pending = scheduled
        for entry in pending { entry.body() }
    }
}

private final class OtherRecoveryScreen: NSScreen {
    override func isEqual(_ object: Any?) -> Bool {
        guard let screen = object as? NSScreen else { return false }
        return self === screen
    }
    override var hash: Int { ObjectIdentifier(self).hashValue }
    override var frame: NSRect { NSRect(x: 5000, y: 0, width: 1200, height: 900) }
    override var visibleFrame: NSRect { frame }
}

/// The two places a window ends up floating without the user asking: the
/// recovery fallback, and a float→tile the tree refused. Both must leave the
/// controller's set and the window's own flag saying the same thing.
final class FloatingFlagConsistencyTests: XCTestCase {

    private var stateCache: WindowStateCache!
    private var displayManager: DisplayManager!
    private var workspaceManager: WorkspaceManager!
    private var tilingEngine: TilingEngine!
    private var controller: FloatingWindowController!
    private var screen: NSScreen!
    private var workspace: Int!

    override func setUpWithError() throws {
        displayManager = DisplayManager()
        guard let primary = displayManager.screens.first else {
            throw XCTSkip("no NSScreen available — test requires a display")
        }
        screen = primary
        stateCache = WindowStateCache()
        workspaceManager = WorkspaceManager(displayManager: displayManager)
        tilingEngine = TilingEngine(displayManager: displayManager,
                                    frameSizingIOFactory: acceptingFrameSizingIOFactory())
        let focusBorder = FocusBorder()
        controller = FloatingWindowController(
            stateCache: stateCache,
            suppressions: SuppressionRegistry(),
            workspaceManager: workspaceManager,
            tilingEngine: tilingEngine,
            displayManager: displayManager,
            accessibility: AccessibilityManager(),
            cursorManager: CursorManager(),
            focusController: FocusStateController(focusBorder: focusBorder),
            focusBorder: focusBorder,
            dimmingOverlay: DimmingOverlay()
        )
        controller.animatedRetile = { body in body() }
        workspace = workspaceManager.workspaceForScreen(screen)
    }

    func testFloatInPlaceSetsBothFlags() {
        let window = makeWindow(id: 771)
        XCTAssertFalse(window.isFloating)

        controller.floatInPlace(window, reason: "admission recovery")

        XCTAssertTrue(stateCache.floatingWindowIDs.contains(771))
        XCTAssertTrue(window.isFloating)
        XCTAssertNotNil(stateCache.cachedWindows[771])
    }

    func testARefusedFloatToTileLeavesTheWindowFloatingAndFlashes() throws {
        try XCTSkipIf(workspaceManager.isMonitorDisabled(screen), "monitor is disabled here")
        // maxDepth 1 fills at two leaves, so a third window is refused
        tilingEngine.maxSplitsPerMonitor[screen.localizedName] = 1
        for id in [CGWindowID(781), 782] {
            XCTAssertEqual(tilingEngine.forceInsertWindow(makeWindow(id: id),
                                                          toWorkspace: workspace, on: screen),
                           .inserted)
        }

        let refused = makeWindow(id: 783)
        refused.observedMinSize = CGSize(width: 100_000, height: 100_000)
        refused.isFloating = true
        stateCache.floatingWindowIDs.insert(refused.windowID)
        var flashed: [(CGWindowID, TilingEngine.ForceInsertFailure)] = []
        controller.rejectFloatToTile = { flashed.append(($0.windowID, $1)) }

        controller.toggle(refused, on: screen, in: workspace)

        XCTAssertTrue(stateCache.floatingWindowIDs.contains(783), "still a floater")
        XCTAssertTrue(refused.isFloating, "and its own flag agrees")
        XCTAssertEqual(flashed.map(\.0), [783])
        XCTAssertEqual(flashed.map(\.1), [.noFittingSlot])
        XCTAssertEqual(Set(tilingEngine.windowIDs(inTreeForWorkspace: workspace, screen: screen)),
                       [781, 782], "the tree the refusal left alone")
    }
}

final class FloatToTileRejectionMessageTests: XCTestCase {
    func testCapacityAndGeometryFailuresUseDifferentMessages() {
        XCTAssertEqual(FloatToTileRejectionMessage.text(for: .noFittingSlot),
                       "No room to tile this window")
        XCTAssertEqual(FloatToTileRejectionMessage.text(
            for: .layoutRejected(.geometryMismatch(91))),
            "This window did not accept the tile size")
        XCTAssertEqual(FloatToTileRejectionMessage.text(
            for: .layoutRejected(.writeFailed(91, .cannotComplete))),
            "Could not apply the tiled layout")
    }
}

final class FloatingRaiseRegressionTests: XCTestCase {
    private func makeController(tiledPID: pid_t, floatingPID: pid_t)
        -> (FloatingWindowController, WindowStateCache, WorkspaceManager, FocusStateController) {
        let screen = PrimaryRecoveryScreen()
        let display = DisplayManager(screenSource: { [screen] })
        let cache = WindowStateCache()
        let workspaces = WorkspaceManager(displayManager: display)
        workspaces.initializeMonitors()
        let tiled = makeWindow(id: 11, pid: tiledPID)
        let floating = makeWindow(id: 12, pid: floatingPID)
        tiled.cachedFrame = CGRect(x: 0, y: 0, width: 500, height: 500)
        floating.cachedFrame = CGRect(x: 50, y: 50, width: 300, height: 300)
        cache.cachedWindows = [11: tiled, 12: floating]
        cache.knownWindowIDs = [11, 12]
        cache.floatingWindowIDs = [12]
        cache.tiledPositions = [11: tiled.cachedFrame!]
        let workspace = workspaces.workspaceForScreen(screen)
        workspaces.assignWindow(11, toWorkspace: workspace)
        workspaces.assignWindow(12, toWorkspace: workspace)
        let border = FocusBorder()
        let focus = FocusStateController(focusBorder: border)
        focus.recordFocus(11, reason: "test")
        let controller = FloatingWindowController(
            stateCache: cache, suppressions: SuppressionRegistry(), workspaceManager: workspaces,
            tilingEngine: TilingEngine(displayManager: display), displayManager: display,
            accessibility: AccessibilityManager(), cursorManager: CursorManager(),
            focusController: focus, focusBorder: border, dimmingOverlay: DimmingOverlay()
        )
        controller.windowListForZOrder = {
            [
                [kCGWindowNumber as String: CGWindowID(11)],
                [kCGWindowNumber as String: CGWindowID(12)],
            ]
        }
        controller.windowFrameForZOrder = { $0.cachedFrame }
        // the tile's app is in front unless a test says otherwise
        controller.frontmostPID = { tiledPID }
        return (controller, cache, workspaces, focus)
    }

    private static let coveredStack: [[String: Any]] = [
        [kCGWindowNumber as String: CGWindowID(11)],
        [kCGWindowNumber as String: CGWindowID(12)],
    ]
    private static let raisedStack: [[String: Any]] = [
        [kCGWindowNumber as String: CGWindowID(12)],
        [kCGWindowNumber as String: CGWindowID(11)],
    ]
    private static func popup(pid: pid_t) -> [String: Any] {
        [kCGWindowNumber as String: CGWindowID(99), kCGWindowOwnerPID as String: pid,
         kCGWindowLayer as String: 101,
         kCGWindowBounds as String: CGRect(x: 40, y: 20, width: 220, height: 300).dictionaryRepresentation]
    }

    func testRepeatedPollsDoNotRaiseOrRestoreSameAppFloatingSibling() {
        let (controller, cache, _, _) = makeController(tiledPID: 100, floatingPID: 100)
        var raises: [CGWindowID] = []
        var restores: [CGWindowID] = []
        var queued = 0
        controller.performRaise = { raises.append($0.windowID); return .success }
        controller.restoreFocusWithoutRaise = { restores.append($0.windowID) }
        controller.scheduleAfter = { _, _ in queued += 1 }
        XCTAssertEqual(controller.floatingWindowsBehindTiled(
            floatingWindowIDs: cache.floatingWindowIDs,
            tiledPositions: cache.tiledPositions
        ), [12], "the floater must physically start behind the tile")

        for _ in 0..<4 { controller.raiseBehind() }

        XCTAssertEqual(raises, [])
        XCTAssertEqual(restores, [])
        XCTAssertEqual(queued, 0)
    }

    func testCrossAppRaiseThatTakesFocusRestoresCapturedFocus() {
        let (controller, cache, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var raises: [CGWindowID] = []
        var restores: [CGWindowID] = []
        var queued: (() -> Void)?
        var front: pid_t = 100
        controller.frontmostPID = { front }
        controller.performRaise = { raises.append($0.windowID); return .success }
        controller.restoreFocusWithoutRaise = { restores.append($0.windowID) }
        controller.scheduleAfter = { _, body in queued = body }
        XCTAssertEqual(controller.floatingWindowsBehindTiled(
            floatingWindowIDs: cache.floatingWindowIDs,
            tiledPositions: cache.tiledPositions
        ), [12])

        controller.raiseBehind()
        // the floater's app activated itself when raised
        front = 200
        queued?()

        XCTAssertEqual(raises, [12])
        XCTAssertEqual(restores, [11])
    }

    func testCrossAppRaiseThatKeepsFocusSendsNoRestore() {
        let (controller, _, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var raises: [CGWindowID] = []
        var restores: [CGWindowID] = []
        var queued: (() -> Void)?
        controller.performRaise = { raises.append($0.windowID); return .success }
        controller.restoreFocusWithoutRaise = { restores.append($0.windowID) }
        controller.scheduleAfter = { _, body in queued = body }

        controller.raiseBehind()
        queued?()

        XCTAssertEqual(raises, [12])
        XCTAssertEqual(restores, [], "key-window events would close a menu the tile has open")
    }

    func testRaiseAfterTheUserActivatedAnotherAppRestoresNothing() {
        let (controller, _, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var restores: [CGWindowID] = []
        var queued: (() -> Void)?
        var front: pid_t = 300
        controller.frontmostPID = { front }
        controller.performRaise = { _ in .success }
        controller.restoreFocusWithoutRaise = { restores.append($0.windowID) }
        controller.scheduleAfter = { _, body in queued = body }

        controller.raiseBehind()
        front = 200
        queued?()

        XCTAssertEqual(restores, [], "focus was not the tile's to give back")
    }

    func testHyprFocusChangeInvalidatesQueuedRestoreIncludingABA() {
        let (controller, _, _, focus) = makeController(tiledPID: 100, floatingPID: 200)
        var restores: [CGWindowID] = []
        var queued: (() -> Void)?
        var front: pid_t = 100
        controller.frontmostPID = { front }
        controller.performRaise = { _ in .success }
        controller.restoreFocusWithoutRaise = { restores.append($0.windowID) }
        controller.scheduleAfter = { _, body in queued = body }

        controller.raiseBehind()
        front = 200
        focus.recordFocus(12, reason: "cycleFocus")
        focus.recordFocus(11, reason: "ABA")
        queued?()

        XCTAssertEqual(restores, [])
    }

    func testRemovedHiddenMenuAndScratchpadTargetsCancelQueuedRestore() {
        func restoreCount(after mutate: (
            WindowStateCache, WorkspaceManager, FloatingWindowController
        ) -> Void) -> Int {
            let (controller, cache, workspaces, _) = makeController(tiledPID: 100, floatingPID: 200)
            var restores = 0
            var queued: (() -> Void)?
            var front: pid_t = 100
            controller.frontmostPID = { front }
            controller.performRaise = { _ in .success }
            controller.restoreFocusWithoutRaise = { _ in restores += 1 }
            controller.scheduleAfter = { _, body in queued = body }
            controller.raiseBehind()
            XCTAssertNotNil(queued, "the cross-app raise must queue a restore before invalidation")
            front = 200
            mutate(cache, workspaces, controller)
            queued?()
            return restores
        }

        XCTAssertEqual(restoreCount { _, _, _ in }, 1, "unmutated, the stolen focus goes back")
        XCTAssertEqual(restoreCount { cache, _, _ in cache.knownWindowIDs.remove(11) }, 0)
        XCTAssertEqual(restoreCount { cache, _, _ in cache.hiddenWindowIDs.insert(11) }, 0)
        XCTAssertEqual(restoreCount { _, workspaces, _ in workspaces.removeWindow(11) }, 0)
        XCTAssertEqual(restoreCount { _, _, controller in controller.isMenuTracking = { true } }, 0)
        XCTAssertEqual(restoreCount { _, _, controller in controller.isScratchpadVisible = { true } }, 0)
        XCTAssertEqual(restoreCount { _, _, controller in
            controller.windowListForZOrder = { Self.coveredStack + [Self.popup(pid: 200)] }
        }, 0, "a popup opened in the new front app")
    }

    func testOpenPopupDefersTheRaiseAndRetriesOnce() {
        let (controller, _, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var raises: [CGWindowID] = []
        var restores: [CGWindowID] = []
        var queued: [(TimeInterval, () -> Void)] = []
        var stack = [Self.popup(pid: 100)] + Self.coveredStack
        controller.windowListForZOrder = { stack }
        controller.performRaise = { raises.append($0.windowID); return .success }
        controller.restoreFocusWithoutRaise = { restores.append($0.windowID) }
        controller.scheduleAfter = { delay, body in queued.append((delay, body)) }

        controller.raiseBehind()
        controller.raiseBehind()

        XCTAssertEqual(raises, [])
        XCTAssertEqual(restores, [])
        XCTAssertEqual(queued.map(\.0), [FloatingWindowController.popupRetryDelay],
                       "one pending retry, not one per call")

        // the menu closed before the retry fired
        stack = Self.coveredStack
        let retry = queued.removeFirst().1
        retry()

        XCTAssertEqual(raises, [12])
    }

    func testAPopupOfAnotherAppDoesNotBlockTheRaise() {
        let (controller, _, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var raises: [CGWindowID] = []
        controller.windowListForZOrder = { [Self.popup(pid: 300)] + Self.coveredStack }
        controller.performRaise = { raises.append($0.windowID); return .success }
        controller.scheduleAfter = { _, _ in }

        controller.raiseBehind()

        XCTAssertEqual(raises, [12])
    }

    func testAnIneffectiveRaiseCoolsThePairDown() {
        let (controller, _, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var raises: [CGWindowID] = []
        var queued: (() -> Void)?
        var clock: TimeInterval = 1000
        controller.now = { clock }
        controller.performRaise = { raises.append($0.windowID); return .success }
        controller.scheduleAfter = { _, body in queued = body }

        // the stack never changes: tahoe refused the cross-app raise
        controller.raiseBehind()
        queued?()
        for _ in 0..<5 {
            clock += 1
            controller.raiseBehind()
        }
        XCTAssertEqual(raises, [12], "no retry on every activation and poll")

        clock += controller.throttle.ineffectiveCooldown
        controller.raiseBehind()
        XCTAssertEqual(raises, [12, 12], "the pair gets another try after the cooldown")
    }

    func testAnEffectiveRaiseLeavesThePairFree() {
        let (controller, _, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var raises: [CGWindowID] = []
        var queued: (() -> Void)?
        var clock: TimeInterval = 1000
        var stack = Self.coveredStack
        controller.now = { clock }
        controller.windowListForZOrder = { stack }
        controller.performRaise = { raises.append($0.windowID); stack = Self.raisedStack; return .success }
        controller.scheduleAfter = { _, body in queued = body }

        controller.raiseBehind()
        queued?()
        // the user clicks the tile later and covers the floater again
        clock += 3
        stack = Self.coveredStack
        controller.raiseBehind()

        XCTAssertEqual(raises, [12, 12])
    }

    func testARaiseRightAfterOurOwnRestoreIsALoopAndCoolsDown() {
        let (controller, _, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var raises: [CGWindowID] = []
        var restores: [CGWindowID] = []
        var queued: (() -> Void)?
        var clock: TimeInterval = 1000
        var front: pid_t = 100
        var stack = Self.coveredStack
        controller.now = { clock }
        controller.frontmostPID = { front }
        controller.windowListForZOrder = { stack }
        controller.performRaise = { w in
            raises.append(w.windowID)
            // the floater's app activates itself and comes up
            stack = Self.raisedStack
            front = 200
            return .success
        }
        controller.restoreFocusWithoutRaise = { w in
            // the restore lifted the tile back over the floater
            restores.append(w.windowID)
            stack = Self.coveredStack
            front = 100
        }
        controller.scheduleAfter = { _, body in queued = body }

        controller.raiseBehind()
        queued?()
        clock += 0.2
        queued = nil
        controller.raiseBehind()

        XCTAssertEqual(raises, [12])
        XCTAssertEqual(restores, [11])
        XCTAssertNil(queued, "the loop stops instead of raising again")
    }

    func testAFloaterBehindATileItDoesNotTouchIsLeftAlone() {
        let (controller, cache, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var raises: [CGWindowID] = []
        cache.cachedWindows[12]?.cachedFrame = CGRect(x: 700, y: 50, width: 300, height: 300)
        controller.performRaise = { raises.append($0.windowID); return .success }
        controller.scheduleAfter = { _, _ in }

        controller.raiseBehind()

        XCTAssertEqual(raises, [])
    }

    // MARK: - click re-raise

    private static func entry(_ id: CGWindowID, _ rect: CGRect, layer: Int = 0, pid: pid_t = 100) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
         kCGWindowBounds as String: rect.dictionaryRepresentation]
    }
    private static let tileFrame = CGRect(x: 0, y: 0, width: 500, height: 500)
    private static let floaterFrame = CGRect(x: 50, y: 50, width: 300, height: 300)
    private static let tileOnTop = [entry(11, tileFrame), entry(12, floaterFrame)]
    private static let floaterOnTop = [entry(12, floaterFrame), entry(11, tileFrame)]
    // a click on the tile outside the floater
    private let click = ClickPress(windowID: 11, point: CGPoint(x: 450, y: 450), popupOpen: false)

    private struct ClickHarness {
        var raises: [CGWindowID] = []
        var refocused: [CGWindowID] = []
        var restacks = 0
        var queued: [() -> Void] = []
    }

    private struct ClickRig {
        let controller: FloatingWindowController
        let focus: FocusStateController
        let workspaces: WorkspaceManager
        let harness: () -> ClickHarness
        let run: () -> Void
    }

    /// A controller whose AXRaise lifts the floater over the tile (unless
    /// `raiseWorks` is false) and whose refocus reports `refocusKeeps`.
    private func clickRig(tiledPID: pid_t, floatingPID: pid_t, raiseWorks: Bool = true,
                          refocusKeeps: Bool = true) -> ClickRig {
        let (controller, _, workspaces, focus) = makeController(tiledPID: tiledPID, floatingPID: floatingPID)
        var harness = ClickHarness()
        var stack = Self.tileOnTop
        controller.windowListForZOrder = { stack }
        controller.performRaise = { w in
            harness.raises.append(w.windowID)
            if raiseWorks { stack = Self.floaterOnTop }
            return .success
        }
        controller.refocusClickedTile = { w, done in
            harness.refocused.append(w.windowID)
            done(refocusKeeps)
        }
        controller.onRestack = { harness.restacks += 1 }
        controller.scheduleAfter = { _, body in harness.queued.append(body) }
        let run = {
            while !harness.queued.isEmpty { harness.queued.removeFirst()() }
            // the next click lifts the tile again
            stack = Self.tileOnTop
        }
        return ClickRig(controller: controller, focus: focus, workspaces: workspaces,
                        harness: { harness }, run: run)
    }

    func testASameAppClickPutsTheFloaterBackAndHandsFocusToTheTile() {
        let rig = clickRig(tiledPID: 100, floatingPID: 100)

        rig.controller.raiseAfterClick(click)
        rig.run()

        XCTAssertEqual(rig.harness().raises, [12])
        XCTAssertEqual(rig.harness().refocused, [11], "the tile keeps the keyboard under the floater")
        XCTAssertGreaterThan(rig.harness().restacks, 0, "the cutouts are redrawn for the new stack")
    }

    func testEveryClickGetsItsRaiseWithoutABurstCooldown() {
        let rig = clickRig(tiledPID: 100, floatingPID: 100)

        for _ in 0..<6 {
            rig.controller.raiseAfterClick(click)
            rig.run()
        }

        XCTAssertEqual(rig.harness().raises.count, 6)
    }

    func testAClickInsideTheFloatersFrameLeavesItBuried() {
        let rig = clickRig(tiledPID: 100, floatingPID: 100)

        rig.controller.raiseAfterClick(ClickPress(windowID: 11, point: CGPoint(x: 100, y: 100), popupOpen: false))
        rig.run()

        XCTAssertEqual(rig.harness().raises, [], "raising it would cover the spot the user just clicked")
    }

    func testAClickOnTheFloaterIsNotAClickOnATile() {
        let rig = clickRig(tiledPID: 100, floatingPID: 100)

        rig.controller.raiseAfterClick(ClickPress(windowID: 12, point: CGPoint(x: 100, y: 100), popupOpen: false))
        rig.run()

        XCTAssertEqual(rig.harness().raises, [])
    }

    func testAFloaterStillOnTopNeedsNothing() {
        let rig = clickRig(tiledPID: 100, floatingPID: 100)
        rig.controller.windowListForZOrder = { Self.floaterOnTop }

        rig.controller.raiseAfterClick(click)

        XCTAssertEqual(rig.harness().raises, [])
        XCTAssertTrue(rig.harness().queued.isEmpty)
    }

    func testAnOpenMenuBlocksTheRaise() {
        let rig = clickRig(tiledPID: 100, floatingPID: 100)

        // open when the click went down
        rig.controller.raiseAfterClick(ClickPress(windowID: 11, point: click.point, popupOpen: true))
        rig.run()
        // opened by the click
        rig.controller.windowListForZOrder = { [Self.popup(pid: 100)] + Self.tileOnTop }
        rig.controller.raiseAfterClick(click)
        rig.run()
        // a native menu
        rig.controller.isMenuTracking = { true }
        rig.controller.windowListForZOrder = { Self.tileOnTop }
        rig.controller.raiseAfterClick(click)
        rig.run()

        XCTAssertEqual(rig.harness().raises, [])
    }

    func testFocusThatMovedOnBlocksTheRaise() {
        let rig = clickRig(tiledPID: 100, floatingPID: 100)
        rig.focus.recordFocus(13, reason: "hover elsewhere")

        rig.controller.raiseAfterClick(click)
        rig.run()

        XCTAssertEqual(rig.harness().raises, [])
    }

    func testAFloaterOnAnotherWorkspaceIsLeftAlone() {
        let rig = clickRig(tiledPID: 100, floatingPID: 100)
        let workspace = rig.workspaces.workspaceFor(11) ?? 1
        rig.workspaces.moveWindow(12, toWorkspace: workspace == 9 ? 8 : 9)

        rig.controller.raiseAfterClick(click)
        rig.run()

        XCTAssertEqual(rig.harness().raises, [])
    }

    func testARaiseThatDoesNothingCoolsThePairDown() {
        let rig = clickRig(tiledPID: 100, floatingPID: 200, raiseWorks: false)

        rig.controller.raiseAfterClick(click)
        rig.run()
        rig.controller.raiseAfterClick(click)
        rig.run()

        XCTAssertEqual(rig.harness().raises, [12], "Tahoe refused the cross-app raise once; no retry every click")
        XCTAssertEqual(rig.harness().refocused, [], "the tile is still on top and still key")
    }

    func testARefocusThatMissesCoolsThePairDown() {
        let rig = clickRig(tiledPID: 100, floatingPID: 100, refocusKeeps: false)

        rig.controller.raiseAfterClick(click)
        rig.run()
        rig.controller.raiseAfterClick(click)
        rig.run()

        XCTAssertEqual(rig.harness().raises, [12], "a flicker per click with no gain stops after one try")
    }

    func testACrossAppRestoreThatLiftsTheTileAgainEndsInALoopCooldown() {
        let rig = clickRig(tiledPID: 100, floatingPID: 200)
        let controller = rig.controller
        var front: pid_t = 100
        var stack = Self.tileOnTop
        var raiseBehindRaises = 0
        controller.frontmostPID = { front }
        controller.windowListForZOrder = { stack }
        controller.performRaise = { _ in
            // the floater's app activated itself when raised
            stack = Self.floaterOnTop
            front = 200
            return .success
        }
        controller.refocusClickedTile = { _, done in
            // giving focus back lifted the tile over the floater again
            stack = Self.tileOnTop
            front = 100
            done(true)
        }

        controller.raiseAfterClick(click)
        rig.run()
        // the activation that restore caused runs raise-behind
        controller.performRaise = { _ in raiseBehindRaises += 1; return .success }
        controller.raiseBehind()

        XCTAssertEqual(raiseBehindRaises, 0, "raise-behind sees our restore and stops the loop")
    }

    func testTheClickedWindowMustBeATile() {
        let rig = clickRig(tiledPID: 100, floatingPID: 100)
        rig.controller.isTiledWindow = { _ in false }

        rig.controller.raiseAfterClick(click)
        rig.run()

        XCTAssertEqual(rig.harness().raises, [], "a newcomer in admission recovery is not a tile")
    }
}

final class MouseTrackingFocusRegressionTests: XCTestCase {
    func testPhysicalTopmostDispatchesFloaterAndExposedTilesWithoutFocusThrough() {
        let tracker = MouseTrackingManager()
        let tiled = makeWindow(id: 11, pid: 100)
        let floating = makeWindow(id: 12, pid: 100)
        let crossAppTile = makeWindow(id: 13, pid: 200)
        var topmost: CGWindowID = 12
        var focused: [CGWindowID] = []
        var recorded: [CGWindowID] = []
        var last: CGWindowID = 11
        tracker.isFocusFollowsMouseEnabled = { true }
        tracker.primaryScreenHeight = { 1000 }
        tracker.mouseLocationNS = { CGPoint(x: 100, y: 900) }
        tracker.hoverThrottleInterval = { 0 }
        tracker.resolveTopmostWindowID = { _ in topmost }
        tracker.floatingWindowIDs = { [12] }
        tracker.isWindowVisible = { $0 == 12 }
        tracker.cachedWindow = { [11: tiled, 12: floating, 13: crossAppTile][$0] }
        tracker.tiledPositions = {
            [
                11: CGRect(x: 0, y: 0, width: 500, height: 500),
                13: CGRect(x: 0, y: 0, width: 500, height: 500),
            ]
        }
        tracker.lastFocusedID = { last }
        tracker.recordFocus = { id, _ in recorded.append(id); last = id }
        tracker.onFocusForFFM = { focused.append($0.windowID) }

        tracker.handleMouseMove()
        tracker.handleMouseMove()
        topmost = 99
        tracker.handleMouseMove()
        topmost = 11
        tracker.handleMouseMove()
        topmost = 13
        tracker.handleMouseMove()

        XCTAssertEqual(recorded, [12, 11, 13])
        XCTAssertEqual(focused, [12, 11, 13])
    }
}

private final class PrimaryRecoveryScreen: NSScreen {
    override func isEqual(_ object: Any?) -> Bool {
        guard let screen = object as? NSScreen else { return false }
        return self === screen
    }
    override var hash: Int { ObjectIdentifier(self).hashValue }
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 1600, height: 1000) }
    override var visibleFrame: NSRect { frame }
}
