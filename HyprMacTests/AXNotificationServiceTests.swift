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
