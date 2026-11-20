import XCTest
@testable import HyprMac

// when a downloaded update may relaunch HyprMac with nobody watching
final class UpdateIdleInstallTests: XCTestCase {

    private func conditions(idle: TimeInterval = 3600, locked: Bool = false, asleep: Bool = false,
                            fullscreen: Bool = false) -> IdleInstallConditions {
        IdleInstallConditions(idleSeconds: idle, screenLocked: locked, displayAsleep: asleep,
                              fullscreenInFront: fullscreen)
    }

    func testInstallsOnceTheMacHasBeenIdleForTheThreshold() {
        let threshold = IdleInstallPolicy.idleThreshold
        XCTAssertEqual(IdleInstallPolicy.wait(conditions(idle: threshold - 1)), .inUse)
        XCTAssertNil(IdleInstallPolicy.wait(conditions(idle: threshold)))
        XCTAssertNil(IdleInstallPolicy.wait(conditions(idle: threshold + 600)))
    }

    func testTheThresholdIsFiveMinutes() {
        // under macOS's default ten-minute display sleep on power
        XCTAssertEqual(IdleInstallPolicy.idleThreshold, 300)
    }

    func testAFullscreenAppInFrontHoldsTheInstall() {
        XCTAssertEqual(IdleInstallPolicy.wait(conditions(fullscreen: true)), .fullscreen)
    }

    // a keep-awake tool must not hold updates back, so the display-sleep
    // assertion it sets is not part of the decision at all
    func testNoInputIsTheOnlyIdleSignal() {
        XCTAssertEqual(IdleInstallPolicy.Wait.allCases, [.inUse, .locked, .displayAsleep, .fullscreen])
    }

    // AX lists only part of the desk behind a lock or a sleeping display
    func testALockedScreenOrSleepingDisplayHoldsTheInstall() {
        XCTAssertEqual(IdleInstallPolicy.wait(conditions(locked: true)), .locked)
        XCTAssertEqual(IdleInstallPolicy.wait(conditions(asleep: true)), .displayAsleep)
        XCTAssertEqual(IdleInstallPolicy.wait(conditions(locked: true, asleep: true)), .locked)
    }

    func testEveryGuardMustClearBeforeAnInstall() {
        XCTAssertNotNil(IdleInstallPolicy.wait(conditions(idle: 0, fullscreen: true)))
        XCTAssertNotNil(IdleInstallPolicy.wait(conditions(idle: 3600, locked: true, fullscreen: true)))
        XCTAssertEqual(IdleInstallPolicy.wait(conditions(idle: 0, fullscreen: true)), .fullscreen)
        XCTAssertNil(IdleInstallPolicy.wait(conditions(idle: 3600)))
    }

    func testAShorterThresholdCanBePassedForATest() {
        XCTAssertNil(IdleInstallPolicy.wait(conditions(idle: 20), threshold: 15))
        XCTAssertEqual(IdleInstallPolicy.wait(conditions(idle: 10), threshold: 15), .inUse)
    }

    func testTheThresholdReadsItsDefaultsOverride() throws {
        let suite = "hyprmac-idle-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(IdleInstallPolicy.threshold(defaults: defaults), IdleInstallPolicy.idleThreshold)
        defaults.set(20, forKey: IdleInstallPolicy.thresholdDefaultsKey)
        XCTAssertEqual(IdleInstallPolicy.threshold(defaults: defaults), 20)
        defaults.set(-5, forKey: IdleInstallPolicy.thresholdDefaultsKey)
        XCTAssertEqual(IdleInstallPolicy.threshold(defaults: defaults), IdleInstallPolicy.idleThreshold)
    }

    func testTheLiveReadAnswersWithoutCrashing() {
        let live = IdleInstallConditions.current(fullscreenInFront: false)
        XCTAssertGreaterThanOrEqual(live.idleSeconds, 0)
        XCTAssertFalse(live.fullscreenInFront)
    }
}
