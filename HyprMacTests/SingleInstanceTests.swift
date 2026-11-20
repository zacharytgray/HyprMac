import XCTest
@testable import HyprMac

// flock belongs to the open file, not the process, so two opens in one
// process shut each other out the same way two copies of the app do.
final class SingleInstanceTests: XCTestCase {
    private var directory: URL!
    private var held: [SingleInstance.Claim] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SingleInstanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        held.forEach(SingleInstance.release)
        held = []
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var lockURL: URL {
        SingleInstance.lockURL(bundleID: "com.zachgray.HyprMac", directory: directory)
    }

    @discardableResult
    private func keep(_ claim: SingleInstance.Claim) -> SingleInstance.Claim {
        held.append(claim)
        return claim
    }

    private func isHeld(_ claim: SingleInstance.Claim) -> Bool {
        if case .held = claim { return true }
        return false
    }

    // MARK: the lock

    func testFirstCopyHoldsTheLockAndSecondIsTurnedAway() {
        XCTAssertTrue(isHeld(keep(SingleInstance.tryClaim(at: lockURL))))
        XCTAssertEqual(SingleInstance.tryClaim(at: lockURL), .taken)
    }

    func testLockIsFreeAgainOnceTheHolderIsGone() {
        let first = SingleInstance.tryClaim(at: lockURL)
        XCTAssertTrue(isHeld(first))
        SingleInstance.release(first)
        XCTAssertTrue(isHeld(keep(SingleInstance.tryClaim(at: lockURL))))
    }

    func testDebugAndReleaseDoNotShutEachOtherOut() {
        let release = SingleInstance.lockURL(bundleID: "com.zachgray.HyprMac", directory: directory)
        let debug = SingleInstance.lockURL(bundleID: "com.zachgray.HyprMac.debug", directory: directory)
        XCTAssertNotEqual(release, debug)
        XCTAssertTrue(isHeld(keep(SingleInstance.tryClaim(at: release))))
        XCTAssertTrue(isHeld(keep(SingleInstance.tryClaim(at: debug))))
    }

    func testTwoCopiesStartingTogetherLeaveExactlyOne() {
        let url = lockURL
        let lock = NSLock()
        var claims: [SingleInstance.Claim] = []
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            let claim = SingleInstance.tryClaim(at: url)
            lock.lock()
            claims.append(claim)
            lock.unlock()
        }
        held.append(contentsOf: claims)
        XCTAssertEqual(claims.filter(isHeld).count, 1)
        XCTAssertEqual(claims.filter { $0 == .taken }.count, 15)
    }

    func testCommandsHyprMacStartsDoNotInheritTheLock() throws {
        guard case let .held(descriptor) = keep(SingleInstance.tryClaim(at: lockURL)) else {
            return XCTFail("expected the lock")
        }
        XCTAssertNotEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0)
    }

    func testUnusableLockFileLetsTheAppRun() throws {
        // a regular file where the folder should be: the lock can't be created
        let blocker = directory.appendingPathComponent("not-a-folder")
        try Data().write(to: blocker)
        let url = SingleInstance.lockURL(bundleID: "com.zachgray.HyprMac", directory: blocker)
        XCTAssertEqual(SingleInstance.claim(at: url, pause: { _ in XCTFail("must not wait") }), .unavailable)
    }

    // MARK: waiting for a copy that is quitting

    func testNewCopyTakesOverWhenTheOldOneFinishesQuitting() {
        let old = SingleInstance.tryClaim(at: lockURL)
        var now: TimeInterval = 100
        var pauses = 0
        let new = SingleInstance.claim(at: lockURL, grace: 3, interval: 0.1, clock: { now }) {
            now += $0
            pauses += 1
            if pauses == 4 { SingleInstance.release(old) }
        }
        XCTAssertTrue(isHeld(keep(new)))
        XCTAssertEqual(pauses, 4)
    }

    func testNewCopyGivesUpWhenTheOldOneStays() {
        keep(SingleInstance.tryClaim(at: lockURL))
        var now: TimeInterval = 100
        let new = SingleInstance.claim(at: lockURL, grace: 3, interval: 0.5, clock: { now }) { now += $0 }
        XCTAssertEqual(new, .taken)
        XCTAssertEqual(now, 103, accuracy: 0.001)
    }

    // a pause that runs long must not stretch the wait past the grace
    func testSlowPausesDoNotStretchTheWait() {
        keep(SingleInstance.tryClaim(at: lockURL))
        var now: TimeInterval = 100
        var pauses = 0
        let new = SingleInstance.claim(at: lockURL, grace: 3, interval: 0.1, clock: { now }) {
            now += $0 * 2
            pauses += 1
        }
        XCTAssertEqual(new, .taken)
        XCTAssertEqual(pauses, 15)
        XCTAssertEqual(now, 103, accuracy: 0.2)
    }

    func testLastPauseStopsAtTheDeadline() {
        keep(SingleInstance.tryClaim(at: lockURL))
        var now: TimeInterval = 100
        var asked: [TimeInterval] = []
        _ = SingleInstance.claim(at: lockURL, grace: 0.25, interval: 0.1, clock: { now }) {
            asked.append($0)
            now += $0
        }
        XCTAssertEqual(asked.count, 3)
        XCTAssertEqual(asked.last ?? 0, 0.05, accuracy: 0.001)
    }

    func testNoGraceMeansOneTry() {
        keep(SingleInstance.tryClaim(at: lockURL))
        let new = SingleInstance.claim(at: lockURL, grace: 0, interval: 0.1) { _ in XCTFail("must not wait") }
        XCTAssertEqual(new, .taken)
    }

    func testFreeLockIsTakenWithoutWaiting() {
        let claim = SingleInstance.claim(at: lockURL) { _ in XCTFail("must not wait") }
        XCTAssertTrue(isHeld(keep(claim)))
    }

    // MARK: launches the guard leaves alone

    func testOrdinaryLaunchIsGuarded() {
        XCTAssertTrue(SingleInstance.guards(arguments: ["/Applications/HyprMac.app/Contents/MacOS/HyprMac"],
                                            environment: ["PATH": "/usr/bin"],
                                            debugApp: false, debugBuild: false))
        // defaults overrides and unknown flags are still an ordinary launch
        XCTAssertTrue(SingleInstance.guards(arguments: ["HyprMac", "-iCloudSyncEnabled", "<false/>", "--glass-fallback"],
                                            environment: [:], debugApp: true, debugBuild: true))
    }

    func testXCTestHostIsNotGuarded() {
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"] {
            XCTAssertFalse(SingleInstance.guards(arguments: ["HyprMac"], environment: [key: "x"],
                                                 debugApp: false, debugBuild: false), key)
        }
    }

    func testDebugDiagnosticFlagsAreNotGuarded() {
        for flag in ["--request-accessibility", "--check-accessibility", "--check-input-monitoring"] {
            XCTAssertFalse(SingleInstance.guards(arguments: ["HyprMac Debug", flag], environment: [:],
                                                 debugApp: true, debugBuild: true), flag)
        }
        for flag in ["--preview-overlays", "--probe-frame"] {
            XCTAssertFalse(SingleInstance.guards(arguments: ["HyprMac", flag, "12"], environment: [:],
                                                 debugApp: false, debugBuild: true), flag)
        }
    }

    // a release build ignores these flags and starts the window manager,
    // so there they are an ordinary launch
    func testReleaseBuildGuardsEvenWithDiagnosticFlags() {
        for flag in ["--request-accessibility", "--check-accessibility", "--check-input-monitoring",
                     "--preview-overlays", "--probe-frame"] {
            XCTAssertTrue(SingleInstance.guards(arguments: ["HyprMac", flag], environment: [:],
                                                debugApp: false, debugBuild: false), flag)
        }
        // the accessibility flags exist only in the Debug app
        XCTAssertTrue(SingleInstance.guards(arguments: ["HyprMac", "--check-accessibility"], environment: [:],
                                            debugApp: false, debugBuild: true))
    }

    func testDiagnosticFlagListMatchesTheCodeThatAnswersThem() {
        XCTAssertEqual(ProbeFrameArguments.flag, "--probe-frame")
    }
}
