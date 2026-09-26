import XCTest
@testable import HyprMac
import AppKit

// ConfigMigrationTests pin Phase 6's persistence-layer contracts:
//
// - SavedConfig decodes pre-version-field configs (version = nil → v1)
// - SavedConfig with the version field set round-trips
// - SavedConfig with all optional fields missing still decodes (partial
//   configs from hand-edited files or older releases must not crash)
// - an optional field this build can't read (an unknown hyprKey, a changed
//   type) drops just that field; the core fields stay strict
// - encoder omits the version field when nil, preserving the byte-equal
//   contract for unchanged settings
// - a nil corner-radius override stays omitted so OS defaults remain adaptive
// - ConfigMigration.resolveMonitorConfig handles the local-only / migrated /
//   embedded variants
// - NSColor.fromHex returns nil + does not crash on malformed input
//   (the actual log call routes through hyprLog and is tested only by
//   the no-crash assertion — hyprLog has its own test surface)

final class ConfigMigrationTests: XCTestCase {

    func testFocusChromeDefaultsUseDimAndBlackCorners() {
        XCTAssertFalse(UserConfigDefaults.showFocusBorder)
        XCTAssertTrue(UserConfigDefaults.dimInactiveWindows)
        XCTAssertEqual(UserConfigDefaults.dimIntensity, 0.135, accuracy: 0.0001)
        XCTAssertEqual(UserConfigDefaults.chromeFadeDurationSec, 0.13, accuracy: 0.0001)
        XCTAssertEqual(UserConfigDefaults.focusBracketStyle, .rounded)
        XCTAssertEqual(UserConfigDefaults.focusBracketRadius, 20)
        XCTAssertEqual(UserConfigDefaults.focusBracketThickness, 4.5)
        XCTAssertEqual(SavedConfig.empty.focusBracketStyle, .rounded)
        XCTAssertEqual(SavedConfig.empty.focusBracketLength, 15)
        XCTAssertEqual(UserConfigDefaults.focusBracketColor, NSColor.black)
        XCTAssertNil(SavedConfig.empty.focusBracketColorHex)
        XCTAssertNil(SavedConfig.empty.focusBracketRadius)
        XCTAssertNil(SavedConfig.empty.focusBracketThickness)
    }

    func testCornerLengthIsOptionalAndRoundTripsIndependently() throws {
        let legacy = Data(#"{"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true,"focusBracketThickness":5}"#.utf8)
        let decoded = try JSONDecoder().decode(SavedConfig.self, from: legacy)
        XCTAssertNil(decoded.overlayAppearance)
        XCTAssertNil(decoded.focusBracketLength)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        object["focusBracketLength"] = 12
        let explicit = try JSONDecoder().decode(SavedConfig.self, from: JSONSerialization.data(withJSONObject: object))
        let roundTrip = try JSONDecoder().decode(SavedConfig.self, from: JSONEncoder().encode(explicit))
        XCTAssertEqual(roundTrip.focusBracketLength, 12)
        XCTAssertEqual(roundTrip.focusBracketThickness, 5)
        XCTAssertEqual(UserConfigDefaults.focusBracketLength, 15)
    }

    func testBracketColorMigrationPreservesExplicitLegacyFocusColor() {
        let saved = SavedConfig(
            version: nil, keybinds: [], gapSize: 8, outerPadding: 8, enabled: true,
            focusFollowsMouse: nil, hyprKey: nil, excludedBundleIDs: nil,
            showMenuBarIndicator: nil, maxSplitsPerMonitor: nil, disabledMonitors: nil,
            showFocusBorder: false, focusBorderColorHex: "000000", floatingBorderColorHex: nil,
            focusBracketStyle: nil, focusBracketColorHex: nil,
            focusBracketRadius: nil,
            focusBracketThickness: nil,
            dimInactiveWindows: true, dimIntensity: 0.135, mouseHoverPollHz: nil,
            chromeFadeDurationSec: 0.13, windowCornerRadius: nil,
            scratchpadTileByDefault: nil, scratchpadRegionInset: nil)

        XCTAssertEqual(ConfigMigration.resolveFocusBracketColor(saved: saved), "000000")
    }

    func testBracketColorMigrationUsesNewFieldFirstAndNilMeansNeutral() throws {
        let explicit = SavedConfig(
            version: nil, keybinds: [], gapSize: 8, outerPadding: 8, enabled: true,
            focusFollowsMouse: nil, hyprKey: nil, excludedBundleIDs: nil,
            showMenuBarIndicator: nil, maxSplitsPerMonitor: nil, disabledMonitors: nil,
            showFocusBorder: nil, focusBorderColorHex: "00FFFF", floatingBorderColorHex: nil,
            focusBracketStyle: .rounded, focusBracketColorHex: "FFFFFF",
            focusBracketRadius: 8,
            focusBracketThickness: nil,
            dimInactiveWindows: nil, dimIntensity: nil, mouseHoverPollHz: nil,
            chromeFadeDurationSec: nil, windowCornerRadius: nil,
            scratchpadTileByDefault: nil, scratchpadRegionInset: nil)
        var neutralJSON = try JSONEncoder().encode(SavedConfig.empty)
        var neutralObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: neutralJSON) as? [String: Any])
        neutralObject.removeValue(forKey: "focusBracketColorHex")
        neutralObject.removeValue(forKey: "focusBorderColorHex")
        neutralJSON = try JSONSerialization.data(withJSONObject: neutralObject)
        let neutral = try JSONDecoder().decode(SavedConfig.self, from: neutralJSON)

        XCTAssertEqual(ConfigMigration.resolveFocusBracketColor(saved: explicit), "FFFFFF")
        XCTAssertNil(ConfigMigration.resolveFocusBracketColor(saved: neutral))
    }

    func testResetNeutralBracketDoesNotReimportLegacyBorderColor() throws {
        var data = try JSONEncoder().encode(SavedConfig.empty)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["focusBorderColorHex"] = "000000"
        object["focusBracketStyle"] = FocusBracketStyle.rounded.rawValue
        object.removeValue(forKey: "focusBracketColorHex")
        data = try JSONSerialization.data(withJSONObject: object)
        let saved = try JSONDecoder().decode(SavedConfig.self, from: data)

        XCTAssertNil(ConfigMigration.resolveFocusBracketColor(saved: saved))
    }

    func testUnknownFutureBracketStyleDoesNotDiscardConfig() throws {
        var data = try JSONEncoder().encode(SavedConfig.empty)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["focusBracketStyle"] = "future-style"
        object["focusBorderColorHex"] = "000000"
        object.removeValue(forKey: "focusBracketColorHex")
        object["dimIntensity"] = 0.17
        data = try JSONSerialization.data(withJSONObject: object)

        let saved = try JSONDecoder().decode(SavedConfig.self, from: data)

        XCTAssertEqual(saved.focusBracketStyle, .rounded)
        XCTAssertNil(ConfigMigration.resolveFocusBracketColor(saved: saved))
        XCTAssertEqual(saved.dimIntensity, 0.17)
    }

    // MARK: - per-field decode tolerance

    // config.json is shared over iCloud, so this build can meet a value a
    // newer build wrote. a value it can't read must cost that one field,
    // not every setting. the fixture sets every optional field, so a field
    // lost along the way shows up in the comparisons below.
    private let fullConfig = SavedConfig(
        version: nil,
        keybinds: [Keybind(keyCode: 18, modifiers: .hypr, action: .switchWorkspace(1))],
        gapSize: 12, outerPadding: 6, enabled: true,
        focusFollowsMouse: false, hyprKey: .rightCommand,
        excludedBundleIDs: ["com.apple.FaceTime"],
        showMenuBarIndicator: false,
        overlayAppearance: .dark,
        maxSplitsPerMonitor: ["Display A": 4], disabledMonitors: ["Display B"],
        showFocusBorder: true,
        focusBorderColorHex: "007AFF", floatingBorderColorHex: "FF9500",
        focusBracketStyle: .rounded, focusBracketColorHex: "FFFFFF",
        focusBracketRadius: 14, focusBracketThickness: 3, focusBracketLength: 12,
        dimInactiveWindows: false, dimIntensity: 0.17,
        mouseHoverPollHz: 60, chromeFadeDurationSec: 0.2,
        windowCornerRadius: 13,
        scratchpadTileByDefault: false, scratchpadRegionInset: 0.03,
        restoreLayoutOnLaunch: true)

    private let tolerantFields = [
        "focusFollowsMouse", "hyprKey", "excludedBundleIDs", "showMenuBarIndicator",
        "maxSplitsPerMonitor", "disabledMonitors", "showFocusBorder",
        "focusBorderColorHex", "floatingBorderColorHex", "focusBracketColorHex",
        "focusBracketRadius", "focusBracketThickness", "focusBracketLength",
        "dimInactiveWindows", "dimIntensity", "mouseHoverPollHz", "chromeFadeDurationSec",
        "windowCornerRadius", "scratchpadTileByDefault", "scratchpadRegionInset",
        "restoreLayoutOnLaunch",
    ]

    private func jsonObject(_ saved: SavedConfig) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
    }

    private func decode(_ object: [String: Any]) throws -> SavedConfig {
        try JSONDecoder().decode(SavedConfig.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testUnknownHyprKeyKeepsEveryOtherSetting() throws {
        var object = try jsonObject(fullConfig)
        object["hyprKey"] = "rightFn"

        let saved = try decode(object)

        XCTAssertNil(saved.hyprKey)
        XCTAssertEqual(saved.hyprKey ?? UserConfigDefaults.hyprKey, .capsLock)
        XCTAssertEqual(saved.keybinds, fullConfig.keybinds)
        XCTAssertEqual(saved.gapSize, 12)
        XCTAssertEqual(saved.excludedBundleIDs, ["com.apple.FaceTime"])
        XCTAssertEqual(saved.focusBorderColorHex, "007AFF")
        XCTAssertEqual(saved.dimIntensity, 0.17)
        XCTAssertEqual(saved.overlayAppearance, .dark)
        XCTAssertEqual(saved.restoreLayoutOnLaunch, true)
        object.removeValue(forKey: "hyprKey")
        XCTAssertEqual(try jsonObject(saved) as NSDictionary, object as NSDictionary)
    }

    func testEachOptionalFieldDropsOnlyItselfWhenUnreadable() throws {
        let original = try jsonObject(fullConfig)
        XCTAssertEqual(Set(tolerantFields).subtracting(original.keys), [],
                       "the fixture must set every tolerant field")

        // an object is the wrong type for every field. the rest are changes a
        // newer build or a hand edit could plausibly make.
        var cases: [(String, Any)] = tolerantFields.map { ($0, ["future": "value"]) }
        cases += [
            ("hyprKey", "rightFn"),
            ("hyprKey", 3),
            ("mouseHoverPollHz", 119.5),
            ("excludedBundleIDs", [42]),
            ("maxSplitsPerMonitor", ["Display A": "four"]),
            ("dimIntensity", "0.2"),
            ("showFocusBorder", "yes"),
            ("focusBorderColorHex", 0x007AFF),
        ]
        for (key, bad) in cases {
            var object = original
            object[key] = bad
            let saved = try decode(object)
            var expected = original
            expected.removeValue(forKey: key)
            XCTAssertEqual(try jsonObject(saved) as NSDictionary, expected as NSDictionary,
                           "\(key) = \(bad)")
        }
    }

    func testTolerantDecodeRoundTripIsByteStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let first = try encoder.encode(fullConfig)
        XCTAssertEqual(try encoder.encode(JSONDecoder().decode(SavedConfig.self, from: first)), first)

        // once the unreadable fields drop, the next save/load cycle is stable
        var object = try jsonObject(fullConfig)
        object["hyprKey"] = "rightFn"
        object["dimIntensity"] = ["future": "value"]
        let dropped = try encoder.encode(decode(object))
        XCTAssertEqual(try encoder.encode(JSONDecoder().decode(SavedConfig.self, from: dropped)), dropped)
    }

    func testEveryHyprKeyRoundTripsByteStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for key in HyprKey.allCases {
            var object = try jsonObject(fullConfig)
            object["hyprKey"] = key.rawValue
            let first = try encoder.encode(decode(object))
            let again = try JSONDecoder().decode(SavedConfig.self, from: first)
            XCTAssertEqual(again.hyprKey, key)
            XCTAssertEqual(try encoder.encode(again), first, key.rawValue)
        }
    }

    func testCoreFieldsStayStrict() throws {
        let cases: [(String, Any)] = [
            ("gapSize", "8"), ("outerPadding", "8"), ("enabled", "yes"), ("version", "2"),
        ]
        for (key, bad) in cases {
            var object = try jsonObject(fullConfig)
            object[key] = bad
            XCTAssertThrowsError(try decode(object), key)
        }
    }

    private let oldFloat = Keybind(keyCode: 17, modifiers: [.hypr, .shift], action: .toggleFloating)
    private let newFloat = Keybind(keyCode: 17, modifiers: .hypr, action: .toggleFloating)
    private let oldFloatingFocus = Keybind(keyCode: 3, modifiers: .hypr, action: .focusFloating)
    private let newFloatingFocus = Keybind(keyCode: 17, modifiers: [.hypr, .shift], action: .focusFloating)

    func testLegacyFloatDecodesUnchangedThenMigratesDuringDefaultMerge() throws {
        let json = #"{"keybinds":[{"keyCode":17,"modifiers":3,"action":{"toggleFloating":{}}}],"gapSize":12,"outerPadding":9,"enabled":false}"#
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
        XCTAssertEqual(saved.keybinds, [oldFloat])
        let merged = UserConfig.mergeNewDefaults(saved: saved.keybinds)
        XCTAssertEqual(merged.filter { $0.action == .toggleFloating }, [newFloat])
        XCTAssertEqual(merged.count, Set(merged.map(\.id)).count)
        XCTAssertEqual(UserConfig.mergeNewDefaults(saved: merged), merged)
        XCTAssertEqual(saved.gapSize, 12)
        XCTAssertEqual(saved.outerPadding, 9)
        XCTAssertFalse(saved.enabled)
        let encoded = try JSONEncoder().encode(merged)
        XCTAssertEqual(try JSONDecoder().decode([Keybind].self, from: encoded), merged)
    }

    func testFloatMigrationPreservesCustomizedKeysAndModifiers() {
        let customs = [
            Keybind(keyCode: 16, modifiers: [.hypr, .shift], action: .toggleFloating),
            Keybind(keyCode: 17, modifiers: [.hypr, .option], action: .toggleFloating),
            Keybind(keyCode: 17, modifiers: [.hypr, .shift, .command], action: .toggleFloating),
            Keybind(keyCode: 17, modifiers: [], action: .toggleFloating), newFloat
        ]
        for custom in customs {
            XCTAssertEqual(UserConfig.mergeNewDefaults(saved: [custom]).filter {
                $0.action == .toggleFloating
            }, [custom])
        }
    }

    func testFloatMigrationLeavesOccupiedTargetChordAlone() {
        let occupant = Keybind(keyCode: 17, modifiers: .hypr, action: .showKeybinds)
        let saved = [oldFloat, occupant]
        XCTAssertEqual(ConfigMigration.migrateToggleFloating(saved: saved), saved)
        let merged = UserConfig.mergeNewDefaults(saved: saved)
        XCTAssertEqual(merged.filter { $0.keyCode == 17 }, saved)
        XCTAssertEqual(merged.count, Set(merged.map(\.id)).count)
        XCTAssertFalse(UserConfig.mergeNewDefaults(saved: [occupant]).contains { $0.action == .toggleFloating })
    }

    func testFloatMigrationPreservesMultipleBindingsAndAmbiguousOldChord() {
        let custom = Keybind(keyCode: 16, modifiers: .hypr, action: .toggleFloating)
        let sameChord = Keybind(keyCode: 17, modifiers: [.hypr, .shift], action: .showKeybinds)
        for saved in [[oldFloat, newFloat], [oldFloat, custom], [oldFloat, oldFloat], [oldFloat, sameChord]] {
            XCTAssertEqual(ConfigMigration.migrateToggleFloating(saved: saved), saved)
        }
    }

    func testFloatMigrationPreservesOrderAndUnrelatedBindings() {
        let unrelated = Keybind(keyCode: 16, modifiers: .command, action: .toggleSplit)
        XCTAssertEqual(ConfigMigration.migrateToggleFloating(saved: [unrelated, oldFloat]), [unrelated, newFloat])
        XCTAssertEqual(ConfigMigration.migrateToggleFloating(saved: []), [])
    }

    func testFloatingFocusMigrationFreesHyprFForEmptyWorkspaceAction() {
        let unrelated = Keybind(keyCode: 16, modifiers: .command, action: .toggleSplit)
        let merged = UserConfig.mergeNewDefaults(saved: [unrelated, oldFloatingFocus])

        XCTAssertEqual(merged.filter { $0.action == .focusFloating }, [newFloatingFocus])
        XCTAssertTrue(merged.contains {
            $0.keyCode == 3 && $0.modifiers == .hypr
                && $0.action == .moveToNextEmptyWorkspace
        })
        XCTAssertEqual(merged.first, unrelated)
        XCTAssertEqual(UserConfig.mergeNewDefaults(saved: merged), merged)
    }

    func testToggleMigrationRunsBeforeFloatingFocusMigration() {
        let merged = UserConfig.mergeNewDefaults(saved: [oldFloat, oldFloatingFocus])

        XCTAssertEqual(merged.filter { $0.action == .toggleFloating }, [newFloat])
        XCTAssertEqual(merged.filter { $0.action == .focusFloating }, [newFloatingFocus])
        XCTAssertTrue(merged.contains { $0.action == .moveToNextEmptyWorkspace })
        XCTAssertEqual(merged.count, Set(merged.map(\.id)).count)
    }

    func testFloatingFocusMigrationPreservesCustomAndAmbiguousBindings() {
        let custom = Keybind(keyCode: 4, modifiers: [.hypr, .option], action: .focusFloating)
        let sameOldChord = Keybind(keyCode: 3, modifiers: .hypr, action: .showKeybinds)
        let existingNewAction = Keybind(keyCode: 5, modifiers: .command,
                                        action: .moveToNextEmptyWorkspace)
        for saved in [
            [custom],
            [oldFloatingFocus, custom],
            [oldFloatingFocus, oldFloatingFocus],
            [oldFloatingFocus, sameOldChord],
            [oldFloatingFocus, existingNewAction],
        ] {
            XCTAssertEqual(ConfigMigration.migrateFocusFloating(saved: saved), saved)
        }
    }

    func testFloatingFocusMigrationLeavesOccupiedTargetAndHyprFAlone() {
        let targetOccupant = Keybind(keyCode: 17, modifiers: [.hypr, .shift],
                                     action: .showKeybinds)
        let saved = [oldFloatingFocus, targetOccupant]

        XCTAssertEqual(ConfigMigration.migrateFocusFloating(saved: saved), saved)
        let merged = UserConfig.mergeNewDefaults(saved: saved)
        XCTAssertEqual(merged.filter { $0.keyCode == 3 && $0.modifiers == .hypr },
                       [oldFloatingFocus])
        XCTAssertFalse(merged.contains { $0.action == .moveToNextEmptyWorkspace })
    }

    func testWorkspaceTenDefaultsPreserveOccupiedChordsAndCustomBindings() {
        let customZero = Keybind(keyCode: 29, modifiers: .hypr, action: .showKeybinds)
        let customShiftZero = Keybind(keyCode: 29, modifiers: [.hypr, .shift], action: .toggleSplit)
        let occupied = UserConfig.mergeNewDefaults(saved: [customZero, customShiftZero])
        XCTAssertTrue(occupied.contains(customZero))
        XCTAssertTrue(occupied.contains(customShiftZero))
        XCTAssertFalse(occupied.contains { $0.action == .switchWorkspace(10) })
        XCTAssertFalse(occupied.contains { $0.action == .moveToWorkspace(10) })

        let customSwitch = Keybind(keyCode: 12, modifiers: [.hypr, .option], action: .switchWorkspace(10))
        let customMove = Keybind(keyCode: 12, modifiers: [.hypr, .option, .shift], action: .moveToWorkspace(10))
        let customized = UserConfig.mergeNewDefaults(saved: [customSwitch, customMove])
        XCTAssertEqual(customized.filter { $0.action == .switchWorkspace(10) }, [customSwitch])
        XCTAssertEqual(customized.filter { $0.action == .moveToWorkspace(10) }, [customMove])
        XCTAssertEqual(UserConfig.mergeNewDefaults(saved: customized), customized)
    }

    func testScratchpadTilesNewMembersByDefault() {
        XCTAssertTrue(UserConfigDefaults.scratchpadTileByDefault)
        XCTAssertTrue(SavedConfig.empty.scratchpadTileByDefault == true)
    }

    func testExplicitFloatingScratchpadPreferenceRoundTrips() throws {
        var json = try JSONEncoder().encode(SavedConfig.empty)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        object["scratchpadTileByDefault"] = false
        json = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(SavedConfig.self, from: json)
        XCTAssertEqual(decoded.scratchpadTileByDefault, false)
    }

    func testScratchpadEntryModeUsesDefaultAndPreservesExistingMembers() {
        XCTAssertEqual(ScratchpadController.entryMode(
            isExistingMember: false, tileByDefault: true), .tiled)
        XCTAssertEqual(ScratchpadController.entryMode(
            isExistingMember: false, tileByDefault: false), .floating)
        XCTAssertEqual(ScratchpadController.entryMode(
            isExistingMember: true, tileByDefault: true), .preserve)
        XCTAssertEqual(ScratchpadController.entryMode(
            isExistingMember: true, tileByDefault: false), .preserve)
    }

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
        XCTAssertNil(saved.windowCornerRadius)
        XCTAssertNil(saved.focusBracketStyle)
        XCTAssertNil(saved.focusBracketColorHex)
        XCTAssertNil(saved.focusBracketRadius)
        XCTAssertNil(saved.scratchpadTileByDefault)
        XCTAssertNil(saved.scratchpadRegionInset)
    }

    func testSavedConfigRoundTripsFullPayload() throws {
        let original = SavedConfig(
            version: nil,
            keybinds: [Keybind(keyCode: 18, modifiers: .hypr, action: .switchWorkspace(1))],
            gapSize: 8, outerPadding: 8, enabled: true,
            focusFollowsMouse: true, hyprKey: .capsLock,
            excludedBundleIDs: ["com.apple.FaceTime"],
            showMenuBarIndicator: true,
            maxSplitsPerMonitor: nil, disabledMonitors: nil,
            showFocusBorder: true,
            focusBorderColorHex: "007AFF", floatingBorderColorHex: nil,
            focusBracketStyle: .rounded, focusBracketColorHex: "FFFFFF",
            focusBracketRadius: 8,
            focusBracketThickness: 4.5,
            dimInactiveWindows: true, dimIntensity: 0.5,
            mouseHoverPollHz: nil, chromeFadeDurationSec: nil,
            windowCornerRadius: 13,
            scratchpadTileByDefault: true, scratchpadRegionInset: 0.03)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SavedConfig.self, from: data)
        XCTAssertEqual(decoded.keybinds.first?.action, .switchWorkspace(1))
        XCTAssertEqual(decoded.focusFollowsMouse, true)
        XCTAssertEqual(decoded.hyprKey, .capsLock)
        XCTAssertEqual(decoded.excludedBundleIDs, ["com.apple.FaceTime"])
        XCTAssertEqual(decoded.dimIntensity, 0.5)
        XCTAssertEqual(decoded.focusBorderColorHex, "007AFF")
        XCTAssertEqual(decoded.focusBracketStyle, .rounded)
        XCTAssertEqual(decoded.focusBracketColorHex, "FFFFFF")
        XCTAssertEqual(decoded.focusBracketRadius, 8)
        XCTAssertEqual(decoded.focusBracketThickness, 4.5)
        XCTAssertEqual(decoded.windowCornerRadius, 13)
        XCTAssertEqual(decoded.scratchpadTileByDefault, true)
        XCTAssertEqual(decoded.scratchpadRegionInset, 0.03)
    }

    // MARK: - monitor-config migration

    func testResolveMonitorConfigPrefersLocalFile() {
        let local = SavedMonitorConfig(
            maxSplitsPerMonitor: ["Display A": 4],
            disabledMonitors: ["Display B"])
        let embedded = SavedConfig(
            version: nil, keybinds: [], gapSize: 8, outerPadding: 8, enabled: true,
            focusFollowsMouse: nil, hyprKey: nil, excludedBundleIDs: nil,
            showMenuBarIndicator: nil,
            maxSplitsPerMonitor: ["Old": 99], disabledMonitors: ["Old"],
            showFocusBorder: nil, focusBorderColorHex: nil,
            floatingBorderColorHex: nil, focusBracketStyle: nil, focusBracketColorHex: nil,
            focusBracketRadius: nil,
            focusBracketThickness: nil,
            dimInactiveWindows: nil, dimIntensity: nil,
            mouseHoverPollHz: nil, chromeFadeDurationSec: nil,
            windowCornerRadius: nil,
            scratchpadTileByDefault: nil, scratchpadRegionInset: nil)
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
            showMenuBarIndicator: nil,
            maxSplitsPerMonitor: ["DELL U2723QE": 2],
            disabledMonitors: ["External"],
            showFocusBorder: nil, focusBorderColorHex: nil,
            floatingBorderColorHex: nil, focusBracketStyle: nil, focusBracketColorHex: nil,
            focusBracketRadius: nil,
            focusBracketThickness: nil,
            dimInactiveWindows: nil, dimIntensity: nil,
            mouseHoverPollHz: nil, chromeFadeDurationSec: nil,
            windowCornerRadius: nil,
            scratchpadTileByDefault: nil, scratchpadRegionInset: nil)
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
            showMenuBarIndicator: nil,
            maxSplitsPerMonitor: nil, disabledMonitors: nil,
            showFocusBorder: nil, focusBorderColorHex: nil,
            floatingBorderColorHex: nil, focusBracketStyle: nil, focusBracketColorHex: nil,
            focusBracketRadius: nil,
            focusBracketThickness: nil,
            dimInactiveWindows: nil, dimIntensity: nil,
            mouseHoverPollHz: nil, chromeFadeDurationSec: nil,
            windowCornerRadius: nil,
            scratchpadTileByDefault: nil, scratchpadRegionInset: nil)
        let r = ConfigMigration.resolveMonitorConfig(local: nil, embedded: embedded)
        XCTAssertFalse(r.needsLocalWrite,
                       "no monitor data anywhere — nothing to write")
    }

    // MARK: - hex color tolerance

    func testFromHexValidSixDigit() {
        XCTAssertNotNil(NSColor.fromHex("007AFF"))
        XCTAssertNotNil(NSColor.fromHex("#007AFF"))  // strip leading hash
    }

    func testWindowCornerRadiusDefaultsPreservePreviousBehavior() {
        XCTAssertEqual(UserConfigDefaults.windowCornerRadius(forOSMajorVersion: 15), 10)
        XCTAssertEqual(UserConfigDefaults.windowCornerRadius(forOSMajorVersion: 26), 16)
        XCTAssertEqual(UserConfigDefaults.windowCornerRadius(forOSMajorVersion: 27), 16)
    }

    func testUnsetWindowCornerRadiusTracksOSVersion() {
        XCTAssertEqual(UserConfigDefaults.resolvedWindowCornerRadius(
            override: nil, forOSMajorVersion: 15), 10)
        XCTAssertEqual(UserConfigDefaults.resolvedWindowCornerRadius(
            override: nil, forOSMajorVersion: 26), 16)
    }

    func testExplicitWindowCornerRadiusOverridesOSDefault() {
        XCTAssertEqual(UserConfigDefaults.resolvedWindowCornerRadius(
            override: 13, forOSMajorVersion: 15), 13)
        XCTAssertEqual(UserConfigDefaults.resolvedWindowCornerRadius(
            override: 13, forOSMajorVersion: 26), 13)
    }

    func testOSDefaultWindowCornerRadiusIsNotPersisted() throws {
        let saved = SavedConfig.empty
        XCTAssertNil(saved.windowCornerRadius)

        let json = String(data: try JSONEncoder().encode(saved), encoding: .utf8)!
        XCTAssertFalse(json.contains("\"windowCornerRadius\""),
                       "OS-default mode must stay adaptive instead of pinning a resolved value: \(json)")
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
