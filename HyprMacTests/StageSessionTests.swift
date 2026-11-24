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

    func testOnboardingRunsAccessThenHyprKeyThenMakeItYours() {
        let session = StageSession.onboarding(accessGranted: false)
        session.nextOnboardingStep()
        XCTAssertEqual(session.screen, .onboarding(.hyprKey))
        XCTAssertFalse(session.canGoBack)
        session.nextOnboardingStep()
        XCTAssertEqual(session.screen, .onboarding(.makeItYours))
        XCTAssertTrue(session.canGoBack)
        session.previousOnboardingStep()
        XCTAssertEqual(session.screen, .onboarding(.hyprKey))
        session.close()
    }

    func testEveryOfferedHyprKeyHasANote() {
        for key in HyprKey.pickerChoices {
            XCTAssertFalse(key.onboardingNote.isEmpty, "\(key)")
        }
    }

    private func tempConfig() throws -> (UserConfig, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ConfigStore(localConfigURL: dir.appendingPathComponent("config.json"),
                                monitorConfigURL: dir.appendingPathComponent("monitors.json"),
                                iCloudRootURL: dir.appendingPathComponent("icloud"))
        return (UserConfig(store: store, iCloudSyncEnabled: false, showDockIcon: false, repairsOnLaunch: false), dir)
    }

    /// A session on a temp config and defaults, with Screen Recording as given.
    private func onboarding(granted: Bool, fresh: Bool = false) throws -> (StageSession, UserConfig, UserDefaults) {
        let (config, dir) = try tempConfig()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let suite = "StageSessionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let access = ScreenRecordingAccess()
        access.inProcess = { granted }
        access.freshCheck = { $0(fresh) }
        let session = StageSession.onboarding(accessGranted: true)
        session.config = config
        session.screenRecording = access
        session.resumeDefaults = defaults
        session.nextOnboardingStep()
        XCTAssertEqual(session.screen, .onboarding(.makeItYours))
        return (session, config, defaults)
    }

    func testTakingTheTutorialMovesToItsFirstLesson() throws {
        let (session, _, _) = try onboarding(granted: true)
        session.finishOnboarding(takeTutorial: true)
        XCTAssertEqual(session.screen, .tutorial(StageSession.builtLessons[0]))
        XCTAssertTrue(session.onboardingDone.contains(.makeItYours))
        session.close()
    }

    func testSkippingForNowClosesAndAReplayStartsTheTutorial() throws {
        var closed = false
        let (session, _, _) = try onboarding(granted: true)
        session.onClose = { closed = true }
        session.finishOnboarding(takeTutorial: false)
        XCTAssertTrue(closed)
        XCTAssertEqual(StageSession.tutorial().screen, .tutorial(.hyprKey))
    }

    // MARK: keep floating windows in front

    func testFloatersInFrontIsPreselectedAndWrittenWhenOnboardingEnds() throws {
        let (session, config, _) = try onboarding(granted: true)
        XCTAssertTrue(session.keepFloatersInFront, "preselected on")
        XCTAssertFalse(config.keepFloatingWindowsInFront, "not written while the step is open")
        session.finishOnboarding(takeTutorial: true)
        XCTAssertTrue(config.keepFloatingWindowsInFront)
        XCTAssertNil(session.awaitingScreenRecording, "granted: straight on")
        XCTAssertEqual(session.screen, .tutorial(StageSession.builtLessons[0]))
        session.close()
    }

    func testTurnedOffOnboardingJustMovesOn() throws {
        var closed = false
        let (session, config, _) = try onboarding(granted: false)
        session.onClose = { closed = true }
        session.keepFloatersInFront = false
        session.finishOnboarding(takeTutorial: false)
        XCTAssertFalse(config.keepFloatingWindowsInFront)
        XCTAssertNil(session.awaitingScreenRecording)
        XCTAssertTrue(closed)
    }

    // on without the grant: the step asks first, and a reopen on the way
    // lands in the tutorial that was picked
    func testOnWithoutTheGrantWaitsAndRemembersTheTutorial() throws {
        let (session, config, defaults) = try onboarding(granted: false)
        session.finishOnboarding(takeTutorial: true)
        XCTAssertTrue(config.keepFloatingWindowsInFront)
        XCTAssertEqual(session.awaitingScreenRecording, true)
        XCTAssertEqual(session.screen, .onboarding(.makeItYours))
        XCTAssertTrue(defaults.bool(forKey: AppDelegate.tutorialAfterReopenKey))

        session.continuePastScreenRecording()
        XCTAssertNil(session.awaitingScreenRecording)
        XCTAssertFalse(defaults.bool(forKey: AppDelegate.tutorialAfterReopenKey))
        XCTAssertEqual(session.screen, .tutorial(StageSession.builtLessons[0]))
        XCTAssertTrue(config.keepFloatingWindowsInFront, "going on without it keeps the switch on")
        session.close()
    }

    func testBackFromScreenRecordingReturnsToTheChoices() throws {
        let (session, _, defaults) = try onboarding(granted: false)
        session.finishOnboarding(takeTutorial: true)
        session.backFromScreenRecording()
        XCTAssertNil(session.awaitingScreenRecording)
        XCTAssertEqual(session.screen, .onboarding(.makeItYours))
        XCTAssertFalse(defaults.bool(forKey: AppDelegate.tutorialAfterReopenKey))
        XCTAssertFalse(session.onboardingDone.contains(.makeItYours))

        // skipping the tutorial never asks for it after a reopen
        session.finishOnboarding(takeTutorial: false)
        XCTAssertEqual(session.awaitingScreenRecording, false)
        XCTAssertFalse(defaults.bool(forKey: AppDelegate.tutorialAfterReopenKey))
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
