import XCTest
@testable import HyprMac

// the hypr key lesson's checklist: what counts, in which order
final class HyprKeyLessonModelTests: XCTestCase {
    private var dir: URL!
    private var config: UserConfig!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ConfigStore(localConfigURL: dir.appendingPathComponent("config.json"),
                                monitorConfigURL: dir.appendingPathComponent("monitors.json"),
                                iCloudRootURL: dir.appendingPathComponent("icloud"))
        config = UserConfig(store: store, iCloudSyncEnabled: false, showDockIcon: false, repairsOnLaunch: false)
        config.hyprKey = .capsLock
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testCapsLockWithDoubleTapNeedsHoldThenOnThenOff() {
        config.doubleTapHyprTogglesCapsLock = true
        let model = HyprKeyLessonModel(config: config)
        XCTAssertEqual(model.taskCount, 3)

        model.heldOnce = true
        model.noteCapsLock(false)   // no change, nothing counts
        XCTAssertEqual(model.tasksDone, 1)

        model.noteCapsLock(true)
        XCTAssertTrue(model.capsTurnedOn)
        XCTAssertFalse(model.isDone)

        model.noteCapsLock(false)
        XCTAssertTrue(model.capsTurnedOff)
        XCTAssertTrue(model.isDone)
    }

    func testTurningCapitalsOffBeforeOnDoesNotCount() {
        config.doubleTapHyprTogglesCapsLock = true
        let model = HyprKeyLessonModel(config: config)
        model.capsLockOn = true
        model.noteCapsLock(false)
        XCTAssertFalse(model.capsTurnedOff)
    }

    func testSkippingDoubleTapLeavesOnlyTheHold() {
        let model = HyprKeyLessonModel(config: config)
        model.skipDoubleTap()
        XCTAssertEqual(model.taskCount, 1)
        model.heldOnce = true
        XCTAssertTrue(model.isDone)
    }

    func testDoubleTapOffListsTheHoldAndTheSwitchThenTheTaps() {
        config.doubleTapHyprTogglesCapsLock = false
        let model = HyprKeyLessonModel(config: config)
        model.heldOnce = true
        XCTAssertEqual(model.taskCount, 2)
        XCTAssertEqual(model.tasksDone, 1)
        model.turnOnDoubleTap()
        XCTAssertTrue(config.doubleTapHyprTogglesCapsLock)
        XCTAssertEqual(model.taskCount, 3)
        XCTAssertFalse(model.isDone)
    }

    func testOtherHyprKeysTeachOnlyTheHold() {
        config.hyprKey = .f18
        let model = HyprKeyLessonModel(config: config)
        XCTAssertFalse(model.teachesDoubleTap)
        XCTAssertEqual(model.taskCount, 1)
    }
}
