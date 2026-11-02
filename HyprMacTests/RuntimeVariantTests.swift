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

    func testDebugSkipsUpdateWelcomeForExistingReleaseUser() {
        XCTAssertNil(RuntimeVariant.shouldShowWelcome(
            hasSeenOnboarding: true, lastVersion: nil,
            currentVersion: "0.12.0", debugApp: true))
    }
}
