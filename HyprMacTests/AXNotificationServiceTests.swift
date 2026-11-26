import ApplicationServices
import XCTest
@testable import HyprMac

final class AXNotificationServiceTests: XCTestCase {
    func testDestroyedEventFallsBackToObserverPIDWhenElementIsUnreadable() {
        let service = AXNotificationService()
        var received: (AXNotificationService.Kind, pid_t)?
        service.onEvent = { received = ($0, $1) }

        service.route(
            notification: kAXUIElementDestroyedNotification as String,
            elementPID: nil,
            observerPID: 4321
        )

        XCTAssertEqual(received?.1, 4321)
        guard case .windowDestroyed? = received?.0 else {
            return XCTFail("expected destroyed event")
        }
    }

    func testMainWindowChangeIsForwarded() {
        let service = AXNotificationService()
        var received: (AXNotificationService.Kind, pid_t)?
        service.onEvent = { received = ($0, $1) }

        service.route(
            notification: kAXMainWindowChangedNotification as String,
            elementPID: 77,
            observerPID: nil
        )

        XCTAssertEqual(received?.1, 77)
        guard case .mainWindowChanged? = received?.0 else {
            return XCTFail("expected main window event")
        }
    }

    // the chrome follows a window an app or another tool moved. a move never asks for a poll
    func testAWindowMoveOrResizeGoesToTheFrameSinkNotThePoll() {
        let service = AXNotificationService()
        var polls = 0
        var moved: [CGWindowID] = []
        service.onEvent = { _, _ in polls += 1 }
        service.onFrameChange = { moved.append($0) }

        service.routeFrameChange(notification: kAXWindowMovedNotification as String, windowID: 42)
        service.routeFrameChange(notification: kAXWindowResizedNotification as String, windowID: 43)
        service.routeFrameChange(notification: kAXWindowMovedNotification as String, windowID: 0)
        service.route(notification: kAXWindowMovedNotification as String, elementPID: 77, observerPID: nil)

        XCTAssertEqual(moved, [42, 43])
        XCTAssertEqual(polls, 0)
    }

    func testEveryAppIsAskedForItsWindowMovesAndResizes() {
        XCTAssertTrue(AXNotificationService.appNotifications.contains(kAXWindowMovedNotification as String))
        XCTAssertTrue(AXNotificationService.appNotifications.contains(kAXWindowResizedNotification as String))
        XCTAssertTrue(AXNotificationService.isFrameChange(kAXWindowMovedNotification as String))
        XCTAssertFalse(AXNotificationService.isFrameChange(kAXWindowCreatedNotification as String))
    }

    func testEventIsDroppedWhenNeitherElementNorObserverHasPID() {
        let service = AXNotificationService()
        var fireCount = 0
        service.onEvent = { _, _ in fireCount += 1 }

        service.route(
            notification: kAXUIElementDestroyedNotification as String,
            elementPID: nil,
            observerPID: nil
        )

        XCTAssertEqual(fireCount, 0)
    }

    func testSubscriptionIsRecordedOnlyWhenTheDestroyNotificationTookHold() {
        XCTAssertTrue(AXNotificationService.subscriptionRecorded(destroyed: .success))
        XCTAssertTrue(AXNotificationService.subscriptionRecorded(destroyed: .notificationAlreadyRegistered))
        XCTAssertFalse(AXNotificationService.subscriptionRecorded(destroyed: .cannotComplete))
        XCTAssertFalse(AXNotificationService.subscriptionRecorded(destroyed: .failure))
    }

    func testNewWindowNeedsAddOnceItTookHold() {
        var ledger = WindowSubscriptionLedger()
        XCTAssertTrue(ledger.needsAdd(17396))

        ledger.noteAdd(17396, tookHold: true)
        ledger.finishPass(present: [17396])
        XCTAssertFalse(ledger.needsAdd(17396))
    }

    // teams, 2026-11-03: one close fired the destroy, every later close of the
    // same id was only found by the reconcile timer
    func testWindowThatLeftAndCameBackUnderTheSameIDIsAddedAgain() {
        var ledger = WindowSubscriptionLedger()
        ledger.noteAdd(17396, tookHold: true)
        ledger.finishPass(present: [17396])

        ledger.finishPass(present: [])
        XCTAssertTrue(ledger.needsAdd(17396))

        ledger.noteAdd(17396, tookHold: true)
        ledger.finishPass(present: [17396])
        XCTAssertFalse(ledger.needsAdd(17396))
    }

    func testDestroyEventRechecksAWindowThatReturnedBeforeAnyPollSawItGone() {
        var ledger = WindowSubscriptionLedger()
        ledger.noteAdd(17396, tookHold: true)
        ledger.finishPass(present: [17396])

        ledger.noteDestroyEvent()
        XCTAssertTrue(ledger.needsAdd(17396))
    }

    func testFailedReAddIsRetriedOnTheNextPass() {
        var ledger = WindowSubscriptionLedger()
        ledger.noteAdd(17396, tookHold: true)
        ledger.finishPass(present: [])

        ledger.noteAdd(17396, tookHold: false)
        ledger.finishPass(present: [17396])
        XCTAssertTrue(ledger.needsAdd(17396))
    }

    /// codex 8: only the destroy result was read. a window whose minimize
    /// add failed was recorded done and its minimize never reported
    func testAFailedMinimizeAddIsRetried() {
        XCTAssertTrue(AXNotificationService.windowSubscriptionsRecorded(
            destroyed: .success, miniaturized: .notificationAlreadyRegistered, deminiaturized: .success))
        XCTAssertFalse(AXNotificationService.windowSubscriptionsRecorded(
            destroyed: .success, miniaturized: .cannotComplete, deminiaturized: .success))
        XCTAssertFalse(AXNotificationService.windowSubscriptionsRecorded(
            destroyed: .success, miniaturized: .success, deminiaturized: .failure))
    }

    func testAWindowThatKeepsRefusingIsRecordedAfterTheBudget() {
        var ledger = WindowSubscriptionLedger()
        var lastTry: [Bool] = []
        for _ in 0..<WindowSubscriptionLedger.maxFailedAdds {
            XCTAssertTrue(ledger.needsAdd(17396))
            lastTry.append(ledger.noteAdd(17396, tookHold: false))
            ledger.finishPass(present: [17396])
        }
        XCTAssertEqual(lastTry.filter { $0 }.count, 1)
        XCTAssertTrue(lastTry.last!)
        XCTAssertFalse(ledger.needsAdd(17396), "no more tries while it stays")

        // away and back: a fresh budget
        ledger.finishPass(present: [])
        XCTAssertTrue(ledger.needsAdd(17396))
        XCTAssertFalse(ledger.noteAdd(17396, tookHold: false))
    }

    /// codex 8 / fable: attach counted as done when either the create or
    /// the focus add took, and the one that failed was never asked again
    func testEachRefusedAppSubscriptionIsRetriedOnItsOwn() {
        var retry = AppSubscriptionRetry()
        let created = kAXWindowCreatedNotification as String
        let focused = kAXFocusedWindowChangedNotification as String
        retry.note(created, tookHold: false)
        retry.note(focused, tookHold: true)
        XCTAssertEqual(retry.due, [created])

        retry.note(created, tookHold: true)
        XCTAssertTrue(retry.due.isEmpty)
        XCTAssertTrue(retry.gaveUp.isEmpty)
    }

    func testARefusedAppSubscriptionGivesUpAfterTheBudget() {
        var retry = AppSubscriptionRetry()
        let created = kAXWindowCreatedNotification as String
        var lastTry: [Bool] = []
        for _ in 0..<AppSubscriptionRetry.maxAttempts {
            lastTry.append(retry.note(created, tookHold: false))
        }
        XCTAssertEqual(lastTry, Array(repeating: false, count: AppSubscriptionRetry.maxAttempts - 1) + [true])
        XCTAssertTrue(retry.due.isEmpty)
        XCTAssertEqual(retry.gaveUp, [created])
    }

    // MARK: - an app that does not answer

    private let names = [kAXFocusedWindowChangedNotification as String,
                         kAXMainWindowChangedNotification as String,
                         kAXWindowCreatedNotification as String]

    func testAPassStopsAtTheFirstAddTheAppLeavesUnanswered() {
        // a launching app: every add waited out its timeout on the main thread
        var retry = AppSubscriptionRetry()
        var asked: [String] = []
        let results = retry.pass(names, now: 10) { asked.append($0); return .cannotComplete }
        XCTAssertEqual(asked, [names[0]])
        XCTAssertEqual(results.map(\.name), [names[0]])
        XCTAssertEqual(retry.due, names.sorted())

        // it answers: the pass asks for all three and nothing is owed
        asked = []
        _ = retry.pass(retry.due, now: 12) { asked.append($0); return .success }
        XCTAssertEqual(asked, names.sorted())
        XCTAssertTrue(retry.due.isEmpty)
    }

    func testNamesNotAskedKeepTheirTries() {
        var retry = AppSubscriptionRetry()
        var last = false
        for pass in 0..<AppSubscriptionRetry.maxAttempts {
            last = retry.pass(pass == 0 ? names : retry.due, now: Double(pass) * 2) { _ in .cannotComplete }
                .first?.lastTry ?? false
        }
        XCTAssertTrue(last)
        XCTAssertEqual(retry.gaveUp, [names[0]])
        XCTAssertEqual(retry.due, [names[1], names[2]].sorted())
    }

    func testAnAppThatLeftAnAddUnansweredIsLeftAloneForThePause() {
        var retry = AppSubscriptionRetry()
        XCTAssertTrue(retry.mayAsk(now: 0))
        _ = retry.pass(names, now: 10) { _ in .cannotComplete }
        XCTAssertFalse(retry.mayAsk(now: 10.5))
        XCTAssertTrue(retry.mayAsk(now: 10 + AppSubscriptionRetry.silentPause))
        // an answer, even a refusal, ends the pause
        _ = retry.pass(retry.due, now: 11) { _ in .failure }
        XCTAssertTrue(retry.mayAsk(now: 11))
    }

    func testARefusalTheAppAnsweredDoesNotEndThePass() {
        var retry = AppSubscriptionRetry()
        var asked: [String] = []
        let results = retry.pass(names, now: 0) { name in
            asked.append(name)
            return name == self.names[0] ? .notificationUnsupported : .success
        }
        XCTAssertEqual(asked, names)
        XCTAssertEqual(results.map(\.wasOwed), [false, false, false])
        XCTAssertEqual(retry.due, [names[0]])
    }

    func testStartupAttachesAppsBeforeSubscribingInitialWindows() {
        var calls: [String] = []
        var subscribed: [CGWindowID] = []

        AXNotificationService.activateInitialSubscriptions(
            initialWindows: [CGWindowID(42)],
            attach: { calls.append("attach") },
            subscribe: {
                calls.append("subscribe")
                subscribed = $0
            }
        )

        XCTAssertEqual(calls, ["attach", "subscribe"])
        XCTAssertEqual(subscribed, [42])
    }
}
