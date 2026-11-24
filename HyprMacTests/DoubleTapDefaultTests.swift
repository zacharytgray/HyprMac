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

    private func load(freshInstall: Bool = true) -> UserConfig {
        let store = ConfigStore(localConfigURL: configURL,
                                monitorConfigURL: dir.appendingPathComponent("monitors.json"),
                                iCloudRootURL: dir.appendingPathComponent("icloud"))
        return UserConfig(store: store, iCloudSyncEnabled: false, showDockIcon: false, repairsOnLaunch: false,
                          freshInstall: freshInstall)
    }

    func testNewInstallStartsOnAndSavesIt() throws {
        let config = load()
        XCTAssertTrue(config.doubleTapHyprTogglesCapsLock)
        config.save()
        XCTAssertTrue(load().doubleTapHyprTogglesCapsLock)
    }

    // an upgrader who never changed a setting has no config.json, but has
    // the earlier launch's defaults: their Caps Lock stays as it was
    func testAnUpgraderWithNoConfigFileKeepsItOff() throws {
        XCTAssertFalse(load(freshInstall: false).doubleTapHyprTogglesCapsLock)
    }

    // ...and both resets still turn it on, as on a new install
    func testResetsTurnItOnForAnUpgraderToo() throws {
        let config = load(freshInstall: false)
        config.resetToDefaults()
        XCTAssertTrue(config.doubleTapHyprTogglesCapsLock)
        let other = load(freshInstall: false)
        other.doubleTapHyprTogglesCapsLock = false
        other.resetKeybindsToDefaults()
        XCTAssertTrue(other.doubleTapHyprTogglesCapsLock)
    }

    func testFreshInstallMeansNoEarlierLaunchInDefaults() throws {
        let suite = "DoubleTapDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(RuntimeVariant.looksLikeFreshInstall(standard: defaults, debugApp: false))
        defaults.set("0.27.1", forKey: "lastSeenVersion")
        XCTAssertFalse(RuntimeVariant.looksLikeFreshInstall(standard: defaults, debugApp: false))
        defaults.removeObject(forKey: "lastSeenVersion")
        defaults.set(true, forKey: "hasSeenOnboarding")
        XCTAssertFalse(RuntimeVariant.looksLikeFreshInstall(standard: defaults, debugApp: false))
    }

    func testConfigFromBeforeTheKeyStaysOff() throws {
        let config = load()
        config.save()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        json.removeValue(forKey: "doubleTapHyprTogglesCapsLock")
        try JSONSerialization.data(withJSONObject: json).write(to: configURL)
        XCTAssertFalse(load().doubleTapHyprTogglesCapsLock)
    }

    func testResetAllSettingsTurnsItOnLikeANewInstall() throws {
        let config = load()
        config.doubleTapHyprTogglesCapsLock = false
        config.save()
        let reloaded = load()
        reloaded.resetToDefaults()
        XCTAssertTrue(reloaded.doubleTapHyprTogglesCapsLock)
    }

    func testSavedOffStaysOff() throws {
        let config = load()
        config.doubleTapHyprTogglesCapsLock = false
        config.save()
        XCTAssertFalse(load().doubleTapHyprTogglesCapsLock)
    }
}
