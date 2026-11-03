import XCTest
@testable import HyprMac

final class ActionPolicyTests: XCTestCase {
    private func decide(_ action: Action, transition: Bool = false, scratchpad: Bool = false)
        -> ActionPolicy.Decision {
        ActionPolicy.decide(action, displayTransitionPending: transition, scratchpadVisible: scratchpad)
    }

    func testOverviewPassesEveryGateAndKeepsRecovery() {
        let decision = decide(.showWorkspaceOverview, transition: true, scratchpad: true)
        XCTAssertEqual(decision.outcome, .toggleOverview)
        XCTAssertFalse(decision.cancelsRecovery)
    }

    func testDroppedPressStillCancelsARecovery() {
        let decision = decide(.moveToWorkspace(2), transition: true)
        XCTAssertEqual(decision.outcome, .dropMidDisplayTransition)
        XCTAssertTrue(decision.cancelsRecovery)
    }

    func testTransitionDropComesBeforeTheScratchpad() {
        XCTAssertEqual(decide(.switchWorkspace(2), transition: true, scratchpad: true).outcome,
                       .dropMidDisplayTransition)
    }

    func testTransitionLeavesOtherActionsAlone() {
        XCTAssertEqual(decide(.focusDirection(.left), transition: true).outcome, .dispatch)
        XCTAssertEqual(decide(.toggleFloating, transition: true, scratchpad: true).outcome,
                       .scratchpad(.toggleMember))
    }

    func testScratchpadRouteOnlyAppliesWhileTheLayerIsUp() {
        XCTAssertEqual(decide(.toggleFloating).outcome, .dispatch)
    }

    func testScratchpadRouteTable() {
        let table: [(Action, ScratchpadActionRoute?)] = [
            (.moveToWorkspace(2), .ejectThenDispatch),
            (.moveToWorkspaceAndFollow(2), .ejectThenDispatch),
            (.moveWindowToMonitor(.left), .ejectThenDispatch),
            (.switchWorkspace(2), .hideThenDispatch),
            (.cycleWorkspace(1), .hideThenDispatch),
            (.moveToNextEmptyWorkspace, .refuse),
            (.toggleFloating, .toggleMember),
            (.focusFloating, .cycleSummoned),
            (.launchApp(bundleID: "com.example.app"), .focusMemberElseDispatch(bundleID: "com.example.app")),
            (.focusDirection(.up), nil),
            (.swapDirection(.up), nil),
            (.resizeDirection(.up), nil),
            (.toggleSplit, nil),
            (.toggleScratchpad, nil),
            (.moveToScratchpad, nil),
            (.closeWindow, nil),
            (.retileAll, nil),
            (.saveLayout, nil),
            (.restoreLayout, nil),
            (.toggleTiling, nil),
            (.focusMenuBar, nil),
            (.showKeybinds, nil),
            (.runCommand(label: "", command: "ls"), nil),
        ]
        for (action, route) in table {
            XCTAssertEqual(ScratchpadActionRoute.route(for: action), route, "\(action)")
        }
    }

    func testLaunchAppDispatchesWithoutTheLayer() {
        XCTAssertEqual(decide(.launchApp(bundleID: "com.example.app")).outcome, .dispatch)
    }
}

final class DisplaySettleTests: XCTestCase {
    func testSpuriousOnlyWhenSettledAndUnchanged() {
        XCTAssertTrue(DisplaySettle.isSpuriousNotification(
            transitionPending: false, fingerprint: "a", lastSettledFingerprint: "a"))
        XCTAssertFalse(DisplaySettle.isSpuriousNotification(
            transitionPending: false, fingerprint: "b", lastSettledFingerprint: "a"))
        XCTAssertFalse(DisplaySettle.isSpuriousNotification(
            transitionPending: true, fingerprint: "a", lastSettledFingerprint: "a"))
    }

    // reading it refreshes DisplayManager, so when it runs matters
    func testPendingTransitionDoesNotReadTheFingerprint() {
        var reads = 0
        func fingerprint() -> String { reads += 1; return "a" }
        _ = DisplaySettle.isSpuriousNotification(
            transitionPending: true, fingerprint: fingerprint(), lastSettledFingerprint: "a")
        XCTAssertEqual(reads, 0)
        _ = DisplaySettle.isSpuriousNotification(
            transitionPending: false, fingerprint: fingerprint(), lastSettledFingerprint: "a")
        XCTAssertEqual(reads, 1)
    }

    func testOnlyTheFirstNotificationSavesTheDepartingLayout() {
        XCTAssertTrue(DisplaySettle.savesDepartingLayout(transitionPending: false, settledKey: "A"))
        XCTAssertFalse(DisplaySettle.savesDepartingLayout(transitionPending: true, settledKey: "A"))
        XCTAssertFalse(DisplaySettle.savesDepartingLayout(transitionPending: false, settledKey: ""))
    }

    func testRecentWakeUsesTheLongerWindow() {
        XCTAssertTrue(DisplaySettle.isRecentWake(sinceInterruption: 19.9))
        XCTAssertFalse(DisplaySettle.isRecentWake(sinceInterruption: 20))
        XCTAssertEqual(DisplaySettle.stabilityWindow(recentWake: true), 5)
        XCTAssertEqual(DisplaySettle.stabilityWindow(recentWake: false), 2)
    }

    func testResettlesOnlyAfterTheSpanEndsWithATransitionPending() {
        XCTAssertTrue(DisplaySettle.resettlesAfterInterruption(transitionPending: true, sessionInterrupted: false))
        XCTAssertFalse(DisplaySettle.resettlesAfterInterruption(transitionPending: true, sessionInterrupted: true))
        XCTAssertFalse(DisplaySettle.resettlesAfterInterruption(transitionPending: false, sessionInterrupted: false))
    }

    private func decision(generationAtSchedule: Int = 1, currentGeneration: Int = 1,
                          interrupted: Bool = false, atSchedule: String = "new",
                          last: String = "old", current: String = "new",
                          reads: UnsafeMutablePointer<Int>? = nil) -> DisplaySettle.TimerDecision {
        DisplaySettle.timerDecision(
            generationAtSchedule: generationAtSchedule, currentGeneration: currentGeneration,
            sessionInterrupted: interrupted, fingerprintAtSchedule: atSchedule,
            lastSettledFingerprint: last,
            currentFingerprint: { reads?.pointee += 1; return current })
    }

    func testTimerDecisions() {
        XCTAssertEqual(decision(), .reconcile(fingerprint: "new"))
        XCTAssertEqual(decision(currentGeneration: 2), .superseded)
        XCTAssertEqual(decision(interrupted: true), .deferredByInterruption)
        XCTAssertEqual(decision(current: "newer"), .stillChanging)
        XCTAssertEqual(decision(last: "new"), .backAsItWas)
    }

    func testTimerChecksRunInOrder() {
        // superseded beats everything, and an interruption beats a changed desk
        XCTAssertEqual(decision(currentGeneration: 2, interrupted: true, current: "newer"), .superseded)
        XCTAssertEqual(decision(interrupted: true, current: "newer"), .deferredByInterruption)
        // still changing beats back-as-it-was
        XCTAssertEqual(decision(atSchedule: "x", last: "new"), .stillChanging)
    }

    // reading it can end an interruption past its cap
    func testASupersededTimerDoesNotReadTheInterruption() {
        var reads = 0
        func interrupted() -> Bool { reads += 1; return false }
        _ = DisplaySettle.timerDecision(
            generationAtSchedule: 1, currentGeneration: 2, sessionInterrupted: interrupted(),
            fingerprintAtSchedule: "a", lastSettledFingerprint: "a", currentFingerprint: { "a" })
        XCTAssertEqual(reads, 0)
        _ = DisplaySettle.resettlesAfterInterruption(transitionPending: false,
                                                     sessionInterrupted: interrupted())
        XCTAssertEqual(reads, 0)
    }

    func testTimerOnlyReadsTheFingerprintPastTheFirstTwoChecks() {
        var reads = 0
        _ = decision(currentGeneration: 2, reads: &reads)
        _ = decision(interrupted: true, reads: &reads)
        XCTAssertEqual(reads, 0)
        _ = decision(reads: &reads)
        XCTAssertEqual(reads, 1)
    }
}

final class FocusResolutionTests: XCTestCase {
    private let a = makeWindow(id: 1)
    private let b = makeWindow(id: 2)
    private let c = makeWindow(id: 3)
    private let d = makeWindow(id: 4)

    private func resolve(border: CGWindowID? = nil, last: CGWindowID = 0,
                         selectable: Set<CGWindowID> = [], cached: Set<CGWindowID> = [1, 2],
                         ax: HyprWindow? = nil, member: HyprWindow? = nil,
                         axReads: UnsafeMutablePointer<Int>? = nil) -> FocusResolution.Resolved? {
        let windows = [a, b, c, d]
        return FocusResolution.resolve(
            borderID: border, lastFocusedID: last,
            isSelectable: { selectable.contains($0) },
            cachedWindow: { id in cached.contains(id) ? windows.first { $0.windowID == id } : nil },
            axFocused: { axReads?.pointee += 1; return ax },
            scratchpadMember: { member })
    }

    func testOrderIsBorderLastAccessibilityMember() {
        XCTAssertEqual(resolve(border: 1, last: 2, selectable: [1, 2, 3], ax: c, member: d)?.source, .border)
        XCTAssertEqual(resolve(border: 1, last: 2, selectable: [2, 3], ax: c, member: d)?.source, .lastFocused)
        XCTAssertEqual(resolve(border: 1, last: 2, selectable: [3], ax: c, member: d)?.source, .accessibility)
        XCTAssertEqual(resolve(border: 1, last: 2, selectable: [], ax: c, member: d)?.source, .scratchpadMember)
        XCTAssertNil(resolve(border: 1, last: 2, selectable: [], ax: c))
    }

    func testSelectableButUncachedFallsThrough() {
        XCTAssertEqual(resolve(border: 1, last: 2, selectable: [1, 2], cached: [2])?.window.windowID, 2)
    }

    func testLastFocusedZeroIsNotACandidate() {
        XCTAssertNil(resolve(last: 0, selectable: [0], cached: [0]))
    }

    func testAccessibilityIsNotReadWhenACachedCandidateWins() {
        var reads = 0
        _ = resolve(border: 1, selectable: [1], axReads: &reads)
        XCTAssertEqual(reads, 0)
        _ = resolve(selectable: [], axReads: &reads)
        XCTAssertEqual(reads, 1)
    }

    private func selectable(_ id: CGWindowID, scratchpad: Bool = false, summoned: Set<CGWindowID> = [],
                            workspace: Set<CGWindowID> = [], floating: Set<CGWindowID> = [],
                            visible: Set<CGWindowID> = []) -> Bool {
        FocusResolution.isSelectable(id, scratchpadVisible: scratchpad,
                                     isSummoned: { summoned.contains($0) },
                                     workspaceWindows: workspace, floatingWindowIDs: floating,
                                     isWindowVisible: { visible.contains($0) })
    }

    func testScratchpadUpOnlyMembersAreSelectable() {
        XCTAssertTrue(selectable(1, scratchpad: true, summoned: [1]))
        XCTAssertFalse(selectable(1, scratchpad: true, workspace: [1], floating: [1], visible: [1]))
    }

    func testWorkspaceWindowsAndVisibleFloatersAreSelectable() {
        XCTAssertTrue(selectable(1, workspace: [1]))
        XCTAssertTrue(selectable(1, floating: [1], visible: [1]))
        XCTAssertFalse(selectable(1, floating: [1]))
        XCTAssertFalse(selectable(1, visible: [1]))
    }
}

final class DockAffordanceTests: XCTestCase {
    private func decide(_ app: [Int], visible: Set<Int> = [1], scratchpadVisible: Bool = false) -> DockAffordance {
        DockAffordance.decide(appWorkspaces: app, visibleWorkspaces: visible,
                              scratchpadWorkspace: 0, scratchpadVisible: scratchpadVisible)
    }

    func testAVisibleWindowDoesNothing() {
        XCTAssertEqual(decide([1, 3]), .none)
    }

    func testAMemberOfTheVisibleLayerDoesNothing() {
        XCTAssertEqual(decide([0, 3], scratchpadVisible: true), .none)
    }

    func testAnAppInTheHiddenScratchpadSummonsTheLayer() {
        XCTAssertEqual(decide([0]), .showScratchpad)
        XCTAssertEqual(decide([0, 3]), .showScratchpad)
    }

    func testAHiddenAppSwitchesToItsLowestWorkspace() {
        XCTAssertEqual(decide([5, 3]), .switchWorkspace(3))
    }

    func testAnAppWithNoTrackedWindowsDoesNothing() {
        XCTAssertEqual(decide([]), .none)
    }
}
