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

    // MARK: - start / stop

    func testStartFiresPeriodicTimer() {
        var fireCount = 0
        let scheduler = PollingScheduler { fireCount += 1 }
        let exp = expectation(description: "first periodic tick")

        scheduler.start()
        // periodic interval is 1.0s — wait long enough for one tick but cap
        // the test runtime. periodicInterval is private; this asserts behavior,
        // not the exact value.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exp.fulfill() }
        wait(for: [exp], timeout: 3.0)
        scheduler.stop()
        XCTAssertGreaterThanOrEqual(fireCount, 1)
    }

    func testStopHaltsPeriodicTicks() {
        var fireCount = 0
        let scheduler = PollingScheduler { fireCount += 1 }
        scheduler.start()
        scheduler.stop()
        let countAfterStop = fireCount

        let exp = expectation(description: "no further ticks after stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exp.fulfill() }
        wait(for: [exp], timeout: 3.0)
        XCTAssertEqual(fireCount, countAfterStop)
    }

    func testStopClearsInFlightToken() {
        var fireCount = 0
        let scheduler = PollingScheduler { fireCount += 1 }
        let exp = expectation(description: "post-stop schedule fires")

        // schedule a poll, immediately stop — the in-flight asyncAfter will still
        // fire (we don't cancel it), but the token must clear on stop so a fresh
        // schedule after start() goes through. the closure increments fireCount
        // either way; we're asserting the token state, not closure invocation count.
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
        // 1 from the pre-stop in-flight + 1 from the post-start schedule
        XCTAssertGreaterThanOrEqual(fireCount, 2)
    }

    // MARK: - suppression (Phase 4 step 5)

    func testSuppressedScheduleIsDropped() {
        var fireCount = 0
        let scheduler = PollingScheduler { fireCount += 1 }
        scheduler.isSuppressed = { true }

        let exp = expectation(description: "no fire")
        scheduler.schedule(after: 0.05)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(fireCount, 0, "suppressed schedule must not fire")
    }

    func testSuppressionStartedAfterScheduleStillBlocksFire() {
        var fireCount = 0
        var suppressed = false
        let scheduler = PollingScheduler { fireCount += 1 }
        scheduler.isSuppressed = { suppressed }

        let exp = expectation(description: "no fire")
        // schedule with no suppression, then suppress before the asyncAfter resolves.
        // the fire-time re-check must drop the call — this is the cross-swap path:
        // a 1Hz poll could land just as DragSwapHandler enters its critical section.
        scheduler.schedule(after: 0.10)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { suppressed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(fireCount, 0, "suppression starting mid-flight must drop the fire")
    }

    func testTimerTickHonoursSuppression() {
        var fireCount = 0
        var suppressed = true
        let scheduler = PollingScheduler { fireCount += 1 }
        scheduler.isSuppressed = { suppressed }

        scheduler.start()
        // wait long enough for ~one tick. while suppressed, ticks must drop.
        let exp1 = expectation(description: "first window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exp1.fulfill() }
        wait(for: [exp1], timeout: 3.0)
        XCTAssertEqual(fireCount, 0, "suppressed timer must not fire onPoll")

        // lift suppression and confirm subsequent ticks fire.
        suppressed = false
        let exp2 = expectation(description: "second window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exp2.fulfill() }
        wait(for: [exp2], timeout: 3.0)
        scheduler.stop()
        XCTAssertGreaterThanOrEqual(fireCount, 1, "post-suppression timer must resume firing")
    }

    func testDoubleStartIsIdempotent() {
        var fireCount = 0
        let scheduler = PollingScheduler { fireCount += 1 }
        let exp = expectation(description: "tick")

        scheduler.start()
        scheduler.start() // second start must not install a second timer

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exp.fulfill() }
        wait(for: [exp], timeout: 3.0)
        scheduler.stop()
        // exactly one timer means roughly one tick in 1.5s, not two
        XCTAssertEqual(fireCount, 1)
    }
}
