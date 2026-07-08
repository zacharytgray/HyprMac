import XCTest
@testable import HyprMac

// PollingSchedulerTests pin the coalescing-token + debounce semantics.
// the scheduler runs on the main run loop, so each timing test waits on
// XCTestExpectation rather than busy-waiting.

final class PollingSchedulerTests: XCTestCase {

    // MARK: - schedule(after:) coalescing

    func testSingleScheduleFiresOnce() {
        var fireCount = 0
        let scheduler = PollingScheduler { fireCount += 1 }
        let exp = expectation(description: "poll fired")

        scheduler.schedule(after: 0.05)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(fireCount, 1)
    }

    func testRepeatedSchedulesCollapseIntoOne() {
        var fireCount = 0
        let scheduler = PollingScheduler { fireCount += 1 }
        let exp = expectation(description: "poll fired")

        // a burst of schedule() calls during the in-flight window must collapse —
        // notification storms (rapid app launches, etc.) shouldn't pile polls.
        scheduler.schedule(after: 0.05)
        scheduler.schedule(after: 0.05)
        scheduler.schedule(after: 0.05)
        scheduler.schedule(after: 0.05)
        scheduler.schedule(after: 0.05)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(fireCount, 1)
    }

    func testScheduleAfterPollFiresAgain() {
        var fireCount = 0
        let scheduler = PollingScheduler { fireCount += 1 }
        let firstFired = expectation(description: "first poll fired")
        let secondFired = expectation(description: "second poll fired")

        // first poll, wait for it to land, then schedule a second.
        // the in-flight token must clear on fire so a new schedule takes effect.
        scheduler.schedule(after: 0.05)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            firstFired.fulfill()
            scheduler.schedule(after: 0.05)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { secondFired.fulfill() }
        wait(for: [firstFired, secondFired], timeout: 1.0)
        XCTAssertEqual(fireCount, 2)
    }

    func testHonoursDebounceDelay() {
        var fireDate: Date?
        let scheduler = PollingScheduler { fireDate = Date() }
        let exp = expectation(description: "poll fired")
        let scheduledAt = Date()

        scheduler.schedule(after: 0.10)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        guard let fired = fireDate else { return XCTFail("poll did not fire") }
        let elapsed = fired.timeIntervalSince(scheduledAt)
        // tolerance: main-queue scheduling drift on CI is ~30ms in our experience
        XCTAssertGreaterThanOrEqual(elapsed, 0.08)
        XCTAssertLessThanOrEqual(elapsed, 0.30)
    }

    // MARK: - reconcile timer

    // the production reconcile interval is a slow 10s safety net now that
    // AXObserver notifications drive discovery. these timer tests inject a
    // short interval so they exercise the timer without a 10s wait; the
    // production value is pinned separately in testDefaultReconcileIntervalIsSlow.

    func testDefaultReconcileIntervalIsSlow() {
        // contract: the timer is a slow reconcile net, not a 1 Hz poller.
        XCTAssertEqual(PollingScheduler.defaultReconcileInterval, 10.0)
    }

    func testStartFiresPeriodicTimer() {
        var fireCount = 0
        let scheduler = PollingScheduler(periodicInterval: 0.2) { fireCount += 1 }
        let exp = expectation(description: "first reconcile tick")

        scheduler.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        scheduler.stop()
        XCTAssertGreaterThanOrEqual(fireCount, 1)
    }

    func testStopHaltsPeriodicTicks() {
        var fireCount = 0
        let scheduler = PollingScheduler(periodicInterval: 0.2) { fireCount += 1 }
        scheduler.start()
        scheduler.stop()
        let countAfterStop = fireCount

        let exp = expectation(description: "no further ticks after stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(fireCount, countAfterStop)
    }

    func testStopCancelsInFlightPollAndClearsToken() {
        var fireCount = 0
        let scheduler = PollingScheduler { fireCount += 1 }
        let exp = expectation(description: "post-stop schedule fires")

        // schedule a poll, immediately stop — clearing pendingPoll cancels
        // the in-flight fire (the closure bails on a cleared token), and the
        // token must clear so a fresh schedule after start() goes through.
        scheduler.schedule(after: 0.05)
        scheduler.stop()

        // wait past the original asyncAfter, then start + schedule again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            scheduler.start()
            scheduler.schedule(after: 0.05)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        scheduler.stop()
        // only the post-start schedule fires; the pre-stop one was canceled
        XCTAssertEqual(fireCount, 1)
    }

    // MARK: - suppression (Phase 4 step 5)

    func testSuppressedScheduleDefersUntilSuppressionLifts() {
        var fireCount = 0
        var suppressed = true
        let scheduler = PollingScheduler { fireCount += 1 }
        scheduler.isSuppressed = { suppressed }

        // while suppressed the poll must not fire — but it must not be lost
        // either. with event-driven triggers there's no 1 Hz timer to catch a
        // dropped event (a windowCreated during a workspace transition would
        // go unmanaged until the 10s reconcile), so the fire defers and lands
        // once the suppression lifts.
        let stillSuppressed = expectation(description: "no fire while suppressed")
        scheduler.schedule(after: 0.05)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            XCTAssertEqual(fireCount, 0, "suppressed poll must not fire")
            suppressed = false
            stillSuppressed.fulfill()
        }
        let fired = expectation(description: "deferred poll fired after lift")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.80) { fired.fulfill() }
        wait(for: [stillSuppressed, fired], timeout: 2.0)
        XCTAssertEqual(fireCount, 1, "deferred poll must fire exactly once after suppression lifts")
    }

    func testSuppressionStartedAfterScheduleDefersFire() {
        var fireCount = 0
        var suppressed = false
        let scheduler = PollingScheduler { fireCount += 1 }
        scheduler.isSuppressed = { suppressed }

        // schedule with no suppression, then suppress before the asyncAfter
        // resolves — the cross-swap path: a poll landing mid-critical-section
        // must hold off, then fire once the suppression clears.
        scheduler.schedule(after: 0.10)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { suppressed = true }
        let stillSuppressed = expectation(description: "no fire while suppressed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            XCTAssertEqual(fireCount, 0, "suppression starting mid-flight must defer the fire")
            suppressed = false
            stillSuppressed.fulfill()
        }
        let fired = expectation(description: "deferred poll fired after lift")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.90) { fired.fulfill() }
        wait(for: [stillSuppressed, fired], timeout: 2.0)
        XCTAssertEqual(fireCount, 1, "deferred poll must fire exactly once after suppression lifts")
    }

    func testTimerTickHonoursSuppression() {
        var fireCount = 0
        var suppressed = true
        let scheduler = PollingScheduler(periodicInterval: 0.2) { fireCount += 1 }
        scheduler.isSuppressed = { suppressed }

        scheduler.start()
        // wait long enough for ~one tick. while suppressed, ticks must drop.
        let exp1 = expectation(description: "first window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp1.fulfill() }
        wait(for: [exp1], timeout: 2.0)
        XCTAssertEqual(fireCount, 0, "suppressed timer must not fire onPoll")

        // lift suppression and confirm subsequent ticks fire.
        suppressed = false
        let exp2 = expectation(description: "second window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp2.fulfill() }
        wait(for: [exp2], timeout: 2.0)
        scheduler.stop()
        XCTAssertGreaterThanOrEqual(fireCount, 1, "post-suppression timer must resume firing")
    }

    func testDoubleStartIsIdempotent() {
        var fireCount = 0
        let scheduler = PollingScheduler(periodicInterval: 0.3) { fireCount += 1 }
        let exp = expectation(description: "tick")

        scheduler.start()
        scheduler.start() // second start must not install a second timer

        // one timer fires once in a 0.5s window (next tick lands at ~0.6s);
        // a second timer would double the count to 2.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        scheduler.stop()
        XCTAssertEqual(fireCount, 1)
    }
}
