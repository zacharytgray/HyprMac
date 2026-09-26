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
        focusedID: CGWindowID = 0
    ) -> WindowChanges {
        svc.computeChanges(
            snapshot: snapshot,
            runningPIDs: runningPIDs,
            excludedBundleIDs: excluded,
            focusedWindowID: focusedID
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
        // not minimized, and it comes back on its own — not a close.
        let access = StubAccessibility()
        access.stateAnswer = .present
        let (svc, cache, _) = makeService(accessibility: access)
        cache.knownWindowIDs = [12]
        cache.windowOwners[12] = 8200

        _ = compute(svc, snapshot: [], runningPIDs: [8200])

        XCTAssertTrue(cache.hiddenWindowIDs.contains(12))
        XCTAssertTrue(cache.reservedHiddenWindowIDs.contains(12))
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

    // MARK: - needsRetile derivation

    func testNeedsRetileOnlyTrueForLifecycleChanges() {
        let (svc, _, _) = makeService()

        // empty: no retile needed
        XCTAssertFalse(compute(svc, snapshot: []).needsRetile)

        // new window: retile
        XCTAssertTrue(compute(svc, snapshot: [makeWindow(id: 1, pid: 1)]).needsRetile)
    }
}
