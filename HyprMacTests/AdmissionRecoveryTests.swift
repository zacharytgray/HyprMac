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
        XCTAssertFalse(ActionPolicy.cancelsPendingRecovery(.switchWorkspace(3)))
        XCTAssertFalse(ActionPolicy.cancelsPendingRecovery(.cycleWorkspace(1)))
    }

    func testFocusAndOverlayActionsKeepPendingRecovery() {
        for action: Action in [.focusDirection(.left), .focusFloating, .focusMenuBar,
                               .showKeybinds, .launchApp(bundleID: "com.apple.Safari"),
                               .runCommand(label: "x", command: "/usr/bin/true")] {
            XCTAssertFalse(ActionPolicy.cancelsPendingRecovery(action), "\(action)")
        }
    }

    func testInTreeGeometryActionsKeepPendingRecovery() {
        // they only rework the live tree, which never holds the stranded
        // window, so cancelling here left it with nothing scheduled
        for action: Action in [.resizeDirection(.up), .swapDirection(.left), .toggleSplit] {
            XCTAssertFalse(ActionPolicy.cancelsPendingRecovery(action), "\(action)")
        }
    }

    func testMembershipActionsCancelAPendingRetry() {
        XCTAssertTrue(ActionPolicy.cancelsPendingRecovery(.moveToWorkspace(3)))
        XCTAssertTrue(ActionPolicy.cancelsPendingRecovery(.toggleFloating))
        XCTAssertTrue(ActionPolicy.cancelsPendingRecovery(.moveToNextEmptyWorkspace))
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

    // MARK: - narrowing: a refusal that names some of the newcomers

    func testARefusalNamingOneNewcomerFloatsOnlyItAndRetriesTheRest() {
        recovery.note(failedAdmission([26, 27]))
        harness.failures = [.geometryMismatch(27), nil]
        harness.placements = [[], [26]]

        harness.fire()

        XCTAssertEqual(harness.attempts.map(\.newcomers), [[26, 27], [26]])
        XCTAssertEqual(harness.floated.map(\.id), [27])
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertEqual(harness.calls,
                       ["attempt", "floatInPlace", "clearUnverified", "attempt", "retileAfterFallback"])
        XCTAssertEqual(harness.scheduled.count, 1, "the second pass runs inside the one retry")
    }

    func testAPairFailureNamingTwoNewcomersFloatsBothAndRetriesTheThird() {
        harness.add(28)
        recovery.note(failedAdmission([26, 27, 28]))
        harness.failures = [.overlap(27, 28), nil]
        harness.placements = [[], [26]]

        harness.fire()

        XCTAssertEqual(harness.attempts.map(\.newcomers), [[26, 27, 28], [26]])
        XCTAssertEqual(Set(harness.floated.map(\.id)), [27, 28])
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
    }

    func testAPreWriteDropFloatsWithTheNamedRefuserBeforeTheRetry() {
        // the engine dropped 28 before writing, and the pass it ran for the
        // rest was refused on 27: both go, and 26 gets the pass alone
        harness.add(28)
        recovery.note(failedAdmission([26, 27, 28]))
        harness.failures = [.geometryMismatch(27), nil]
        harness.refusals = [[28], []]
        harness.placements = [[], [26]]

        harness.fire()

        XCTAssertEqual(harness.attempts.map(\.newcomers), [[26, 27, 28], [26]])
        XCTAssertEqual(Set(harness.floated.map(\.id)), [27, 28])
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
    }

    func testARefusalNamingAnIncumbentStillFloatsEveryNewcomer() {
        // nothing says which newcomer squeezed the incumbent, so there is
        // nothing to narrow by
        recovery.note(failedAdmission([26, 27]))
        harness.failure = .geometryMismatch(11)

        harness.fire()

        XCTAssertEqual(harness.attempts.count, 1)
        XCTAssertEqual(harness.floated.map(\.id), [26, 27])
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
    }

    func testARefusalNamingTheOnlyWaitingNewcomerIsTheOrdinaryFallback() {
        recovery.note(failedAdmission([26]))
        harness.failure = .geometryMismatch(26)

        harness.fire()

        XCTAssertEqual(harness.attempts.count, 1, "nothing is left to retry without it")
        XCTAssertEqual(harness.floated.map(\.id), [26])
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
    }

    func testNarrowingIsBoundedAndThenFloatsTheRest() {
        harness.add(28, 29, 30)
        recovery.note(failedAdmission([26, 27, 28, 29, 30]))
        harness.failures = [.geometryMismatch(30), .geometryMismatch(29),
                            .geometryMismatch(28), .geometryMismatch(27)]

        harness.fire()

        XCTAssertEqual(harness.attempts.map(\.newcomers),
                       [[26, 27, 28, 29, 30], [26, 27, 28, 29], [26, 27, 28], [26, 27]])
        XCTAssertEqual(harness.floated.map(\.id), [30, 29, 28, 26, 27],
                       "three rounds, then the fourth refusal floats what is left")
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertEqual(harness.scheduled.count, 1, "narrowing never arms a timer")
    }

    /// a key's rounds share one main-thread budget. once it is spent no
    /// round starts, and the rest float as past the bound
    func testNarrowingStopsOnceTheRoundsBudgetIsSpent() {
        harness.add(28)
        var budgets = 0
        var inside = false
        let attempt = recovery.attempt
        recovery.attempt = { workspace, screen, bypass, keep in
            XCTAssertTrue(inside, "every round runs inside the one budget")
            return attempt(workspace, screen, bypass, keep)
        }
        recovery.sharingOneBudget = { body in
            budgets += 1
            inside = true
            body()
            inside = false
        }
        recovery.budgetLeft = { [harness] in harness!.attempts.count < 2 }
        recovery.note(failedAdmission([26, 27, 28]))
        harness.failures = [.geometryMismatch(28), .geometryMismatch(27), nil]

        harness.fire()

        XCTAssertEqual(harness.attempts.map(\.newcomers), [[26, 27, 28], [26, 27]],
                       "the second round spent the budget; there is no third")
        XCTAssertEqual(harness.floated.map(\.id), [28, 26, 27])
        XCTAssertEqual(budgets, 1, "one budget for the key, not one per round")
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
    }

    /// the fallback retile tiled a pending newcomer the round could not
    /// judge; when its evidence arrives it is resolved, not floated off the
    /// slot it just got
    func testANewcomerTiledMeanwhileIsResolvedNotFloated() {
        harness.readable.remove(26)
        recovery.note(failedAdmission([26]))
        harness.fire()
        XCTAssertEqual(recovery.phase(of: 26), .awaitingEvidence)

        harness.readable.insert(26)
        harness.tiled.insert(26)
        recovery.noteEvidence(for: 26)

        XCTAssertTrue(harness.floated.isEmpty, "a tiled window is not floated")
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
    }

    func testAPreWriteDropFloatsForItsOwnReason() {
        harness.add(28)
        recovery.note(failedAdmission([26, 27, 28]))
        harness.failures = [nil]
        harness.refusals = [[28]]
        harness.placements = [[26, 27]]

        harness.fire()

        XCTAssertEqual(harness.floated.map(\.id), [28])
        XCTAssertTrue(harness.floated[0].reason.contains("retry=noFittingSlot(28)"),
                      "the fallback line names the drop, not the pass that tiled the rest: \(harness.floated[0].reason)")
    }

    func testATimeoutIsNeverNarrowed() {
        recovery.note(failedAdmission([26, 27]))
        harness.failure = .deadlineExceeded

        harness.fire()

        XCTAssertEqual(harness.attempts.count, 1)
        XCTAssertTrue(harness.floated.isEmpty)
        XCTAssertEqual(recovery.pendingWindowIDs, [26, 27], "both back off together")
    }

    func testTheNarrowingRuleReadsTheFailureNotTheRefusalsAlone() {
        XCTAssertEqual(AdmissionRecovery.narrowing(of: [26, 27], refused: [],
                                                   failure: .geometryMismatch(27)), [27])
        XCTAssertEqual(AdmissionRecovery.narrowing(of: [26, 27, 28], refused: [28],
                                                   failure: .geometryMismatch(27)), [27, 28])
        XCTAssertNil(AdmissionRecovery.narrowing(of: [26, 27], refused: [27],
                                                 failure: .geometryMismatch(11)),
                     "a refusal naming an incumbent says nothing about the rest")
        XCTAssertNil(AdmissionRecovery.narrowing(of: [26, 27], refused: [],
                                                 failure: .overlap(26, 27)),
                     "nothing would be left to retry")
        XCTAssertNil(AdmissionRecovery.narrowing(of: [26, 27], refused: [],
                                                 failure: .writeFailed(27, .cannotComplete)),
                     "a timeout is not a refusal")
        XCTAssertNil(AdmissionRecovery.narrowing(of: [26, 27], refused: [], failure: nil))
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

    // MARK: - a key a window just left

    /// A pass on ws2 after a window closed or moved away, refused by an AX
    /// error on the window that should have grown into the gap.
    private func vacatedPass(workspace: Int = 2, vacated: Bool = true,
                             failure: FrameSizingFailure? = .writeFailed(11, .failure),
                             inserted: Set<CGWindowID> = [],
                             published: Set<CGWindowID> = [11]) -> TilingEngine.AdmissionResult {
        TilingEngine.AdmissionResult(workspace: workspace, screen: screen, generation: 7,
                                     insertedIDs: inserted, publishedIDs: published,
                                     failure: failure, restoredIDs: failure == nil ? [] : [11],
                                     refusedIDs: [], vacated: vacated)
    }

    func testAFailedPassOnAVacatedKeyRetilesItAfterAShortDelay() {
        recovery.note(vacatedPass())

        XCTAssertEqual(harness.scheduled.map(\.delay), [0.25])
        harness.fire()
        XCTAssertEqual(harness.vacatedRetiles, [2])
        XCTAssertEqual(harness.scheduled.count, 1, "an accepted retry arms nothing more")
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty, "no newcomer was involved")
    }

    func testAVacatedRetryBacksOffAndStopsAtItsBound() {
        harness.vacatedResults = [vacatedPass(), vacatedPass(), vacatedPass()]
        recovery.note(vacatedPass())

        for _ in 0..<5 { harness.fire() }

        XCTAssertEqual(harness.scheduled.map(\.delay), [0.25, 0.5, 1.0])
        XCTAssertEqual(harness.vacatedRetiles, [2, 2, 2])
    }

    func testATimedOutPassOnAVacatedKeyIsRetriedToo() {
        recovery.note(vacatedPass(failure: .writeFailed(11, .cannotComplete)))
        XCTAssertEqual(harness.scheduled.count, 1)
    }

    func testAGeometryRefusalOnAVacatedKeyIsNotRetried() {
        // the window answered and said no; writing the same frame again
        // would only resize it and roll it back once more
        recovery.note(vacatedPass(failure: .geometryMismatch(11)))
        XCTAssertTrue(harness.scheduled.isEmpty)
    }

    func testAFailedPassThatVacatedNothingIsNotRetried() {
        recovery.note(vacatedPass(vacated: false))
        XCTAssertTrue(harness.scheduled.isEmpty)
    }

    func testAnAcceptedPassOnAVacatedKeyArmsNothing() {
        recovery.note(vacatedPass(failure: nil))
        XCTAssertTrue(harness.scheduled.isEmpty)
    }

    func testOnlyOneVacatedRetryIsArmedPerKey() {
        recovery.note(vacatedPass())
        recovery.note(vacatedPass())
        XCTAssertEqual(harness.scheduled.count, 1)
        harness.fire()
        XCTAssertEqual(harness.vacatedRetiles, [2])
    }

    func testAnotherPassThatFillsTheKeySettlesThePendingRetry() {
        recovery.note(vacatedPass())
        // a workspace switch away and back, or a later poll, got there first
        recovery.note(vacatedPass(failure: nil))
        harness.fire()
        XCTAssertTrue(harness.vacatedRetiles.isEmpty)
    }

    func testAVacatedRetryOnAHiddenWorkspaceIsDropped() {
        recovery.note(vacatedPass())
        // the switch that hid it lays the key out again when it is shown
        harness.visibleWorkspaces = []
        harness.fire()
        harness.fire()
        XCTAssertTrue(harness.vacatedRetiles.isEmpty)
        XCTAssertEqual(harness.scheduled.count, 1)
    }

    func testAVacatedRetryWaitsOutNothingDuringADisplayTransition() {
        recovery.note(vacatedPass())
        harness.displayTransitionPending = true
        harness.fire()
        XCTAssertTrue(harness.vacatedRetiles.isEmpty)
    }

    func testANewcomerRetryOwnsAKeyThatAlsoLostAMember() {
        // the admission retry already lays the key out again, members and all
        recovery.note(vacatedPass(inserted: [26]))
        XCTAssertEqual(harness.scheduled.count, 1)
        harness.fire()
        XCTAssertEqual(harness.attempts.count, 1)
        XCTAssertTrue(harness.vacatedRetiles.isEmpty)
    }

    func testCancellingEverythingDropsAVacatedRetry() {
        recovery.note(vacatedPass())
        recovery.cancelAll(reason: "stop")
        harness.fire()
        XCTAssertTrue(harness.vacatedRetiles.isEmpty)
    }

    func testVacatedRetriesOnTwoKeysRunIndependently() {
        harness.visibleWorkspaces = [2, 3]
        recovery.note(vacatedPass(workspace: 2))
        recovery.note(vacatedPass(workspace: 3))
        harness.fire()
        XCTAssertEqual(harness.vacatedRetiles.sorted(), [2, 3])
    }

    func testAVacatedRetryWaitsOutADragOrAMoveTransition() {
        recovery.note(vacatedPass())
        harness.layoutSuspended = true
        harness.fire()
        XCTAssertTrue(harness.vacatedRetiles.isEmpty, "no pass under the user's hand")
        XCTAssertEqual(harness.scheduled.map(\.delay), [0.25, 0.25])

        harness.layoutSuspended = false
        harness.fire()
        XCTAssertEqual(harness.vacatedRetiles, [2])
    }

    func testAVacatedRetryStopsWaitingOnASuspensionThatNeverEnds() {
        recovery.vacatedSuspensionWaits = 2
        recovery.note(vacatedPass())
        harness.layoutSuspended = true
        for _ in 0..<6 { harness.fire() }
        XCTAssertTrue(harness.vacatedRetiles.isEmpty)
        XCTAssertEqual(harness.scheduled.count, 3, "the first timer and two waits")
    }

    func testARetryPassReportingBackDoesNotArmASecondRetry() {
        harness.reportsTo = recovery
        harness.vacatedResults = [vacatedPass()]
        recovery.note(vacatedPass())

        harness.fire()

        XCTAssertEqual(harness.vacatedRetiles, [2])
        XCTAssertEqual(harness.scheduled.map(\.delay), [0.25, 0.5],
                       "the series re-arms itself once; the report arms nothing")
    }

    func testARetryPassThatStrandsANewcomerHandsTheKeyToItsRetry() {
        harness.reportsTo = recovery
        harness.vacatedResults = [vacatedPass(inserted: [26])]
        recovery.note(vacatedPass())

        harness.fire()

        XCTAssertEqual(recovery.pendingWindowIDs, [26], "the newcomer retry has it")
        harness.fire()
        XCTAssertEqual(harness.vacatedRetiles, [2], "no second vacated pass on the same key")
    }

    func testAnAXFailureIsOneTheAppMayGetRightNextTime() {
        XCTAssertTrue(FrameSizingFailure.writeFailed(1, .failure).isAXFailure)
        XCTAssertTrue(FrameSizingFailure.readFailed(1, .cannotComplete).isAXFailure)
        XCTAssertTrue(FrameSizingFailure.cleanupFailed(1, primary: nil, error: .failure).isAXFailure)
        XCTAssertTrue(FrameSizingFailure.deadlineExceeded.isAXFailure)
        XCTAssertFalse(FrameSizingFailure.geometryMismatch(1).isAXFailure)
        XCTAssertFalse(FrameSizingFailure.overlap(1, 2).isAXFailure)
        XCTAssertFalse(FrameSizingFailure.windowUnavailable(1).isAXFailure)
        XCTAssertFalse(FrameSizingFailure.superseded.isAXFailure)
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
    /// ids a published tree holds when the recovery asks
    var tiled: Set<CGWindowID> = []
    var alive: Set<CGWindowID> = [11, 26, 27]
    var readable: Set<CGWindowID> = [11, 26, 27]

    /// ids the next attempt manages to tile
    var place: Set<CGWindowID> = []
    /// what each attempt places, in order; `place` once it runs out
    var placements: [Set<CGWindowID>] = []
    /// failures for the next attempts, in order; `failure` once it runs out
    var failures: [FrameSizingFailure?] = []
    /// ids each attempt's engine refused pre-write, in order; none once it
    /// runs out
    var refusals: [Set<CGWindowID>] = []
    /// the engine keeping a timed-out tile: a keepOnTimeout attempt that
    /// times out places every newcomer it was given
    var keepsTimeouts = true
    /// ids the fallback retile leaves visible, nonfloating and in no tree
    var leftovers: Set<CGWindowID> = []
    /// what each vacated-key retile returns, in order; an accepted pass once
    /// it runs out
    var vacatedResults: [TilingEngine.AdmissionResult] = []
    /// the workspaces the vacated-key retry laid out again, in order
    private(set) var vacatedRetiles: [Int] = []
    /// a drag or a workspace transition is settling
    var layoutSuspended = false
    /// the production retile reports its pass back through `note`
    weak var reportsTo: AdmissionRecovery?
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

    /// More newcomers on ws2, alive and readable.
    func add(_ ids: CGWindowID...) {
        for id in ids {
            windows[id] = makeWindow(id: id)
            alive.insert(id)
            readable.insert(id)
            workspaces[id] = 2
        }
    }

    func install(on recovery: AdmissionRecovery) {
        recovery.schedule = { [weak self] delay, body in self?.scheduled.append((delay, body)) }
        recovery.workspaceFor = { [weak self] id in self?.workspaces[id] }
        recovery.homeScreenForWorkspace = { [weak self] _ in self?.homeScreen }
        recovery.isWorkspaceVisible = { [weak self] ws in self?.visibleWorkspaces.contains(ws) ?? false }
        recovery.isFloating = { [weak self] id in self?.floatingIDs.contains(id) ?? false }
        recovery.isTiled = { [weak self] id in self?.tiled.contains(id) ?? false }
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
            let placed = self.placements.isEmpty ? self.place : self.placements.removeFirst()
            let refused = self.refusals.isEmpty ? [] : self.refusals.removeFirst()
            if keepOnTimeout, self.keepsTimeouts, let failure, failure.isTimeout {
                return AdmissionRecovery.AttemptResult(placed: Set(bypass.keys), failure: failure)
            }
            let admission = TilingEngine.AdmissionResult(
                workspace: workspace, screen: self.screen, generation: 8,
                insertedIDs: Set(bypass.keys).subtracting(refused),
                publishedIDs: placed.union([11]), failure: failure,
                restoredIDs: [], refusedIDs: refused)
            return AdmissionRecovery.AttemptResult(placed: placed, failure: failure,
                                                   admission: admission)
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
        recovery.retileVacated = { [weak self] workspace, screen in
            guard let self else { return nil }
            self.calls.append("retileVacated")
            self.vacatedRetiles.append(workspace)
            let result = self.vacatedResults.isEmpty
                ? TilingEngine.AdmissionResult(
                    workspace: workspace, screen: screen, generation: 9, insertedIDs: [],
                    publishedIDs: [11], failure: nil, restoredIDs: [], refusedIDs: [])
                : self.vacatedResults.removeFirst()
            self.reportsTo?.note(result)
            return result
        }
        recovery.isLayoutSuspended = { [weak self] in self?.layoutSuspended ?? false }
    }

    /// Run every timer armed so far, once.
    func fire() {
        let pending = scheduled
        for entry in pending { entry.body() }
    }
}

private final class OtherRecoveryScreen: SyntheticScreen {
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
        controller.retile = { body in body() }
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
        // focus sits on a third tile, so 11 is an unfocused tile over the floater
        let focused = makeWindow(id: 13, pid: tiledPID)
        focused.cachedFrame = CGRect(x: 600, y: 0, width: 400, height: 500)
        cache.cachedWindows[13] = focused
        cache.knownWindowIDs.insert(13)
        cache.tiledPositions[13] = focused.cachedFrame!
        workspaces.assignWindow(13, toWorkspace: workspace)
        focus.recordFocus(13, reason: "test")
        let controller = FloatingWindowController(
            stateCache: cache, suppressions: SuppressionRegistry(), workspaceManager: workspaces,
            tilingEngine: TilingEngine(displayManager: display), displayManager: display,
            accessibility: AccessibilityManager(), cursorManager: CursorManager(),
            focusController: focus, focusBorder: border, dimmingOverlay: DimmingOverlay()
        )
        // the real one fronts whatever process owns these made-up pids
        controller.frontApp = { _ in }
        controller.restoreFocusLifting = { _ in }
        controller.isMouseDown = { false }
        controller.secondsSinceLastKey = { .infinity }
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
        controller.restoreFocusLifting = { restores.append($0.windowID) }
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
        var queued: [() -> Void] = []
        var front: pid_t = 100
        controller.frontmostPID = { front }
        controller.performRaise = { raises.append($0.windowID); return .success }
        controller.restoreFocusLifting = { restores.append($0.windowID) }
        controller.scheduleAfter = { _, body in queued.append(body) }
        XCTAssertEqual(controller.floatingWindowsBehindTiled(
            floatingWindowIDs: cache.floatingWindowIDs,
            tiledPositions: cache.tiledPositions
        ), [12])

        controller.raiseBehind()
        // the floater's app activated itself when raised
        front = 200
        for _ in 0..<(FloatingWindowController.frontedRechecks + 1) where !queued.isEmpty {
            queued.removeFirst()()
        }

        XCTAssertEqual(raises, [12])
        XCTAssertEqual(restores, [13, 13], "the hand-back in the raise's own turn, and the backstop")
    }

    func testCrossAppRaiseThatKeepsFocusSendsNoRestore() {
        let (controller, _, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var raises: [CGWindowID] = []
        var restores: [CGWindowID] = []
        var queued: (() -> Void)?
        controller.performRaise = { raises.append($0.windowID); return .success }
        controller.restoreFocusLifting = { restores.append($0.windowID) }
        controller.scheduleAfter = { _, body in queued = body }

        controller.raiseBehind()
        queued?()

        XCTAssertEqual(raises, [12])
        XCTAssertEqual(restores, [13], "only the hand-back in the raise's own turn, no backstop")
    }

    func testRaiseAfterTheUserActivatedAnotherAppRestoresNothing() {
        let (controller, _, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var restores: [CGWindowID] = []
        var queued: (() -> Void)?
        var front: pid_t = 300
        controller.frontmostPID = { front }
        controller.performRaise = { _ in .success }
        controller.restoreFocusLifting = { restores.append($0.windowID) }
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
        controller.restoreFocusLifting = { restores.append($0.windowID) }
        controller.scheduleAfter = { _, body in queued = body }

        controller.raiseBehind()
        front = 200
        focus.recordFocus(12, reason: "cycleFocus")
        focus.recordFocus(11, reason: "ABA")
        queued?()

        XCTAssertEqual(restores, [13], "the backstop stands down: focus moved on")
    }

    func testRemovedHiddenMenuAndScratchpadTargetsCancelQueuedRestore() {
        func restoreCount(after mutate: (
            WindowStateCache, WorkspaceManager, FloatingWindowController
        ) -> Void) -> Int {
            let (controller, cache, workspaces, _) = makeController(tiledPID: 100, floatingPID: 200)
            var restores = 0
            var queued: [() -> Void] = []
            var front: pid_t = 100
            controller.frontmostPID = { front }
            controller.performRaise = { _ in .success }
            controller.restoreFocusLifting = { _ in restores += 1 }
            controller.scheduleAfter = { _, body in queued.append(body) }
            controller.raiseBehind()
            XCTAssertFalse(queued.isEmpty, "the cross-app raise must queue a restore before invalidation")
            front = 200
            mutate(cache, workspaces, controller)
            for _ in 0..<(FloatingWindowController.frontedRechecks + 1) where !queued.isEmpty {
                queued.removeFirst()()
            }
            return restores
        }

        XCTAssertEqual(restoreCount { _, _, _ in }, 2, "unmutated, the backstop runs too")
        XCTAssertEqual(restoreCount { cache, _, _ in cache.knownWindowIDs.remove(13) }, 1)
        XCTAssertEqual(restoreCount { cache, _, _ in cache.hiddenWindowIDs.insert(13) }, 1)
        XCTAssertEqual(restoreCount { _, workspaces, _ in workspaces.removeWindow(13) }, 1)
        XCTAssertEqual(restoreCount { _, _, controller in controller.isMenuTracking = { true } }, 1)
        XCTAssertEqual(restoreCount { _, _, controller in controller.isScratchpadVisible = { true } }, 1)
        XCTAssertEqual(restoreCount { _, _, controller in
            controller.windowListForZOrder = { Self.coveredStack + [Self.popup(pid: 200)] }
        }, 1, "a popup opened in the new front app")
    }

    func testOpenPopupDefersTheRaiseAndRetriesOnce() {
        let (controller, _, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var raises: [CGWindowID] = []
        var restores: [CGWindowID] = []
        var queued: [(TimeInterval, () -> Void)] = []
        var stack = [Self.popup(pid: 100)] + Self.coveredStack
        controller.windowListForZOrder = { stack }
        controller.performRaise = { raises.append($0.windowID); return .success }
        controller.restoreFocusLifting = { restores.append($0.windowID) }
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
        controller.scheduleAfter = { _, body in
            queued = body
        }

        // the stack never changes: the raise never lands. each check runs in
        // turn, and the first miss rests, so nothing raises yet
        controller.raiseBehind()
        for _ in 0...FloatingWindowController.frontedRechecks {
            let next = queued
            queued = nil
            next?()
        }
        controller.raiseBehind()
        XCTAssertEqual(raises, [12], "no retry on every activation and poll")

        clock += FloatingWindowController.frontedRaiseBusy + controller.throttle.frontedIneffectiveCooldown
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

    func testAFrontedRaiseThatKeepsGettingReburiedRunsOncePerHandOff() {
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
        controller.restoreFocusLifting = { w in
            // the restore lifted the tile back over the floater
            restores.append(w.windowID)
            stack = Self.coveredStack
            front = 100
        }
        controller.scheduleAfter = { _, body in queued = body }

        for _ in 0..<4 {
            controller.raiseBehind()
            queued?()
            queued = nil
            clock += FloatingWindowController.frontedRaiseBusy / 2
            controller.raiseBehind()
            queued = nil
            clock += FloatingWindowController.frontedRaiseBusy / 2
        }

        XCTAssertEqual(raises.count, 4, "one per hand-off, however often it's asked. the router marks the app")
        XCTAssertEqual(restores.count, 4)
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

    // MARK: - the rule: behind the focused tile is fine, behind any other isn't

    func testAFloaterBehindOnlyTheFocusedTileIsLeftThere() {
        let (controller, _, _, focus) = makeController(tiledPID: 100, floatingPID: 200)
        var raises = 0
        focus.recordFocus(11, reason: "the click")
        controller.windowListForZOrder = { Self.coveredStack }
        controller.performRaise = { _ in raises += 1; return .success }

        controller.raiseBehind()

        XCTAssertEqual(raises, 0, "a raise here is the flicker on every click")
    }

    func testAFloaterBehindATileThatLostFocusComesBack() {
        let (controller, _, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var steps: [String] = []
        var queued: [() -> Void] = []
        controller.windowListForZOrder = { Self.coveredStack }
        controller.frontApp = { steps.append("front \($0.windowID)") }
        controller.performRaise = { steps.append("raise \($0.windowID)"); return .success }
        controller.scheduleAfter = { _, body in queued.append(body) }

        controller.raiseBehind()

        XCTAssertEqual(steps, ["front 12", "raise 12"], "macOS 27 ignores the raise without the front")
    }

    private static func entry(_ id: CGWindowID, _ frame: CGRect) -> [String: Any] {
        [kCGWindowNumber as String: id,
         kCGWindowBounds as String: CGRectCreateDictionaryRepresentation(frame),
         kCGWindowLayer as String: 0]
    }
    private static let focusedOverFloaterOverOther = [entry(13, CGRect(x: 40, y: 40, width: 400, height: 400)),
                                                      entry(11, CGRect(x: 0, y: 0, width: 500, height: 500)),
                                                      entry(12, CGRect(x: 50, y: 50, width: 300, height: 300))]

    // focused window, floater, the rest
    func testTheFocusedTileGoesBackOnTopInTheSameTurn() {
        let (controller, _, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var steps: [String] = []
        controller.windowListForZOrder = { Self.focusedOverFloaterOverOther }
        controller.performRaise = { steps.append("raise \($0.windowID)"); return .success }
        controller.restoreFocusLifting = { steps.append("lift \($0.windowID)") }
        controller.scheduleAfter = { _, _ in }

        controller.raiseBehind()

        XCTAssertEqual(steps, ["raise 12", "lift 13"])
    }

    // the old focused tile covers the floater. it has to go up before the new tile
    // lifts, or it pops over the window taking focus
    func testAFocusChangeRaisesTheFloaterFromUnderTheOldTile() {
        let (controller, cache, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var steps: [String] = []
        controller.windowListForZOrder = { Self.coveredStack }
        controller.frontApp = { steps.append("front \($0.windowID)") }
        controller.performRaise = { steps.append("raise \($0.windowID)"); return .success }

        controller.raiseFloatersBeforeFocus(cache.cachedWindows[13]!)

        XCTAssertEqual(steps, ["front 12", "raise 12"])
    }

    func testAFocusChangeLeavesAFloaterOnlyTheTargetCovers() {
        let (controller, cache, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var raises = 0
        controller.windowListForZOrder = { Self.coveredStack }
        controller.performRaise = { _ in raises += 1; return .success }

        controller.raiseFloatersBeforeFocus(cache.cachedWindows[11]!)

        XCTAssertEqual(raises, 0, "the target is taking focus, so it stays over the floater")
    }

    private static let floaterOverTile = [entry(12, CGRect(x: 50, y: 50, width: 300, height: 300)),
                                          entry(11, CGRect(x: 0, y: 0, width: 500, height: 500))]

    // hovering Dia lifted it and hovering Terminal didn't
    func testATileTakingFocusIsLiftedOverAFloaterStillOverIt() {
        let (controller, cache, _, focus) = makeController(tiledPID: 100, floatingPID: 200)
        var raises: [CGWindowID] = []
        focus.recordFocus(11, reason: "hover")
        controller.windowListForZOrder = { Self.floaterOverTile }
        controller.performRaise = { raises.append($0.windowID); return .success }
        controller.scheduleAfter = { _, _ in }

        controller.liftOverFloaters(cache.cachedWindows[11]!)

        XCTAssertEqual(raises, [11])
    }

    func testATileAlreadyOverTheFloaterIsNotRaised() {
        let (controller, cache, _, focus) = makeController(tiledPID: 100, floatingPID: 200)
        var raises = 0
        focus.recordFocus(11, reason: "hover")
        controller.windowListForZOrder = { Self.coveredStack }
        controller.performRaise = { _ in raises += 1; return .success }

        controller.liftOverFloaters(cache.cachedWindows[11]!)

        XCTAssertEqual(raises, 0)
    }

    func testTheLiftStandsDownOnceFocusHasMovedOn() {
        let (controller, cache, _, focus) = makeController(tiledPID: 100, floatingPID: 200)
        var raises = 0
        focus.recordFocus(13, reason: "newer")
        controller.windowListForZOrder = { Self.floaterOverTile }
        controller.performRaise = { _ in raises += 1; return .success }

        controller.liftOverFloaters(cache.cachedWindows[11]!)

        XCTAssertEqual(raises, 0)
    }

    func testAFocusChangeSkipsTheRaiseWhileTyping() {
        let (controller, cache, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var raises = 0
        var queued = 0
        controller.secondsSinceLastKey = { 0.05 }
        controller.windowListForZOrder = { Self.coveredStack }
        controller.performRaise = { _ in raises += 1; return .success }
        controller.scheduleAfter = { _, _ in queued += 1 }

        controller.raiseFloatersBeforeFocus(cache.cachedWindows[13]!)

        XCTAssertEqual(raises, 0)
        XCTAssertEqual(queued, 1, "a retry brings it back after the typing")
    }

    func testRaiseBehindFrontsTheFloatersAppOnlyWithTheFocusedTilesAppInFront() {
        let (controller, _, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var fronted = 0
        var front: pid_t = 100
        controller.frontApp = { _ in fronted += 1 }
        controller.frontmostPID = { front }
        controller.windowListForZOrder = { Self.coveredStack }
        controller.performRaise = { _ in .success }
        controller.scheduleAfter = { _, _ in }

        front = 300 // an app HyprMac doesn't manage: fronting would take its keyboard
        controller.raiseBehind()
        XCTAssertEqual(fronted, 0)

        front = 100
        controller.throttle = RaiseBehindThrottle()
        controller.raiseBehind()
        XCTAssertEqual(fronted, 1, "the restore can hand this one back")
    }

    func testRaiseBehindWaitsForTheMouseUp() {
        let (controller, _, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var raises = 0
        controller.isMouseDown = { true }
        controller.windowListForZOrder = { Self.coveredStack }
        controller.performRaise = { _ in raises += 1; return .success }

        controller.raiseBehind()

        XCTAssertEqual(raises, 0, "switching apps mid press breaks a text selection")
    }

    // keys go to the front app, so fronting the floater's app here would put them
    // in the floater
    func testAFrontedRaiseWaitsForTypingToStop() {
        let (controller, _, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var raises = 0
        var sinceKey: TimeInterval = 0.05
        var queued: [() -> Void] = []
        controller.secondsSinceLastKey = { sinceKey }
        controller.windowListForZOrder = { Self.coveredStack }
        controller.performRaise = { _ in raises += 1; return .success }
        controller.scheduleAfter = { _, body in queued.append(body) }

        controller.raiseBehind()
        XCTAssertEqual(raises, 0, "typing")
        sinceKey = 1
        queued.removeFirst()()

        XCTAssertEqual(raises, 1, "it comes back up once the typing stops")
    }

    func testOnlyOneFrontedRaiseRunsPerHandOff() {
        let (controller, _, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var raises = 0
        var clock: TimeInterval = 1000
        var queued: [() -> Void] = []
        controller.now = { clock }
        controller.windowListForZOrder = { Self.coveredStack }
        controller.performRaise = { _ in raises += 1; return .success }
        controller.scheduleAfter = { _, body in queued.append(body) }

        controller.raiseBehind()
        clock += 0.1
        controller.raiseBehind()
        XCTAssertEqual(raises, 1, "the first still owns the front app")
    }

    // a slow app missed the 50 ms check, and the pair then rested with the floater buried
    func testASlowFrontedRaiseStillCounts() {
        let (controller, _, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var queued: [() -> Void] = []
        var reads = 0
        controller.windowListForZOrder = {
            reads += 1
            return reads > 2 ? Self.raisedStack : Self.coveredStack
        }
        controller.performRaise = { _ in .success }
        controller.scheduleAfter = { _, body in queued.append(body) }

        controller.raiseBehind()
        for _ in 0..<(FloatingWindowController.frontedRechecks + 1) where !queued.isEmpty {
            queued.removeFirst()()
        }

        XCTAssertNil(controller.throttle.cooldown(RaiseBehindThrottle.Pair(floater: 12, tile: 11),
                                                  now: controller.now()))
    }

    func testRepeatedMissesRestLongerAndStopRetrying() {
        var throttle = RaiseBehindThrottle()
        let pair = RaiseBehindThrottle.Pair(floater: 1, tile: 2)

        throttle.noteIneffective(pair, now: 0, fronted: true)
        XCTAssertEqual(throttle.cooldown(pair, now: 0)?.remaining, 1)
        XCTAssertTrue(throttle.retriesAfterMiss(pair))
        throttle.noteIneffective(pair, now: 10, fronted: true)
        XCTAssertEqual(throttle.cooldown(pair, now: 10)?.remaining, 2)
        throttle.noteIneffective(pair, now: 20, fronted: true)
        XCTAssertEqual(throttle.cooldown(pair, now: 20)?.remaining, 4)
        XCTAssertFalse(throttle.retriesAfterMiss(pair), "an app that never comes up gets left alone")

        throttle.noteFrontedRaiseLanded(pair)
        XCTAssertTrue(throttle.retriesAfterMiss(pair))
    }

    func testManyFrontedRaisesDoNotHitABurstCooldown() {
        let (controller, _, _, _) = makeController(tiledPID: 100, floatingPID: 200)
        var raises = 0
        var clock: TimeInterval = 1000
        var stack = Self.coveredStack
        controller.now = { clock }
        controller.windowListForZOrder = { stack }
        controller.performRaise = { _ in raises += 1; stack = Self.raisedStack; return .success }
        controller.scheduleAfter = { _, body in body() }

        for _ in 0..<(controller.throttle.burstLimit * 2) {
            stack = Self.coveredStack
            controller.raiseBehind()
            clock += FloatingWindowController.frontedRaiseBusy
        }

        XCTAssertEqual(raises, controller.throttle.burstLimit * 2)
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

private final class PrimaryRecoveryScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 1600, height: 1000) }
    override var visibleFrame: NSRect { frame }
}

/// A window leaving a workspace (closed, or moved to another one) leaves a
/// gap its neighbour should grow into. Seen live on 2026-10-30: the grow
/// came back with an AX error, the pass rolled the neighbour back to its
/// half, and nothing laid the key out again until a workspace switch or
/// Hypr+R. The engine has to say the key was vacated, so the recovery can
/// lay it out again, and an accepted pass has to fill the gap.
final class VacatedKeyEngineTests: XCTestCase {

    private var screen: PrimaryRecoveryScreen!
    private var io: GrowRefusingIO!
    private var engine: TilingEngine!

    override func setUp() {
        screen = PrimaryRecoveryScreen()
        io = GrowRefusingIO()
        engine = TilingEngine(displayManager: DisplayManager(screenSource: { [screen] in [screen!] }),
                              frameSizingIOFactory: { [io] _, generation in io!.io(generation: generation) })
    }

    /// Two windows side by side on ws2. Same app or not, by pid.
    private func tiledPair(pids: (pid_t, pid_t)) -> (HyprWindow, HyprWindow) {
        let left = makeWindow(id: 71, pid: pids.0)
        let right = makeWindow(id: 72, pid: pids.1)
        let first = engine.tileWindows([left, right], onWorkspace: 2, screen: screen)
        XCTAssertNil(first.failure)
        XCTAssertFalse(first.vacated)
        return (left, right)
    }

    private static let pairs: [(String, (pid_t, pid_t))] = [("same app", (501, 501)),
                                                             ("different apps", (501, 502))]

    func testClosingOneOfTwoWindowsWhoseNeighbourCannotGrowReportsTheKeyVacated() throws {
        for (label, pids) in Self.pairs {
            setUp()
            let (left, right) = tiledPair(pids: pids)
            let half = try XCTUnwrap(io.frames[left.windowID])

            io.refusingGrowth = [left.windowID]
            engine.removeWindowID(right.windowID)
            let result = engine.tileWindows([left], onWorkspace: 2, screen: screen)

            XCTAssertEqual(result.failure, .writeFailed(left.windowID, .failure), label)
            XCTAssertTrue(result.vacated, label)
            XCTAssertEqual(io.frames[left.windowID], half, "\(label): the rollback is the gap")
            XCTAssertEqual(engine.windowIDs(inTreeForWorkspace: 2, screen: screen), [left.windowID],
                           "\(label): the closed window stays out of the tree")
        }
    }

    func testMovingAWindowAwayReportsOnlyTheSourceKeyVacated() throws {
        for (label, pids) in Self.pairs {
            setUp()
            let (left, right) = tiledPair(pids: pids)

            io.refusingGrowth = [left.windowID]
            engine.removeWindowMembershipOnly(right, fromWorkspace: 2)
            let source = engine.tileWindows([left], onWorkspace: 2, screen: screen)
            let destination = engine.tileWindows([right], onWorkspace: 3, screen: screen)

            XCTAssertTrue(source.vacated, label)
            XCTAssertEqual(source.failure, .writeFailed(left.windowID, .failure), label)
            XCTAssertNil(destination.failure, label)
            XCTAssertFalse(destination.vacated, "\(label): the destination gained a window")
            XCTAssertEqual(engine.windowIDs(inTreeForWorkspace: 2, screen: screen), [left.windowID], label)
            XCTAssertEqual(engine.windowIDs(inTreeForWorkspace: 3, screen: screen), [right.windowID], label)
        }
    }

    func testTheNextAcceptedPassFillsTheGapAndClearsTheMark() throws {
        for (label, pids) in Self.pairs {
            setUp()
            let (left, right) = tiledPair(pids: pids)
            let half = try XCTUnwrap(io.frames[left.windowID])

            io.refusingGrowth = [left.windowID]
            engine.removeWindowID(right.windowID)
            _ = engine.tileWindows([left], onWorkspace: 2, screen: screen)
            io.refusingGrowth = []
            let retry = engine.tileWindows([left], onWorkspace: 2, screen: screen)

            XCTAssertNil(retry.failure, label)
            XCTAssertFalse(retry.vacated, label)
            let filled = try XCTUnwrap(io.frames[left.windowID])
            XCTAssertGreaterThan(filled.width, half.width * 1.5, "\(label): the window took the gap")
        }
    }

    func testAFailedPassWithNoWindowLeavingIsNotVacated() throws {
        let (left, right) = tiledPair(pids: (501, 502))
        // knocked off its tile by the app, and the re-apply cannot grow it back
        let half = try XCTUnwrap(io.frames[left.windowID])
        io.frames[left.windowID] = half.insetBy(dx: 40, dy: 0)
        io.refusingGrowth = [left.windowID]

        let result = engine.tileWindows([left, right], onWorkspace: 2, screen: screen)

        XCTAssertNotNil(result.failure)
        XCTAssertFalse(result.vacated)
    }

    func testRemovingTheLastWindowLeavesNothingToFill() {
        let only = makeWindow(id: 75, pid: 501)
        XCTAssertNil(engine.tileWindows([only], onWorkspace: 2, screen: screen).failure)

        engine.removeWindowID(only.windowID)
        let result = engine.tileWindows([], onWorkspace: 2, screen: screen)

        XCTAssertFalse(result.vacated)
    }
}

/// Accepts every write except one that widens a window in `refusingGrowth`,
/// which comes back with `.failure` and changes nothing.
private final class GrowRefusingIO {
    var frames: [CGWindowID: CGRect] = [:]
    var refusingGrowth: Set<CGWindowID> = []

    func io(generation: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { [self] id, size, _ in
                var frame = frames[id] ?? CGRect(x: 0, y: 0, width: 100, height: 100)
                if refusingGrowth.contains(id), size.width > frame.width + 1 { return .failure }
                frame.size = size
                frames[id] = frame
                return .success
            },
            writePosition: { [self] id, position, _ in
                var frame = frames[id] ?? CGRect(x: 0, y: 0, width: 100, height: 100)
                frame.origin = position
                frames[id] = frame
                return .success
            },
            readPosition: { [self] id, _ in (.success, (frames[id] ?? .zero).origin) },
            readSize: { [self] id, _ in
                (.success, frames[id]?.size ?? CGSize(width: 100, height: 100))
            },
            now: { 0 }, sleep: { _ in }, currentGeneration: generation
        )
    }
}
