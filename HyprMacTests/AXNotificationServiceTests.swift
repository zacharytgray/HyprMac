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
