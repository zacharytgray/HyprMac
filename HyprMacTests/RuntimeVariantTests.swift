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
            hasSeenOnboarding: false, lastVersion: nil, currentVersion: "0.12.0",
            debugApp: false), .firstRun)
        XCTAssertEqual(RuntimeVariant.shouldShowWelcome(
            hasSeenOnboarding: true, lastVersion: "0.11.0", currentVersion: "0.12.0",
            debugApp: false), .whatsNew)
        XCTAssertNil(RuntimeVariant.shouldShowWelcome(
            hasSeenOnboarding: true, lastVersion: "0.12.0", currentVersion: "0.12.0",
            debugApp: false))
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
    func testAppBundleStartsOutOfTheDock() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HyprMac/Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: plist))
        XCTAssertEqual(info["LSUIElement"] as? Bool, true)
    }

    func testDebugSkipsUpdateWelcomeForExistingReleaseUser() {
        XCTAssertNil(RuntimeVariant.shouldShowWelcome(
            hasSeenOnboarding: true, lastVersion: nil,
            currentVersion: "0.12.0", debugApp: true))
    }
}
