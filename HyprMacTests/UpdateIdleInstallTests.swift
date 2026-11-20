import XCTest
@testable import HyprMac

// when a downloaded update may relaunch HyprMac with nobody watching
final class UpdateIdleInstallTests: XCTestCase {

    private func conditions(idle: TimeInterval = 3600, locked: Bool = false, asleep: Bool = false,
                            heldAwake: Bool = false, fullscreen: Bool = false) -> IdleInstallConditions {
        IdleInstallConditions(idleSeconds: idle, screenLocked: locked, displayAsleep: asleep,
                              displayHeldAwake: heldAwake, fullscreenInFront: fullscreen)
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

    // a video, a call or slides: no input for a long time, but someone is watching
    func testAnAppKeepingTheDisplayAwakeHoldsTheInstall() {
        XCTAssertEqual(IdleInstallPolicy.wait(conditions(heldAwake: true)), .displayHeldAwake)
    }

    // AX lists only part of the desk behind a lock or a sleeping display
    func testALockedScreenOrSleepingDisplayHoldsTheInstall() {
        XCTAssertEqual(IdleInstallPolicy.wait(conditions(locked: true)), .locked)
        XCTAssertEqual(IdleInstallPolicy.wait(conditions(asleep: true)), .displayAsleep)
        XCTAssertEqual(IdleInstallPolicy.wait(conditions(locked: true, asleep: true)), .locked)
    }

    func testEveryGuardMustClearBeforeAnInstall() {
        XCTAssertNotNil(IdleInstallPolicy.wait(conditions(idle: 0, fullscreen: true)))
        XCTAssertNotNil(IdleInstallPolicy.wait(conditions(idle: 3600, heldAwake: true, fullscreen: true)))
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

    func testDisplayAssertionsCountAsHeldAwake() {
        XCTAssertFalse(IdleInstallConditions.heldAwake(assertionStatus: [:]))
        XCTAssertFalse(IdleInstallConditions.heldAwake(assertionStatus: [
            "PreventUserIdleDisplaySleep": 0, "PreventUserIdleSystemSleep": 3,
        ]))
        XCTAssertTrue(IdleInstallConditions.heldAwake(assertionStatus: ["PreventUserIdleDisplaySleep": 1]))
        XCTAssertTrue(IdleInstallConditions.heldAwake(assertionStatus: ["NoDisplaySleepAssertion": 2]))
    }

    func testTheLiveReadAnswersWithoutCrashing() {
        let live = IdleInstallConditions.current(fullscreenInFront: false)
        XCTAssertGreaterThanOrEqual(live.idleSeconds, 0)
        XCTAssertFalse(live.fullscreenInFront)
    }
}
