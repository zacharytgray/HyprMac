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

        scheduler.start()
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
        scheduler.start()
        scheduler.schedule(after: 0.05)
        scheduler.schedule(after: 0.05)
        scheduler.schedule(after: 0.05)
        scheduler.schedule(after: 0.05)
        scheduler.schedule(after: 0.05)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(fireCount, 1)
    }

    func testSoonerScheduleReArmsAPendingLaterOne() {
        var fireCount = 0
        let scheduler = PollingScheduler { fireCount += 1 }
        let exp = expectation(description: "sooner request fired")

        // a hold running out asks for a poll seconds away. an event poll
        // asked for after it must not wait behind it
        scheduler.start()
        scheduler.schedule(after: 5.0)
        scheduler.schedule(after: 0.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        scheduler.stop()
        XCTAssertEqual(fireCount, 1, "the 0.2 s request must fire, not wait for the 5 s one")
    }

    func testScheduleAfterPollFiresAgain() {
        var fireCount = 0
        var onFire: (() -> Void)?
        let scheduler = PollingScheduler {
            fireCount += 1
            onFire?()
        }
        let secondFired = expectation(description: "second poll fired")

        scheduler.start()
        // waits for the real fire, not a fixed delay: timers can run late.
        // the in-flight token must clear on fire so a new schedule takes effect.
        onFire = {
            onFire = { secondFired.fulfill() }
            DispatchQueue.main.async { scheduler.schedule(after: 0.05) }
        }
        scheduler.schedule(after: 0.05)
        wait(for: [secondFired], timeout: 5.0)
        scheduler.stop()
        XCTAssertEqual(fireCount, 2)
    }

    func testHonoursDebounceDelay() {
        var fireDate: Date?
        let scheduler = PollingScheduler { fireDate = Date() }
        let exp = expectation(description: "poll fired")
        let scheduledAt = Date()

        scheduler.start()
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

    func testScheduleBeforeStartWaitsForStartupAndThenFires() {
        var fireCount = 0
        let scheduler = PollingScheduler(periodicInterval: 10) { fireCount += 1 }

        scheduler.schedule(after: 0.02)
        scheduler.schedule(after: 0.02)

        let beforeStart = expectation(description: "pre-start request stays dormant")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            XCTAssertEqual(fireCount, 0)
            beforeStart.fulfill()
        }
        wait(for: [beforeStart], timeout: 1.0)

        scheduler.start()
        let afterStart = expectation(description: "coalesced request fires after start")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { afterStart.fulfill() }
        wait(for: [afterStart], timeout: 1.0)
        scheduler.stop()
        XCTAssertEqual(fireCount, 1)
    }

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
        var awaitingRestartedPoll = false
        let canceled = expectation(description: "pre-stop schedule stays canceled")
        canceled.isInverted = true
        let restarted = expectation(description: "post-stop schedule fires")
        let scheduler = PollingScheduler {
            if awaitingRestartedPoll {
                restarted.fulfill()
            } else {
                canceled.fulfill()
            }
        }

        // schedule a poll, immediately stop — clearing pendingPoll cancels
        // the in-flight fire (the closure bails on a cleared token), and the
        // token must clear so a fresh schedule after start() goes through.
        scheduler.schedule(after: 0.05)
        scheduler.stop()

        wait(for: [canceled], timeout: 0.10)

        awaitingRestartedPoll = true
        scheduler.start()
        scheduler.schedule(after: 0.05)
        wait(for: [restarted], timeout: 1.0)
        scheduler.stop()
    }

    func testStoppedClosureCannotConsumeNewSchedule() {
        var fireCount = 0
        let scheduler = PollingScheduler { fireCount += 1 }

        scheduler.schedule(after: 0.10)
        scheduler.stop()
        scheduler.schedule(after: 0.30)
        scheduler.start()

        let oldDeadlinePassed = expectation(description: "old deadline passed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            XCTAssertEqual(fireCount, 0, "pre-stop closure must not fire the new schedule")
            oldDeadlinePassed.fulfill()
        }
        let newDeadlinePassed = expectation(description: "new deadline passed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
            XCTAssertEqual(fireCount, 1, "post-stop schedule must keep its own deadline")
            newDeadlinePassed.fulfill()
        }

        wait(for: [oldDeadlinePassed, newDeadlinePassed], timeout: 1.0)
        scheduler.stop()
    }

    // MARK: - suppression

    func testSuppressedScheduleDefersUntilSuppressionLifts() {
        var fireCount = 0
        var suppressed = true
        let scheduler = PollingScheduler { fireCount += 1 }
        scheduler.isSuppressed = { suppressed }

        scheduler.start()
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

        scheduler.start()
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
        // wait long enough for ~one tick. while suppressed, ticks must wait.
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

    func testTickMissedWhileSuppressedRunsOnceWhenSuppressionLifts() {
        var fireCount = 0
        var suppressed = true
        let scheduler = PollingScheduler(periodicInterval: 0.1) { fireCount += 1 }
        scheduler.isSuppressed = { suppressed }
        scheduler.start()

        let held = expectation(description: "held across several ticks")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { held.fulfill() }
        wait(for: [held], timeout: 2.0)
        XCTAssertEqual(fireCount, 0)

        // stop the timer so a later tick can't pass for the deferred poll
        let timer = Mirror(reflecting: scheduler).children.first { $0.label == "timer" }?.value as? Timer
        XCTAssertNotNil(timer)
        timer?.invalidate()
        suppressed = false

        let lifted = expectation(description: "deferred retry had time to run")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { lifted.fulfill() }
        wait(for: [lifted], timeout: 2.0)
        scheduler.stop()
        XCTAssertEqual(fireCount, 1, "the ticks missed during one suppression collapse into one poll")
    }

    func testDoubleStartIsIdempotent() {
        let scheduler = PollingScheduler(periodicInterval: 10) {}

        func installedTimer() -> Timer? {
            guard let optional = Mirror(reflecting: scheduler).children
                .first(where: { $0.label == "timer" })?.value else { return nil }
            return Mirror(reflecting: optional).children.first?.value as? Timer
        }

        scheduler.start()
        let first = installedTimer()
        scheduler.start() // second start must not install a second timer
        let second = installedTimer()

        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
        XCTAssertTrue(first?.isValid == true)
        scheduler.stop()
        XCTAssertFalse(first?.isValid == true)
    }
}
