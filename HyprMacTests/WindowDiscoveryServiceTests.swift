import XCTest
@testable import HyprMac

// WindowDiscoveryServiceTests pin the diff semantics that pollWindowChanges
// used to compute inline. tests inject snapshots + runningPID sets directly
// via computeChanges, so the service is exercised without AX or NSWorkspace.
//
// drift detection and auto-float-on-disabled-monitor depend on NSScreen-keyed
// state and aren't exercisable at this level — those land in the manual smoke
// checklist.

/// answers the minimized/app-hidden query with a scripted value so the
/// gone path's reservation branch is testable without live AX.
final class StubAccessibility: AccessibilityManager {
    var stateAnswer: AccessibilityManager.HiddenWindowState?
    /// ids the service asked about, so tests can pin who gets re-verified.
    var queries: [CGWindowID] = []
    /// pids the walk is backing off from
    var backingOff: Set<pid_t> = []
    /// when the walk would next ask a skipped app
    var backoffWake: TimeInterval?

    override func isBackingOff(pid: pid_t) -> Bool { backingOff.contains(pid) }
    override var secondsUntilABackoffEnds: TimeInterval? { backoffWake }

    override func hiddenWindowState(windowID: CGWindowID, pid: pid_t) -> AccessibilityManager.HiddenWindowState? {
        queries.append(windowID)
        return stateAnswer
    }
}

final class WindowDiscoveryServiceTests: XCTestCase {

    func testFloatingAdmissionPolicyIsSharedAndConservative() {
        XCTAssertEqual(
            FloatingAdmissionPolicy.reason(isExcluded: true, isSizeSettable: nil),
            .excludedApp
        )
        XCTAssertEqual(
            FloatingAdmissionPolicy.reason(isExcluded: false, isSizeSettable: false),
            .fixedSize
        )
        XCTAssertNil(FloatingAdmissionPolicy.reason(isExcluded: false, isSizeSettable: true))
        XCTAssertNil(FloatingAdmissionPolicy.reason(isExcluded: false, isSizeSettable: nil))
    }

    // MARK: - fixtures

    private func makeService(
        cache: WindowStateCache = WindowStateCache(),
        accessibility: AccessibilityManager = AccessibilityManager(),
        bundleIDForPID: @escaping (pid_t) -> String? = { _ in nil },
        isWindowSizeSettable: @escaping (HyprWindow) -> Bool? = { _ in true }
    ) -> (WindowDiscoveryService, WindowStateCache, WorkspaceManager) {
        let display = DisplayManager()
        let workspaces = WorkspaceManager(displayManager: display)
        let access = accessibility
        let svc = WindowDiscoveryService(
            stateCache: cache,
            accessibility: access,
            displayManager: display,
            workspaceManager: workspaces,
            bundleIDForPID: bundleIDForPID,
            isWindowSizeSettable: isWindowSizeSettable
        )
        return (svc, cache, workspaces)
    }

    private func compute(
        _ svc: WindowDiscoveryService,
        snapshot: [HyprWindow],
        runningPIDs: Set<pid_t> = [],
        excluded: Set<String> = [],
        focusedID: CGWindowID = 0,
        unreadable: Set<CGWindowID> = []
    ) -> WindowChanges {
        svc.computeChanges(
            snapshot: snapshot,
            runningPIDs: runningPIDs,
            excludedBundleIDs: excluded,
            focusedWindowID: focusedID,
            unreadableWindowIDs: unreadable
        )
    }

    // MARK: - empty / no-op

    func testEmptySnapshotEmptyCacheProducesEmptyChanges() {
        let (svc, _, _) = makeService()
        let changes = compute(svc, snapshot: [])

        XCTAssertTrue(changes.newWindows.isEmpty)
        XCTAssertTrue(changes.returned.isEmpty)
        XCTAssertTrue(changes.goneIDs.isEmpty)
        XCTAssertTrue(changes.fullyForgottenIDs.isEmpty)
        XCTAssertTrue(changes.screenDrift.isEmpty)
        XCTAssertFalse(changes.focusedWindowGone)
        XCTAssertFalse(changes.needsRetile)
    }

    // MARK: - admit-only pass under a workspace switch's hold

    private func admit(_ svc: WindowDiscoveryService, _ snapshot: [HyprWindow],
                       unreadable: Set<CGWindowID> = []) -> WindowChanges {
        svc.computeAdmissions(snapshot: snapshot, excludedBundleIDs: [], unreadableWindowIDs: unreadable)
    }

    func testTheAdmitOnlyPassTakesABrandNewWindow() {
        let (svc, cache, _) = makeService()
        let changes = admit(svc, [makeWindow(id: 300, pid: 5000)])

        XCTAssertEqual(changes.newWindows.map(\.windowID), [300])
        XCTAssertTrue(cache.knownWindowIDs.contains(300))
        XCTAssertEqual(cache.windowOwners[300], 5000)
        XCTAssertTrue(changes.returned.isEmpty)
        XCTAssertTrue(changes.goneIDs.isEmpty)
        XCTAssertTrue(changes.screenDrift.isEmpty)
    }

    // the switch parks and reveals known windows, and a walk mid-hold reads
    // them at stale frames. the admit-only pass must change nothing about
    // them, nor about ghosts, minimized windows or one missing from the walk
    func testTheAdmitOnlyPassLeavesEveryWindowItAlreadyKnowsAlone() {
        let (svc, cache, workspaces) = makeService()
        cache.knownWindowIDs = [10, 11, 12]
        cache.hiddenWindowIDs = [20, 21]
        cache.reservedHiddenWindowIDs = [21]
        cache.floatingWindowIDs = [11]
        for id: CGWindowID in [10, 11, 12, 20, 21] { cache.windowOwners[id] = 5000 }
        // 10 tiled on the revealed workspace, 11 a floater being parked, 20 a
        // ghost, 21 minimized. 30 is unknown to discovery but already on a
        // workspace: the switch's to move, not a newcomer
        workspaces.assignWindow(10, toWorkspace: 2)
        workspaces.assignWindow(11, toWorkspace: 1)
        workspaces.assignWindow(20, toWorkspace: 1)
        workspaces.assignWindow(21, toWorkspace: 2)
        workspaces.assignWindow(30, toWorkspace: 1)
        let known = cache.knownWindowIDs, hidden = cache.hiddenWindowIDs
        let reserved = cache.reservedHiddenWindowIDs, owners = cache.windowOwners

        // 12 is missing from this walk, 40 could not be read
        let changes = admit(svc, [10, 11, 20, 21, 30, 40].map { makeWindow(id: $0, pid: 5000) },
                            unreadable: [40])

        XCTAssertTrue(changes.newWindows.isEmpty)
        XCTAssertFalse(changes.needsRetile)
        XCTAssertEqual(cache.knownWindowIDs, known, "12 is not gone, 20 and 21 are not back")
        XCTAssertEqual(cache.hiddenWindowIDs, hidden)
        XCTAssertEqual(cache.reservedHiddenWindowIDs, reserved)
        XCTAssertEqual(cache.floatingWindowIDs, [11])
        XCTAssertEqual(cache.windowOwners, owners)
        XCTAssertEqual(workspaces.workspaceFor(10), 2)
        XCTAssertEqual(workspaces.workspaceFor(11), 1)
        XCTAssertEqual(workspaces.workspaceFor(30), 1)
    }

    func testTheAdmitOnlyPassAdmitsNothingWhileTheSessionIsLocked() {
        let (svc, cache, _) = makeService()
        svc.noteSystemInterruption(Self.locked)
        XCTAssertTrue(admit(svc, [makeWindow(id: 301, pid: 5000)]).newWindows.isEmpty)
        XCTAssertFalse(cache.knownWindowIDs.contains(301))
    }

    func testTheFullPollAfterTheHoldDoesNotAdmitAnAdmittedWindowAgain() {
        let (svc, _, _) = makeService()
        let w = makeWindow(id: 302, pid: 5000)
        _ = admit(svc, [w])
        XCTAssertTrue(compute(svc, snapshot: [w], runningPIDs: [5000]).newWindows.isEmpty)
    }

    // MARK: - new-window detection

    func testNewWindowAppearsInNewWindowsAndUpdatesCache() {
        let (svc, cache, _) = makeService()
        let w = makeWindow(id: 100, pid: 5000)

        let changes = compute(svc, snapshot: [w])

        XCTAssertEqual(changes.newWindows.map { $0.windowID }, [100])
        XCTAssertTrue(cache.knownWindowIDs.contains(100))
        XCTAssertEqual(cache.windowOwners[100], 5000)
        XCTAssertTrue(changes.needsRetile)
    }

    func testKnownWindowIsNotFlaggedAsNew() {
        let (svc, cache, _) = makeService()
        cache.knownWindowIDs.insert(42)
        cache.windowOwners[42] = 7000

        let w = makeWindow(id: 42, pid: 7000)
        let changes = compute(svc, snapshot: [w], runningPIDs: [7000])

        XCTAssertTrue(changes.newWindows.isEmpty)
        XCTAssertFalse(changes.needsRetile)
    }

    func testAutoFloatExcludedBundleIDMutatesCacheButStillAssignableForCaller() {
        let (svc, cache, _) = makeService(bundleIDForPID: { _ in "com.apple.FaceTime" })

        let w = makeWindow(id: 1, pid: 99)
        let changes = compute(svc, snapshot: [w], excluded: ["com.apple.FaceTime"])

        XCTAssertEqual(changes.newWindows.count, 1)
        XCTAssertTrue(cache.floatingWindowIDs.contains(1))
        XCTAssertTrue(w.isFloating)
        // excluded apps still get a workspace assignment in the caller's apply
        // loop — only disabled-monitor autofloat goes into newOnDisabledMonitor.
        XCTAssertFalse(changes.newOnDisabledMonitor.contains(1))
    }

    func testNonExcludedBundleIDDoesNotAutoFloat() {
        let (svc, cache, _) = makeService(bundleIDForPID: { _ in "com.apple.Terminal" })

        let w = makeWindow(id: 1, pid: 99)
        let changes = compute(svc, snapshot: [w], excluded: ["com.apple.FaceTime"])

        XCTAssertFalse(cache.floatingWindowIDs.contains(1))
        XCTAssertFalse(w.isFloating)
        XCTAssertEqual(changes.newWindows.count, 1)
    }

    func testNonResizableWindowAutoFloatsWithoutAnAppException() {
        let (svc, cache, _) = makeService(
            bundleIDForPID: { _ in "com.example.Utility" },
            isWindowSizeSettable: { _ in false }
        )

        let w = makeWindow(id: 2, pid: 100)
        let changes = compute(svc, snapshot: [w])

        XCTAssertEqual(changes.newWindows.map(\.windowID), [2])
        XCTAssertTrue(cache.floatingWindowIDs.contains(2))
        XCTAssertTrue(w.isFloating)
    }

    func testUnknownResizeCapabilityDoesNotAutoFloat() {
        let (svc, cache, _) = makeService(isWindowSizeSettable: { _ in nil })

        let w = makeWindow(id: 3, pid: 101)
        _ = compute(svc, snapshot: [w])

        XCTAssertFalse(cache.floatingWindowIDs.contains(3))
        XCTAssertFalse(w.isFloating)
    }

    func testExcludedAppStillAutoFloatsWhenResizeCapabilityIsUnknown() {
        let (svc, cache, _) = makeService(
            bundleIDForPID: { _ in "com.example.Excluded" },
            isWindowSizeSettable: { _ in nil }
        )

        let w = makeWindow(id: 4, pid: 102)
        _ = compute(svc, snapshot: [w], excluded: ["com.example.Excluded"])

        XCTAssertTrue(cache.floatingWindowIDs.contains(4))
        XCTAssertTrue(w.isFloating)
    }

    // MARK: - gone (alive pid → hidden)

    func testMassGoneGuardRequestsPromptRecheck() {
        let (svc, cache, _) = makeService()
        cache.knownWindowIDs = [1, 2, 3, 4]
        cache.windowOwners = [1: 8000, 2: 8000, 3: 8000, 4: 8000]

        let first = compute(svc, snapshot: [], runningPIDs: [8000])

        XCTAssertTrue(first.goneIDs.isEmpty)
        XCTAssertTrue(first.requestsRecheck)

        XCTAssertTrue(compute(svc, snapshot: [], runningPIDs: [8000]).requestsRecheck)
        XCTAssertTrue(compute(svc, snapshot: [], runningPIDs: [8000]).requestsRecheck)
        let fourth = compute(svc, snapshot: [], runningPIDs: [8000])
        XCTAssertEqual(fourth.goneIDs, [1, 2, 3, 4])
        XCTAssertTrue(fourth.needsRetile)
        XCTAssertFalse(fourth.requestsRecheck)
    }

    // MARK: - lock and display sleep

    private static let locked = "com.apple.screenIsLocked"
    private static let unlocked = "com.apple.screenIsUnlocked"

    /// five windows on one live pid, the shape of the 09:36 lock log
    private func lockFixture() -> (WindowDiscoveryService, WindowStateCache, [HyprWindow]) {
        let (svc, cache, _) = makeService()
        let windows = (1...5).map { makeWindow(id: CGWindowID($0), pid: 8000) }
        cache.knownWindowIDs = Set(windows.map(\.windowID))
        for w in windows { cache.windowOwners[w.windowID] = 8000 }
        return (svc, cache, windows)
    }

    func testALockedSessionHoldsEveryMissingWindowUntilUnlock() {
        let (svc, cache, windows) = lockFixture()
        svc.noteSystemInterruption(Self.locked)

        // well past the three mass-gone skips, and through a display sleep
        // and wake that both happen while the lock screen is up
        for poll in 0..<8 {
            if poll == 2 { svc.noteSystemInterruption(NSWorkspace.screensDidSleepNotification.rawValue) }
            if poll == 5 { svc.noteSystemInterruption(NSWorkspace.screensDidWakeNotification.rawValue) }
            let changes = compute(svc, snapshot: [], runningPIDs: [8000])
            XCTAssertTrue(changes.heldForInterruption, "poll \(poll)")
            XCTAssertTrue(changes.goneIDs.isEmpty, "poll \(poll)")
            XCTAssertFalse(changes.needsRetile, "poll \(poll)")
            XCTAssertFalse(changes.requestsRecheck, "no prompt re-poll while locked")
        }
        XCTAssertEqual(cache.knownWindowIDs, Set(windows.map(\.windowID)))
        XCTAssertTrue(cache.hiddenWindowIDs.isEmpty, "nothing was marked hidden")

        svc.noteSystemInterruption(Self.unlocked)
        let back = compute(svc, snapshot: windows, runningPIDs: [8000])

        XCTAssertTrue(back.returned.isEmpty, "nothing left, so nothing returns")
        XCTAssertFalse(back.needsRetile, "and no retile rebuilds the trees")
        XCTAssertFalse(back.heldForInterruption)
    }

    func testTheSpanLastsUntilEveryReasonHasEnded() {
        let (svc, _, _) = lockFixture()
        svc.noteSystemInterruption(NSWorkspace.screensDidSleepNotification.rawValue)
        svc.noteSystemInterruption(Self.locked)
        svc.noteSystemInterruption(NSWorkspace.screensDidWakeNotification.rawValue)

        XCTAssertTrue(compute(svc, snapshot: [], runningPIDs: [8000]).goneIDs.isEmpty)
        XCTAssertFalse(compute(svc, snapshot: [], runningPIDs: [8000]).requestsRecheck)

        svc.noteSystemInterruption(Self.unlocked)
        XCTAssertTrue(compute(svc, snapshot: [], runningPIDs: [8000]).requestsRecheck,
                      "unlocked and awake: the ordinary mass-gone guard is back in charge")
    }

    func testAWindowThatReallyClosedDuringTheLockIsHiddenAfterUnlock() {
        let (svc, cache, windows) = lockFixture()
        svc.noteSystemInterruption(Self.locked)
        let fourLeft = Array(windows.dropFirst())
        XCTAssertTrue(compute(svc, snapshot: fourLeft, runningPIDs: [8000]).goneIDs.isEmpty)

        svc.noteSystemInterruption(Self.unlocked)
        let changes = compute(svc, snapshot: fourLeft, runningPIDs: [8000])

        XCTAssertEqual(changes.goneIDs, [1])
        XCTAssertTrue(cache.hiddenWindowIDs.contains(1))
    }

    func testTheCapEndsASpanWhoseEndNeverCame() {
        let (svc, _, _) = lockFixture()
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        svc.now = { clock }
        svc.noteSystemInterruption(Self.locked)
        clock += WindowDiscoveryService.interruptionCap - 1
        XCTAssertFalse(compute(svc, snapshot: [], runningPIDs: [8000]).requestsRecheck, "still held")

        clock += 2
        XCTAssertTrue(compute(svc, snapshot: [], runningPIDs: [8000]).requestsRecheck,
                      "past the cap the span is over and the mass-gone guard runs")
    }

    func testAHeldCycleIsOnlyAHoldWhileSomethingIsMissing() {
        let (svc, _, windows) = lockFixture()
        svc.noteSystemInterruption(Self.locked)

        XCTAssertFalse(compute(svc, snapshot: windows, runningPIDs: [8000]).heldForInterruption,
                       "a full snapshot is an ordinary no-op cycle")
    }

    func testAHotkeyPressEndsTheSpan() {
        let (svc, _, _) = lockFixture()
        svc.noteSystemInterruption(Self.locked)
        svc.endSessionInterruption(evidence: "hotkey press")

        XCTAssertTrue(compute(svc, snapshot: [], runningPIDs: [8000]).requestsRecheck)
    }

    func testNotificationsThatOpenNoSpanChangeNothing() {
        let (svc, _, _) = lockFixture()
        // a system wake says nothing about the lock, and an unlock with no
        // lock before it has nothing to end
        svc.noteSystemInterruption(NSWorkspace.didWakeNotification.rawValue)
        svc.noteSystemInterruption(Self.unlocked)

        XCTAssertTrue(compute(svc, snapshot: [], runningPIDs: [8000]).requestsRecheck)
    }

    func testASwitchedOutSessionHoldsMissingWindowsToo() {
        let (svc, _, _) = lockFixture()
        svc.noteSystemInterruption(NSWorkspace.sessionDidResignActiveNotification.rawValue)
        XCTAssertFalse(compute(svc, snapshot: [], runningPIDs: [8000]).requestsRecheck)

        svc.noteSystemInterruption(NSWorkspace.sessionDidBecomeActiveNotification.rawValue)
        XCTAssertTrue(compute(svc, snapshot: [], runningPIDs: [8000]).requestsRecheck)
    }

    func testTheSpanIsReadableForTheRecoveryRetry() {
        // the admission recovery's own timer reads this, not a poll
        let (svc, _, _) = lockFixture()
        XCTAssertFalse(svc.isSessionInterrupted)
        svc.noteSystemInterruption(NSWorkspace.screensDidSleepNotification.rawValue)
        XCTAssertTrue(svc.isSessionInterrupted, "display sleep alone opens a span")
        svc.noteSystemInterruption(Self.locked)
        svc.noteSystemInterruption(NSWorkspace.screensDidWakeNotification.rawValue)
        XCTAssertTrue(svc.isSessionInterrupted, "still locked")
        svc.noteSystemInterruption(Self.unlocked)
        XCTAssertFalse(svc.isSessionInterrupted)
    }

    func testGoneWindowWithLivePIDMovesToHidden() {
        let (svc, cache, _) = makeService()
        cache.knownWindowIDs = [10]
        cache.windowOwners[10] = 8000

        let changes = compute(svc, snapshot: [], runningPIDs: [8000])

        XCTAssertTrue(changes.goneIDs.contains(10))
        XCTAssertFalse(changes.fullyForgottenIDs.contains(10))
        XCTAssertFalse(cache.knownWindowIDs.contains(10))
        XCTAssertTrue(cache.hiddenWindowIDs.contains(10))
        // owner pid retained so the un-hide path can restore the wid as "returned"
        XCTAssertEqual(cache.windowOwners[10], 8000)
        XCTAssertTrue(changes.needsRetile)
    }

    // MARK: - unreadable windows

    /// the window server still shows the window; its app just did not
    /// answer. it stays known, on its workspace and in its tree, and nobody
    /// asks the same app whether the window is minimized
    func testAnUnreadableWindowIsHeldNotHidden() {
        let stub = StubAccessibility()
        let (svc, cache, _) = makeService(accessibility: stub)
        cache.knownWindowIDs = [10, 11]
        cache.windowOwners = [10: 8000, 11: 8000]

        let changes = compute(svc, snapshot: [makeWindow(id: 10, pid: 8000)],
                              runningPIDs: [8000], unreadable: [11])

        XCTAssertTrue(changes.goneIDs.isEmpty)
        XCTAssertFalse(changes.needsRetile)
        XCTAssertTrue(cache.knownWindowIDs.contains(11))
        XCTAssertFalse(cache.hiddenWindowIDs.contains(11))
        XCTAssertTrue(stub.queries.isEmpty)
    }

    /// once the app answers again the window is simply present: not
    /// returned, not new, nothing to retile
    func testAHeldWindowThatReadsAgainIsNoChange() {
        let (svc, cache, _) = makeService(accessibility: StubAccessibility())
        cache.knownWindowIDs = [10, 11]
        cache.windowOwners = [10: 8000, 11: 8000]
        let windows = [makeWindow(id: 10, pid: 8000), makeWindow(id: 11, pid: 8000)]
        _ = compute(svc, snapshot: [windows[0]], runningPIDs: [8000], unreadable: [11])

        let changes = compute(svc, snapshot: windows, runningPIDs: [8000])

        XCTAssertTrue(changes.returned.isEmpty)
        XCTAssertTrue(changes.newWindows.isEmpty)
        XCTAssertFalse(changes.needsRetile)
    }

    /// a whole app that stops answering is not a mass close
    func testHeldWindowsDoNotTripTheMassGoneGuard() {
        let (svc, cache, _) = makeService(accessibility: StubAccessibility())
        cache.knownWindowIDs = [1, 2, 3, 4]
        cache.windowOwners = [1: 8000, 2: 8000, 3: 8000, 4: 8000]

        let changes = compute(svc, snapshot: [], runningPIDs: [8000], unreadable: [1, 2, 3, 4])

        XCTAssertFalse(changes.requestsRecheck)
        XCTAssertTrue(changes.goneIDs.isEmpty)
        XCTAssertEqual(cache.knownWindowIDs, [1, 2, 3, 4])
    }

    /// a window its app answered for and no longer lists is gone as before
    func testAMissingWindowOfAReadableAppIsStillGone() {
        let (svc, cache, _) = makeService(accessibility: StubAccessibility())
        cache.knownWindowIDs = [10, 11]
        cache.windowOwners = [10: 8000, 11: 8000]

        let changes = compute(svc, snapshot: [makeWindow(id: 10, pid: 8000)],
                              runningPIDs: [8000], unreadable: [])

        XCTAssertEqual(changes.goneIDs, [11])
        XCTAssertTrue(cache.hiddenWindowIDs.contains(11))
        XCTAssertTrue(changes.needsRetile)
    }

    // MARK: - hidden-window workspace reservations

    func testVerifiedClosedHiddenWindowDoesNotReserveItsWorkspaceSlot() {
        let access = StubAccessibility()
        access.stateAnswer = .absent
        let (svc, cache, _) = makeService(accessibility: access)
        cache.knownWindowIDs = [10]
        cache.windowOwners[10] = 8000

        _ = compute(svc, snapshot: [], runningPIDs: [8000])

        XCTAssertTrue(cache.hiddenWindowIDs.contains(10))
        XCTAssertFalse(cache.reservedHiddenWindowIDs.contains(10))
    }

    func testMinimizedHiddenWindowReservesItsWorkspaceSlot() {
        let access = StubAccessibility()
        access.stateAnswer = .minimized
        let (svc, cache, _) = makeService(accessibility: access)
        cache.knownWindowIDs = [11]
        cache.windowOwners[11] = 8100

        _ = compute(svc, snapshot: [], runningPIDs: [8100])

        XCTAssertTrue(cache.hiddenWindowIDs.contains(11))
        XCTAssertTrue(cache.reservedHiddenWindowIDs.contains(11))
    }

    func testWindowStillListedByItsAppReservesItsWorkspaceSlot() {
        // another Space or native full-screen: the app still lists it, it is
        // not minimized, and it comes back on its own — not a close. held
        // first (below); once the hold passes it is hidden with its slot
        // reserved.
        let access = StubAccessibility()
        access.stateAnswer = .present
        let (svc, cache, _) = makeService(accessibility: access)
        var clock = Date(timeIntervalSinceReferenceDate: 1000)
        svc.now = { clock }
        cache.knownWindowIDs = [12]
        cache.windowOwners[12] = 8200

        _ = compute(svc, snapshot: [], runningPIDs: [8200])
        clock += WindowDiscoveryService.listedHoldSpan + 1
        _ = compute(svc, snapshot: [], runningPIDs: [8200])

        XCTAssertTrue(cache.hiddenWindowIDs.contains(12))
        XCTAssertTrue(cache.reservedHiddenWindowIDs.contains(12))
    }

    // MARK: - windows off the screen their app still lists

    /// a native full-screen app on the display, or a Space switched away:
    /// the window server stops showing the window, its app still lists it
    /// and it is not minimized. taking it out of its tree expanded the
    /// neighbour over its slot and put it back somewhere else a second later
    func testAWindowItsAppStillListsIsHeldBeforeItIsHidden() {
        let access = StubAccessibility()
        access.stateAnswer = .present
        let (svc, cache, _) = makeService(accessibility: access)
        cache.knownWindowIDs = [10, 12]
        cache.windowOwners = [10: 8200, 12: 8200]

        let changes = compute(svc, snapshot: [makeWindow(id: 10, pid: 8200)], runningPIDs: [8200])

        XCTAssertTrue(changes.goneIDs.isEmpty)
        XCTAssertFalse(changes.needsRetile)
        XCTAssertTrue(cache.knownWindowIDs.contains(12))
        XCTAssertFalse(cache.hiddenWindowIDs.contains(12))
        XCTAssertEqual(svc.heldWindowIDs, [12])
        XCTAssertEqual(access.queries, [12], "asked once, for the hold and the classification together")
    }

    func testAListedWindowBackWithinTheSpanIsNoChange() {
        let access = StubAccessibility()
        access.stateAnswer = .present
        let (svc, cache, _) = makeService(accessibility: access)
        cache.knownWindowIDs = [10, 12]
        cache.windowOwners = [10: 8200, 12: 8200]
        let windows = [makeWindow(id: 10, pid: 8200), makeWindow(id: 12, pid: 8200)]
        _ = compute(svc, snapshot: [windows[0]], runningPIDs: [8200])

        let changes = compute(svc, snapshot: windows, runningPIDs: [8200])

        XCTAssertTrue(changes.returned.isEmpty)
        XCTAssertFalse(changes.needsRetile)
        XCTAssertTrue(svc.heldWindowIDs.isEmpty)
    }

    func testAListedWindowStillMissingAfterTheSpanIsHiddenAndReserved() {
        let access = StubAccessibility()
        access.stateAnswer = .present
        let (svc, cache, _) = makeService(accessibility: access)
        var clock = Date(timeIntervalSinceReferenceDate: 1000)
        svc.now = { clock }
        cache.knownWindowIDs = [10, 12]
        cache.windowOwners = [10: 8200, 12: 8200]
        let other = makeWindow(id: 10, pid: 8200)
        _ = compute(svc, snapshot: [other], runningPIDs: [8200])
        clock += 3
        XCTAssertFalse(compute(svc, snapshot: [other], runningPIDs: [8200]).needsRetile, "still held")
        clock += 3

        let changes = compute(svc, snapshot: [other], runningPIDs: [8200])

        XCTAssertEqual(changes.goneIDs, [12])
        XCTAssertTrue(cache.hiddenWindowIDs.contains(12))
        XCTAssertTrue(cache.reservedHiddenWindowIDs.contains(12))
        XCTAssertTrue(svc.heldWindowIDs.isEmpty)
    }

    /// the hold ends on its own; the caller polls then, not at the next
    /// ten-second reconcile
    func testAHoldSaysWhenItEnds() {
        let access = StubAccessibility()
        access.stateAnswer = .present
        let (svc, cache, _) = makeService(accessibility: access)
        var clock = Date(timeIntervalSinceReferenceDate: 1000)
        svc.now = { clock }
        cache.knownWindowIDs = [10, 12]
        cache.windowOwners = [10: 8200, 12: 8200]
        let other = makeWindow(id: 10, pid: 8200)
        XCTAssertNil(svc.secondsUntilAHoldEnds)

        _ = compute(svc, snapshot: [other], runningPIDs: [8200])
        XCTAssertEqual(svc.secondsUntilAHoldEnds!, WindowDiscoveryService.listedHoldSpan, accuracy: 0.001)
        clock += 3
        XCTAssertEqual(svc.secondsUntilAHoldEnds!, WindowDiscoveryService.listedHoldSpan - 3, accuracy: 0.001)
        clock += 3
        _ = compute(svc, snapshot: [other], runningPIDs: [8200])
        XCTAssertNil(svc.secondsUntilAHoldEnds, "hidden now; nothing to wait for")
    }

    func testAListedWindowMinimizedDuringTheHoldIsHiddenAtOnce() {
        let access = StubAccessibility()
        access.stateAnswer = .present
        let (svc, cache, _) = makeService(accessibility: access)
        cache.knownWindowIDs = [10, 12]
        cache.windowOwners = [10: 8200, 12: 8200]
        let other = makeWindow(id: 10, pid: 8200)
        _ = compute(svc, snapshot: [other], runningPIDs: [8200])
        access.stateAnswer = .minimized

        let changes = compute(svc, snapshot: [other], runningPIDs: [8200])

        XCTAssertEqual(changes.goneIDs, [12])
        XCTAssertTrue(cache.hiddenWindowIDs.contains(12))
    }

    // issue #73: the poll follows a minimized window's return, never a
    // closed id's reuse
    func testAMinimizedReturnIsMarkedAsAUserHideReturn() {
        let access = StubAccessibility()
        access.stateAnswer = .minimized
        let (svc, cache, _) = makeService(accessibility: access)
        cache.knownWindowIDs = [12]
        cache.windowOwners = [12: 8200]
        _ = compute(svc, snapshot: [], runningPIDs: [8200])

        let changes = compute(svc, snapshot: [makeWindow(id: 12, pid: 8200)], runningPIDs: [8200])

        XCTAssertEqual(changes.returned.map(\.windowID), [12])
        XCTAssertEqual(changes.returnedFromUserHide, [12])
    }

    // a slow app's window that dropped out of one walk must not pull the
    // user to its workspace
    func testAnUnreadableThenReturnedWindowIsNotAUserHideReturn() {
        let access = StubAccessibility()
        access.stateAnswer = nil
        let (svc, cache, _) = makeService(accessibility: access)
        cache.knownWindowIDs = [12]
        cache.windowOwners = [12: 8200]
        _ = compute(svc, snapshot: [], runningPIDs: [8200])
        XCTAssertTrue(cache.reservedHiddenWindowIDs.contains(12), "still reserved, the safe side")

        let changes = compute(svc, snapshot: [makeWindow(id: 12, pid: 8200)], runningPIDs: [8200])

        XCTAssertEqual(changes.returned.map(\.windowID), [12])
        XCTAssertTrue(changes.returnedFromUserHide.isEmpty)
    }

    func testAnUnreadableHideLaterVerifiedMinimizedIsAUserHideReturn() {
        let access = StubAccessibility()
        access.stateAnswer = nil
        let (svc, cache, _) = makeService(accessibility: access)
        cache.knownWindowIDs = [12]
        cache.windowOwners = [12: 8200]
        _ = compute(svc, snapshot: [], runningPIDs: [8200])
        access.stateAnswer = .minimized
        _ = compute(svc, snapshot: [], runningPIDs: [8200])

        let changes = compute(svc, snapshot: [makeWindow(id: 12, pid: 8200)], runningPIDs: [8200])

        XCTAssertEqual(changes.returnedFromUserHide, [12])
    }

    func testAClosedIdComingBackIsNotAUserHideReturn() {
        let access = StubAccessibility()
        access.stateAnswer = .absent
        let (svc, cache, _) = makeService(accessibility: access)
        cache.knownWindowIDs = [12]
        cache.windowOwners = [12: 8200]
        _ = compute(svc, snapshot: [], runningPIDs: [8200])

        let changes = compute(svc, snapshot: [makeWindow(id: 12, pid: 8200)], runningPIDs: [8200])

        XCTAssertEqual(changes.returned.map(\.windowID), [12])
        XCTAssertTrue(changes.returnedFromUserHide.isEmpty)
    }

    func testAClosedWindowIsNeverHeld() {
        let access = StubAccessibility()
        access.stateAnswer = .absent
        let (svc, cache, _) = makeService(accessibility: access)
        cache.knownWindowIDs = [10, 12]
        cache.windowOwners = [10: 8200, 12: 8200]

        let changes = compute(svc, snapshot: [makeWindow(id: 10, pid: 8200)], runningPIDs: [8200])

        XCTAssertEqual(changes.goneIDs, [12])
        XCTAssertTrue(svc.heldWindowIDs.isEmpty)
    }

    func testUnreadableHiddenWindowStopsBeingReQueriedAfterTheBudgetButStaysReserved() {
        let access = StubAccessibility()
        access.stateAnswer = nil
        let (svc, cache, _) = makeService(accessibility: access)
        cache.knownWindowIDs = [13]
        cache.windowOwners[13] = 8300

        _ = compute(svc, snapshot: [], runningPIDs: [8300])
        for _ in 0..<10 { _ = compute(svc, snapshot: [], runningPIDs: [8300]) }

        // one query when it vanished plus a bounded number of re-checks
        XCTAssertEqual(access.queries.filter { $0 == 13 }.count, 1 + 5)
        XCTAssertTrue(cache.hiddenWindowIDs.contains(13))
        XCTAssertTrue(cache.reservedHiddenWindowIDs.contains(13))
    }

    /// while the walk backs off from an app, a re-check of its hidden
    /// window would time out too; it is skipped and spends none of the few
    /// asks the re-check gets
    func testAReCheckOfABackedOffAppSpendsNoAsk() {
        let access = StubAccessibility()
        access.stateAnswer = nil
        let (svc, cache, _) = makeService(accessibility: access)
        cache.knownWindowIDs = [14]
        cache.windowOwners[14] = 8400

        _ = compute(svc, snapshot: [], runningPIDs: [8400])
        access.backingOff = [8400]
        for _ in 0..<10 { _ = compute(svc, snapshot: [], runningPIDs: [8400]) }
        XCTAssertEqual(access.queries.filter { $0 == 14 }.count, 1, "the one ask when it vanished")

        access.backingOff = []
        for _ in 0..<10 { _ = compute(svc, snapshot: [], runningPIDs: [8400]) }
        XCTAssertEqual(access.queries.filter { $0 == 14 }.count, 1 + 5, "the budget was untouched meanwhile")
    }

    func testUnreadableHiddenWindowReservesUntilAReVerifyProvesItClosed() {
        let access = StubAccessibility()
        access.stateAnswer = nil
        let (svc, cache, _) = makeService(accessibility: access)
        cache.knownWindowIDs = [12]
        cache.windowOwners[12] = 8200

        _ = compute(svc, snapshot: [], runningPIDs: [8200])
        XCTAssertTrue(cache.hiddenWindowIDs.contains(12))
        XCTAssertTrue(cache.reservedHiddenWindowIDs.contains(12))

        // AX reads fine on the next cycle and says the window is gone
        access.stateAnswer = .absent
        _ = compute(svc, snapshot: [], runningPIDs: [8200])

        XCTAssertTrue(cache.hiddenWindowIDs.contains(12))
        XCTAssertFalse(cache.reservedHiddenWindowIDs.contains(12))
    }

    func testReturningUnverifiedWindowIsNotReVerifiedAsClosed() {
        // a flapping window comes back in the same cycle the re-verify runs.
        // asking AX then answers "not minimized" for a window that is plainly
        // on screen, which would strip the reservation and misfile the return
        // as a recycled-id reopen.
        let access = StubAccessibility()
        access.stateAnswer = nil
        let (svc, cache, _) = makeService(accessibility: access)
        cache.knownWindowIDs = [14]
        cache.windowOwners[14] = 8400

        _ = compute(svc, snapshot: [], runningPIDs: [8400])
        XCTAssertTrue(cache.reservedHiddenWindowIDs.contains(14))

        access.queries.removeAll()
        access.stateAnswer = .absent
        let w = makeWindow(id: 14, pid: 8400)
        let back = compute(svc, snapshot: [w], runningPIDs: [8400])

        XCTAssertEqual(back.returned.map { $0.windowID }, [14])
        XCTAssertFalse(access.queries.contains(14),
                       "a window present in the snapshot must be left to the returned pass")
    }

    func testReturnedWindowDropsItsReservation() {
        let access = StubAccessibility()
        access.stateAnswer = .minimized
        let (svc, cache, _) = makeService(accessibility: access)
        cache.knownWindowIDs = [13]
        cache.windowOwners[13] = 8300

        _ = compute(svc, snapshot: [], runningPIDs: [8300])
        XCTAssertTrue(cache.reservedHiddenWindowIDs.contains(13))

        let w = makeWindow(id: 13, pid: 8300)
        let back = compute(svc, snapshot: [w], runningPIDs: [8300])

        XCTAssertEqual(back.returned.map { $0.windowID }, [13])
        XCTAssertFalse(cache.hiddenWindowIDs.contains(13))
        XCTAssertFalse(cache.reservedHiddenWindowIDs.contains(13))
    }

    // the reopen drift is the one a pin may redirect: a verified close back
    // on screen while its recorded workspace is hidden. a minimize keeps its
    // workspace, and a reopen on its own visible workspace does not drift
    func testOnlyAReopenOntoAHiddenWorkspaceIsMarked() {
        let screen = DiscoveryDriftScreen()
        let display = DisplayManager(screenSource: { [screen] })
        let workspaces = WorkspaceManager(displayManager: display)
        workspaces.initializeMonitors()
        _ = workspaces.switchWorkspace(4, cursorScreen: screen)
        let access = StubAccessibility()
        let cache = WindowStateCache()
        let svc = WindowDiscoveryService(stateCache: cache, accessibility: access,
                                         displayManager: display, workspaceManager: workspaces,
                                         bundleIDForPID: { _ in nil }, isWindowSizeSettable: { _ in true })
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let closedOnHidden = DiscoveryFramedWindow(id: 15, frame: frame)
        let minimized = DiscoveryFramedWindow(id: 16, frame: frame)
        let closedOnVisible = DiscoveryFramedWindow(id: 17, frame: frame)
        cache.knownWindowIDs = [15, 16, 17]
        for id: CGWindowID in [15, 16, 17] { cache.windowOwners[id] = 8500 }
        workspaces.assignWindow(15, toWorkspace: 1)
        workspaces.assignWindow(16, toWorkspace: 1)
        workspaces.assignWindow(17, toWorkspace: 4)

        access.stateAnswer = .absent
        _ = compute(svc, snapshot: [minimized], runningPIDs: [8500])
        access.stateAnswer = .minimized
        _ = compute(svc, snapshot: [], runningPIDs: [8500])

        let back = compute(svc, snapshot: [closedOnHidden, minimized, closedOnVisible], runningPIDs: [8500])

        XCTAssertEqual(Set(back.returned.map(\.windowID)), [15, 16, 17])
        XCTAssertEqual(back.screenDrift.map(\.windowID), [15])
        XCTAssertEqual(back.screenDrift.first?.toWorkspace, 4)
        XCTAssertEqual(back.reopenedOntoHiddenWorkspace, [15])
    }

    // MARK: - gone (dead pid → fully forgotten)

    func testGoneWindowWithDeadPIDIsFullyForgotten() {
        let (svc, cache, _) = makeService()
        cache.knownWindowIDs = [20]
        cache.windowOwners[20] = 9000
        cache.tiledPositions[20] = .zero
        cache.cachedWindows[20] = makeWindow(id: 20, pid: 9000)
        cache.originalFrames[20] = .zero
        cache.floatingWindowIDs = [20]

        // pid 9000 is NOT in runningPIDs
        let changes = compute(svc, snapshot: [], runningPIDs: [])

        XCTAssertTrue(changes.goneIDs.contains(20))
        XCTAssertTrue(changes.fullyForgottenIDs.contains(20))
        XCTAssertFalse(cache.knownWindowIDs.contains(20))
        XCTAssertFalse(cache.hiddenWindowIDs.contains(20))
        XCTAssertNil(cache.windowOwners[20])
        XCTAssertNil(cache.cachedWindows[20])
        XCTAssertNil(cache.tiledPositions[20])
        XCTAssertNil(cache.originalFrames[20])
        XCTAssertFalse(cache.floatingWindowIDs.contains(20))
    }

    // MARK: - what admission recovery reads

    func testAVanishedNewcomerStopsLookingLiveToAdmissionRecovery() {
        let (svc, cache, _) = makeService()
        cache.knownWindowIDs = [26]
        cache.windowOwners[26] = 9100
        cache.cachedWindows[26] = makeWindow(id: 26, pid: 9100)

        // the liveness probe WindowManager hands the recovery: a window is
        // live only while discovery still calls it known and not hidden.
        // this is the discovery half only — the production closure also
        // checks NSRunningApplication, which needs the whole manager graph
        func looksLive(_ id: CGWindowID) -> Bool {
            cache.knownWindowIDs.contains(id) && !cache.hiddenWindowIDs.contains(id)
                && cache.cachedWindows[id] != nil
        }
        XCTAssertTrue(looksLive(26))

        // the window went away while its app kept running
        let changes = compute(svc, snapshot: [], runningPIDs: [9100])

        XCTAssertTrue(changes.goneIDs.contains(26))
        XCTAssertFalse(changes.fullyForgottenIDs.contains(26))
        XCTAssertFalse(looksLive(26),
                       "a vanished newcomer leaves recovery through ordinary cleanup")
    }

    // MARK: - returned (hidden → present)

    func testReturnedWindowComesBackFromHidden() {
        let (svc, cache, _) = makeService()
        cache.hiddenWindowIDs = [33]
        cache.windowOwners[33] = 12000

        let w = makeWindow(id: 33, pid: 12000)
        let changes = compute(svc, snapshot: [w], runningPIDs: [12000])

        XCTAssertEqual(changes.returned.map { $0.windowID }, [33])
        XCTAssertFalse(cache.hiddenWindowIDs.contains(33))
        XCTAssertTrue(cache.knownWindowIDs.contains(33))
        XCTAssertEqual(cache.windowOwners[33], 12000)
        XCTAssertTrue(changes.newWindows.isEmpty)
        XCTAssertTrue(changes.needsRetile)
    }

    // MARK: - sweep stale state

    func testSweepRemovesHiddenWindowOwnedByDeadPID() {
        let (svc, cache, _) = makeService()
        cache.hiddenWindowIDs = [50]
        cache.windowOwners[50] = 13000

        // pid 13000 not running → sweep should fully forget
        let changes = compute(svc, snapshot: [], runningPIDs: [])

        XCTAssertTrue(changes.fullyForgottenIDs.contains(50))
        XCTAssertFalse(cache.hiddenWindowIDs.contains(50))
        XCTAssertNil(cache.windowOwners[50])
    }

    func testSweepForgetsFloatingIDWithoutKnownOrHidden() {
        let (svc, cache, _) = makeService()
        // wid 60 marked floating but never added to known/hidden — leaked state.
        cache.floatingWindowIDs = [60]

        let changes = compute(svc, snapshot: [], runningPIDs: [])

        XCTAssertTrue(changes.fullyForgottenIDs.contains(60))
        XCTAssertFalse(cache.floatingWindowIDs.contains(60))
    }

    func testSweepForgetsOwnerEntryWithoutKnownOrHidden() {
        let (svc, cache, _) = makeService()
        cache.windowOwners[70] = 99

        let changes = compute(svc, snapshot: [], runningPIDs: [99])

        XCTAssertTrue(changes.fullyForgottenIDs.contains(70))
        XCTAssertNil(cache.windowOwners[70])
    }

    func testSweepDoesNotBumpNeedsRetile() {
        let (svc, cache, _) = makeService()
        cache.windowOwners[80] = 99 // leaked owner entry, will be swept

        let changes = compute(svc, snapshot: [], runningPIDs: [99])

        XCTAssertTrue(changes.fullyForgottenIDs.contains(80))
        // sweep-only forget is silent state hygiene; needsRetile gates on
        // new/gone/returned/drift, not on sweep.
        XCTAssertFalse(changes.needsRetile)
    }

    // MARK: - focusedWindowGone

    func testFocusedWindowGoneFlagSetWhenFocusedIDDisappears() {
        let (svc, cache, _) = makeService()
        cache.knownWindowIDs = [100]
        cache.windowOwners[100] = 1000

        let changes = compute(svc, snapshot: [], runningPIDs: [1000], focusedID: 100)

        XCTAssertTrue(changes.focusedWindowGone)
    }

    func testFocusedWindowGoneFlagFalseWhenFocusedIDStays() {
        let (svc, cache, _) = makeService()
        cache.knownWindowIDs = [100]
        cache.windowOwners[100] = 1000

        let w = makeWindow(id: 100, pid: 1000)
        let changes = compute(svc, snapshot: [w], runningPIDs: [1000], focusedID: 100)

        XCTAssertFalse(changes.focusedWindowGone)
    }

    func testFocusedWindowGoneFlagFalseForUnrelatedDisappearance() {
        let (svc, cache, _) = makeService()
        cache.knownWindowIDs = [100, 200]
        cache.windowOwners[100] = 1000
        cache.windowOwners[200] = 1000

        // wid 200 disappears, focused id is 100 (still present)
        let w = makeWindow(id: 100, pid: 1000)
        let changes = compute(svc, snapshot: [w], runningPIDs: [1000], focusedID: 100)

        XCTAssertTrue(changes.goneIDs.contains(200))
        XCTAssertFalse(changes.focusedWindowGone)
    }

    // MARK: - forgetApp

    func testForgetAppReturnsAllWIDsForPID() {
        let (svc, cache, _) = makeService()
        cache.windowOwners = [1: 100, 2: 100, 3: 200, 4: 100]
        cache.knownWindowIDs = [1, 2, 3, 4]

        let forgotten = svc.forgetApp(100)

        XCTAssertEqual(forgotten, [1, 2, 4])
        XCTAssertNil(cache.windowOwners[1])
        XCTAssertNil(cache.windowOwners[2])
        XCTAssertNil(cache.windowOwners[4])
        XCTAssertEqual(cache.windowOwners[3], 200)
        XCTAssertEqual(cache.knownWindowIDs, [3])
    }

    func testForgetAppForUnknownPIDReturnsEmpty() {
        let (svc, _, _) = makeService()
        XCTAssertTrue(svc.forgetApp(99999).isEmpty)
    }

    // MARK: - quick looks for windows not ready yet

    /// a window its app lists before the window server shows it gets no
    /// event when it appears. it used to wait for the ten-second reconcile
    func testANewWindowListedBeforeItIsOnScreenGetsQuickLooks() {
        let access = StubAccessibility()
        let (svc, _, _) = makeService(accessibility: access)
        var clock = Date(timeIntervalSinceReferenceDate: 1000)
        svc.now = { clock }
        XCTAssertNil(svc.secondsUntilARetryIsDue)

        access.unboundWindowIDs = [50]
        _ = compute(svc, snapshot: [])
        XCTAssertEqual(svc.secondsUntilARetryIsDue!, 0.25, accuracy: 0.001)
        XCTAssertEqual(svc.windowsAwaitingALook, [50])

        // a poll before the look is due spends nothing
        clock += 0.1
        _ = compute(svc, snapshot: [])
        XCTAssertEqual(svc.secondsUntilARetryIsDue!, 0.15, accuracy: 0.001)

        // each due poll spends one look, with a longer gap, until they run out
        var gaps: [TimeInterval] = []
        clock += 0.15
        for _ in 0..<4 {
            _ = compute(svc, snapshot: [])
            guard let wait = svc.secondsUntilARetryIsDue else { break }
            gaps.append(wait)
            clock += wait
        }
        XCTAssertEqual(gaps, [0.5, 1, 2])
        XCTAssertNil(svc.secondsUntilARetryIsDue, "left to events and the reconcile")
        XCTAssertTrue(svc.windowsAwaitingALook.isEmpty)
    }

    func testANewWindowThatTurnsUpEndsItsLooks() {
        let access = StubAccessibility()
        let (svc, _, _) = makeService(accessibility: access)
        svc.now = { Date(timeIntervalSinceReferenceDate: 1000) }
        access.unboundWindowIDs = [50]
        _ = compute(svc, snapshot: [])
        XCTAssertNotNil(svc.secondsUntilARetryIsDue)

        access.unboundWindowIDs = []
        let changes = compute(svc, snapshot: [makeWindow(id: 50, pid: 9)])
        XCTAssertEqual(changes.newWindows.map(\.windowID), [50])
        XCTAssertNil(svc.secondsUntilARetryIsDue)
    }

    /// on screen by the window server's account, unreadable to AX: a new
    /// id was not held and got no second look
    func testANewUnreadableWindowGetsQuickLooks() {
        let (svc, cache, _) = makeService()
        svc.now = { Date(timeIntervalSinceReferenceDate: 1000) }
        let changes = compute(svc, snapshot: [], unreadable: [60])
        XCTAssertTrue(changes.newWindows.isEmpty)
        XCTAssertFalse(cache.knownWindowIDs.contains(60))
        XCTAssertEqual(svc.secondsUntilARetryIsDue!, 0.25, accuracy: 0.001)
    }

    /// a known window its app lists off screen has the listed hold and its
    /// own wake-up; it takes no quick looks
    func testAKnownListedWindowTakesNoQuickLooks() {
        let access = StubAccessibility()
        access.stateAnswer = .present
        let (svc, cache, _) = makeService(accessibility: access)
        svc.now = { Date(timeIntervalSinceReferenceDate: 1000) }
        cache.knownWindowIDs = [10, 12]
        cache.windowOwners = [10: 8200, 12: 8200]
        access.unboundWindowIDs = [12]
        _ = compute(svc, snapshot: [makeWindow(id: 10, pid: 8200)], runningPIDs: [8200])
        XCTAssertNil(svc.secondsUntilARetryIsDue)
        XCTAssertNotNil(svc.secondsUntilAHoldEnds)
    }

    /// a held window of a stalled app is read when the app is asked again.
    /// the poll for that comes when its backoff ends, after the quick looks
    /// have run out too
    func testAHeldWindowOfAStalledAppWakesWhenTheBackoffEnds() {
        let access = StubAccessibility()
        let (svc, cache, _) = makeService(accessibility: access)
        var clock = Date(timeIntervalSinceReferenceDate: 1000)
        svc.now = { clock }
        cache.knownWindowIDs = [10]
        cache.windowOwners = [10: 8200]
        access.backoffWake = 6
        for _ in 0..<6 {
            _ = compute(svc, snapshot: [], runningPIDs: [8200], unreadable: [10])
            clock += 2
        }
        XCTAssertEqual(svc.heldWindowIDs, [10])
        XCTAssertEqual(svc.secondsUntilARetryIsDue, 6)
        access.backoffWake = nil
        XCTAssertNil(svc.secondsUntilARetryIsDue)
    }

    /// a look still due after a cycle means the cycle was guarded and
    /// checked nothing; the wake must not undercut the guard's half second
    func testAnOverdueLookDoesNotAskForATightPoll() {
        let access = StubAccessibility()
        let (svc, _, _) = makeService(accessibility: access)
        var clock = Date(timeIntervalSinceReferenceDate: 1000)
        svc.now = { clock }
        access.unboundWindowIDs = [50]
        _ = compute(svc, snapshot: [])
        clock += 5
        XCTAssertEqual(svc.secondsUntilARetryIsDue, WindowDiscoveryService.overdueRetry)
    }

    // MARK: - fixed-size auto-float re-check

    private func fixedSizeFixture(settable: @escaping () -> Bool?)
        -> (WindowDiscoveryService, WindowStateCache, WorkspaceManager, HyprWindow, () -> Void) {
        let (svc, cache, workspaces) = makeService(isWindowSizeSettable: { _ in settable() })
        var clock = Date(timeIntervalSinceReferenceDate: 1000)
        svc.now = { clock }
        let w = makeWindow(id: 2, pid: 100)
        _ = compute(svc, snapshot: [w], runningPIDs: [100])
        workspaces.assignWindow(2, toWorkspace: 1)
        return (svc, cache, workspaces, w, { clock += svc.secondsUntilARetryIsDue ?? 100 })
    }

    /// floated once at first sight, never asked again: a window its app made
    /// resizable a moment later stayed floating
    func testAWindowThatBecomesResizableGoesBackToTiling() {
        var settable: Bool? = false
        let (svc, cache, _, w, advance) = fixedSizeFixture { settable }
        XCTAssertTrue(cache.floatingWindowIDs.contains(2))
        XCTAssertEqual(svc.secondsUntilARetryIsDue!, 0.5, accuracy: 0.001)

        settable = true
        advance()
        let changes = compute(svc, snapshot: [w], runningPIDs: [100])
        XCTAssertEqual(changes.unfloated, [2])
        XCTAssertTrue(changes.needsRetile)
        XCTAssertFalse(cache.floatingWindowIDs.contains(2))
        XCTAssertFalse(w.isFloating)
        XCTAssertNil(svc.secondsUntilARetryIsDue)
    }

    func testAWindowThatStaysFixedStaysFloatingAfterThreeChecks() {
        var checks = 0
        let (svc, cache, _, w, advance) = fixedSizeFixture { checks += 1; return false }
        for _ in 0..<5 {
            advance()
            XCTAssertTrue(compute(svc, snapshot: [w], runningPIDs: [100]).unfloated.isEmpty)
        }
        XCTAssertEqual(checks, 1 + WindowDiscoveryService.fixedSizeRecheckDelays.count)
        XCTAssertTrue(cache.floatingWindowIDs.contains(2))
        XCTAssertNil(svc.secondsUntilARetryIsDue)
    }

    /// the user tiled it before the check: the check leaves it alone
    func testAWindowTheUserTiledIsNotRechecked() {
        var settable: Bool? = false
        let (svc, cache, _, w, advance) = fixedSizeFixture { settable }
        cache.setFloating(false, window: w)
        settable = true
        advance()
        XCTAssertTrue(compute(svc, snapshot: [w], runningPIDs: [100]).unfloated.isEmpty)
        XCTAssertNil(svc.secondsUntilARetryIsDue)
    }

    /// a scratchpad member floats for the scratchpad, whatever its size says
    func testAScratchpadMemberIsNotHandedToTiling() {
        var settable: Bool? = false
        let (svc, cache, workspaces, w, advance) = fixedSizeFixture { settable }
        workspaces.moveWindow(2, toWorkspace: ScratchpadController.workspace)
        settable = true
        advance()
        XCTAssertTrue(compute(svc, snapshot: [w], runningPIDs: [100]).unfloated.isEmpty)
        XCTAssertTrue(cache.floatingWindowIDs.contains(2))
    }

    /// an unreadable cycle keeps the check's turn
    func testAHeldWindowKeepsItsRecheck() {
        var settable: Bool? = false
        let (svc, cache, _, w, advance) = fixedSizeFixture { settable }
        settable = true
        advance()
        _ = compute(svc, snapshot: [], runningPIDs: [100], unreadable: [2])
        XCTAssertTrue(cache.floatingWindowIDs.contains(2))
        // no tight loop of polls while it is held
        XCTAssertGreaterThanOrEqual(svc.secondsUntilARetryIsDue!, 0.25)
        var unfloated: Set<CGWindowID> = []
        for _ in 0..<3 where unfloated.isEmpty {
            advance()
            unfloated = compute(svc, snapshot: [w], runningPIDs: [100]).unfloated
        }
        XCTAssertEqual(unfloated, [2])
    }

    // MARK: - needsRetile derivation

    func testNeedsRetileOnlyTrueForLifecycleChanges() {
        let (svc, _, _) = makeService()

        // empty: no retile needed
        XCTAssertFalse(compute(svc, snapshot: []).needsRetile)

        // new window: retile
        XCTAssertTrue(compute(svc, snapshot: [makeWindow(id: 1, pid: 1)]).needsRetile)
    }
}

/// the walk's backoff for apps whose window list does not answer
final class StallBackoffTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    func testAnUnknownAppIsAskedAndAFailureStartsTheBackoff() {
        var backoff = StallBackoff()
        XCTAssertFalse(backoff.isBackingOff(7, now: t0))
        XCTAssertFalse(backoff.isDue(7, now: t0))

        XCTAssertEqual(backoff.noteFailure(7, now: t0), 0.5)

        XCTAssertTrue(backoff.isBackingOff(7, now: t0.addingTimeInterval(0.4)))
        XCTAssertFalse(backoff.isDue(7, now: t0.addingTimeInterval(0.4)))
        XCTAssertTrue(backoff.isDue(7, now: t0.addingTimeInterval(0.5)), "one probe is due once it is up")
        XCTAssertFalse(backoff.isBackingOff(7, now: t0.addingTimeInterval(0.5)))
    }

    func testRepeatedFailuresDoubleUpToTheCap() {
        var backoff = StallBackoff()
        var now = t0
        var waits: [TimeInterval] = []
        for _ in 0..<6 {
            let wait = backoff.noteFailure(7, now: now)
            waits.append(wait)
            now = now.addingTimeInterval(wait)
        }
        XCTAssertEqual(waits, [0.5, 1, 2, 4, 8, 8])
    }

    func testAnAnswerEndsTheBackoffAndTheNextFailureStartsSmall() {
        var backoff = StallBackoff()
        _ = backoff.noteFailure(7, now: t0)
        _ = backoff.noteFailure(7, now: t0.addingTimeInterval(1))
        backoff.noteSuccess(7)
        XCTAssertFalse(backoff.isBackingOff(7, now: t0.addingTimeInterval(1)))
        XCTAssertTrue(backoff.stalledPIDs.isEmpty)
        XCTAssertEqual(backoff.noteFailure(7, now: t0.addingTimeInterval(2)), 0.5)
    }

    /// only a timeout backs off. an app that answers with any other error,
    /// one still launching, is asked again on the next walk
    func testOnlyATimeoutStartsTheBackoff() {
        var backoff = StallBackoff()
        for error in [AXError.failure, .apiDisabled, .notImplemented, .attributeUnsupported, .invalidUIElement] {
            XCTAssertNil(backoff.noteListReadFailure(7, error: error, now: t0), "\(error.rawValue)")
            XCTAssertFalse(backoff.isBackingOff(7, now: t0))
            XCTAssertFalse(backoff.isDue(7, now: t0))
        }
        XCTAssertTrue(backoff.stalledPIDs.isEmpty)

        XCTAssertEqual(backoff.noteListReadFailure(7, error: .cannotComplete, now: t0), 0.5)
        XCTAssertTrue(backoff.isBackingOff(7, now: t0.addingTimeInterval(0.4)))
    }

    func testAnAppThatQuitIsForgotten() {
        var backoff = StallBackoff()
        _ = backoff.noteFailure(7, now: t0)
        _ = backoff.noteFailure(8, now: t0)
        backoff.retain([8])
        XCTAssertEqual(backoff.stalledPIDs, [8])
    }
}

extension StallBackoffTests {
    /// codex 4: one due app is probed per walk, and it was the first in
    /// enumeration order. with walks ten seconds apart and an eight-second
    /// cap, an earlier app that always stalls was due on every walk and a
    /// later one that had recovered was never asked again
    func testARecoveredAppIsNotStarvedByOneThatAlwaysStalls() {
        var backoff = StallBackoff()
        var now = t0
        backoff.noteFailure(1, now: now)
        backoff.noteFailure(2, now: now)
        var asked: [pid_t] = []
        for _ in 0..<4 {
            now = now.addingTimeInterval(10)
            guard let probe = backoff.probeTarget(among: [1, 2], now: now) else { continue }
            backoff.noteProbe(probe, now: now)
            asked.append(probe)
            if probe == 1 {
                backoff.noteFailure(1, now: now)
            } else {
                backoff.noteSuccess(2)
            }
        }
        XCTAssertTrue(asked.contains(2), "asked: \(asked)")
        XCTAssertFalse(backoff.stalledPIDs.contains(2))
    }

    func testTheProbeGoesToTheAppAskedLongestAgo() {
        var backoff = StallBackoff()
        backoff.noteFailure(1, now: t0)
        backoff.noteFailure(2, now: t0)
        backoff.noteFailure(3, now: t0)
        let later = t0.addingTimeInterval(1)
        backoff.noteProbe(1, now: t0)
        backoff.noteProbe(2, now: t0.addingTimeInterval(0.5))
        XCTAssertEqual(backoff.probeTarget(among: [1, 2, 3], now: later), 3, "never asked goes first")
        backoff.noteProbe(3, now: later)
        XCTAssertEqual(backoff.probeTarget(among: [1, 2, 3], now: later), 1)
        XCTAssertNil(backoff.probeTarget(among: [4], now: later))
    }

    /// a reveal retry's read answered: the walk that retiles the held tile
    /// right after asks the app instead of skipping it as stalled
    func testAnAppThatAnsweredOutsideTheWalkIsNoLongerStalled() {
        let ax = AccessibilityManager()
        ax.now = { [t0] in t0 }
        ax.stallBackoff.noteFailure(7, now: t0)
        XCTAssertTrue(ax.isBackingOff(pid: 7))

        ax.noteWindowListAnswered(7)

        XCTAssertFalse(ax.isBackingOff(pid: 7))
        XCTAssertFalse(ax.stallBackoff.isDue(7, now: t0.addingTimeInterval(1)), "no probe pending either")
        XCTAssertTrue(ax.stallBackoff.stalledPIDs.isEmpty)
    }

    /// fable A: nothing polled when a backoff ended, so an app that
    /// stalled once waited for the next unrelated event or the reconcile
    func testTheWakeUpIsWhenTheNextBackoffEnds() {
        var backoff = StallBackoff()
        XCTAssertNil(backoff.secondsUntilNextProbe(now: t0))
        backoff.noteFailure(7, now: t0)
        XCTAssertEqual(backoff.secondsUntilNextProbe(now: t0)!, 0.5, accuracy: 0.001)
        XCTAssertEqual(backoff.secondsUntilNextProbe(now: t0.addingTimeInterval(0.3))!, 0.2, accuracy: 0.001)
        // due but not asked: another walk soon, not at once
        XCTAssertEqual(backoff.secondsUntilNextProbe(now: t0.addingTimeInterval(0.6))!, StallBackoff.dueRetry,
                       accuracy: 0.001)
        backoff.noteSuccess(7)
        XCTAssertNil(backoff.secondsUntilNextProbe(now: t0.addingTimeInterval(0.6)))
    }
}

/// the discovery walk's whole-walk time budget
final class WalkPacingTests: XCTestCase {
    func testPastTheBudgetOnlyAppsKnownToBeFastAreAsked() {
        var pacing = WalkPacing()
        pacing.noteCost(1, 0.02)
        pacing.noteCost(2, 0.3)
        XCTAssertFalse(pacing.shouldSkip(2, elapsed: 0.2), "within the budget every app is asked")
        XCTAssertFalse(pacing.shouldSkip(1, elapsed: 0.6))
        XCTAssertTrue(pacing.shouldSkip(2, elapsed: 0.6))
        XCTAssertTrue(pacing.shouldSkip(3, elapsed: 0.6), "an app not read yet might be slow")
    }

    /// codex 10: ten apps timing out for the first time cost a walk two
    /// and a half seconds on the main thread
    func testFirstTimeStallsCannotStretchAWalk() {
        var pacing = WalkPacing()
        let pids: [pid_t] = Array(1...10)
        var elapsed: TimeInterval = 0
        var asked: [pid_t] = []
        for pid in pacing.order(pids) where !pacing.shouldSkip(pid, elapsed: elapsed) {
            elapsed += 0.25
            pacing.noteCost(pid, 0.25)
            asked.append(pid)
        }
        let skipped = pids.filter { !asked.contains($0) }
        pacing.finishWalk(skipped: skipped, running: Set(pids))
        XCTAssertLessThanOrEqual(elapsed, WalkPacing.budget + 0.25)
        XCTAssertEqual(asked, [1, 2])
        XCTAssertEqual(pacing.secondsUntilRetry, WalkPacing.skippedRetry)
        // the skipped apps are asked first next walk, so none waits forever
        XCTAssertEqual(Array(pacing.order(pids).prefix(2)), [3, 4])
    }

    func testAWalkWithinBudgetSchedulesNothing() {
        var pacing = WalkPacing()
        pacing.finishWalk(skipped: [3], running: [1, 3])
        pacing.finishWalk(skipped: [], running: [1, 3])
        XCTAssertNil(pacing.secondsUntilRetry)
        XCTAssertEqual(pacing.order([1, 3]), [1, 3])
    }

    func testAnAppThatQuitIsForgotten() {
        var pacing = WalkPacing()
        pacing.noteCost(1, 0.02)
        pacing.noteCost(2, 0.02)
        pacing.finishWalk(skipped: [], running: [2])
        XCTAssertEqual(Set(pacing.cost.keys), [2])
    }
}

/// how one app's AX windows pair with its CG windows
final class AXWindowMatcherTests: XCTestCase {
    private func element(_ frame: CGRect, spi: CGWindowID?) -> AXWindowMatcher.Element {
        .init(frame: frame, spiID: spi)
    }
    private func candidate(_ id: CGWindowID, _ bounds: CGRect) -> AXWindowMatcher.Candidate {
        .init(windowID: id, bounds: bounds)
    }
    private let left = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let right = CGRect(x: 800, y: 0, width: 800, height: 600)

    func testAnOnScreenSPIIDBinds() {
        let result = AXWindowMatcher.match([element(left, spi: 100)], candidates: [candidate(100, left)],
                                           used: [], isRealWindow: { _ in true })
        XCTAssertEqual(result.bound, [.init(index: 0, windowID: 100, fallbackDistance: nil)])
        XCTAssertTrue(result.unbound.isEmpty)
    }

    /// codex 2 / B6: window A is off screen and named correctly by the SPI;
    /// B is on screen but not in this AX list yet. A's element took B's id,
    /// so B's frame writes went to A
    func testAnOffScreenSPIIDIsNeverReboundToAnotherWindow() {
        let result = AXWindowMatcher.match([element(left, spi: 100)], candidates: [candidate(200, left)],
                                           used: [], isRealWindow: { $0 == 100 })
        XCTAssertTrue(result.bound.isEmpty)
        XCTAssertEqual(result.unbound.map(\.reason), [.offScreen(100)])
    }

    func testATakenSPIIDStaysUnbound() {
        let result = AXWindowMatcher.match([element(left, spi: 100), element(right, spi: 100)],
                                           candidates: [candidate(100, left), candidate(200, right)],
                                           used: [], isRealWindow: { _ in true })
        XCTAssertEqual(result.bound.map(\.windowID), [100])
        XCTAssertEqual(result.unbound.map(\.reason), [.taken(100)])
    }

    func testAFailedSPIFallsBackToANearWindow() {
        let near = left.offsetBy(dx: 3, dy: 1)
        let result = AXWindowMatcher.match([element(near, spi: nil)], candidates: [candidate(100, left)],
                                           used: [], isRealWindow: { _ in true })
        XCTAssertEqual(result.bound, [.init(index: 0, windowID: 100, fallbackDistance: 4)])
    }

    func testAnSPIIDTheWindowServerDoesNotKnowFallsBack() {
        let result = AXWindowMatcher.match([element(left, spi: 999)], candidates: [candidate(100, left)],
                                           used: [], isRealWindow: { _ in false })
        XCTAssertEqual(result.bound.map(\.windowID), [100])
    }

    /// the fallback had no distance limit: any unused id would do
    func testTheFallbackRefusesAFarWindow() {
        let result = AXWindowMatcher.match([element(left, spi: nil)], candidates: [candidate(200, right)],
                                           used: [], isRealWindow: { _ in true })
        XCTAssertTrue(result.bound.isEmpty)
        XCTAssertEqual(result.unbound.map(\.reason), [.tooFar(nearest: 200, distance: 800)])
    }

    func testTheFallbackNeverHandsOutAUsedID() {
        let result = AXWindowMatcher.match([element(left, spi: nil)], candidates: [candidate(100, left)],
                                           used: [100], isRealWindow: { _ in true })
        XCTAssertEqual(result.unbound.map(\.reason), [.noCandidate])
    }

    /// closest pairs first, so the order the app lists windows in can't
    /// hand the nearer element's window to the farther one
    func testTheFallbackPairsTheClosestFirst() {
        let a = left.offsetBy(dx: 30, dy: 0)
        let b = left.offsetBy(dx: 2, dy: 0)
        let c2 = left.offsetBy(dx: 60, dy: 0)
        let result = AXWindowMatcher.match([element(a, spi: nil), element(b, spi: nil)],
                                           candidates: [candidate(1, left), candidate(2, c2)],
                                           used: [], isRealWindow: { _ in true })
        XCTAssertEqual(result.bound, [.init(index: 0, windowID: 2, fallbackDistance: 30),
                                      .init(index: 1, windowID: 1, fallbackDistance: 2)])
    }
}

private final class DiscoveryDriftScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 1600, height: 1000) }
    override var visibleFrame: NSRect { frame }
}

private final class DiscoveryFramedWindow: HyprWindow {
    let storedFrame: CGRect
    init(id: CGWindowID, frame: CGRect) {
        storedFrame = frame
        super.init(element: AXUIElementCreateApplication(8500), windowID: id, ownerPID: 8500)
    }
    override func readPosition() -> (AXError, CGPoint?) { (.success, storedFrame.origin) }
    override func readSize() -> (AXError, CGSize?) { (.success, storedFrame.size) }
}
