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
