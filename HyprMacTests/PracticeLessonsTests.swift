import XCTest
@testable import HyprMac

// lessons 3 to 7: each task counts only when its key ran and HyprMac's
// state shows the result
final class PracticeLessonsTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1000)
    private var dir: URL!
    private var config: UserConfig!
    private var practice: PracticeSession!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ConfigStore(localConfigURL: dir.appendingPathComponent("config.json"),
                                monitorConfigURL: dir.appendingPathComponent("monitors.json"),
                                iCloudRootURL: dir.appendingPathComponent("icloud"))
        config = UserConfig(store: store, iCloudSyncEnabled: false, showDockIcon: false, repairsOnLaunch: false)
        practice = PracticeSession(host: nil)
        practice.setWorkspacesForTesting(practice: 4, other: 5)
        practice.apply(["focused": 1, "order": [1, 2, 3]])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func windows(_ states: [(Int, Int, Bool)], on workspace: Int = 4) {
        practice.setWindowsForTesting(states.map { PracticeWindowState(number: $0.0, workspace: $0.1, floating: $0.2) },
                                      workspace: workspace)
    }

    // MARK: 3 workspaces

    func testWorkspacesAwayBackAndSend() {
        let model = WorkspacesLessonModel(practice: practice, config: config) { [unowned self] in self.clock }
        windows([(1, 4, false), (2, 4, false), (3, 4, false)], on: 5)
        model.evaluate()
        XCTAssertFalse(model.wentAway, "no key yet")

        model.recorder.note("switchWorkspace")
        XCTAssertTrue(model.wentAway)
        windows([(1, 4, false), (2, 4, false), (3, 4, false)], on: 4)
        model.recorder.note("switchWorkspace")
        XCTAssertTrue(model.cameBack)

        windows([(1, 4, false), (2, 4, false), (3, 5, false)], on: 4)
        model.recorder.note("moveToWorkspace")
        XCTAssertTrue(model.sent)
    }

    // a window parked on another workspace drops out of the list entirely
    func testSendCountsWhenAWindowLeavesThePracticeWorkspace() {
        let model = WorkspacesLessonModel(practice: practice, config: config) { [unowned self] in self.clock }
        windows([(1, 4, false), (2, 4, false), (3, 4, false)], on: 4)
        model.evaluate()
        windows([(2, 4, false), (3, 4, false)], on: 4)
        model.recorder.note("moveToWorkspace")
        XCTAssertTrue(model.sent)
    }

    func testComingBackFirstDoesNotCount() {
        let model = WorkspacesLessonModel(practice: practice, config: config) { [unowned self] in self.clock }
        windows([], on: 4)
        model.recorder.note("switchWorkspace")
        XCTAssertFalse(model.cameBack)
    }

    // MARK: 4 floating

    func testFloatTwoCycleAndTileOneBack() {
        let model = FloatingLessonModel(practice: practice, config: config) { [unowned self] in self.clock }
        windows([(1, 4, true), (2, 4, false), (3, 4, false)])
        model.recorder.note("toggleFloating")
        XCTAssertFalse(model.floatedTwo)
        windows([(1, 4, true), (2, 4, true), (3, 4, false)])
        model.recorder.note("toggleFloating")
        XCTAssertTrue(model.floatedTwo)

        practice.apply(["focused": 2, "order": [3, 1, 2]])
        model.recorder.note("focusFloating")
        XCTAssertTrue(model.cycled)

        windows([(1, 4, false), (2, 4, true), (3, 4, false)])
        model.recorder.note("toggleFloating")
        XCTAssertTrue(model.tiledBack)
    }

    func testFloatersOnAnotherWorkspaceDoNotCount() {
        let model = FloatingLessonModel(practice: practice, config: config) { [unowned self] in self.clock }
        windows([(1, 4, true), (3, 5, true)])
        model.recorder.note("toggleFloating")
        XCTAssertFalse(model.floatedTwo)
    }

    // MARK: 5 fix a window

    func testFixNeedsTheTileRuleAndTheWindowTiled() {
        let model = FixWindowLessonModel(practice: practice, config: config) { [unowned self] in self.clock }
        model.recorder.note("showWindowRules")
        XCTAssertTrue(model.openedRules)
        windows([(4, 4, true)])
        config.addFloatingRule(FloatingRule(bundleID: PracticeSession.helperBundleID, action: .tile))
        model.evaluate()
        XCTAssertFalse(model.fixed, "the window still floats")
        windows([(4, 4, false)])
        model.evaluate()
        XCTAssertTrue(model.fixed)
    }

    func testCleanupRemovesEveryPracticeRule() {
        config.addFloatingRule(FloatingRule(bundleID: PracticeSession.helperBundleID, action: .tile))
        config.addFloatingRule(FloatingRule(bundleID: "com.apple.FaceTime", action: .float))
        config.excludedBundleIDs.insert(PracticeSession.helperBundleID)
        PracticeSession.removeRules(bundleID: PracticeSession.helperBundleID, from: config)
        XCTAssertFalse(config.floatingRules.contains { $0.bundleID == PracticeSession.helperBundleID })
        // an app-wide float rule lives in the Never tile list
        XCTAssertTrue(config.excludedBundleIDs.contains("com.apple.FaceTime"), "others stay")
        XCTAssertFalse(config.excludedBundleIDs.contains(PracticeSession.helperBundleID))
    }

    // MARK: 6 menu bar and keys

    func testMenuBarJumpKeepsTheAppAndTheSearchFindsFloat() {
        let model = MenuBarAndKeysLessonModel(practice: practice, config: config) { [unowned self] in self.clock }
        practice.setFrontForTesting(false)
        model.recorder.note("focusMenuBar")
        XCTAssertFalse(model.jumped, "the menu bar moved to another app")
        practice.setFrontForTesting(true)
        model.recorder.note("focusMenuBar")
        XCTAssertTrue(model.jumped)

        model.recorder.note("showKeybinds")
        XCTAssertTrue(model.openedKeys)
        practice.setFrontForTesting(true, search: "Flo")
        model.evaluate()
        XCTAssertFalse(model.searched)
        practice.setFrontForTesting(true, search: "Float")
        model.evaluate()
        XCTAssertTrue(model.searched)
    }

    // MARK: 7 pause

    private func pauseDefaults() throws -> UserDefaults {
        let suite = "PracticeLessonsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private var owesResume: (UserDefaults) -> Bool { { $0.bool(forKey: PauseLessonModel.ownedPauseKey) } }

    func testPauseThenResume() throws {
        let defaults = try pauseDefaults()
        let model = PauseLessonModel(practice: practice, config: config, defaults: defaults) { [unowned self] in self.clock }
        model.didStart()
        config.enabled = false
        model.evaluate()
        XCTAssertTrue(model.paused)
        XCTAssertTrue(owesResume(defaults), "the lesson turned tiling off")
        model.resume()
        model.evaluate()
        XCTAssertTrue(model.resumed)
        XCTAssertTrue(config.enabled)
        XCTAssertFalse(owesResume(defaults), "back on, nothing owed")
    }

    // the tutorial ends with tiling still off from the lesson: it goes back on
    func testAPauseTheLessonMadeIsResumedWhenTheTutorialEnds() throws {
        let defaults = try pauseDefaults()
        let model = PauseLessonModel(practice: practice, config: config, defaults: defaults) { [unowned self] in self.clock }
        model.didStart()
        config.enabled = false
        model.evaluate()
        PauseLessonModel.resumeOwnedPause(config: config, defaults: defaults)
        XCTAssertTrue(config.enabled)
        XCTAssertFalse(owesResume(defaults))
    }

    // paused before the tutorial: the user's choice, never turned on for them
    func testAPauseFromBeforeTheTutorialIsLeftAlone() throws {
        let defaults = try pauseDefaults()
        config.enabled = false
        let model = PauseLessonModel(practice: practice, config: config, defaults: defaults) { [unowned self] in self.clock }
        model.didStart()
        model.evaluate()
        XCTAssertTrue(model.paused)
        config.enabled = true
        model.evaluate()
        config.enabled = false
        model.evaluate()
        XCTAssertFalse(owesResume(defaults))
        PauseLessonModel.resumeOwnedPause(config: config, defaults: defaults)
        XCTAssertFalse(config.enabled)
    }

    // a crash mid-lesson: the flag outlives the process, and the next launch
    // turns tiling back on once
    func testALaunchAfterACrashResumesTheLessonsPause() throws {
        let defaults = try pauseDefaults()
        defaults.set(true, forKey: PauseLessonModel.ownedPauseKey)
        config.enabled = false
        PauseLessonModel.resumeOwnedPause(config: config, defaults: defaults)
        XCTAssertTrue(config.enabled)
        config.enabled = false
        PauseLessonModel.resumeOwnedPause(config: config, defaults: defaults)
        XCTAssertFalse(config.enabled, "only once")
    }

    // MARK: stale keys

    func testAStaleKeyDoesNotCount() {
        let model = WorkspacesLessonModel(practice: practice, config: config) { [unowned self] in self.clock }
        model.recorder.note("switchWorkspace")
        clock.addTimeInterval(3)
        windows([], on: 5)
        model.evaluate()
        XCTAssertFalse(model.wentAway)
    }
}
