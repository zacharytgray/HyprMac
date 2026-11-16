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

// trailing create polls, fire triggers and suppression wake-ups, on an
// injected clock and queue so nothing here waits on the wall clock

final class PollingSchedulerClockTests: XCTestCase {

    private final class FakeQueue {
        var nowNS: UInt64 = 1_000_000_000
        private var queue: [(at: UInt64, seq: Int, block: () -> Void)] = []
        private var seq = 0

        func install(on scheduler: PollingScheduler) {
            scheduler.now = { [unowned self] in DispatchTime(uptimeNanoseconds: self.nowNS) }
            scheduler.arm = { [unowned self] delay, block in
                self.seq += 1
                self.queue.append((self.nowNS + UInt64((delay * 1e9).rounded()), self.seq, block))
            }
        }

        var elapsed: TimeInterval { Double(nowNS - 1_000_000_000) / 1e9 }

        func advance(by seconds: TimeInterval) {
            let end = nowNS + UInt64((seconds * 1e9).rounded())
            while let next = queue.enumerated()
                .filter({ $0.element.at <= end })
                .min(by: { ($0.element.at, $0.element.seq) < ($1.element.at, $1.element.seq) }) {
                queue.remove(at: next.offset)
                nowNS = max(nowNS, next.element.at)
                next.element.block()
            }
            nowNS = end
        }
    }

    private var fires: [(at: TimeInterval, fire: PollingScheduler.Fire)] = []
    private var queue = FakeQueue()
    private var scheduler: PollingScheduler!

    override func setUp() {
        super.setUp()
        fires = []
        queue = FakeQueue()
        scheduler = PollingScheduler(periodicInterval: 1000) { [unowned self] in
            self.fires.append((self.queue.elapsed, self.scheduler.currentFire!))
        }
        queue.install(on: scheduler)
        scheduler.start()
    }

    override func tearDown() {
        scheduler.stop()
        scheduler = nil
        super.tearDown()
    }

    func testCreateAfterAPendingPollStillGetsAPollAtItsOwnDeadline() {
        // an activation poll is due in 50 ms when the create lands. the
        // activation poll alone ran before AX listed the window
        scheduler.schedule(after: 0.05, trigger: .activation)
        queue.advance(by: 0.04)
        let outcome = scheduler.schedule(after: 0.2, trigger: .create, trailing: true)
        XCTAssertEqual(outcome, .trailing(dueMS: 200, pendingDueMS: 10))
        queue.advance(by: 1)
        XCTAssertEqual(fires.map(\.fire.triggers), [[.activation], [.create]])
        XCTAssertEqual(fires[0].at, 0.05, accuracy: 0.001)
        XCTAssertEqual(fires[1].at, 0.24, accuracy: 0.001)
    }

    func testPlainRequestStillCoalescesIntoThePendingPoll() {
        scheduler.schedule(after: 0.05, trigger: .activation)
        let outcome = scheduler.schedule(after: 0.2, trigger: .focus)
        XCTAssertEqual(outcome, .coalesced(pendingDueMS: 50))
        queue.advance(by: 1)
        XCTAssertEqual(fires.map(\.fire.triggers), [[.activation, .focus]])
    }

    func testTrailingRequestWithinTheSlackRidesThePendingPoll() {
        scheduler.schedule(after: 0.2, trigger: .focus)
        queue.advance(by: 0.01)
        let outcome = scheduler.schedule(after: 0.2, trigger: .create, trailing: true)
        XCTAssertEqual(outcome, .coalesced(pendingDueMS: 190))
        queue.advance(by: 1)
        XCTAssertEqual(fires.count, 1)
        XCTAssertEqual(fires[0].fire.triggers, [.focus, .create])
    }

    func testSoonerTrailingRequestMovesThePendingPollUp() {
        scheduler.schedule(after: 5, trigger: .hold)
        let outcome = scheduler.schedule(after: 0.2, trigger: .create, trailing: true)
        XCTAssertEqual(outcome, .advanced(dueMS: 200))
        queue.advance(by: 1)
        XCTAssertEqual(fires.map(\.fire.triggers), [[.hold, .create]])
    }

    func testDeferredPollThatRunsPastTheTrailingDeadlineCoversIt() {
        var suppressed = true
        scheduler.isSuppressed = { suppressed }
        scheduler.suppressionReason = { "workspace transition" }
        scheduler.schedule(after: 0.05, trigger: .activation)
        queue.advance(by: 0.06)
        scheduler.schedule(after: 0.2, trigger: .create, trailing: true)
        queue.advance(by: 0.6)
        suppressed = false
        queue.advance(by: 1)
        XCTAssertEqual(fires.count, 1, "one poll after the transition answers both")
        XCTAssertEqual(fires[0].fire.triggers, [.activation, .create])
        XCTAssertEqual(fires[0].fire.deferredBy, "workspace transition")
        XCTAssertGreaterThan(fires[0].fire.deferredMS, 0)
    }

    func testTrailingPollCoalescesWithOneThePollAskedFor() {
        // the poll that runs first asks for a follow-up before the trailing
        // deadline; the trailing one then rides behind it, not beside it
        var askedOnce = false
        scheduler = PollingScheduler(periodicInterval: 1000) { [unowned self] in
            self.fires.append((self.queue.elapsed, self.scheduler.currentFire!))
            if !askedOnce {
                askedOnce = true
                self.scheduler.schedule(after: 0.3, trigger: .followUp)
            }
        }
        queue.install(on: scheduler)
        scheduler.start()
        scheduler.schedule(after: 0.05, trigger: .activation)
        scheduler.schedule(after: 0.2, trigger: .create, trailing: true)
        queue.advance(by: 2)
        XCTAssertEqual(fires.map(\.fire.triggers), [[.activation], [.followUp, .create]])
        XCTAssertEqual(fires[1].at, 0.2, accuracy: 0.002)
    }

    func testFireReportsItsWait() {
        scheduler.schedule(after: 0.2, trigger: .create, trailing: true)
        queue.advance(by: 1)
        XCTAssertEqual(fires.count, 1)
        XCTAssertEqual(fires[0].fire.waitedMS, 200)
        XCTAssertEqual(fires[0].fire.deferredMS, 0)
        XCTAssertNil(fires[0].fire.deferredBy)
        XCTAssertEqual(fires[0].fire.summary, "create, waited 200ms")
    }

    func testDeferredFireWakesWhenTheTimedSuppressionEnds() {
        // a transition with 0.45 s left: the poll runs at its end, not on
        // the next 0.3 s step after it
        let liftsAt: TimeInterval = 0.5
        scheduler.isSuppressed = { [unowned self] in self.queue.elapsed < liftsAt }
        scheduler.suppressionEndsIn = { [unowned self] in
            let left = liftsAt - self.queue.elapsed
            return left > 0 ? left : nil
        }
        scheduler.schedule(after: 0.05, trigger: .create, trailing: true)
        queue.advance(by: 2)
        XCTAssertEqual(fires.count, 1)
        XCTAssertEqual(fires[0].at, liftsAt + 0.01, accuracy: 0.002)
        XCTAssertEqual(fires[0].fire.deferredMS, 460)
    }

    func testDeferredFireWithoutATimedEndStepsAtThreeTenths() {
        var suppressed = true
        scheduler.isSuppressed = { suppressed }
        scheduler.schedule(after: 0.05, trigger: .create, trailing: true)
        queue.advance(by: 0.5)
        suppressed = false
        queue.advance(by: 1)
        XCTAssertEqual(fires.count, 1)
        XCTAssertEqual(fires[0].at, 0.65, accuracy: 0.002, "fires on the 0.3 s step after the lift")
    }

    func testReconcileTickReportsItself() {
        scheduler.reconcileTick()
        XCTAssertEqual(fires.count, 1)
        XCTAssertTrue(fires[0].fire.isReconcileOnly)
    }

    func testSuppressedReconcileTickRunsOnceItLifts() {
        var suppressed = true
        scheduler.isSuppressed = { suppressed }
        scheduler.reconcileTick()
        scheduler.reconcileTick()
        queue.advance(by: 0.4)
        XCTAssertTrue(fires.isEmpty)
        suppressed = false
        queue.advance(by: 0.4)
        XCTAssertEqual(fires.count, 1)
        XCTAssertTrue(fires[0].fire.isReconcileOnly)
    }

    func testRequestBeforeStartIsHeld() {
        let idle = PollingScheduler(periodicInterval: 1000) {}
        XCTAssertEqual(idle.schedule(after: 0.2, trigger: .create, trailing: true), .beforeStart)
    }

    // MARK: - admit-only pass under a switch's hold

    private var admits: [(at: TimeInterval, fire: PollingScheduler.Fire)] = []

    /// a hold that lifts at `liftsAt`, and a gate that opens at `settlesAt`
    private func holdAdmits(liftsAt: TimeInterval, settlesAt: TimeInterval) {
        admits = []
        scheduler.isSuppressed = { [unowned self] in self.queue.elapsed < liftsAt }
        scheduler.suppressionEndsIn = { [unowned self] in
            let left = liftsAt - self.queue.elapsed
            return left > 0 ? left : nil
        }
        scheduler.admitsNewWindowsDuringHold = { [unowned self] in self.queue.elapsed >= settlesAt }
        scheduler.onAdmitDuringHold = { [unowned self] in
            self.admits.append((self.queue.elapsed, self.scheduler.currentFire!))
        }
    }

    func testACreateUnderASwitchHoldGetsAnAdmitPassOnceTheSwitchIsDone() {
        // the switch writes frames until 0.4 s; its hold lasts to 1.5 s
        holdAdmits(liftsAt: 1.5, settlesAt: 0.4)
        scheduler.schedule(after: 0.2, trigger: .create, trailing: true)
        queue.advance(by: 0.3)
        XCTAssertTrue(admits.isEmpty, "not while the switch is still writing frames")
        queue.advance(by: 0.3)
        XCTAssertEqual(admits.count, 1)
        XCTAssertEqual(admits[0].at, 0.5, accuracy: 0.002, "the first ask after the switch settled")
        XCTAssertTrue(admits[0].fire.admitOnly)
        XCTAssertEqual(admits[0].fire.triggers, [.create])
        XCTAssertTrue(admits[0].fire.summary.hasSuffix("admit-only during the switch hold"))
        XCTAssertTrue(fires.isEmpty, "the full poll still waits out the hold")
        queue.advance(by: 2)
        XCTAssertEqual(admits.count, 1, "one pass per request")
        XCTAssertEqual(fires.count, 1)
        XCTAssertEqual(fires[0].at, 1.51, accuracy: 0.002, "the full poll runs as the hold ends")
        XCTAssertEqual(fires[0].fire.triggers, [.create])
        XCTAssertFalse(fires[0].fire.admitOnly)
    }

    func testAnAdmitPassThatFoundNothingIsAskedAgainByTheWatchsRetry() {
        holdAdmits(liftsAt: 1.5, settlesAt: 0)
        scheduler.onAdmitDuringHold = { [unowned self] in
            self.admits.append((self.queue.elapsed, self.scheduler.currentFire!))
            // AX did not list the window yet: the watch asks again in 0.3 s
            if self.admits.count == 1 { self.scheduler.schedule(after: 0.3, trigger: .followUp) }
        }
        scheduler.schedule(after: 0.2, trigger: .create, trailing: true)
        queue.advance(by: 1)
        XCTAssertEqual(admits.map(\.fire.triggers), [[.create], [.followUp]])
        XCTAssertEqual(admits[1].at, 0.5, accuracy: 0.002)
        XCTAssertTrue(fires.isEmpty)
    }

    func testExistingWindowWorkGetsNoAdmitPass() {
        holdAdmits(liftsAt: 1.5, settlesAt: 0)
        scheduler.schedule(after: 0.2, trigger: .destroy)
        scheduler.schedule(after: 0.2, trigger: .reveal)
        queue.advance(by: 1)
        XCTAssertTrue(admits.isEmpty)
        queue.advance(by: 1)
        XCTAssertEqual(fires.map(\.fire.triggers), [[.destroy, .reveal]])
    }

    func testNoHoldMeansTheOrdinaryPollAndNoAdmitPass() {
        holdAdmits(liftsAt: 0, settlesAt: 0)
        scheduler.schedule(after: 0.2, trigger: .create, trailing: true)
        queue.advance(by: 2)
        XCTAssertTrue(admits.isEmpty)
        XCTAssertEqual(fires.count, 1)
        XCTAssertEqual(fires[0].at, 0.2, accuracy: 0.002)
    }

    /// the production gate over a real registry, with the switch done
    private func registryHold(_ registry: SuppressionRegistry) {
        admits = []
        scheduler.isSuppressed = { registry.isSuppressed(.workspaceTransition) }
        scheduler.admitsNewWindowsDuringHold = {
            SwitchHoldAdmission.allows(
                heldOnlyBySwitch: registry.isHeldOnlyByWorkspaceSwitch(.workspaceTransition),
                switchSettled: true, mouseButtonDown: false, finishingDrag: false,
                displayTransitionPending: false, sessionInterrupted: false)
        }
        scheduler.onAdmitDuringHold = { [unowned self] in
            self.admits.append((self.queue.elapsed, self.scheduler.currentFire!))
        }
    }

    func testAWakeHoldStillDefersANewWindow() {
        let registry = SuppressionRegistry()
        registryHold(registry)
        registry.suppress(.workspaceTransition, for: SuppressionDelay.systemInterruption)
        scheduler.schedule(after: 0.2, trigger: .create, trailing: true)
        queue.advance(by: 3)
        XCTAssertTrue(admits.isEmpty, "a wake hold admits nothing early")
        XCTAssertTrue(fires.isEmpty)
        registry.clear(.workspaceTransition)
        queue.advance(by: 0.4)
        XCTAssertEqual(fires.count, 1, "the poll after the hold admits it")
        XCTAssertTrue(admits.isEmpty)
    }

    func testADisplayHoldUnderASwitchStillDefersANewWindow() {
        let registry = SuppressionRegistry()
        registryHold(registry)
        registry.suppress(.workspaceTransition, for: SuppressionDelay.displaySettle)
        // a switch inside the display settle is still held by the settle
        registry.suppress(.workspaceTransition, for: SuppressionDelay.transition, source: .workspaceSwitch)
        scheduler.schedule(after: 0.2, trigger: .create, trailing: true)
        queue.advance(by: 3)
        XCTAssertTrue(admits.isEmpty)
        registry.clear(.workspaceTransition)
        queue.advance(by: 0.4)
        XCTAssertEqual(fires.count, 1)
    }

    func testASwitchOnlyHoldAdmitsThroughTheRegistry() {
        let registry = SuppressionRegistry()
        registryHold(registry)
        registry.suppress(.workspaceTransition, for: SuppressionDelay.transition, source: .workspaceSwitch)
        scheduler.schedule(after: 0.2, trigger: .create, trailing: true)
        queue.advance(by: 0.3)
        XCTAssertEqual(admits.count, 1)
        XCTAssertTrue(fires.isEmpty)
    }

    func testTheGateOpensForAFinishedSwitchsOwnHoldOnly() {
        func allows(switchOnly: Bool = true, settled: Bool = true, mouse: Bool = false,
                    drag: Bool = false, display: Bool = false, interrupted: Bool = false) -> Bool {
            SwitchHoldAdmission.allows(heldOnlyBySwitch: switchOnly, switchSettled: settled,
                                       mouseButtonDown: mouse, finishingDrag: drag,
                                       displayTransitionPending: display, sessionInterrupted: interrupted)
        }
        XCTAssertTrue(allows())
        XCTAssertFalse(allows(switchOnly: false), "wake, display, move or scratchpad hold")
        XCTAssertFalse(allows(settled: false), "the switch is still writing frames")
        XCTAssertFalse(allows(mouse: true))
        XCTAssertFalse(allows(drag: true))
        XCTAssertFalse(allows(display: true))
        XCTAssertFalse(allows(interrupted: true))
    }

    func testATiledMemberMissingFromTheWalkStopsTheAdmitPass() {
        XCTAssertEqual(SwitchHoldAdmission.missingTiledMembers([1, 2, 3], listed: [1, 3, 9], held: []), [2])
        XCTAssertEqual(SwitchHoldAdmission.missingTiledMembers([1, 2], listed: [1], held: [2]), [],
                       "a held member keeps its leaf, so the pass may run")
    }
}
