import Cocoa
import XCTest
@testable import HyprMac

/// Deterministic virtual time for the activation workflow. Tests never wait on
/// DispatchQueue and never touch a real application or Accessibility object.
private final class ActivationTestScheduler {
    private final class Task: ApplicationActivationScheduledTask {
        let id: Int
        let deadline: TimeInterval
        let block: () -> Void
        var isCancelled = false

        init(id: Int, deadline: TimeInterval, block: @escaping () -> Void) {
            self.id = id
            self.deadline = deadline
            self.block = block
        }

        func cancel() {
            isCancelled = true
        }
    }

    private var nextID = 0
    private var tasks: [Task] = []
    private(set) var now: TimeInterval = 0
    private(set) var scheduledCount = 0

    func schedule(after delay: TimeInterval,
                  _ block: @escaping () -> Void) -> ApplicationActivationScheduledTask {
        nextID += 1
        scheduledCount += 1
        let task = Task(id: nextID, deadline: now + max(0, delay), block: block)
        tasks.append(task)
        return task
    }

    func advance(by interval: TimeInterval) {
        precondition(interval >= 0)
        let destination = now + interval

        while let task = nextRunnableTask(through: destination) {
            tasks.removeAll { $0 === task }
            now = task.deadline
            if !task.isCancelled {
                task.block()
            }
        }

        now = destination
        tasks.removeAll { $0.isCancelled }
    }

    private func nextRunnableTask(through deadline: TimeInterval) -> Task? {
        tasks
            .filter { !$0.isCancelled && $0.deadline <= deadline }
            .min {
                if $0.deadline != $1.deadline { return $0.deadline < $1.deadline }
                return $0.id < $1.id
            }
    }
}

/// In-memory model of the small OS surface used by the coordinator.
private final class ActivationTestSystem {
    final class VisibilityProtection: ApplicationLaunchVisibilityProtecting {
        private(set) var openedPIDs: [pid_t] = []
        private(set) var finishCount = 0
        private(set) var disarmCount = 0

        func applicationOpened(pid: pid_t) { openedPIDs.append(pid) }
        func finish() { finishCount += 1 }
        func disarmAfterObservedReveal() { disarmCount += 1 }
    }

    struct OpenCall {
        let url: URL
        let hidden: Bool
        let completion: (ApplicationOpenResult) -> Void
    }

    struct WindowCall: Equatable {
        let pid: pid_t
        let windowID: CGWindowID
    }

    struct WindowSetCall: Equatable {
        let pid: pid_t
        let windowIDs: Set<CGWindowID>
        let selectedWindowID: CGWindowID
    }

    struct ReservationCall {
        let bundleID: String
        let requestID: UInt64
        let completion: () -> Void
    }

    struct ReservationFinish: Equatable {
        let requestID: UInt64
        let result: ApplicationActivationResult
    }

    struct RouteCall: Equatable {
        let pid: pid_t
        let windowID: CGWindowID
        let requestID: UInt64
    }

    let scheduler = ActivationTestScheduler()
    private var installedApplications: [String: URL] = [:]
    private(set) var processes: [String: ApplicationProcessSnapshot] = [:]
    private(set) var inventories: [pid_t: ApplicationWindowInventory] = [:]

    private(set) var applicationURLLookups: [String] = []
    private(set) var processLookups: [String] = []
    private(set) var openCalls: [OpenCall] = []
    private(set) var unhideCalls: [pid_t] = []
    private(set) var unminimizeCalls: [WindowCall] = []
    private(set) var activateCalls: [pid_t] = []
    private(set) var prepareCalls: [WindowSetCall] = []
    private(set) var routeCalls: [RouteCall] = []
    private(set) var discoveryDelays: [TimeInterval] = []
    private(set) var events: [String] = []
    private(set) var protections: [VisibilityProtection] = []
    private(set) var protectionTimeouts: [TimeInterval] = []
    private(set) var reservations: [ReservationCall] = []
    private(set) var reservationFinishes: [ReservationFinish] = []

    var prepareSucceeds = true
    var routeSucceeds = true
    var available = true
    var lastFocusedWindowID: CGWindowID = 0
    var automaticallyCompleteReservation = true

    func install(_ bundleID: String) {
        guard installedApplications[bundleID] == nil else { return }
        installedApplications[bundleID] = URL(
            fileURLWithPath: "/Applications/Test-\(installedApplications.count + 1).app"
        )
    }

    func setProcess(_ bundleID: String,
                    pid: pid_t,
                    hidden: Bool,
                    active: Bool = false) {
        install(bundleID)
        processes[bundleID] = ApplicationProcessSnapshot(
            pid: pid,
            isHidden: hidden,
            isActive: active
        )
    }

    func setInventory(_ inventory: ApplicationWindowInventory, for pid: pid_t) {
        inventories[pid] = inventory
    }

    func completeOpen(at index: Int = 0,
                      bundleID: String,
                      pid: pid_t,
                      hidden: Bool,
                      active: Bool = false) {
        setProcess(bundleID, pid: pid, hidden: hidden, active: active)
        openCalls[index].completion(.opened(pid: pid))
    }

    func makeEnvironment() -> ApplicationActivationEnvironment {
        ApplicationActivationEnvironment(
            now: { [unowned self] in scheduler.now },
            application: { [unowned self] bundleID, preferredPID in
                processLookups.append(bundleID)
                guard let process = processes[bundleID],
                      preferredPID == nil || preferredPID == process.pid else { return nil }
                return process
            },
            applicationURL: { [unowned self] bundleID in
                applicationURLLookups.append(bundleID)
                return installedApplications[bundleID]
            },
            inventory: { [unowned self] pid in
                inventories[pid] ?? .unavailable
            },
            openApplication: { [unowned self] url, hidden, completion in
                events.append(hidden ? "open-hidden" : "open-visible")
                openCalls.append(OpenCall(url: url, hidden: hidden, completion: completion))
            },
            unhide: { [unowned self] pid in
                events.append("unhide:\(pid)")
                unhideCalls.append(pid)
                return updateProcess(pid: pid, hidden: false)
            },
            unminimize: { [unowned self] pid, windowID in
                events.append("unminimize:\(windowID)")
                unminimizeCalls.append(WindowCall(pid: pid, windowID: windowID))
                return updateWindow(pid: pid, windowID: windowID, minimized: false)
            },
            activate: { [unowned self] pid in
                events.append("activate:\(pid)")
                activateCalls.append(pid)
                return updateProcess(pid: pid, active: true)
            },
            protectHiddenLaunch: { [unowned self] _, timeout in
                let protection = VisibilityProtection()
                protections.append(protection)
                protectionTimeouts.append(timeout)
                return protection
            },
            schedule: { [unowned self] delay, block in
                scheduler.schedule(after: delay, block)
            }
        )
    }

    func wire(_ coordinator: ApplicationActivationCoordinator) {
        coordinator.prepareWindowsForReveal = { [unowned self] pid, windowIDs, selectedWindowID in
            events.append("prepare")
            prepareCalls.append(WindowSetCall(pid: pid, windowIDs: windowIDs, selectedWindowID: selectedWindowID))
            return prepareSucceeds
        }
        coordinator.reserveSpaceBeforeLaunch = { [unowned self] bundleID, requestID, completion in
            events.append("reserve")
            reservations.append(ReservationCall(bundleID: bundleID, requestID: requestID, completion: completion))
            if automaticallyCompleteReservation { completeReservation() }
        }
        coordinator.finishLaunchReservation = { [unowned self] requestID, result in
            reservationFinishes.append(ReservationFinish(requestID: requestID, result: result))
        }
        coordinator.routeWindow = { [unowned self] pid, windowID, requestID in
            events.append("route:\(windowID)")
            routeCalls.append(RouteCall(pid: pid, windowID: windowID, requestID: requestID))
            return routeSucceeds
        }
        coordinator.requestDiscovery = { [unowned self] delay in
            discoveryDelays.append(delay)
        }
        coordinator.lastFocusedWindowID = { [unowned self] in lastFocusedWindowID }
        coordinator.isAvailable = { [unowned self] in available }
    }

    func completeReservation(at index: Int = 0) {
        events.append("reservation-complete")
        reservations[index].completion()
    }

    @discardableResult
    private func updateProcess(pid: pid_t,
                               hidden: Bool? = nil,
                               active: Bool? = nil) -> Bool {
        guard let entry = processes.first(where: { $0.value.pid == pid }) else { return false }
        processes[entry.key] = ApplicationProcessSnapshot(
            pid: pid,
            isHidden: hidden ?? entry.value.isHidden,
            isActive: active ?? entry.value.isActive
        )
        return true
    }

    @discardableResult
    private func updateWindow(pid: pid_t,
                              windowID: CGWindowID,
                              minimized: Bool) -> Bool {
        guard case .available(let windows, let hasUnaddressableWindows) = inventories[pid],
              windows.contains(where: { $0.windowID == windowID }) else { return false }
        inventories[pid] = .available(
            windows: windows.map { window in
                guard window.windowID == windowID else { return window }
                return ApplicationWindowCandidate(
                    windowID: window.windowID,
                    isMinimized: minimized,
                    isMain: window.isMain,
                    isFocused: window.isFocused
                )
            },
            hasUnaddressableWindows: hasUnaddressableWindows
        )
        return true
    }
}

final class ApplicationActivationCoordinatorTests: XCTestCase {
    private let appA = "com.example.alpha"
    private let appB = "com.example.beta"

    private func makeCoordinator(
        system: ActivationTestSystem,
        hardTimeout: TimeInterval = 1.0,
        quietPeriod: TimeInterval = 0.1,
        noWindowGrace: TimeInterval = 0.2
    ) -> ApplicationActivationCoordinator {
        let coordinator = ApplicationActivationCoordinator(
            environment: system.makeEnvironment(),
            hardTimeout: hardTimeout,
            windowQuietPeriod: quietPeriod,
            windowBurstCap: 0.4,
            noWindowGrace: noWindowGrace
        )
        system.wire(coordinator)
        return coordinator
    }

    private func window(_ id: CGWindowID,
                        minimized: Bool = false,
                        main: Bool = false,
                        focused: Bool = false) -> ApplicationWindowCandidate {
        ApplicationWindowCandidate(
            windowID: id,
            isMinimized: minimized,
            isMain: main,
            isFocused: focused
        )
    }

    func testUnknownApplicationReturnsUnavailableWithoutSideEffects() {
        let system = ActivationTestSystem()
        let coordinator = makeCoordinator(system: system)
        var results: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .hotkey) { results.append($0) }

        XCTAssertEqual(results, [.unavailable])
        XCTAssertEqual(system.applicationURLLookups, [appA])
        XCTAssertTrue(system.processLookups.isEmpty)
        XCTAssertTrue(system.openCalls.isEmpty)
        XCTAssertTrue(system.unhideCalls.isEmpty)
        XCTAssertTrue(system.unminimizeCalls.isEmpty)
        XCTAssertTrue(system.activateCalls.isEmpty)
        XCTAssertTrue(system.prepareCalls.isEmpty)
        XCTAssertTrue(system.routeCalls.isEmpty)
        XCTAssertEqual(system.scheduler.scheduledCount, 0)
    }

    func testConfirmedEmptyRunningApplicationReopensExactlyOnce() {
        let system = ActivationTestSystem()
        system.setProcess(appA, pid: 101, hidden: false)
        system.setInventory(.available(windows: [], hasUnaddressableWindows: false), for: 101)
        let coordinator = makeCoordinator(system: system)
        var results: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .hotkey) { results.append($0) }
        XCTAssertEqual(system.openCalls.count, 1)
        XCTAssertFalse(system.openCalls[0].hidden)

        system.openCalls[0].completion(.opened(pid: 101))
        coordinator.noteAXEvent(pid: 101)
        coordinator.noteDiscoveryCompleted()
        system.scheduler.advance(by: 0.25)

        XCTAssertEqual(system.openCalls.count, 1, "empty-window probes must not reopen repeatedly")
        XCTAssertEqual(system.activateCalls, [101])
        XCTAssertEqual(results, [.openedWithoutWindow])
    }

    func testUnavailableAXNeverReopensAndFailsOpenSafely() {
        let system = ActivationTestSystem()
        system.setProcess(appA, pid: 102, hidden: true)
        system.setInventory(.unavailable, for: 102)
        let coordinator = makeCoordinator(system: system)
        var results: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .spotlight) { results.append($0) }
        system.scheduler.advance(by: 0)

        XCTAssertTrue(system.openCalls.isEmpty, "unreadable AX state is not proof of an empty app")
        XCTAssertEqual(system.unhideCalls, [102])
        XCTAssertEqual(system.activateCalls, [102])
        XCTAssertEqual(results, [.openedWithoutWindow])
    }

    func testOnlySelectedMinimizedWindowIsRestored() {
        let system = ActivationTestSystem()
        system.setProcess(appA, pid: 103, hidden: false)
        system.lastFocusedWindowID = 20
        system.setInventory(
            .available(
                windows: [
                    window(10, minimized: true, main: true, focused: true),
                    window(20, minimized: true),
                    window(30, minimized: true)
                ],
                hasUnaddressableWindows: false
            ),
            for: 103
        )
        let coordinator = makeCoordinator(system: system)
        var results: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .hotkey) { results.append($0) }

        XCTAssertEqual(system.prepareCalls, [
            ActivationTestSystem.WindowSetCall(pid: 103, windowIDs: [20], selectedWindowID: 20)
        ])
        XCTAssertEqual(system.unminimizeCalls, [
            ActivationTestSystem.WindowCall(pid: 103, windowID: 20)
        ])

        system.scheduler.advance(by: 0.05)
        XCTAssertEqual(system.routeCalls.map(\.windowID), [20])
        XCTAssertEqual(results, [.activated(windowID: 20)])
    }

    func testSelectionOrderIsLastFocusedThenFocusedThenMainThenWindowID() {
        func selected(from windows: [ApplicationWindowCandidate],
                      lastFocused: CGWindowID = 0) -> CGWindowID? {
            let system = ActivationTestSystem()
            system.setProcess(appA, pid: 104, hidden: false)
            system.setInventory(
                .available(windows: windows, hasUnaddressableWindows: false),
                for: 104
            )
            system.lastFocusedWindowID = lastFocused
            let coordinator = makeCoordinator(system: system)
            _ = coordinator.activate(bundleID: appA, source: .hotkey) { _ in }
            return system.routeCalls.first?.windowID
        }

        XCTAssertEqual(
            selected(
                from: [
                    window(10, focused: true),
                    window(20, main: true),
                    window(30),
                    window(40)
                ],
                lastFocused: 40
            ),
            40
        )
        XCTAssertEqual(selected(from: [window(20, main: true), window(10, focused: true)]), 10)
        XCTAssertEqual(selected(from: [window(20, main: true), window(10)]), 20)
        XCTAssertEqual(selected(from: [window(20), window(10)]), 10)
    }

    func testColdHiddenLaunchPreparesAllWindowsBeforeRevealAndRoute() {
        let system = ActivationTestSystem()
        system.install(appA)
        let coordinator = makeCoordinator(system: system)
        var results: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .spotlight) { results.append($0) }
        system.scheduler.advance(by: 0)
        XCTAssertEqual(system.openCalls.count, 1)
        XCTAssertTrue(system.openCalls[0].hidden)

        system.setInventory(
            .available(
                windows: [window(201), window(202, main: true), window(203, minimized: true)],
                hasUnaddressableWindows: false
            ),
            for: 105
        )
        system.completeOpen(bundleID: appA, pid: 105, hidden: true)
        system.scheduler.advance(by: 0)

        system.scheduler.advance(by: 0.099)
        XCTAssertTrue(system.prepareCalls.isEmpty)
        XCTAssertTrue(system.unhideCalls.isEmpty)

        system.scheduler.advance(by: 0.002)
        XCTAssertEqual(system.prepareCalls, [
            ActivationTestSystem.WindowSetCall(pid: 105, windowIDs: [201, 202], selectedWindowID: 202)
        ])
        XCTAssertEqual(system.unhideCalls, [105])
        XCTAssertTrue(system.unminimizeCalls.isEmpty, "unselected minimized windows must stay minimized")
        XCTAssertTrue(system.routeCalls.isEmpty)

        system.scheduler.advance(by: 0.05)
        XCTAssertEqual(system.routeCalls.map(\.windowID), [202])
        XCTAssertEqual(results, [.activated(windowID: 202)])

        let prepareIndex = system.events.firstIndex(of: "prepare")
        let unhideIndex = system.events.firstIndex(of: "unhide:105")
        let routeIndex = system.events.firstIndex(of: "route:202")
        guard let prepareIndex, let unhideIndex, let routeIndex else {
            return XCTFail("expected prepare, unhide, and route events")
        }
        XCTAssertLessThan(prepareIndex, unhideIndex)
        XCTAssertLessThan(unhideIndex, routeIndex)
    }

    func testTimeoutFailsOpenByUnhidingAndActivating() {
        let system = ActivationTestSystem()
        system.install(appA)
        let coordinator = makeCoordinator(system: system, hardTimeout: 0.5)
        var results: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .spotlight) { results.append($0) }
        system.scheduler.advance(by: 0)
        system.setInventory(.unavailable, for: 106)
        system.completeOpen(bundleID: appA, pid: 106, hidden: true)
        system.scheduler.advance(by: 0)
        system.scheduler.advance(by: 0.51)

        XCTAssertEqual(system.unhideCalls, [106])
        XCTAssertEqual(system.activateCalls, [106])
        XCTAssertEqual(results, [.timedOut])
        XCTAssertTrue(system.prepareCalls.isEmpty)
        XCTAssertTrue(system.routeCalls.isEmpty)
    }

    func testSameBundleRequestsCoalesceOntoOneLaunch() {
        let system = ActivationTestSystem()
        system.install(appA)
        let coordinator = makeCoordinator(system: system)
        var firstResults: [ApplicationActivationResult] = []
        var secondResults: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .hotkey) { firstResults.append($0) }
        _ = coordinator.activate(bundleID: appA, source: .spotlight) { secondResults.append($0) }
        system.scheduler.advance(by: 0)
        XCTAssertEqual(system.openCalls.count, 1)

        system.setInventory(
            .available(windows: [window(301)], hasUnaddressableWindows: false),
            for: 107
        )
        system.completeOpen(bundleID: appA, pid: 107, hidden: true)
        system.scheduler.advance(by: 0)
        system.scheduler.advance(by: 0.11)
        system.scheduler.advance(by: 0.05)

        XCTAssertEqual(system.openCalls.count, 1)
        XCTAssertEqual(firstResults, [.activated(windowID: 301)])
        XCTAssertEqual(secondResults, [.activated(windowID: 301)])
    }

    func testDifferentBundleCancelsOldRequestAndStaleOpenCannotStealFocus() {
        let system = ActivationTestSystem()
        system.install(appA)
        system.setProcess(appB, pid: 109, hidden: false)
        system.setInventory(
            .available(windows: [window(401)], hasUnaddressableWindows: false),
            for: 109
        )
        let coordinator = makeCoordinator(system: system)
        var firstResults: [ApplicationActivationResult] = []
        var secondResults: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .spotlight) { firstResults.append($0) }
        system.scheduler.advance(by: 0)
        _ = coordinator.activate(bundleID: appB, source: .hotkey) { secondResults.append($0) }
        system.scheduler.advance(by: 0)

        XCTAssertEqual(firstResults, [.cancelled])
        XCTAssertEqual(secondResults, [.activated(windowID: 401)])

        // Launch Services may finish A after its request was superseded. It
        // must be made visible for safety, but never activated or routed.
        system.setInventory(.unavailable, for: 108)
        system.completeOpen(at: 0, bundleID: appA, pid: 108, hidden: true)
        system.scheduler.advance(by: 1.1)

        XCTAssertEqual(system.unhideCalls, [108])
        XCTAssertFalse(system.activateCalls.contains(108))
        XCTAssertEqual(system.routeCalls.map(\.pid), [109])
        XCTAssertEqual(firstResults, [.cancelled])
        XCTAssertEqual(secondResults, [.activated(windowID: 401)])
    }

    func testForeignActivationImmediatelyCancelsRequest() {
        let system = ActivationTestSystem()
        system.install(appA)
        let coordinator = makeCoordinator(system: system)
        var results: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .spotlight) { results.append($0) }
        let claim = coordinator.noteApplicationActivated(bundleID: appB, pid: 202)
        system.scheduler.advance(by: 0)

        XCTAssertEqual(claim, .cancelledForUserOverride)
        XCTAssertEqual(results, [.cancelled])
    }

    func testMatchingActivationIsClaimedAndRequestContinues() {
        let system = ActivationTestSystem()
        system.install(appA)
        let coordinator = makeCoordinator(system: system)
        var results: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .spotlight) { results.append($0) }
        system.scheduler.advance(by: 0)
        system.setProcess(appA, pid: 110, hidden: false, active: true)
        system.setInventory(
            .available(windows: [window(501, focused: true)], hasUnaddressableWindows: false),
            for: 110
        )

        let claim = coordinator.noteApplicationActivated(bundleID: appA, pid: 110)
        system.scheduler.advance(by: 0)

        XCTAssertEqual(claim, .claimed)
        XCTAssertEqual(results, [.activated(windowID: 501)])
        XCTAssertEqual(system.routeCalls.map(\.windowID), [501])
    }

    func testFilteredWindowsAreNotTreatedAsConfirmedEmpty() {
        let system = ActivationTestSystem()
        system.setProcess(appA, pid: 111, hidden: false)
        system.setInventory(
            .available(windows: [], hasUnaddressableWindows: true),
            for: 111
        )
        let coordinator = makeCoordinator(system: system)
        var results: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .hotkey) { results.append($0) }
        system.scheduler.advance(by: 0)

        XCTAssertTrue(system.openCalls.isEmpty)
        XCTAssertEqual(system.activateCalls, [111])
        XCTAssertEqual(results, [.openedWithoutWindow])
    }

    func testSelectedWindowDoesNotChangeWhileRestoring() {
        let system = ActivationTestSystem()
        system.setProcess(appA, pid: 112, hidden: true)
        system.lastFocusedWindowID = 601
        system.setInventory(
            .available(windows: [window(601), window(602, focused: true)],
                       hasUnaddressableWindows: false),
            for: 112
        )
        let coordinator = makeCoordinator(system: system)
        var results: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .hotkey) { results.append($0) }
        system.lastFocusedWindowID = 602
        system.scheduler.advance(by: 0.05)

        XCTAssertEqual(system.routeCalls.map(\.windowID), [601])
        XCTAssertEqual(results, [.activated(windowID: 601)])
    }

    func testCancellingKnownColdLaunchUnhidesWithoutActivating() {
        let system = ActivationTestSystem()
        system.install(appA)
        let coordinator = makeCoordinator(system: system)
        var results: [ApplicationActivationResult] = []

        let handle = coordinator.activate(bundleID: appA, source: .spotlight) {
            results.append($0)
        }
        system.scheduler.advance(by: 0)
        system.setInventory(.unavailable, for: 113)
        system.completeOpen(bundleID: appA, pid: 113, hidden: true)
        system.scheduler.advance(by: 0)

        handle.cancel()
        system.scheduler.advance(by: 0)

        XCTAssertEqual(results, [.cancelled])
        XCTAssertEqual(system.unhideCalls, [113])
        XCTAssertTrue(system.activateCalls.isEmpty)
    }

    func testColdLaunchWaitsForReservationAndUsesRemainingDeadline() {
        let system = ActivationTestSystem()
        system.install(appA)
        system.automaticallyCompleteReservation = false
        let coordinator = makeCoordinator(system: system)

        _ = coordinator.activate(bundleID: appA, source: .spotlight) { _ in }
        system.scheduler.advance(by: 0.3)
        XCTAssertEqual(system.events, ["reserve"])
        XCTAssertTrue(system.openCalls.isEmpty)

        system.completeReservation()
        XCTAssertTrue(system.openCalls.isEmpty, "opening must yield to already queued user input")
        system.scheduler.advance(by: 0)

        XCTAssertEqual(system.events, ["reserve", "reservation-complete", "open-hidden"])
        XCTAssertEqual(system.openCalls.count, 1)
        XCTAssertEqual(system.protectionTimeouts.first ?? -1, 0.7, accuracy: 0.000_001)
    }

    func testCancellationDuringReservationPreventsLaunch() {
        let system = ActivationTestSystem()
        system.install(appA)
        system.automaticallyCompleteReservation = false
        let coordinator = makeCoordinator(system: system)
        var results: [ApplicationActivationResult] = []

        let handle = coordinator.activate(bundleID: appA, source: .hotkey) { results.append($0) }
        handle.cancel()
        system.scheduler.advance(by: 0)
        system.completeReservation()
        system.scheduler.advance(by: 1.1)

        XCTAssertTrue(system.openCalls.isEmpty)
        XCTAssertTrue(system.protections.isEmpty)
        XCTAssertEqual(results, [.cancelled])
        XCTAssertEqual(system.reservationFinishes.map(\.result), [.cancelled])
    }

    func testAppStartedExternallyDuringReservationUsesExistingWindowPath() {
        let system = ActivationTestSystem()
        system.install(appA)
        system.automaticallyCompleteReservation = false
        let coordinator = makeCoordinator(system: system)
        var results: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .spotlight) { results.append($0) }
        system.setProcess(appA, pid: 114, hidden: false)
        system.setInventory(
            .available(windows: [window(701)], hasUnaddressableWindows: false),
            for: 114
        )
        system.completeReservation()
        system.scheduler.advance(by: 0)

        XCTAssertTrue(system.openCalls.isEmpty, "never hide an app that started during preflow")
        XCTAssertTrue(system.protections.isEmpty)
        XCTAssertEqual(system.routeCalls.map(\.windowID), [701])
        XCTAssertEqual(results, [.activated(windowID: 701)])
    }

    func testModalAlongsideStandardWindowUsesAppOwnedFocus() {
        let system = ActivationTestSystem()
        system.setProcess(appA, pid: 115, hidden: true)
        system.setInventory(
            .available(windows: [window(801)], hasUnaddressableWindows: true),
            for: 115
        )
        let coordinator = makeCoordinator(system: system)
        var results: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .spotlight) { results.append($0) }
        system.scheduler.advance(by: 0)

        XCTAssertTrue(system.openCalls.isEmpty)
        XCTAssertTrue(system.prepareCalls.isEmpty)
        XCTAssertTrue(system.routeCalls.isEmpty, "do not raise a document above the app's dialog")
        XCTAssertEqual(system.unhideCalls, [115])
        XCTAssertEqual(system.activateCalls, [115])
        XCTAssertEqual(results, [.openedWithoutWindow])
    }

    func testDelayedTriggerInputIsIgnoredButNewInputCancelsRequest() {
        let system = ActivationTestSystem()
        system.install(appA)
        system.automaticallyCompleteReservation = false
        system.scheduler.advance(by: 10)
        let coordinator = makeCoordinator(system: system)
        var results: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .spotlight) { results.append($0) }
        coordinator.cancelForUserOverride(eventTimestamp: 9.9)
        system.scheduler.advance(by: 0)
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(system.reservationFinishes.isEmpty)

        coordinator.cancelForUserOverride(eventTimestamp: 10.1)
        system.scheduler.advance(by: 0)
        XCTAssertEqual(results, [.cancelled])
    }

    func testDelayedTriggerInputPreservesFocusTailButNewInputInvalidatesIt() {
        let system = ActivationTestSystem()
        system.setProcess(appA, pid: 116, hidden: false)
        system.setInventory(
            .available(windows: [window(901)], hasUnaddressableWindows: false),
            for: 116
        )
        system.scheduler.advance(by: 10)
        let coordinator = makeCoordinator(system: system)

        _ = coordinator.activate(bundleID: appA, source: .spotlight) { _ in }
        system.scheduler.advance(by: 0)
        guard let requestID = system.routeCalls.first?.requestID else {
            return XCTFail("expected an exact-window route")
        }

        coordinator.cancelForUserOverride(eventTimestamp: 9.9)
        XCTAssertTrue(coordinator.allowsFocusReassertion(for: requestID))
        coordinator.cancelForUserOverride(eventTimestamp: 10.1)
        XCTAssertFalse(coordinator.allowsFocusReassertion(for: requestID))
    }

    func testLateOpenCallbackRespectsManualHideAfterObservedReveal() {
        let system = ActivationTestSystem()
        system.install(appA)
        let coordinator = makeCoordinator(system: system)
        var results: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .spotlight) { results.append($0) }
        system.scheduler.advance(by: 0)
        system.setProcess(appA, pid: 117, hidden: true)
        system.setInventory(
            .available(windows: [window(902)], hasUnaddressableWindows: false),
            for: 117
        )
        coordinator.noteApplicationLaunched(bundleID: appA, pid: 117)
        system.scheduler.advance(by: 0.16)
        XCTAssertEqual(results, [.activated(windowID: 902)])
        XCTAssertEqual(system.unhideCalls, [117])
        XCTAssertEqual(system.protections.first?.disarmCount, 1)

        system.completeOpen(bundleID: appA, pid: 117, hidden: true)
        system.scheduler.advance(by: 0)
        XCTAssertEqual(system.unhideCalls, [117], "a late callback must not undo a later Cmd-H")
    }

    func testUnknownSecondApplicationCancelsPendingRequestWithoutStealingFocus() {
        let system = ActivationTestSystem()
        system.install(appA)
        let coordinator = makeCoordinator(system: system)
        var firstResults: [ApplicationActivationResult] = []
        var secondResults: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .spotlight) { firstResults.append($0) }
        system.scheduler.advance(by: 0)
        _ = coordinator.activate(bundleID: appB, source: .hotkey) { secondResults.append($0) }
        XCTAssertEqual(secondResults, [.unavailable])
        system.scheduler.advance(by: 0)
        XCTAssertEqual(firstResults, [.cancelled])

        system.completeOpen(bundleID: appA, pid: 118, hidden: true)
        system.scheduler.advance(by: 1.1)
        XCTAssertEqual(system.unhideCalls, [118])
        XCTAssertTrue(system.activateCalls.isEmpty)
        XCTAssertTrue(system.routeCalls.isEmpty)
        XCTAssertEqual(firstResults, [.cancelled])
    }

    func testTimeoutDuringReservationNeverStartsApplication() {
        let system = ActivationTestSystem()
        system.install(appA)
        system.automaticallyCompleteReservation = false
        let coordinator = makeCoordinator(system: system, hardTimeout: 0.5)
        var results: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .spotlight) { results.append($0) }
        system.scheduler.advance(by: 0.51)
        system.completeReservation()
        system.scheduler.advance(by: 0)

        XCTAssertEqual(results, [.timedOut])
        XCTAssertEqual(system.reservationFinishes.map(\.result), [.timedOut])
        XCTAssertTrue(system.openCalls.isEmpty)
        XCTAssertTrue(system.protections.isEmpty)
        XCTAssertTrue(system.activateCalls.isEmpty)
    }

    func testSameBundleLaunchNotificationCannotReplaceEstablishedPID() {
        let system = ActivationTestSystem()
        system.setProcess(appA, pid: 119, hidden: false)
        system.setInventory(
            .available(windows: [window(903)], hasUnaddressableWindows: false),
            for: 119
        )
        system.routeSucceeds = false
        let coordinator = makeCoordinator(system: system)
        var results: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .hotkey) { results.append($0) }
        coordinator.noteApplicationLaunched(bundleID: appA, pid: 120)
        coordinator.noteAXEvent(pid: 120)
        system.routeSucceeds = true
        coordinator.noteDiscoveryCompleted()
        system.scheduler.advance(by: 0.05)

        XCTAssertEqual(system.routeCalls.map(\.pid), [119, 119])
        XCTAssertEqual(results, [.activated(windowID: 903)])
    }

    func testCompletionCanStartAnotherActivationWithoutLosingIt() {
        let system = ActivationTestSystem()
        system.setProcess(appA, pid: 121, hidden: false)
        system.setProcess(appB, pid: 122, hidden: false)
        system.setInventory(.available(windows: [window(904)], hasUnaddressableWindows: false), for: 121)
        system.setInventory(.available(windows: [window(905)], hasUnaddressableWindows: false), for: 122)
        let coordinator = makeCoordinator(system: system)
        var firstResults: [ApplicationActivationResult] = []
        var secondResults: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .hotkey) { result in
            firstResults.append(result)
            _ = coordinator.activate(bundleID: self.appB, source: .spotlight) { secondResults.append($0) }
        }
        system.scheduler.advance(by: 0)

        XCTAssertEqual(firstResults, [.activated(windowID: 904)])
        XCTAssertEqual(secondResults, [.activated(windowID: 905)])
        XCTAssertEqual(system.routeCalls.map(\.pid), [121, 122])
    }

    func testFailedRouteAndDiscoveryStormRemainBounded() {
        let system = ActivationTestSystem()
        system.setProcess(appA, pid: 123, hidden: false)
        system.setInventory(.available(windows: [window(906)], hasUnaddressableWindows: false), for: 123)
        system.routeSucceeds = false
        let coordinator = makeCoordinator(system: system, hardTimeout: 0.5)
        var results: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .hotkey) { results.append($0) }
        for _ in 0..<100 {
            coordinator.noteDiscoveryCompleted()
            system.scheduler.advance(by: 0)
        }
        XCTAssertEqual(system.routeCalls.count, 1, "discovery must not start a zero-delay route loop")
        system.scheduler.advance(by: 0.51)

        XCTAssertTrue(system.routeCalls.count <= 8, "route retries must remain time-gated")
        XCTAssertTrue(system.discoveryDelays.count <= 6, "failed routes must coalesce discovery")
        XCTAssertEqual(results, [.timedOut])
    }

    func testNoWindowGraceStartsAtLateProcessAppearance() {
        let system = ActivationTestSystem()
        system.install(appA)
        let coordinator = makeCoordinator(system: system, hardTimeout: 2)
        var results: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .spotlight) { results.append($0) }
        system.scheduler.advance(by: 0.7)
        system.setInventory(.available(windows: [], hasUnaddressableWindows: false), for: 124)
        system.completeOpen(bundleID: appA, pid: 124, hidden: true)
        system.scheduler.advance(by: 0.19)
        XCTAssertTrue(results.isEmpty, "a slow process still gets its own window-creation grace")
        XCTAssertTrue(system.unhideCalls.isEmpty)

        system.scheduler.advance(by: 0.06)
        XCTAssertEqual(results, [.openedWithoutWindow])
        XCTAssertEqual(system.unhideCalls, [124])
    }

    func testNoWindowGraceStartsAtLateReopen() {
        let system = ActivationTestSystem()
        system.setProcess(appA, pid: 125, hidden: false)
        system.setInventory(.available(windows: [window(907)], hasUnaddressableWindows: false), for: 125)
        system.routeSucceeds = false
        let coordinator = makeCoordinator(system: system, hardTimeout: 2)
        var results: [ApplicationActivationResult] = []

        _ = coordinator.activate(bundleID: appA, source: .hotkey) { results.append($0) }
        system.scheduler.advance(by: 0.5)
        system.setInventory(.available(windows: [], hasUnaddressableWindows: false), for: 125)
        coordinator.noteAXEvent(pid: 125)
        system.scheduler.advance(by: 0.031)
        XCTAssertEqual(system.openCalls.count, 1)
        system.openCalls[0].completion(.opened(pid: 125))
        system.scheduler.advance(by: 0.19)
        XCTAssertTrue(results.isEmpty, "reopen grace must not use the old trigger timestamp")

        system.scheduler.advance(by: 0.06)
        XCTAssertEqual(results, [.openedWithoutWindow])
        XCTAssertEqual(system.openCalls.count, 1)
    }

    func testDeinitializationReleasesSubscriberCaptureWhileTimersRemainPending() {
        let system = ActivationTestSystem()
        system.setProcess(appA, pid: 126, hidden: false)
        system.setInventory(.available(windows: [window(908)], hasUnaddressableWindows: false), for: 126)
        system.routeSucceeds = false
        var coordinator: ApplicationActivationCoordinator? = makeCoordinator(system: system)
        weak var observedCoordinator: ApplicationActivationCoordinator?
        observedCoordinator = coordinator
        weak var capturedObject: NSObject?

        do {
            let object = NSObject()
            capturedObject = object
            _ = coordinator?.activate(bundleID: appA, source: .hotkey) { [object] _ in
                withExtendedLifetime(object) {}
            }
        }
        XCTAssertFalse(capturedObject == nil, "the in-flight subscriber should retain its capture")
        XCTAssertTrue(system.openCalls.isEmpty)

        coordinator = nil

        XCTAssertTrue(observedCoordinator == nil)
        XCTAssertTrue(capturedObject == nil, "pending timers must not keep the request/subscriber alive")
        system.scheduler.advance(by: 1.1)
        XCTAssertEqual(system.routeCalls.count, 1)
        XCTAssertTrue(system.activateCalls.isEmpty)
    }
}
