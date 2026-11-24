import XCTest
@testable import HyprMac

// double tap starts on for a new install only; a config saved before the
// key existed keeps it off
final class DoubleTapDefaultTests: XCTestCase {
    private var dir: URL!
    private var configURL: URL { dir.appendingPathComponent("config.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func load() -> UserConfig {
        let store = ConfigStore(localConfigURL: configURL,
                                monitorConfigURL: dir.appendingPathComponent("monitors.json"),
                                iCloudRootURL: dir.appendingPathComponent("icloud"))
        return UserConfig(store: store, iCloudSyncEnabled: false, showDockIcon: false, repairsOnLaunch: false)
    }

    func testNewInstallStartsOnAndSavesIt() throws {
        let config = load()
        XCTAssertTrue(config.doubleTapHyprTogglesCapsLock)
        config.save()
        XCTAssertTrue(load().doubleTapHyprTogglesCapsLock)
    }

    func testConfigFromBeforeTheKeyStaysOff() throws {
        let config = load()
        config.save()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        json.removeValue(forKey: "doubleTapHyprTogglesCapsLock")
        try JSONSerialization.data(withJSONObject: json).write(to: configURL)
        XCTAssertFalse(load().doubleTapHyprTogglesCapsLock)
    }

    func testSavedOffStaysOff() throws {
        let config = load()
        config.doubleTapHyprTogglesCapsLock = false
        config.save()
        XCTAssertFalse(load().doubleTapHyprTogglesCapsLock)
    }
}
