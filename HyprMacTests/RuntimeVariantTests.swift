import XCTest
@testable import HyprMac

final class RuntimeVariantTests: XCTestCase {
    // the harness pins iCloudSyncEnabled in the argument domain, which every
    // UserDefaults instance reads first. these tests need it unset.
    private var savedArguments: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = savedArguments
        arguments.removeValue(forKey: "iCloudSyncEnabled")
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    override func tearDown() {
        UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
        super.tearDown()
    }

    func testReleaseOnboardingPolicy() {
        XCTAssertEqual(RuntimeVariant.shouldShowWelcome(
            alreadyOnboarded: false, lastVersion: nil, currentVersion: "0.12.0",
            debugApp: false), .onboarding)
        XCTAssertEqual(RuntimeVariant.shouldShowWelcome(
            alreadyOnboarded: true, lastVersion: "0.11.0", currentVersion: "0.12.0",
            debugApp: false), .whatsNew)
        XCTAssertNil(RuntimeVariant.shouldShowWelcome(
            alreadyOnboarded: true, lastVersion: "0.12.0", currentVersion: "0.12.0",
            debugApp: false))
    }

    // only a Mac with none of the earlier launch's marks is fresh
    func testAnySignOfAnEarlierLaunchSkipsOnboarding() {
        XCTAssertFalse(RuntimeVariant.alreadyOnboarded(hasSeenOnboarding: false, lastVersion: nil, hadConfigFile: false))
        XCTAssertTrue(RuntimeVariant.alreadyOnboarded(hasSeenOnboarding: true, lastVersion: nil, hadConfigFile: false))
        XCTAssertTrue(RuntimeVariant.alreadyOnboarded(hasSeenOnboarding: false, lastVersion: "0.27.1", hadConfigFile: false))
        XCTAssertTrue(RuntimeVariant.alreadyOnboarded(hasSeenOnboarding: false, lastVersion: nil, hadConfigFile: true))
    }

    // a 0.27.1 user updating gets What's New, never onboarding
    func testUpgradeFrom0271ShowsWhatsNewNotOnboarding() {
        let onboarded = RuntimeVariant.alreadyOnboarded(hasSeenOnboarding: true, lastVersion: "0.27.1", hadConfigFile: true)
        XCTAssertEqual(RuntimeVariant.shouldShowWelcome(
            alreadyOnboarded: onboarded, lastVersion: "0.27.1", currentVersion: "0.28.0", debugApp: false), .whatsNew)
    }

    func testReleaseDefaultsDoNotInheritAnotherDomain() throws {
        let suite = "RuntimeVariantTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(RuntimeVariant.inheritedBool(
            forKey: "iCloudSyncEnabled", standard: defaults,
            releaseDomain: ["iCloudSyncEnabled": true], debugApp: false))
    }

    func testDefaultPolicyMatchesCompiledVariant() throws {
        let suite = "RuntimeVariantTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(RuntimeVariant.inheritedBool(
            forKey: "iCloudSyncEnabled", standard: defaults,
            releaseDomain: ["iCloudSyncEnabled": true]), RuntimeVariant.isDebugApp)
    }

    func testDebugDefaultsPreferLocalThenReadReleaseFallback() throws {
        let suite = "RuntimeVariantTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(RuntimeVariant.inheritedBool(
            forKey: "iCloudSyncEnabled", standard: defaults,
            releaseDomain: ["iCloudSyncEnabled": true], debugApp: true))
        defaults.set(false, forKey: "iCloudSyncEnabled")
        XCTAssertFalse(RuntimeVariant.inheritedBool(
            forKey: "iCloudSyncEnabled", standard: defaults,
            releaseDomain: ["iCloudSyncEnabled": true], debugApp: true))
    }

    // Show in Dock is off until the user turns it on, and maps to the policy
    // that keeps the app out of the Dock and command-tab
    func testDockIconDefaultsOffAndMapsToActivationPolicy() throws {
        let suite = "RuntimeVariantTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(RuntimeVariant.inheritedBool(
            forKey: UserConfig.showDockIconKey, standard: defaults,
            releaseDomain: [:], debugApp: false))
        XCTAssertEqual(AppDelegate.activationPolicy(showDockIcon: false), .accessory)
        XCTAssertEqual(AppDelegate.activationPolicy(showDockIcon: true), .regular)
    }

    // LSUIElement keeps a second `open` of the running app from making it
    // a Dock app again, which undid Show in Dock = off
    // closing the menu bar panel or Settings must not quit the app
    func testClosingTheLastWindowDoesNotQuit() {
        XCTAssertFalse(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    func testAppBundleStartsOutOfTheDock() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HyprMac/Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: plist))
        XCTAssertEqual(info["LSUIElement"] as? Bool, true)
    }

    func testDebugSkipsUpdateWelcomeForExistingReleaseUser() {
        XCTAssertNil(RuntimeVariant.shouldShowWelcome(
            alreadyOnboarded: true, lastVersion: nil,
            currentVersion: "0.12.0", debugApp: true))
    }

    func testOnlyANixInstallLeavesUpdatesToNix() {
        let nix = ["/nix/store/abc123-hyprmac-0.24.2/Applications/HyprMac.app",
                   "/Applications/Nix Apps/HyprMac.app",
                   "/Users/me/Applications/Home Manager Apps/HyprMac.app"]
        for path in nix { XCTAssertTrue(RuntimeVariant.isNixInstall(bundlePath: path), path) }

        let other = ["/Applications/HyprMac.app",
                     "/Users/me/Applications/HyprMac.app",
                     "/Users/me/Nix Apps Backup/HyprMac.app",
                     "/Volumes/HyprMac/HyprMac.app"]
        for path in other { XCTAssertFalse(RuntimeVariant.isNixInstall(bundlePath: path), path) }
    }

    // a copy outside the Nix paths opts out of Sparkle through the defaults key
    func testTheDefaultsKeyLeavesUpdatesToAnExternalManager() throws {
        let suite = "RuntimeVariantTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = RuntimeVariant.updatesManagedExternallyKey
        XCTAssertEqual(key, "HyprMacUpdatesManagedExternally")

        XCTAssertFalse(RuntimeVariant.updatesManagedExternally(nixInstall: false, defaults: defaults))
        XCTAssertTrue(RuntimeVariant.updatesManagedExternally(nixInstall: true, defaults: defaults))

        defaults.set(true, forKey: key)
        XCTAssertTrue(RuntimeVariant.updatesManagedExternally(nixInstall: false, defaults: defaults))
        XCTAssertTrue(RuntimeVariant.updatesManagedExternally(nixInstall: true, defaults: defaults))

        // false never turns Sparkle back on for a Nix install
        defaults.set(false, forKey: key)
        XCTAssertFalse(RuntimeVariant.updatesManagedExternally(nixInstall: false, defaults: defaults))
        XCTAssertTrue(RuntimeVariant.updatesManagedExternally(nixInstall: true, defaults: defaults))
    }
}
