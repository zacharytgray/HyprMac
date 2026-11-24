import XCTest
@testable import HyprMac

// onboarding then the tutorial: which step comes next, and the focus
// indicator choice over its two config keys
final class StageSessionTests: XCTestCase {
    func testOnboardingStartsAtAccessOnlyWhileAccessIsMissing() {
        XCTAssertEqual(StageSession.onboarding(accessGranted: false).screen, .onboarding(.access))
        let granted = StageSession.onboarding(accessGranted: true)
        XCTAssertNotEqual(granted.screen, .onboarding(.access))
        XCTAssertTrue(granted.onboardingDone.contains(.access))
    }

    func testBackNeverReturnsToAccess() {
        let session = StageSession.onboarding(accessGranted: false)
        XCTAssertFalse(session.canGoBack)
        session.nextOnboardingStep()
        session.previousOnboardingStep()
        session.previousOnboardingStep()
        XCTAssertNotEqual(session.screen, .onboarding(.access))
    }

    func testTakingTheTutorialMovesToItsFirstLesson() {
        let session = StageSession.onboarding(accessGranted: true)
        session.finishOnboarding(takeTutorial: true)
        XCTAssertEqual(session.screen, .tutorial(StageSession.builtLessons[0]))
        XCTAssertTrue(session.onboardingDone.contains(.makeItYours))
        session.close()
    }

    func testSkippingForNowClosesAndAReplayStartsTheTutorial() {
        var closed = false
        let session = StageSession.onboarding(accessGranted: true)
        session.onClose = { closed = true }
        session.finishOnboarding(takeTutorial: false)
        XCTAssertTrue(closed)
        XCTAssertEqual(StageSession.tutorial().screen, .tutorial(.hyprKey))
    }

    func testFocusIndicatorChoiceRoundTripsThroughBothKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(localConfigURL: dir.appendingPathComponent("config.json"),
                                monitorConfigURL: dir.appendingPathComponent("monitors.json"),
                                iCloudRootURL: dir.appendingPathComponent("icloud"))
        let config = UserConfig(store: store, iCloudSyncEnabled: false, showDockIcon: false, repairsOnLaunch: false)
        for choice in FocusIndicatorChoice.allCases {
            choice.apply(to: config)
            XCTAssertEqual(FocusIndicatorChoice(bracketStyle: config.focusBracketStyle,
                                                showBorder: config.showFocusBorder), choice)
        }
        FocusIndicatorChoice.cornersAndBorders.apply(to: config)
        XCTAssertEqual(config.focusBracketStyle, .rounded)
        XCTAssertTrue(config.showFocusBorder)
    }
}
