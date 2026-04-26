import XCTest
@testable import HyprMac

// WindowDiscoveryServiceTests pin the diff semantics that pollWindowChanges
// used to compute inline. tests inject snapshots + runningPID sets directly
// via computeChanges, so the service is exercised without AX or NSWorkspace.
//
// drift detection and auto-float-on-disabled-monitor depend on NSScreen-keyed
// state and aren't exercisable at this level — those land in the manual smoke
// checklist.

final class WindowDiscoveryServiceTests: XCTestCase {

    // MARK: - fixtures

    private func makeService(
        cache: WindowStateCache = WindowStateCache(),
        bundleIDForPID: @escaping (pid_t) -> String? = { _ in nil }
    ) -> (WindowDiscoveryService, WindowStateCache, WorkspaceManager) {
        let display = DisplayManager()
        let workspaces = WorkspaceManager(displayManager: display)
        let access = AccessibilityManager()
        let svc = WindowDiscoveryService(
            stateCache: cache,
            accessibility: access,
            displayManager: display,
            workspaceManager: workspaces,
            bundleIDForPID: bundleIDForPID
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
            focusedWindowID: focusedID,
            animationInProgress: false
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

    // MARK: - gone (alive pid → hidden)

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
