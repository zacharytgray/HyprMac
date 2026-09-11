import XCTest
@testable import HyprMac

final class RuntimeVariantTests: XCTestCase {
    func testReleaseOnboardingPolicy() {
        XCTAssertEqual(RuntimeVariant.shouldShowWelcome(
            hasSeenOnboarding: false, lastVersion: nil, currentVersion: "0.12.0"), .firstRun)
        XCTAssertEqual(RuntimeVariant.shouldShowWelcome(
            hasSeenOnboarding: true, lastVersion: "0.11.0", currentVersion: "0.12.0"), .whatsNew)
        XCTAssertNil(RuntimeVariant.shouldShowWelcome(
            hasSeenOnboarding: true, lastVersion: "0.12.0", currentVersion: "0.12.0"))
    }

    func testReleaseDefaultsDoNotInheritAnotherDomain() throws {
        let suite = "RuntimeVariantTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(RuntimeVariant.inheritedBool(
            forKey: "iCloudSyncEnabled", standard: defaults,
            releaseDomain: ["iCloudSyncEnabled": true]))
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
