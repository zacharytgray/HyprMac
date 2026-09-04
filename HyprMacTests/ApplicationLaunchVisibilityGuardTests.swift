import Cocoa
import XCTest
@testable import HyprMac

final class ApplicationLaunchVisibilityGuardTests: XCTestCase {
    private final class Process: ApplicationLaunchVisibilityProcess {
        let bundleIdentifier: String? = "test.application"
        var isTerminated = false
        var isHidden = true
        var unhideRequests = 0
        var onUnhide: (() -> Void)?
        var acceptsUnhide = true

        func unhide() -> Bool {
            unhideRequests += 1
            onUnhide?()
            return acceptsUnhide
        }

        func isSameProcess(as other: ApplicationLaunchVisibilityProcess) -> Bool { self === other }
    }

    private final class Fixture {
        let queue = DispatchQueue(label: "test.launch-visibility")
        // Tests mutate/read these only before guard creation or on queue.
        var applications: [Process]
        var byPID: [pid_t: Process] = [:]

        init(initial: [Process] = []) { applications = initial }

        func makeGuard(timeout: TimeInterval = 60, attempts: Int = 3) -> ApplicationLaunchVisibilityGuard {
            ApplicationLaunchVisibilityGuard(
                bundleID: "test.application", timeout: timeout,
                environment: .init(
                    runningApplications: { [weak self] _ in self?.applications ?? [] },
                    applicationForPID: { [weak self] in self?.byPID[$0] }
                ),
                queue: queue, maximumAttempts: attempts, retryInterval: 0.005
            )
        }

        func add(_ process: Process, pid: pid_t = 1) {
            queue.sync {
                applications.append(process)
                byPID[pid] = process
            }
        }

        func drain() { queue.sync {} }

        func allowRetries() {
            let done = DispatchSemaphore(value: 0)
            queue.asyncAfter(deadline: .now() + 0.08) { done.signal() }
            XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        }
    }

    func testDeadlineFindsNewProcessWithoutMainQueueCompletion() {
        let fixture = Fixture()
        let guardObject = fixture.makeGuard(timeout: 0.02)
        defer { guardObject.disarmAfterObservedReveal(); fixture.drain() }
        let process = Process()
        let requested = DispatchSemaphore(value: 0)
        process.onUnhide = { requested.signal() }
        fixture.add(process)
        // The test deliberately blocks main: rescue must not need its timer,
        // run loop, NSWorkspace completion, or any live app/AX operation.
        XCTAssertEqual(requested.wait(timeout: .now() + 1), .success)
        XCTAssertGreaterThan(fixture.queue.sync { process.unhideRequests }, 0)
    }

    func testObservedRevealDisarmsFinishAndLateCompletion() {
        let fixture = Fixture()
        let guardObject = fixture.makeGuard()
        let process = Process()
        fixture.add(process)
        guardObject.disarmAfterObservedReveal()
        // A later manual hide belongs to the user, not this launch request.
        fixture.queue.sync { process.isHidden = true }
        guardObject.finish()
        guardObject.applicationOpened(pid: 1)
        fixture.drain()
        XCTAssertEqual(fixture.queue.sync { process.unhideRequests }, 0)
    }

    func testFinishBeforePIDStillHandlesLateOpenCompletion() {
        let fixture = Fixture()
        let guardObject = fixture.makeGuard(attempts: 1)
        defer { guardObject.disarmAfterObservedReveal(); fixture.drain() }
        guardObject.finish()
        fixture.drain()
        let process = Process()
        fixture.add(process)
        guardObject.applicationOpened(pid: 1)
        fixture.drain()
        XCTAssertEqual(fixture.queue.sync { process.unhideRequests }, 1)
    }

    func testEarlyFinishKeepsIndependentDeadlineDiscovery() {
        let fixture = Fixture()
        let guardObject = fixture.makeGuard(timeout: 0.03, attempts: 1)
        defer { guardObject.disarmAfterObservedReveal(); fixture.drain() }
        guardObject.finish()
        fixture.drain() // No process existed during this exhausted batch.
        let process = Process()
        let requested = DispatchSemaphore(value: 0)
        process.onUnhide = { requested.signal() }
        fixture.add(process)
        XCTAssertEqual(requested.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(fixture.queue.sync { process.unhideRequests }, 1)
    }

    func testPreexistingProcessIsNeverUnhidden() {
        let existing = Process()
        let fixture = Fixture(initial: [existing])
        fixture.byPID[1] = existing
        let guardObject = fixture.makeGuard(attempts: 1)
        defer { guardObject.disarmAfterObservedReveal(); fixture.drain() }
        guardObject.finish()
        guardObject.applicationOpened(pid: 1)
        fixture.drain()
        XCTAssertEqual(fixture.queue.sync { existing.unhideRequests }, 0)
        let newProcess = Process()
        fixture.add(newProcess, pid: 2)
        guardObject.applicationOpened(pid: 2)
        fixture.drain()
        XCTAssertEqual(fixture.queue.sync { newProcess.unhideRequests }, 1)
    }

    func testAmbiguousProcessesWaitForExactCompletion() {
        let fixture = Fixture()
        let guardObject = fixture.makeGuard(attempts: 1)
        defer { guardObject.disarmAfterObservedReveal(); fixture.drain() }
        let first = Process()
        let second = Process()
        fixture.add(first, pid: 1)
        fixture.add(second, pid: 2)
        guardObject.finish()
        fixture.drain()
        XCTAssertEqual(fixture.queue.sync { first.unhideRequests + second.unhideRequests }, 0)
        guardObject.applicationOpened(pid: 2)
        fixture.drain()
        XCTAssertEqual(fixture.queue.sync { first.unhideRequests }, 0)
        XCTAssertEqual(fixture.queue.sync { second.unhideRequests }, 1)
    }

    func testRetryBudgetIsBoundedAndCannotBeRestartedByRepeatedCallbacks() {
        let fixture = Fixture()
        let guardObject = fixture.makeGuard(timeout: 0.02, attempts: 3)
        defer { guardObject.disarmAfterObservedReveal(); fixture.drain() }
        let process = Process()
        fixture.add(process)
        guardObject.finish()
        fixture.allowRetries()
        XCTAssertEqual(fixture.queue.sync { process.unhideRequests }, 3)
        for _ in 0..<10 {
            guardObject.finish()
            guardObject.applicationOpened(pid: 1)
        }
        fixture.allowRetries()
        XCTAssertEqual(fixture.queue.sync { process.unhideRequests }, 3)
    }

    func testVisibleReadbackDisarmsFurtherRequestsEvenWhenUnhideWasRejected() {
        let fixture = Fixture()
        let guardObject = fixture.makeGuard()
        defer { guardObject.disarmAfterObservedReveal(); fixture.drain() }
        let process = Process()
        process.acceptsUnhide = false
        process.onUnhide = { [weak process] in process?.isHidden = false }
        fixture.add(process)
        guardObject.finish()
        fixture.allowRetries()
        XCTAssertEqual(fixture.queue.sync { process.unhideRequests }, 1)
        fixture.queue.sync { process.isHidden = true }
        guardObject.finish()
        guardObject.applicationOpened(pid: 1)
        fixture.allowRetries()
        XCTAssertEqual(fixture.queue.sync { process.unhideRequests }, 1)
    }

    func testTerminatedProcessIsNotUnhidden() {
        let fixture = Fixture()
        let guardObject = fixture.makeGuard()
        defer { guardObject.disarmAfterObservedReveal(); fixture.drain() }
        let process = Process()
        process.isTerminated = true
        fixture.add(process)
        guardObject.applicationOpened(pid: 1)
        guardObject.finish()
        fixture.allowRetries()
        XCTAssertEqual(fixture.queue.sync { process.unhideRequests }, 0)
    }

    func testDisarmDuringInFlightRequestPreventsFurtherRetries() {
        let fixture = Fixture()
        let guardObject = fixture.makeGuard()
        defer { guardObject.disarmAfterObservedReveal(); fixture.drain() }
        let process = Process()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        process.onUnhide = {
            started.signal()
            _ = release.wait(timeout: .now() + 1)
        }
        fixture.add(process)
        guardObject.finish()
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        // Disarm must not wait for the OS request, which cannot be recalled.
        guardObject.disarmAfterObservedReveal()
        release.signal()
        guardObject.finish()
        guardObject.applicationOpened(pid: 1)
        fixture.allowRetries()
        XCTAssertEqual(fixture.queue.sync { process.unhideRequests }, 1)
    }
}
