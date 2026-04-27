import XCTest
@testable import HyprMac
import AppKit

// ConfigMigrationTests pin Phase 6's persistence-layer contracts:
//
// - SavedConfig decodes pre-version-field configs (version = nil → v1)
// - SavedConfig with the version field set round-trips
// - SavedConfig with all optional fields missing still decodes (partial
//   configs from hand-edited files or older releases must not crash)
// - encoder omits the version field when nil, preserving the byte-equal
//   contract for unchanged settings
// - ConfigMigration.resolveMonitorConfig handles the local-only / migrated /
//   embedded variants
// - NSColor.fromHex returns nil + does not crash on malformed input
//   (the actual log call routes through hyprLog and is tested only by
//   the no-crash assertion — hyprLog has its own test surface)

final class ConfigMigrationTests: XCTestCase {

    // MARK: - schema versioning

    func testSavedConfigWithoutVersionDecodesAsV1() throws {
        // a v0.4.2 config — no `version` key.
        let json = """
        {"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true}
        """
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
        XCTAssertNil(saved.version)
        XCTAssertEqual(ConfigMigration.schemaVersion(of: saved), 1)
    }

    func testSavedConfigWithExplicitVersionDecodes() throws {
        let json = """
        {"version":1,"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true}
        """
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
        XCTAssertEqual(saved.version, 1)
        XCTAssertEqual(ConfigMigration.schemaVersion(of: saved), 1)
    }

    func testEncoderOmitsVersionWhenNil() throws {
        // critical for byte-equal round-trip: the version field must NOT
        // appear in encoded output until we actually need it.
        let saved = SavedConfig.empty
        let s = String(data: try JSONEncoder().encode(saved), encoding: .utf8)!
        XCTAssertFalse(s.contains("\"version\""),
                       "version field must be omitted from encoded JSON: \(s)")
    }

    // MARK: - partial-config tolerance

    func testMinimalSavedConfigDecodes() throws {
        // every optional field absent. only the four required fields present.
        let json = """
        {"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true}
        """
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
        XCTAssertEqual(saved.keybinds.count, 0)
        XCTAssertEqual(saved.gapSize, 8)
        XCTAssertNil(saved.focusFollowsMouse)
        XCTAssertNil(saved.hyprKey)
        XCTAssertNil(saved.excludedBundleIDs)
        XCTAssertNil(saved.dimIntensity)
        XCTAssertNil(saved.maxSplitsPerMonitor)
    }

    func testSavedConfigRoundTripsFullPayload() throws {
        let original = SavedConfig(
            version: nil,
            keybinds: [Keybind(keyCode: 18, modifiers: .hypr, action: .switchWorkspace(1))],
            gapSize: 8, outerPadding: 8, enabled: true,
            focusFollowsMouse: true, hyprKey: .capsLock,
            excludedBundleIDs: ["com.apple.FaceTime"],
            animateWindows: true, animationDuration: 0.15,
            showMenuBarIndicator: true,
            maxSplitsPerMonitor: nil, disabledMonitors: nil,
            showFocusBorder: true,
            focusBorderColorHex: "007AFF", floatingBorderColorHex: nil,
            dimInactiveWindows: true, dimIntensity: 0.5)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SavedConfig.self, from: data)
        XCTAssertEqual(decoded.keybinds.first?.action, .switchWorkspace(1))
        XCTAssertEqual(decoded.focusFollowsMouse, true)
        XCTAssertEqual(decoded.hyprKey, .capsLock)
        XCTAssertEqual(decoded.excludedBundleIDs, ["com.apple.FaceTime"])
        XCTAssertEqual(decoded.dimIntensity, 0.5)
        XCTAssertEqual(decoded.focusBorderColorHex, "007AFF")
    }

    // MARK: - monitor-config migration

    func testResolveMonitorConfigPrefersLocalFile() {
        let local = SavedMonitorConfig(
            maxSplitsPerMonitor: ["Display A": 4],
            disabledMonitors: ["Display B"])
        let embedded = SavedConfig(
            version: nil, keybinds: [], gapSize: 8, outerPadding: 8, enabled: true,
            focusFollowsMouse: nil, hyprKey: nil, excludedBundleIDs: nil,
            animateWindows: nil, animationDuration: nil, showMenuBarIndicator: nil,
            maxSplitsPerMonitor: ["Old": 99], disabledMonitors: ["Old"],
            showFocusBorder: nil, focusBorderColorHex: nil,
            floatingBorderColorHex: nil, dimInactiveWindows: nil, dimIntensity: nil)
        let r = ConfigMigration.resolveMonitorConfig(local: local, embedded: embedded)
        XCTAssertEqual(r.maxSplits, ["Display A": 4])
        XCTAssertEqual(r.disabled, ["Display B"])
        XCTAssertFalse(r.needsLocalWrite,
                       "local file present — no migration needed")
    }

    func testResolveMonitorConfigMigratesFromEmbeddedWhenLocalAbsent() {
        let embedded = SavedConfig(
            version: nil, keybinds: [], gapSize: 8, outerPadding: 8, enabled: true,
            focusFollowsMouse: nil, hyprKey: nil, excludedBundleIDs: nil,
            animateWindows: nil, animationDuration: nil, showMenuBarIndicator: nil,
            maxSplitsPerMonitor: ["DELL U2723QE": 2],
            disabledMonitors: ["External"],
            showFocusBorder: nil, focusBorderColorHex: nil,
            floatingBorderColorHex: nil, dimInactiveWindows: nil, dimIntensity: nil)
        let r = ConfigMigration.resolveMonitorConfig(local: nil, embedded: embedded)
        XCTAssertEqual(r.maxSplits, ["DELL U2723QE": 2])
        XCTAssertEqual(r.disabled, ["External"])
        XCTAssertTrue(r.needsLocalWrite,
                      "embedded data present + no local file → must persist locally")
    }

    func testResolveMonitorConfigEmptyWhenNothingPresent() {
        let r = ConfigMigration.resolveMonitorConfig(local: nil, embedded: nil)
        XCTAssertEqual(r.maxSplits, [:])
        XCTAssertEqual(r.disabled, [])
        XCTAssertFalse(r.needsLocalWrite)
    }

    func testResolveMonitorConfigEmptyEmbeddedDoesNotTriggerWrite() {
        let embedded = SavedConfig(
            version: nil, keybinds: [], gapSize: 8, outerPadding: 8, enabled: true,
            focusFollowsMouse: nil, hyprKey: nil, excludedBundleIDs: nil,
            animateWindows: nil, animationDuration: nil, showMenuBarIndicator: nil,
            maxSplitsPerMonitor: nil, disabledMonitors: nil,
            showFocusBorder: nil, focusBorderColorHex: nil,
            floatingBorderColorHex: nil, dimInactiveWindows: nil, dimIntensity: nil)
        let r = ConfigMigration.resolveMonitorConfig(local: nil, embedded: embedded)
        XCTAssertFalse(r.needsLocalWrite,
                       "no monitor data anywhere — nothing to write")
    }

    // MARK: - hex color tolerance

    func testFromHexValidSixDigit() {
        XCTAssertNotNil(NSColor.fromHex("007AFF"))
        XCTAssertNotNil(NSColor.fromHex("#007AFF"))  // strip leading hash
    }

    func testFromHexEmptyReturnsNil() {
        XCTAssertNil(NSColor.fromHex(""))
    }

    func testFromHexWrongLengthReturnsNil() {
        XCTAssertNil(NSColor.fromHex("ABC"))
        XCTAssertNil(NSColor.fromHex("12345"))
        XCTAssertNil(NSColor.fromHex("1234567"))
    }

    func testFromHexNonHexCharsReturnsNil() {
        XCTAssertNil(NSColor.fromHex("ZZZZZZ"))
        XCTAssertNil(NSColor.fromHex("not!ok"))
    }

    func testFromHexDoesNotCrashOnArbitraryInput() {
        // sweep a handful of pathological strings — the contract is no
        // crash, no force-unwrap, just nil + a logged warning.
        let pathological = ["", "#", "##", "12 34 56", "💀💀💀💀💀💀", "\n\n\n"]
        for h in pathological {
            _ = NSColor.fromHex(h)
        }
    }
}
