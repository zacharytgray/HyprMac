import XCTest
@testable import HyprMac

final class DragSwapHandlerInsertionTests: XCTestCase {
    func testDeferredDegradedFeedbackRequiresFreshCompleteSameKeyRecovery() {
        let key = TiledDragFeedbackKey(workspace: 2, displayID: 7)
        let other = TiledDragFeedbackKey(workspace: 3, displayID: 7)
        var feedback = TiledDragFeedbackReconciler()
        XCTAssertEqual(feedback.beginDegraded(key: key, generation: 40,
                                              affectedIDs: [11, 12, 13]), [])

        XCTAssertEqual(feedback.reconcile(.accepted(
            key: other, generation: 41, publishedIDs: [11, 12, 13, 14],
            expectedIDs: [11, 12, 13, 14])), [])
        XCTAssertEqual(feedback.reconcile(.accepted(
            key: key, generation: 40, publishedIDs: [11, 12, 13, 14],
            expectedIDs: [11, 12, 13, 14])), [])
        XCTAssertEqual(feedback.reconcile(.failed(
            key: key, generation: 41, requiredIDs: [11, 12, 13, 14], recoveryPending: true)), [])
        XCTAssertTrue(feedback.hasPendingFeedback)

        XCTAssertEqual(feedback.reconcile(.accepted(
            key: key, generation: 42, publishedIDs: [11, 12, 13],
            expectedIDs: [11, 12, 13, 14])), [.showDegraded(key: key, generation: 42)])
        XCTAssertTrue(feedback.hasPendingFeedback)
        feedback.feedbackFinished(generation: 42)
        XCTAssertFalse(feedback.hasPendingFeedback)
    }

    func testDeferredFeedbackCancelsVerifiedRecoveryAndReportsEveryTerminalPathOnce() {
        let key = TiledDragFeedbackKey(workspace: 2, displayID: 7)
        var feedback = TiledDragFeedbackReconciler()
        _ = feedback.beginDegraded(key: key, generation: 40, affectedIDs: [11, 12, 13])
        XCTAssertEqual(feedback.reconcile(.accepted(
            key: key, generation: 41, publishedIDs: [11, 12, 13, 14],
            expectedIDs: [11, 12, 13, 14])), [.cancelDegraded(key: key)])

        _ = feedback.beginDegraded(key: key, generation: 50, affectedIDs: [11])
        XCTAssertEqual(feedback.reconcile(.failed(
            key: key, generation: 51, requiredIDs: [11], recoveryPending: false)),
            [.showDegraded(key: key, generation: 51)])
        XCTAssertEqual(feedback.reconcile(.terminalFailure(key: key)), [])
        feedback.feedbackFinished(generation: 51)

        _ = feedback.beginDegraded(key: key, generation: 60, affectedIDs: [11])
        XCTAssertEqual(feedback.reconcile(.terminalFailure(key: key)),
                       [.showDegraded(key: key, generation: 60)])
        feedback.feedbackFinished(generation: 60)
        _ = feedback.beginDegraded(key: key, generation: 70, affectedIDs: [11])
        XCTAssertEqual(feedback.reconcile(.noResult),
                       [.showDegraded(key: key, generation: 70)])
    }

    func testSecondDegradedOutcomeCoalescesWithoutLosingFirstFailure() {
        let key = TiledDragFeedbackKey(workspace: 2, displayID: 7)
        var feedback = TiledDragFeedbackReconciler()
        _ = feedback.beginDegraded(key: key, generation: 40, affectedIDs: [11])
        XCTAssertEqual(feedback.beginDegraded(key: key, generation: 40,
                                              affectedIDs: [11]), [])
        XCTAssertEqual(feedback.beginDegraded(key: key, generation: 41,
                                              affectedIDs: [11]), [])
        XCTAssertTrue(feedback.hasPendingFeedback)
        feedback.cancel()
        XCTAssertFalse(feedback.hasPendingFeedback)
    }

    func testPostPollUsesNewestSameKeyOutcomeAndOnlyWaitsForActiveRetry() {
        let key = TiledDragFeedbackKey(workspace: 2, displayID: 7)
        let other = TiledDragFeedbackKey(workspace: 8, displayID: 9)
        var feedback = TiledDragFeedbackReconciler()
        _ = feedback.beginDegraded(key: key, generation: 10, affectedIDs: [11])

        XCTAssertEqual(feedback.reconcileNewest([
            .accepted(key: key, generation: 11, publishedIDs: [11], expectedIDs: [11]),
            .failed(key: key, generation: 12, requiredIDs: [11], recoveryPending: true),
            .accepted(key: other, generation: 99, publishedIDs: [11], expectedIDs: [11])
        ], activeRetry: true), [])
        XCTAssertTrue(feedback.hasPendingFeedback)

        XCTAssertEqual(feedback.reconcileNewest([], activeRetry: true), [])
        XCTAssertEqual(feedback.reconcileNewest([], activeRetry: false),
                       [.showDegraded(key: key, generation: 12)])
        XCTAssertEqual(feedback.reconcile(.accepted(
            key: key, generation: 13, publishedIDs: [11], expectedIDs: [11])),
            [.cancelDegraded(key: key)])
        XCTAssertFalse(feedback.hasPendingFeedback)
    }

    func testRetrySuccessAndAnyAppsSameKeyCreationCanVerifyRecovery() {
        let key = TiledDragFeedbackKey(workspace: 2, displayID: 7)
        var feedback = TiledDragFeedbackReconciler()
        _ = feedback.beginDegraded(key: key, generation: 10, affectedIDs: [11, 12])
        XCTAssertEqual(feedback.reconcile(.failed(
            key: key, generation: 11, requiredIDs: [11, 12, 99], recoveryPending: true)), [])

        // The verifier is deliberately app-agnostic: a new member from any
        // app is recovery when the whole key publishes exactly what is due.
        XCTAssertEqual(feedback.reconcile(.accepted(
            key: key, generation: 12, publishedIDs: [11, 12, 99],
            expectedIDs: [11, 12, 99])), [.cancelDegraded(key: key)])
    }

    func testOlderFeedbackFinishCannotClearNewerDegradedOutcome() {
        let key = TiledDragFeedbackKey(workspace: 2, displayID: 7)
        var feedback = TiledDragFeedbackReconciler()
        _ = feedback.beginDegraded(key: key, generation: 10, affectedIDs: [11])
        XCTAssertEqual(feedback.reconcile(.noResult),
                       [.showDegraded(key: key, generation: 10)])
        XCTAssertEqual(feedback.beginDegraded(key: key, generation: 11,
                                              affectedIDs: [11]), [])

        feedback.feedbackFinished(generation: 10)

        XCTAssertTrue(feedback.hasPendingFeedback)
        XCTAssertEqual(feedback.reconcile(.terminalFailure(key: key)),
                       [.showDegraded(key: key, generation: 11)])
    }

    func testShownFeedbackFinishSurvivesNewerRecoveryWatermark() {
        let key = TiledDragFeedbackKey(workspace: 2, displayID: 7)
        var feedback = TiledDragFeedbackReconciler()
        _ = feedback.beginDegraded(key: key, generation: 10, affectedIDs: [11])
        XCTAssertEqual(feedback.reconcile(.noResult),
                       [.showDegraded(key: key, generation: 10)])
        XCTAssertEqual(feedback.reconcile(.failed(
            key: key, generation: 11, requiredIDs: [11], recoveryPending: true)), [])

        feedback.feedbackFinished(generation: 10)

        XCTAssertFalse(feedback.hasPendingFeedback)
    }

    func testDifferentKeyDegradedOutcomeCarriesOldFeedbackIdentity() {
        let first = TiledDragFeedbackKey(workspace: 2, displayID: 7)
        let second = TiledDragFeedbackKey(workspace: 3, displayID: 8)
        var feedback = TiledDragFeedbackReconciler()
        _ = feedback.beginDegraded(key: first, generation: 10, affectedIDs: [11])

        XCTAssertEqual(feedback.beginDegraded(key: second, generation: 11,
                                              affectedIDs: [21]),
                       [.showDegraded(key: first, generation: 10)])
        XCTAssertEqual(feedback.reconcile(.accepted(
            key: second, generation: 12, publishedIDs: [21], expectedIDs: [21])),
            [.cancelDegraded(key: second)])
    }

    func testFallbackWarningCannotBeCancelledByHealthyIncumbentSubset() {
        let key = TiledDragFeedbackKey(workspace: 2, displayID: 7)
        var feedback = TiledDragFeedbackReconciler()
        _ = feedback.beginDegraded(key: key, generation: 10, affectedIDs: [1, 2, 3])
        _ = feedback.reconcile(.failed(key: key, generation: 11,
                                       requiredIDs: [1, 2, 3, 4], recoveryPending: true))
        XCTAssertEqual(feedback.reconcile(.terminalFailure(key: key)),
                       [.showDegraded(key: key, generation: 11)])

        XCTAssertEqual(feedback.reconcile(.accepted(
            key: key, generation: 12, publishedIDs: [1, 2, 3], expectedIDs: [1, 2, 3])), [])
        XCTAssertTrue(feedback.hasPendingFeedback)
    }

    func testAwaitingEvidenceWarningCancelsAfterFullRequiredMembershipRecovers() {
        let key = TiledDragFeedbackKey(workspace: 2, displayID: 7)
        var feedback = TiledDragFeedbackReconciler()
        _ = feedback.beginDegraded(key: key, generation: 10, affectedIDs: [1, 2, 3])
        _ = feedback.reconcile(.failed(key: key, generation: 11,
                                       requiredIDs: [1, 2, 3, 4], recoveryPending: true))
        XCTAssertEqual(feedback.reconcile(.terminalFailure(key: key)),
                       [.showDegraded(key: key, generation: 11)])

        XCTAssertEqual(feedback.reconcile(.accepted(
            key: key, generation: 12, publishedIDs: [1, 2, 3, 4],
            expectedIDs: [1, 2, 3, 4])), [.cancelDegraded(key: key)])
        XCTAssertFalse(feedback.hasPendingFeedback)
    }

    func testFeedbackPolicyReportsEveryVerifiedRejectionExactlyOnce() {
        let frames: [CGWindowID: CGRect] = [
            1: CGRect(x: 10, y: 20, width: 300, height: 200)
        ]

        // a release with nowhere to land is not a refused arrangement
        XCTAssertNil(TiledDragFeedbackPolicy.feedback(for: .rejectedRestored(
            reason: .preflight(.noTarget), actualFrames: frames)))
        XCTAssertEqual(TiledDragFeedbackPolicy.feedback(for: .rejectedRestored(
            reason: .preflight(.maxDepthExceeded), actualFrames: frames)), .rejected)
        XCTAssertEqual(TiledDragFeedbackPolicy.feedback(for: .rejectedRestored(
            reason: .sizing(.attemptsExhausted), actualFrames: frames)), .rejected)
    }

    func testFeedbackPolicyDistinguishesDegradedRestoration() {
        XCTAssertEqual(TiledDragFeedbackPolicy.feedback(for: .degraded(
            candidateReason: .preflight(.noTarget),
            restorationReason: .deadlineExceeded,
            actualFrames: [:], progress: nil)), .degraded)
    }

    func testFeedbackPolicyStaysSilentForNonFailures() {
        let tree = BSPTree()
        XCTAssertNil(TiledDragFeedbackPolicy.feedback(for: .committed(
            candidate: tree, actualFrames: [:], progress: FrameSizingProgressReport())))
        XCTAssertNil(TiledDragFeedbackPolicy.feedback(for: .ignored))
        XCTAssertNil(TiledDragFeedbackPolicy.feedback(for: .superseded))
    }

    func testMouseDragLifecycleStopResetClearsEverySuppressionState() {
        var state = MouseDragLifecycleState(buttonDown: true,
                                            sawDragEvent: true,
                                            preDragFocusedID: 991,
                                            swapRequested: true)

        state.resetForStop()

        XCTAssertFalse(state.buttonDown)
        XCTAssertFalse(state.sawDragEvent)
        XCTAssertEqual(state.preDragFocusedID, 0)
        XCTAssertFalse(state.swapRequested)
    }

    func testMouseDragLifecycleLatchesHyprAcrossTheWholeGesture() {
        var heldAtPress = MouseDragLifecycleState()
        heldAtPress.beginPress(hyprHeld: true)
        XCTAssertTrue(heldAtPress.releaseRequestsSwap(hyprHeld: false, optionDown: false))

        var pressedDuringDrag = MouseDragLifecycleState()
        pressedDuringDrag.beginPress(hyprHeld: false)
        pressedDuringDrag.observeDrag(hyprHeld: true)
        XCTAssertTrue(pressedDuringDrag.releaseRequestsSwap(hyprHeld: false, optionDown: false))

        var pressedNearRelease = MouseDragLifecycleState()
        pressedNearRelease.beginPress(hyprHeld: false)
        pressedNearRelease.noteHyprKeyDown()
        XCTAssertTrue(pressedNearRelease.releaseRequestsSwap(hyprHeld: false, optionDown: false))
    }

    func testMouseDragLifecycleUsesReleaseStateAndKeepsOptionCompatibility() {
        var state = MouseDragLifecycleState()
        state.beginPress(hyprHeld: false)

        XCTAssertFalse(state.releaseRequestsSwap(hyprHeld: false, optionDown: false))
        XCTAssertTrue(state.releaseRequestsSwap(hyprHeld: true, optionDown: false))
        XCTAssertTrue(state.releaseRequestsSwap(hyprHeld: false, optionDown: true))
    }

    func testPressResolverRequiresOneActualTileAndNoOccluder() {
        let tiles: [CGWindowID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 100, height: 100),
            2: CGRect(x: 100, y: 0, width: 100, height: 100)
        ]

        XCTAssertEqual(TiledDragPressResolver.resolve(
            pointer: CGPoint(x: 25, y: 25), tiledFrames: tiles, occluderFrames: [:]), 1)
        XCTAssertNil(TiledDragPressResolver.resolve(
            pointer: CGPoint(x: 25, y: 25), tiledFrames: tiles,
            occluderFrames: [9: CGRect(x: 10, y: 10, width: 50, height: 50)]))
        XCTAssertNil(TiledDragPressResolver.resolve(
            pointer: CGPoint(x: 100, y: 25), tiledFrames: tiles, occluderFrames: [:]))
        XCTAssertNil(TiledDragPressResolver.resolve(
            pointer: CGPoint(x: 300, y: 25), tiledFrames: tiles, occluderFrames: [:]))
    }

    func testDeferredReleaseKeepsExactSnapshotPointerAndOption() {
        let first = snapshot(draggedID: 1)
        let scheduler = DeferredScheduler()
        var capturedPoint: CGPoint?
        var appliedDraggedID: CGWindowID?
        var appliedMode: TiledDragMode?
        var reports = 0
        let coordinator = TiledDragSessionCoordinator(
            capture: { point in capturedPoint = point; return .captured(first) },
            apply: { snapshot, mode in
                appliedDraggedID = snapshot.draggedID
                appliedMode = mode
                return .committed(candidate: snapshot.originalTree,
                                  actualFrames: snapshot.originalFrames,
                                  progress: FrameSizingProgressReport())
            },
            resolveTarget: { point, _ in
                point == CGPoint(x: 220, y: 40)
                    ? TiledDragTarget(windowID: 2, edge: .left) : nil
            },
            schedule: scheduler.schedule,
            report: { _ in reports += 1 }
        )

        coordinator.mouseDown(at: CGPoint(x: 20, y: 30))
        coordinator.mouseUp(TiledDragRelease(
            pointer: CGPoint(x: 220, y: 40), optionDown: false, sawDragEvent: true
        ))

        XCTAssertEqual(capturedPoint, CGPoint(x: 20, y: 30))
        XCTAssertTrue(coordinator.isFinishingDrag)
        XCTAssertEqual(scheduler.delays, [0.1])
        scheduler.run(0)
        XCTAssertFalse(coordinator.isFinishingDrag)
        XCTAssertEqual(appliedDraggedID, 1)
        XCTAssertInsert(appliedMode, targetID: 2, edge: .left)
        XCTAssertEqual(reports, 1)
    }

    func testOptionAtMouseUpSelectsExplicitSwap() {
        let captured = snapshot(draggedID: 7)
        let scheduler = DeferredScheduler()
        var mode: TiledDragMode?
        let coordinator = TiledDragSessionCoordinator(
            capture: { _ in .captured(captured) },
            apply: { _, value in mode = value; return .superseded },
            resolveTarget: { _, _ in TiledDragTarget(windowID: 8, edge: .bottom) },
            schedule: scheduler.schedule,
            report: { _ in }
        )

        coordinator.mouseDown(at: .zero)
        coordinator.mouseUp(TiledDragRelease(pointer: CGPoint(x: 10, y: 20),
                                              optionDown: true, sawDragEvent: true))
        scheduler.run(0)

        XCTAssertSwap(mode, targetID: 8)
    }

    func testSemanticHyprIntentSelectsExplicitSwapWithoutOption() {
        let captured = snapshot(draggedID: 7)
        let scheduler = DeferredScheduler()
        var mode: TiledDragMode?
        let coordinator = TiledDragSessionCoordinator(
            capture: { _ in .captured(captured) },
            apply: { _, value in mode = value; return .superseded },
            resolveTarget: { _, _ in TiledDragTarget(windowID: 8, edge: .bottom) },
            schedule: scheduler.schedule,
            report: { _ in }
        )

        coordinator.mouseDown(at: .zero)
        coordinator.mouseUp(TiledDragRelease(pointer: CGPoint(x: 10, y: 20),
                                              swapRequested: true, sawDragEvent: true))
        scheduler.run(0)

        XCTAssertSwap(mode, targetID: 8)
    }

    func testNoTargetAndShortDragUseVerifiedSnapbackMode() {
        let captured = snapshot(draggedID: 1)
        let scheduler = DeferredScheduler()
        var applied = 0
        var receivedMode = TiledDragMode?.some(.swap(targetID: 99))
        let coordinator = TiledDragSessionCoordinator(
            capture: { _ in .captured(captured) },
            apply: { _, mode in
                applied += 1
                receivedMode = mode
                return .rejectedRestored(reason: .preflight(.noTarget),
                                         actualFrames: captured.originalFrames)
            },
            resolveTarget: { _, _ in nil },
            schedule: scheduler.schedule,
            report: { _ in }
        )
        coordinator.mouseDown(at: .zero)
        coordinator.mouseUp(TiledDragRelease(pointer: CGPoint(x: 2, y: 2),
                                              optionDown: false, sawDragEvent: true))
        scheduler.run(0)
        XCTAssertEqual(applied, 1)
        XCTAssertNil(receivedMode)
        XCTAssertFalse(coordinator.isFinishingDrag)

        let clickScheduler = DeferredScheduler()
        var clickApplications = 0
        let clickCoordinator = TiledDragSessionCoordinator(
            capture: { _ in .captured(captured) },
            apply: { _, _ in clickApplications += 1; return .superseded },
            resolveTarget: { _, _ in TiledDragTarget(windowID: 2, edge: .right) },
            schedule: clickScheduler.schedule,
            report: { _ in }
        )
        clickCoordinator.mouseDown(at: .zero)
        clickCoordinator.mouseUp(TiledDragRelease(pointer: CGPoint(x: 500, y: 500),
                                                   optionDown: true, sawDragEvent: false))
        XCTAssertEqual(clickScheduler.jobCount, 0)
        XCTAssertEqual(clickApplications, 0)
        XCTAssertFalse(clickCoordinator.isFinishingDrag)
    }

    func testNewPressCancelsOlderDeferredReleaseWithoutClearingNewFlag() {
        let scheduler = DeferredScheduler()
        var nextID: CGWindowID = 1
        var appliedIDs: [CGWindowID] = []
        let coordinator = TiledDragSessionCoordinator(
            capture: { [self] _ in .captured(snapshot(draggedID: nextID)) },
            apply: { snapshot, _ in appliedIDs.append(snapshot.draggedID); return .superseded },
            resolveTarget: { _, _ in nil },
            schedule: scheduler.schedule,
            report: { _ in }
        )

        coordinator.mouseDown(at: CGPoint(x: 1, y: 1))
        coordinator.mouseUp(TiledDragRelease(pointer: .zero, optionDown: false, sawDragEvent: true))
        nextID = 2
        coordinator.mouseDown(at: CGPoint(x: 2, y: 2))
        coordinator.mouseUp(TiledDragRelease(pointer: .zero, optionDown: false, sawDragEvent: true))

        scheduler.run(0)
        XCTAssertTrue(coordinator.isFinishingDrag)
        XCTAssertTrue(appliedIDs.isEmpty)
        scheduler.run(1)
        XCTAssertFalse(coordinator.isFinishingDrag)
        XCTAssertEqual(appliedIDs, [2])
    }

    func testReentrantCaptureCannotOverwriteNewerPressSnapshot() {
        let first = snapshot(draggedID: 1)
        let second = snapshot(draggedID: 2)
        let scheduler = DeferredScheduler()
        var coordinator: TiledDragSessionCoordinator!
        var appliedIDs: [CGWindowID] = []
        coordinator = TiledDragSessionCoordinator(
            capture: { point in
                if point.x == 1 {
                    coordinator.mouseDown(at: CGPoint(x: 2, y: 0))
                    return .captured(first)
                }
                return .captured(second)
            },
            apply: { snapshot, _ in appliedIDs.append(snapshot.draggedID); return .superseded },
            resolveTarget: { _, _ in nil },
            schedule: scheduler.schedule,
            report: { _ in }
        )

        coordinator.mouseDown(at: CGPoint(x: 1, y: 0))
        coordinator.mouseUp(TiledDragRelease(pointer: .zero, optionDown: false,
                                              sawDragEvent: true))
        scheduler.run(0)

        XCTAssertEqual(appliedIDs, [2])
    }

    func testOlderCompletionCannotClearReentrantNewSessionState() {
        let first = snapshot(draggedID: 1)
        let second = snapshot(draggedID: 2)
        let scheduler = DeferredScheduler()
        var nextID: CGWindowID = 1
        var coordinator: TiledDragSessionCoordinator!
        var appliedIDs: [CGWindowID] = []
        coordinator = TiledDragSessionCoordinator(
            capture: { _ in .captured(nextID == 1 ? first : second) },
            apply: { snapshot, _ in
                appliedIDs.append(snapshot.draggedID)
                if snapshot.draggedID == 1 {
                    nextID = 2
                    coordinator.mouseDown(at: CGPoint(x: 2, y: 0))
                    coordinator.mouseUp(TiledDragRelease(pointer: .zero, optionDown: false,
                                                          sawDragEvent: true))
                }
                return .superseded
            },
            resolveTarget: { _, _ in nil },
            schedule: scheduler.schedule,
            report: { _ in }
        )

        coordinator.mouseDown(at: CGPoint(x: 1, y: 0))
        coordinator.mouseUp(TiledDragRelease(pointer: .zero, optionDown: false,
                                              sawDragEvent: true))
        scheduler.run(0)

        XCTAssertTrue(coordinator.isFinishingDrag)
        scheduler.run(1)
        XCTAssertFalse(coordinator.isFinishingDrag)
        XCTAssertEqual(appliedIDs, [1, 2])
    }

    func testOnlyUnknownCaptureFromARealDragReports() {
        let scheduler = DeferredScheduler()
        var result: TiledDragCaptureResult = .captured(snapshot(draggedID: 1))
        var reports: [String] = []
        let coordinator = TiledDragSessionCoordinator(
            capture: { _ in result },
            apply: { _, _ in XCTFail("capture failure must not apply"); return .superseded },
            resolveTarget: { _, _ in nil },
            schedule: scheduler.schedule,
            report: { _ in XCTFail("capture failure is not a drop outcome") },
            captureFailureReport: { failure in
                switch failure {
                case .unknown(.deadlineExceeded): reports.append("deadline")
                default: reports.append("wrong")
                }
            }
        )

        result = .ineligible(.floating)
        coordinator.mouseDown(at: .zero)
        coordinator.mouseUp(TiledDragRelease(pointer: .zero, optionDown: false,
                                              sawDragEvent: true))
        XCTAssertTrue(reports.isEmpty)

        result = .unknown(.deadlineExceeded)
        coordinator.mouseDown(at: .zero)
        coordinator.mouseUp(TiledDragRelease(pointer: .zero, optionDown: false,
                                              sawDragEvent: false))
        XCTAssertTrue(reports.isEmpty)

        coordinator.mouseDown(at: .zero)
        XCTAssertTrue(reports.isEmpty)
        coordinator.mouseUp(TiledDragRelease(pointer: .zero, optionDown: false,
                                              sawDragEvent: true))

        XCTAssertEqual(reports, ["deadline"])
        XCTAssertEqual(scheduler.jobCount, 0)
        XCTAssertFalse(coordinator.isFinishingDrag)
    }

    func testCachePolicyMergesOnlyVerifiedFinalFrames() {
        let existing: [CGWindowID: CGRect] = [
            1: CGRect(x: 1, y: 1, width: 10, height: 10),
            2: CGRect(x: 2, y: 2, width: 20, height: 20),
            99: CGRect(x: 99, y: 99, width: 9, height: 9)
        ]
        let verified: [CGWindowID: CGRect] = [
            1: CGRect(x: 100, y: 100, width: 30, height: 30),
            2: CGRect(x: 200, y: 100, width: 30, height: 30)
        ]
        let candidate = BSPTree()

        let committed = TiledDragCacheUpdate.applying(
            .committed(candidate: candidate, actualFrames: verified,
                       progress: FrameSizingProgressReport()),
            draggedID: 1, affectedIDs: [1, 2], to: existing
        )
        XCTAssertEqual(committed[1], verified[1])
        XCTAssertEqual(committed[2], verified[2])
        XCTAssertEqual(committed[99], existing[99])

        let restored = TiledDragCacheUpdate.applying(
            .rejectedRestored(reason: .preflight(.noTarget), actualFrames: verified),
            draggedID: 1, affectedIDs: [1, 2], to: existing
        )
        XCTAssertEqual(restored[1], verified[1])
        XCTAssertEqual(restored[2], verified[2])
        XCTAssertEqual(restored[99], existing[99])
    }

    func testCachePolicyInvalidatesOnlyTheDraggedWindowWhenNothingWasWritten() {
        let existing: [CGWindowID: CGRect] = [
            1: CGRect(x: 1, y: 1, width: 10, height: 10),
            2: CGRect(x: 2, y: 2, width: 20, height: 20),
            3: CGRect(x: 3, y: 3, width: 30, height: 30)
        ]
        // the classification read failed before any setter went out. macOS
        // moved the dragged window, nobody moved the others
        let outcome = TiledDragDropOutcome.degraded(
            candidateReason: .sizing(.readFailed(1, .cannotComplete)),
            restorationReason: .readFailed(1, .cannotComplete),
            actualFrames: [:],
            progress: FrameSizingProgressReport())

        let actions = TiledDragCachePolicy.actions(for: outcome, draggedID: 1,
                                                   affectedIDs: [1, 2, 3])
        XCTAssertEqual(actions[1], .invalidate)
        XCTAssertEqual(actions[2], .preserve)
        XCTAssertEqual(actions[3], .preserve)

        let updated = TiledDragCacheUpdate.applying(outcome, draggedID: 1,
                                                    affectedIDs: [1, 2, 3], to: existing)
        XCTAssertNil(updated[1])
        XCTAssertEqual(updated[2], existing[2])
        XCTAssertEqual(updated[3], existing[3])
    }

    func testCachePolicyInvalidatesEveryWindowTheRestorationTouched() {
        let existing: [CGWindowID: CGRect] = [
            1: CGRect(x: 1, y: 1, width: 10, height: 10),
            2: CGRect(x: 2, y: 2, width: 20, height: 20),
            3: CGRect(x: 3, y: 3, width: 30, height: 30)
        ]
        // the candidate reached window 1, the rollback reached 1 and 2, and
        // nothing reached 3
        var progress = FrameSizingProgressReport()
        progress.candidate.possiblyWritten = [1]
        var restoration = FrameSizingAttempt.Progress()
        restoration.possiblyWritten = [1, 2]
        progress.restoration = restoration
        let outcome = TiledDragDropOutcome.degraded(
            candidateReason: .sizing(.geometryMismatch(1)),
            restorationReason: .writeFailed(2, .cannotComplete),
            actualFrames: [:],
            progress: progress)

        let actions = TiledDragCachePolicy.actions(for: outcome, draggedID: 1,
                                                   affectedIDs: [1, 2, 3])
        XCTAssertEqual(actions[1], .invalidate)
        XCTAssertEqual(actions[2], .invalidate)
        XCTAssertEqual(actions[3], .preserve)

        let updated = TiledDragCacheUpdate.applying(outcome, draggedID: 1,
                                                    affectedIDs: [1, 2, 3], to: existing)
        XCTAssertNil(updated[1])
        XCTAssertNil(updated[2])
        XCTAssertEqual(updated[3], existing[3])
    }

    func testEveryCacheGetsTheSameDecisionPerWindow() {
        let existing: [CGWindowID: CGRect] = [
            1: CGRect(x: 1, y: 1, width: 10, height: 10),
            2: CGRect(x: 2, y: 2, width: 20, height: 20),
            3: CGRect(x: 3, y: 3, width: 30, height: 30)
        ]
        var progress = FrameSizingProgressReport()
        progress.candidate.possiblyWritten = [2]
        let verified: [CGWindowID: CGRect] = [
            1: CGRect(x: 100, y: 0, width: 10, height: 10),
            2: CGRect(x: 200, y: 0, width: 10, height: 10),
            3: CGRect(x: 300, y: 0, width: 10, height: 10)
        ]
        let outcomes: [TiledDragDropOutcome] = [
            .committed(candidate: BSPTree(), actualFrames: verified,
                       progress: FrameSizingProgressReport()),
            .rejectedRestored(reason: .preflight(.noTarget), actualFrames: verified),
            .degraded(candidateReason: .sizing(.geometryMismatch(2)), restorationReason: nil,
                      actualFrames: [:], progress: progress),
            .degraded(candidateReason: nil, restorationReason: nil, actualFrames: [:],
                      progress: nil)
        ]

        for outcome in outcomes {
            let actions = TiledDragCachePolicy.actions(for: outcome, draggedID: 1,
                                                       affectedIDs: [1, 2, 3])
            let updated = TiledDragCacheUpdate.applying(outcome, draggedID: 1,
                                                        affectedIDs: [1, 2, 3], to: existing)
            // whatever the tiled-position cache did for a window is exactly
            // what the frame cache is told to do for it
            for id in [CGWindowID(1), 2, 3] {
                switch actions[id] {
                case let .refresh(frame): XCTAssertEqual(updated[id], frame)
                case .invalidate: XCTAssertNil(updated[id])
                case .preserve, .none: XCTAssertEqual(updated[id], existing[id])
                }
            }
        }
    }

    func testCachePolicyWipesEveryAffectedFrameWhenProvenanceIsMissing() {
        let existing: [CGWindowID: CGRect] = [
            1: CGRect(x: 1, y: 1, width: 10, height: 10),
            2: CGRect(x: 2, y: 2, width: 20, height: 20),
            99: CGRect(x: 99, y: 99, width: 9, height: 9)
        ]
        let partial: [CGWindowID: CGRect] = [
            1: CGRect(x: 500, y: 500, width: 5, height: 5)
        ]
        let updated = TiledDragCacheUpdate.applying(
            .degraded(candidateReason: .sizing(.attemptsExhausted),
                      restorationReason: .deadlineExceeded, actualFrames: partial,
                      progress: nil),
            draggedID: 1, affectedIDs: [1, 2], to: existing
        )

        XCTAssertNil(updated[1])
        XCTAssertNil(updated[2])
        XCTAssertEqual(updated[99], existing[99])
        XCTAssertFalse(updated.values.contains(partial[1]!))
    }

    func testCachePolicyLeavesNewerCacheUntouchedWhenSuperseded() {
        let newer: [CGWindowID: CGRect] = [
            1: CGRect(x: 700, y: 1, width: 10, height: 10),
            2: CGRect(x: 800, y: 2, width: 20, height: 20),
            99: CGRect(x: 99, y: 99, width: 9, height: 9)
        ]

        XCTAssertEqual(TiledDragCacheUpdate.applying(
            .superseded, draggedID: 1, affectedIDs: [1, 2], to: newer
        ), newer)
    }

    func testDegradedFeedbackAcrossMonitorsWaitsForBothKeys() {
        var reconciler = TiledDragFeedbackReconciler()
        let source = TiledDragFeedbackKey(workspace: 1, displayID: 2)
        let release = TiledDragFeedbackKey(workspace: 2, displayID: 4)
        XCTAssertEqual(reconciler.beginDegraded(key: source, generation: 10, affectedIDs: [1, 2],
                                                alsoAwaiting: [release: [10, 11]]), [])
        XCTAssertEqual(Set(reconciler.pendingKeys), [source, release])

        // the source verified on its own is not enough
        XCTAssertEqual(reconciler.reconcile(.accepted(key: source, generation: 11,
                                                      publishedIDs: [1, 2], expectedIDs: [1, 2])), [])
        XCTAssertTrue(reconciler.hasPendingFeedback)
        XCTAssertEqual(reconciler.pendingKeys, [release])
        XCTAssertEqual(reconciler.reconcile(.accepted(key: release, generation: 12,
                                                      publishedIDs: [10, 11], expectedIDs: [10, 11])),
                       [.cancelDegraded(key: source)])
        XCTAssertFalse(reconciler.hasPendingFeedback)
    }

    func testDegradedFeedbackAcrossMonitorsShowsWhenTheReleaseScreenFails() {
        var reconciler = TiledDragFeedbackReconciler()
        let source = TiledDragFeedbackKey(workspace: 1, displayID: 2)
        let release = TiledDragFeedbackKey(workspace: 2, displayID: 4)
        _ = reconciler.beginDegraded(key: source, generation: 10, affectedIDs: [1, 2],
                                     alsoAwaiting: [release: [10, 11]])
        XCTAssertEqual(reconciler.reconcile(.failed(key: release, generation: 11, requiredIDs: [10],
                                                    recoveryPending: false)),
                       [.showDegraded(key: source, generation: 11)])
        XCTAssertEqual(reconciler.reconcile(.terminalFailure(key: release)), [], "shown once")
    }

    func testASecondFailureFromTheSameSourceKeepsWaitingOnTheReleaseScreen() {
        var reconciler = TiledDragFeedbackReconciler()
        let source = TiledDragFeedbackKey(workspace: 1, displayID: 2)
        let release = TiledDragFeedbackKey(workspace: 2, displayID: 4)
        _ = reconciler.beginDegraded(key: source, generation: 10, affectedIDs: [1, 2],
                                     alsoAwaiting: [release: [10, 11]])
        // a same-tree drop from the same source then degrades too
        XCTAssertEqual(reconciler.beginDegraded(key: source, generation: 12, affectedIDs: [1, 3]), [])
        XCTAssertEqual(Set(reconciler.pendingKeys), [source, release])

        // the source must publish both failures' windows, after the second one
        XCTAssertEqual(reconciler.reconcile(.accepted(key: source, generation: 11,
                                                      publishedIDs: [1, 2, 3],
                                                      expectedIDs: [1, 2, 3])), [],
                       "older than the second failure")
        XCTAssertEqual(reconciler.reconcile(.accepted(key: source, generation: 13,
                                                      publishedIDs: [1, 2, 3],
                                                      expectedIDs: [1, 2, 3])), [])
        XCTAssertEqual(reconciler.pendingKeys, [release])
        XCTAssertEqual(reconciler.reconcile(.accepted(key: release, generation: 14,
                                                      publishedIDs: [10, 11],
                                                      expectedIDs: [10, 11])),
                       [.cancelDegraded(key: source)])
    }

    func testANewestPassMustReachEveryAwaitedKey() {
        let source = TiledDragFeedbackKey(workspace: 1, displayID: 2)
        let release = TiledDragFeedbackKey(workspace: 2, displayID: 4)
        let pass: [TiledDragFeedbackReconciliation] = [
            .accepted(key: source, generation: 11, publishedIDs: [1, 2], expectedIDs: [1, 2])
        ]
        var reconciler = TiledDragFeedbackReconciler()
        _ = reconciler.beginDegraded(key: source, generation: 10, affectedIDs: [1, 2],
                                     alsoAwaiting: [release: [10, 11]])
        XCTAssertEqual(reconciler.reconcileNewest(pass, activeRetry: false),
                       [.showDegraded(key: source, generation: 10)],
                       "the release screen was never retiled, so nothing verified it")

        var waiting = TiledDragFeedbackReconciler()
        _ = waiting.beginDegraded(key: source, generation: 10, affectedIDs: [1, 2],
                                  alsoAwaiting: [release: [10, 11]])
        XCTAssertEqual(waiting.reconcileNewest(pass, activeRetry: true), [])
        XCTAssertEqual(waiting.pendingKeys, [release])
    }

    func testCachePolicyAcrossTreesTakesTheReleaseScreensMembersToo() {
        let existing: [CGWindowID: CGRect] = [
            1: CGRect(x: 1, y: 1, width: 10, height: 10),
            2: CGRect(x: 2, y: 2, width: 20, height: 20),
            10: CGRect(x: 10, y: 10, width: 10, height: 10),
            11: CGRect(x: 11, y: 11, width: 10, height: 10),
            99: CGRect(x: 99, y: 99, width: 9, height: 9)
        ]
        let target = TiledDragContext(
            workspace: 2, physicalDisplayID: 78,
            usableFrame: CGRect(x: 400, y: 0, width: 400, height: 300),
            gap: 8, padding: 8, maxDepth: 2, memberIDs: [10, 11], floatingIDs: [],
            fingerprint: BSPTree().structuralFingerprint())
        let cross = TiledDragCrossTree(target: target, targetCandidate: nil, moves: [:])
        let verified: [CGWindowID: CGRect] = [
            1: CGRect(x: 408, y: 8, width: 100, height: 100),
            2: CGRect(x: 8, y: 8, width: 100, height: 100),
            10: CGRect(x: 508, y: 8, width: 100, height: 100),
            11: CGRect(x: 608, y: 8, width: 100, height: 100)
        ]
        let committed = TiledDragCacheUpdate.applying(
            .acrossTrees(.committed(candidate: BSPTree(), actualFrames: verified,
                                    progress: FrameSizingProgressReport()), cross),
            draggedID: 1, affectedIDs: [1, 2], to: existing)
        for id: CGWindowID in [1, 2, 10, 11] { XCTAssertEqual(committed[id], verified[id]) }
        XCTAssertEqual(committed[99], existing[99])

        // the candidate reached 1 and 10; nothing reached 2 or 11
        var progress = FrameSizingProgressReport()
        progress.candidate.possiblyWritten = [1, 10]
        let degraded = TiledDragCachePolicy.actions(
            for: .acrossTrees(.degraded(candidateReason: .sizing(.geometryMismatch(10)),
                                        restorationReason: nil, actualFrames: [:],
                                        progress: progress), cross),
            draggedID: 1, affectedIDs: [1, 2])
        XCTAssertEqual(degraded, [1: .invalidate, 2: .preserve, 10: .invalidate, 11: .preserve])
        XCTAssertEqual(TiledDragFeedbackPolicy.feedback(
            for: .acrossTrees(.rejectedRestored(reason: .preflight(.maxDepthExceeded),
                                                actualFrames: verified), cross)), .rejected)
    }

    func testOnlyAReleaseOffTheSourceMonitorAsksForACrossMonitorDrop() {
        let captured = snapshot(draggedID: 1)
        let scheduler = DeferredScheduler()
        var modes: [TiledDragMode?] = []
        let coordinator = TiledDragSessionCoordinator(
            capture: { _ in .captured(captured) },
            apply: { _, mode in modes.append(mode); return .superseded },
            resolveTarget: { point, _ in
                point.x < 100 ? TiledDragTarget(windowID: 2, edge: .left) : nil
            },
            schedule: scheduler.schedule,
            report: { _ in },
            isCrossMonitor: { point, _ in point.x >= 1000 })

        // a same-tree target wins, a miss on the source stays a miss, and
        // only a release on another monitor carries its pointer across
        let releases: [(CGFloat, Bool)] = [(50, false), (500, false), (1500, false), (1500, true)]
        for (index, release) in releases.enumerated() {
            coordinator.mouseDown(at: .zero)
            coordinator.mouseUp(TiledDragRelease(pointer: CGPoint(x: release.0, y: 10),
                                                 swapRequested: release.1, sawDragEvent: true))
            scheduler.run(index)
        }

        XCTAssertEqual(modes.count, 4)
        XCTAssertInsert(modes[0], targetID: 2, edge: .left)
        XCTAssertNil(modes[1])
        for (mode, swap) in [(modes[2], false), (modes[3], true)] {
            guard case let .crossMonitor(pointer, swapRequested)? = mode else {
                return XCTFail("expected a cross-monitor release")
            }
            XCTAssertEqual(pointer, CGPoint(x: 1500, y: 10))
            XCTAssertEqual(swapRequested, swap)
        }
    }

    func testCompletionReportsTheExactSnapshotPairedWithItsOutcome() {
        let captured = snapshot(draggedID: 71)
        let scheduler = DeferredScheduler()
        var completion: TiledDragCompletion?
        let coordinator = TiledDragSessionCoordinator(
            capture: { _ in .captured(captured) },
            apply: { _, _ in
                .rejectedRestored(reason: .preflight(.noTarget),
                                  actualFrames: captured.originalFrames)
            },
            resolveTarget: { _, _ in nil },
            schedule: scheduler.schedule,
            report: { completion = $0 }
        )

        coordinator.mouseDown(at: .zero)
        coordinator.mouseUp(TiledDragRelease(pointer: .zero, optionDown: false,
                                              sawDragEvent: true))
        scheduler.run(0)

        XCTAssertEqual(completion?.snapshot.draggedID, 71)
        switch completion?.outcome {
        case .some(.rejectedRestored(reason: .preflight(.noTarget), actualFrames: _)):
            break
        default:
            XCTFail("completion lost its drop outcome")
        }
    }

    func testReentrantReportCannotClearNewerSessionOwnership() {
        let first = snapshot(draggedID: 81)
        let second = snapshot(draggedID: 82)
        let scheduler = DeferredScheduler()
        var next = first
        var reportedIDs: [CGWindowID] = []
        var coordinator: TiledDragSessionCoordinator!
        coordinator = TiledDragSessionCoordinator(
            capture: { _ in .captured(next) },
            apply: { _, _ in .superseded },
            resolveTarget: { _, _ in nil },
            schedule: scheduler.schedule,
            report: { completion in
                reportedIDs.append(completion.snapshot.draggedID)
                if completion.snapshot.draggedID == 81 {
                    next = second
                    coordinator.mouseDown(at: CGPoint(x: 2, y: 0))
                    coordinator.mouseUp(TiledDragRelease(pointer: .zero, optionDown: false,
                                                          sawDragEvent: true))
                }
            }
        )

        coordinator.mouseDown(at: CGPoint(x: 1, y: 0))
        coordinator.mouseUp(TiledDragRelease(pointer: .zero, optionDown: false,
                                              sawDragEvent: true))
        scheduler.run(0)

        XCTAssertEqual(reportedIDs, [81])
        XCTAssertTrue(coordinator.isFinishingDrag)
        scheduler.run(1)
        XCTAssertEqual(reportedIDs, [81, 82])
        XCTAssertFalse(coordinator.isFinishingDrag)
    }

    func testInjectedHandlerRoutesExactEventsAndCapturedFrameSideChannel() {
        let captured = snapshot(draggedID: 91)
        let combined: [CGWindowID: CGRect] = [
            91: CGRect(x: 0, y: 0, width: 400, height: 300),
            99: CGRect(x: 20, y: 20, width: 80, height: 80)
        ]
        let scheduler = DeferredScheduler()
        var downPoint: CGPoint?
        var published: [CGWindowID: CGRect]?
        var droppedID: CGWindowID?
        var droppedMode: TiledDragMode?
        var completions: [CGWindowID] = []
        let handler = TiledDragHandler(
            capture: { point, publish in
                downPoint = point
                publish(combined)
                return .captured(captured)
            },
            drop: { snapshot, mode in
                droppedID = snapshot.draggedID
                droppedMode = mode
                return .committed(candidate: snapshot.originalTree,
                                  actualFrames: snapshot.originalFrames,
                                  progress: FrameSizingProgressReport())
            },
            resolveTarget: { point, _ in
                point == CGPoint(x: 350, y: 250)
                    ? TiledDragTarget(windowID: 92, edge: .bottom) : nil
            },
            schedule: scheduler.schedule,
            capturedFrames: { published = $0 },
            readCache: { [:] },
            writeCache: { _ in },
            completion: { completions.append($0.snapshot.draggedID) },
            captureFailure: { _ in XCTFail("successful capture must not report failure") }
        )

        handler.handleMouseDown(at: CGPoint(x: 12, y: 34))
        handler.handleMouseUp(TiledDragRelease(pointer: CGPoint(x: 350, y: 250),
                                               optionDown: true, sawDragEvent: true))

        XCTAssertEqual(downPoint, CGPoint(x: 12, y: 34))
        XCTAssertEqual(published, combined)
        XCTAssertTrue(handler.isFinishingDrag)
        scheduler.run(0)
        XCTAssertEqual(droppedID, 91)
        XCTAssertSwap(droppedMode, targetID: 92)
        XCTAssertEqual(completions, [91])
        XCTAssertFalse(handler.isFinishingDrag)
    }

    func testInjectedHandlerOwnsVerifiedCacheApplicationAndFailureReporting() {
        let captured = snapshot(draggedID: 101)
        let scheduler = DeferredScheduler()
        let existing: [CGWindowID: CGRect] = [
            101: CGRect(x: 1, y: 1, width: 10, height: 10),
            999: CGRect(x: 9, y: 9, width: 9, height: 9)
        ]
        let verified: [CGWindowID: CGRect] = [
            101: CGRect(x: 100, y: 100, width: 400, height: 300)
        ]
        var written: [CGWindowID: CGRect]?
        var completion: TiledDragCompletion?
        var captureFailures = 0
        var captureResult: TiledDragCaptureResult = .captured(captured)
        let handler = TiledDragHandler(
            capture: { _, _ in captureResult },
            drop: { _, _ in
                .rejectedRestored(reason: .preflight(.noTarget), actualFrames: verified)
            },
            resolveTarget: { _, _ in nil },
            schedule: scheduler.schedule,
            capturedFrames: { _ in },
            readCache: { existing },
            writeCache: { written = $0 },
            completion: { completion = $0 },
            captureFailure: { _ in captureFailures += 1 }
        )

        handler.handleMouseDown(at: .zero)
        handler.handleMouseUp(TiledDragRelease(pointer: .zero, optionDown: false,
                                               sawDragEvent: true))
        scheduler.run(0)
        XCTAssertEqual(written?[101], verified[101])
        XCTAssertEqual(written?[999], existing[999])
        XCTAssertEqual(completion?.snapshot.draggedID, 101)

        written = nil
        captureResult = .unknown(.deadlineExceeded)
        handler.handleMouseDown(at: .zero)
        handler.handleMouseUp(TiledDragRelease(pointer: .zero, optionDown: false,
                                               sawDragEvent: true))
        XCTAssertEqual(captureFailures, 1)
        XCTAssertNil(written)
    }

    func testClickJitterOnAFailedCaptureNeitherReportsNorCompletes() {
        let press = CGPoint(x: 400, y: 300)
        let release = CGPoint(x: 403, y: 302)
        let scheduler = DeferredScheduler()
        var captureFailures = 0
        var completions = 0
        let handler = TiledDragHandler(
            capture: { _, _ in .unknown(.deadlineExceeded) },
            drop: { _, _ in XCTFail("a click must not apply a drop"); return .superseded },
            resolveTarget: { _, _ in nil },
            schedule: scheduler.schedule,
            capturedFrames: { _ in },
            readCache: { [:] },
            writeCache: { _ in XCTFail("a click must not write the cache") },
            completion: { _ in completions += 1 },
            captureFailure: { _ in captureFailures += 1 }
        )

        handler.handleMouseDown(at: press)
        handler.handleMouseUp(TiledDragRelease(
            pointer: release, optionDown: false,
            sawDragEvent: TiledDragEvent.isDrag(from: press, to: release, sawDragEvent: true)))

        XCTAssertEqual(captureFailures, 0)
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(scheduler.jobCount, 0)
        XCTAssertFalse(handler.isFinishingDrag)
    }

    func testInjectedHandlerSkipsCacheWriteEntirelyForSupersededCompletion() {
        let captured = snapshot(draggedID: 111)
        let scheduler = DeferredScheduler()
        var cacheWrites = 0
        var completionIDs: [CGWindowID] = []
        let handler = TiledDragHandler(
            capture: { _, _ in .captured(captured) },
            drop: { _, _ in .superseded },
            resolveTarget: { _, _ in nil },
            schedule: scheduler.schedule,
            capturedFrames: { _ in },
            readCache: { [111: .zero] },
            writeCache: { _ in cacheWrites += 1 },
            completion: { completionIDs.append($0.snapshot.draggedID) },
            captureFailure: { _ in }
        )

        handler.handleMouseDown(at: .zero)
        handler.handleMouseUp(TiledDragRelease(pointer: .zero, optionDown: false,
                                               sawDragEvent: true))
        scheduler.run(0)

        XCTAssertEqual(cacheWrites, 0)
        XCTAssertEqual(completionIDs, [111])
    }

    func testInjectedHandlerIgnoredDropHasNoCacheOrUIEffects() {
        let captured = snapshot(draggedID: 112)
        let scheduler = DeferredScheduler()
        var cacheReads = 0
        var cacheWrites = 0
        var completions = 0
        let handler = TiledDragHandler(
            capture: { _, _ in .captured(captured) },
            drop: { _, _ in .ignored },
            resolveTarget: { _, _ in TiledDragTarget(windowID: 113, edge: .right) },
            schedule: scheduler.schedule,
            capturedFrames: { _ in },
            readCache: { cacheReads += 1; return [112: .zero] },
            writeCache: { _ in cacheWrites += 1 },
            completion: { _ in completions += 1 },
            captureFailure: { _ in }
        )

        handler.handleMouseDown(at: .zero)
        handler.handleMouseUp(TiledDragRelease(pointer: CGPoint(x: 2, y: 0),
                                               optionDown: false, sawDragEvent: true))
        XCTAssertTrue(handler.isFinishingDrag)
        scheduler.run(0)

        XCTAssertEqual(cacheReads, 0)
        XCTAssertEqual(cacheWrites, 0)
        XCTAssertEqual(completions, 0)
        XCTAssertFalse(handler.isFinishingDrag)
    }

    func testReentrantCapturedFramesCallbackLeavesNewerPressAsOwner() {
        let first = snapshot(draggedID: 121)
        let second = snapshot(draggedID: 122)
        let scheduler = DeferredScheduler()
        var handler: TiledDragHandler!
        var activePoint = CGPoint(x: 1, y: 0)
        var publishedIDs: [CGWindowID] = []
        var appliedIDs: [CGWindowID] = []
        handler = TiledDragHandler(
            capture: { point, publish in
                if point.x == 1 {
                    publish([121: CGRect(x: 1, y: 0, width: 10, height: 10)])
                    return .captured(first)
                }
                publish([122: CGRect(x: 2, y: 0, width: 10, height: 10)])
                return .captured(second)
            },
            drop: { snapshot, _ in appliedIDs.append(snapshot.draggedID); return .superseded },
            resolveTarget: { _, _ in nil },
            schedule: scheduler.schedule,
            capturedFrames: { frames in
                publishedIDs.append(contentsOf: frames.keys.sorted())
                if frames[121] != nil {
                    activePoint = CGPoint(x: 2, y: 0)
                    handler.handleMouseDown(at: activePoint)
                }
            },
            readCache: { [:] },
            writeCache: { _ in },
            completion: { _ in },
            captureFailure: { _ in }
        )

        handler.handleMouseDown(at: activePoint)
        handler.handleMouseUp(TiledDragRelease(pointer: .zero, optionDown: false,
                                               sawDragEvent: true))
        scheduler.run(0)

        XCTAssertEqual(publishedIDs, [121, 122])
        XCTAssertEqual(appliedIDs, [122])
    }

    func testMouseUpReentrantDuringNewCaptureCannotSchedulePriorSnapshot() {
        let first = snapshot(draggedID: 131)
        let second = snapshot(draggedID: 132)
        let third = snapshot(draggedID: 133)
        let scheduler = DeferredScheduler()
        var coordinator: TiledDragSessionCoordinator!
        var appliedIDs: [CGWindowID] = []
        coordinator = TiledDragSessionCoordinator(
            capture: { point in
                if point.x == 2 {
                    coordinator.mouseUp(TiledDragRelease(pointer: .zero, optionDown: false,
                                                          sawDragEvent: true))
                    return .captured(second)
                }
                return point.x == 3 ? .captured(third) : .captured(first)
            },
            apply: { snapshot, _ in appliedIDs.append(snapshot.draggedID); return .superseded },
            resolveTarget: { _, _ in nil },
            schedule: scheduler.schedule,
            report: { _ in }
        )

        coordinator.mouseDown(at: CGPoint(x: 1, y: 0))
        coordinator.mouseDown(at: CGPoint(x: 2, y: 0))
        XCTAssertEqual(scheduler.jobCount, 0)

        coordinator.mouseUp(TiledDragRelease(pointer: .zero, optionDown: false,
                                              sawDragEvent: true))
        XCTAssertEqual(scheduler.jobCount, 0)

        coordinator.mouseDown(at: CGPoint(x: 3, y: 0))
        coordinator.mouseUp(TiledDragRelease(pointer: .zero, optionDown: false,
                                              sawDragEvent: true))
        XCTAssertEqual(scheduler.jobCount, 1)
        scheduler.run(0)
        XCTAssertEqual(appliedIDs, [133])
    }

    func testSnapshotTargetResolutionUsesCapturedActualFrames() {
        let dragged = makeWindow(id: 141)
        let target = makeWindow(id: 142)
        let tree = BSPTree()
        _ = tree.insert(dragged, maxDepth: 2)
        _ = tree.insert(target, maxDepth: 2)
        let usable = CGRect(x: 0, y: 0, width: 400, height: 300)
        let actualTarget = CGRect(x: 40, y: 20, width: 80, height: 100)
        let context = TiledDragContext(
            workspace: 1, physicalDisplayID: 77, usableFrame: usable,
            gap: 8, padding: 8, maxDepth: 2, memberIDs: [141, 142], floatingIDs: [],
            fingerprint: tree.structuralFingerprint())
        let snapshot = TiledDragSnapshot(
            draggedID: 141, sourceTree: tree, originalTree: tree.deepClone(),
            context: context,
            originalFrames: [141: CGRect(x: 220, y: 20, width: 80, height: 100),
                             142: actualTarget], generation: 1)
        let point = CGPoint(x: actualTarget.maxX - 2, y: actualTarget.midY)

        // the drop's own resolution, as WindowManager asks it at release
        let resolved = TiledDropPlanner.sameTreeTarget(
            pointer: point, draggedID: snapshot.draggedID,
            sourceTiles: snapshot.context.usableFrame, sourceSlots: snapshot.originalFrames)

        XCTAssertEqual(resolved, TiledDragTarget(windowID: 142, edge: .right))
    }

    func testCancelPreventsQueuedReleaseFromApplying() {
        let captured = snapshot(draggedID: 151)
        let scheduler = DeferredScheduler()
        var applies = 0
        var reports = 0
        let coordinator = TiledDragSessionCoordinator(
            capture: { _ in .captured(captured) },
            apply: { _, _ in applies += 1; return .superseded },
            resolveTarget: { _, _ in nil },
            schedule: scheduler.schedule,
            report: { _ in reports += 1 })
        coordinator.mouseDown(at: .zero)
        coordinator.mouseUp(TiledDragRelease(pointer: .zero, optionDown: false,
                                              sawDragEvent: true))

        coordinator.cancel()
        scheduler.run(0)

        XCTAssertEqual(applies, 0)
        XCTAssertEqual(reports, 0)
        XCTAssertFalse(coordinator.isFinishingDrag)
    }

    func testCancelDuringCapturePreventsLateSnapshotInstallation() {
        let captured = snapshot(draggedID: 152)
        let scheduler = DeferredScheduler()
        var coordinator: TiledDragSessionCoordinator!
        coordinator = TiledDragSessionCoordinator(
            capture: { _ in coordinator.cancel(); return .captured(captured) },
            apply: { _, _ in XCTFail("canceled capture applied"); return .superseded },
            resolveTarget: { _, _ in nil }, schedule: scheduler.schedule,
            report: { _ in XCTFail("canceled capture reported") })

        coordinator.mouseDown(at: .zero)
        coordinator.mouseUp(TiledDragRelease(pointer: .zero, optionDown: false,
                                              sawDragEvent: true))

        XCTAssertEqual(scheduler.jobCount, 0)
        XCTAssertFalse(coordinator.isFinishingDrag)
    }

    private func snapshot(draggedID: CGWindowID) -> TiledDragSnapshot {
        let tree = BSPTree()
        _ = tree.insert(makeWindow(id: draggedID), maxDepth: 2)
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = TiledDragContext(
            workspace: 1, physicalDisplayID: 77, usableFrame: frame,
            gap: 8, padding: 8, maxDepth: 2, memberIDs: [draggedID], floatingIDs: [],
            fingerprint: tree.structuralFingerprint()
        )
        return TiledDragSnapshot(draggedID: draggedID, sourceTree: tree,
                                 originalTree: tree.deepClone(),
                                 context: context, originalFrames: [draggedID: frame], generation: 1)
    }

    private func XCTAssertInsert(_ mode: TiledDragMode?, targetID: CGWindowID,
                                 edge: BSPTargetEdge, file: StaticString = #filePath,
                                 line: UInt = #line) {
        if case let .insert(actualID, actualEdge) = mode {
            XCTAssertEqual(actualID, targetID, file: file, line: line)
            XCTAssertEqual(actualEdge, edge, file: file, line: line)
        } else {
            XCTFail("expected insert mode", file: file, line: line)
        }
    }

    private func XCTAssertSwap(_ mode: TiledDragMode?, targetID: CGWindowID,
                               file: StaticString = #filePath, line: UInt = #line) {
        if case let .swap(actualID) = mode {
            XCTAssertEqual(actualID, targetID, file: file, line: line)
        } else {
            XCTFail("expected swap mode", file: file, line: line)
        }
    }
}

private final class DeferredScheduler {
    var delays: [TimeInterval] = []
    private var jobs: [() -> Void] = []
    var jobCount: Int { jobs.count }

    func schedule(delay: TimeInterval, job: @escaping () -> Void) {
        delays.append(delay)
        jobs.append(job)
    }

    func run(_ index: Int) {
        guard jobs.indices.contains(index) else {
            XCTFail("expected queued job at index \(index)")
            return
        }
        jobs[index]()
    }
}

final class TiledDragFeedbackPolicyTests: XCTestCase {
    /// a release with nowhere to land puts the window back; it is not an
    /// arrangement that was refused, so it neither beeps nor flashes
    func testAReleaseWithNoTargetGivesNoFeedback() {
        XCTAssertNil(TiledDragFeedbackPolicy.feedback(
            for: .rejectedRestored(reason: .preflight(.noTarget), actualFrames: [:])))
    }
}
