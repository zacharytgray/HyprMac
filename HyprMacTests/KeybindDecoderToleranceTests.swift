import XCTest
@testable import HyprMac

// KeybindDecoderToleranceTests pin the wire-format contract for user configs.
//
// the JSON shapes here are byte-identical to what shipped in v0.4.2 user
// configs. any decoder change that breaks them breaks every existing user.
//
// these tests also pin phase 6's decoder-hardening behaviors:
//   - malformed direction strings log + fall back to .right (was: crash)
//   - mixed action shapes (with/without payload) coexist in one keybinds array
//   - encoder output stays on the v0.4.2 case keys (switchDesktop/moveToDesktop)
//
// and the per-keybind tolerance in SavedConfig's decoder: one unreadable
// keybind is skipped, the rest of the config survives.

final class KeybindDecoderToleranceTests: XCTestCase {

    // MARK: - real-config wire-format round-trips

    func testFocusDirectionWireFormatDecodes() throws {
        let json = #"{"action":{"focusDirection":{"_0":"left"}},"keyCode":123,"modifiers":1}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .focusDirection(.left))
        XCTAssertEqual(kb.keyCode, 123)
        XCTAssertEqual(kb.modifiers, .hypr)
    }

    func testSwapDirectionWireFormatDecodes() throws {
        let json = #"{"action":{"swapDirection":{"_0":"down"}},"keyCode":125,"modifiers":3}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .swapDirection(.down))
        XCTAssertEqual(kb.modifiers, [.hypr, .shift])
    }

    func testSwitchDesktopWireFormatDecodes() throws {
        let json = #"{"action":{"switchDesktop":{"_0":3}},"keyCode":20,"modifiers":1}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .switchWorkspace(3))
    }

    func testMoveToDesktopWireFormatDecodes() throws {
        let json = #"{"action":{"moveToDesktop":{"_0":7}},"keyCode":26,"modifiers":3}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .moveToWorkspace(7))
    }

    func testMoveWorkspaceToMonitorWireFormatDecodes() throws {
        // legacy wire key — decodes to the repurposed moveWindowToMonitor case
        let json = #"{"action":{"moveWorkspaceToMonitor":{"_0":"left"}},"keyCode":123,"modifiers":9}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .moveWindowToMonitor(.left))
        XCTAssertEqual(kb.modifiers, [.hypr, .control])
    }

    func testToggleFloatingWireFormatDecodes() throws {
        let json = #"{"action":{"toggleFloating":{}},"keyCode":17,"modifiers":3}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .toggleFloating)
    }

    func testToggleSplitWireFormatDecodes() throws {
        let json = #"{"action":{"toggleSplit":{}},"keyCode":38,"modifiers":1}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .toggleSplit)
    }

    func testLaunchAppWireFormatDecodes() throws {
        let json = #"{"action":{"launchApp":{"bundleID":"com.apple.Safari"}},"keyCode":11,"modifiers":1}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .launchApp(bundleID: "com.apple.Safari"))
    }

    func testCycleWorkspaceNegativeWireFormatDecodes() throws {
        let json = #"{"action":{"cycleWorkspace":{"_0":-1}},"keyCode":48,"modifiers":3}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .cycleWorkspace(-1))
    }

    func testFocusMenuBarWireFormatDecodes() throws {
        let json = #"{"action":{"focusMenuBar":{}},"keyCode":50,"modifiers":1}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .focusMenuBar)
    }

    func testFocusFloatingWireFormatDecodes() throws {
        let json = #"{"action":{"focusFloating":{}},"keyCode":3,"modifiers":1}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .focusFloating)
    }

    func testShowKeybindsWireFormatDecodes() throws {
        let json = #"{"action":{"showKeybinds":{}},"keyCode":40,"modifiers":1}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .showKeybinds)
    }

    func testCloseWindowWireFormatDecodes() throws {
        let json = #"{"action":{"closeWindow":{}},"keyCode":13,"modifiers":1}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .closeWindow)
    }

    // MARK: - malformed-direction tolerance (was crash, now log + fallback)

    func testMalformedFocusDirectionFallsBack() throws {
        let json = #"{"action":{"focusDirection":{"_0":"diagonal"}},"keyCode":123,"modifiers":1}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        // does not crash; falls back to .right per the documented contract.
        XCTAssertEqual(kb.action, .focusDirection(.right))
    }

    func testEmptyFocusDirectionFallsBack() throws {
        let json = #"{"action":{"focusDirection":{"_0":""}},"keyCode":123,"modifiers":1}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .focusDirection(.right))
    }

    func testMalformedSwapDirectionFallsBack() throws {
        let json = #"{"action":{"swapDirection":{"_0":"NORTH"}},"keyCode":126,"modifiers":3}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .swapDirection(.right))
    }

    func testMalformedMoveWorkspaceDirectionFallsBack() throws {
        let json = #"{"action":{"moveWorkspaceToMonitor":{"_0":"sideways"}},"keyCode":123,"modifiers":9}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .moveWindowToMonitor(.right))
    }

    // MARK: - mixed-shape arrays

    func testMixedActionShapesInArrayDecode() throws {
        let json = """
        [
            {"action":{"focusDirection":{"_0":"down"}},"keyCode":125,"modifiers":1},
            {"action":{"toggleFloating":{}},"keyCode":17,"modifiers":3},
            {"action":{"cycleWorkspace":{"_0":-1}},"keyCode":48,"modifiers":3},
            {"action":{"launchApp":{"bundleID":"com.apple.Terminal"}},"keyCode":36,"modifiers":1}
        ]
        """
        let kbs = try JSONDecoder().decode([Keybind].self, from: Data(json.utf8))
        XCTAssertEqual(kbs.count, 4)
        XCTAssertEqual(kbs[0].action, .focusDirection(.down))
        XCTAssertEqual(kbs[1].action, .toggleFloating)
        XCTAssertEqual(kbs[2].action, .cycleWorkspace(-1))
        XCTAssertEqual(kbs[3].action, .launchApp(bundleID: "com.apple.Terminal"))
    }

    // MARK: - encoder byte-equality contract

    // these guard the JSON case-key freeze: the encoder must continue producing
    // "switchDesktop" / "moveToDesktop" after the in-code rename to switchWorkspace
    // / moveToWorkspace, so user configs never see noisy churn.

    func testEncoderProducesSwitchDesktopKey() throws {
        let kb = Keybind(keyCode: 18, modifiers: .hypr, action: .switchWorkspace(1))
        let s = String(data: try JSONEncoder().encode(kb), encoding: .utf8)!
        XCTAssertTrue(s.contains(#""switchDesktop":{"_0":1}"#),
                      "expected switchDesktop key in encoded JSON: \(s)")
    }

    func testEncoderProducesMoveToDesktopKey() throws {
        let kb = Keybind(keyCode: 18, modifiers: [.hypr, .shift], action: .moveToWorkspace(2))
        let s = String(data: try JSONEncoder().encode(kb), encoding: .utf8)!
        XCTAssertTrue(s.contains(#""moveToDesktop":{"_0":2}"#),
                      "expected moveToDesktop key in encoded JSON: \(s)")
    }

    func testEncoderProducesFocusDirectionKey() throws {
        let kb = Keybind(keyCode: 123, modifiers: .hypr, action: .focusDirection(.left))
        let s = String(data: try JSONEncoder().encode(kb), encoding: .utf8)!
        XCTAssertTrue(s.contains(#""focusDirection":{"_0":"left"}"#),
                      "expected focusDirection key in encoded JSON: \(s)")
    }

    func testEncoderProducesEmptyObjectForUnitCases() throws {
        let kb = Keybind(keyCode: 17, modifiers: [.hypr, .shift], action: .toggleFloating)
        let s = String(data: try JSONEncoder().encode(kb), encoding: .utf8)!
        XCTAssertTrue(s.contains(#""toggleFloating":{}"#),
                      "expected toggleFloating:{} in encoded JSON: \(s)")
    }

    // MARK: - default keybinds round-trip

    func testAllDefaultKeybindsRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for kb in Keybind.defaults {
            let data = try encoder.encode(kb)
            let decoded = try decoder.decode(Keybind.self, from: data)
            XCTAssertEqual(decoded.keyCode, kb.keyCode)
            XCTAssertEqual(decoded.modifiers, kb.modifiers)
            XCTAssertEqual(decoded.action, kb.action)
        }
    }

    // MARK: - alias-key tolerance

    // the JSON case keys "switchDesktop" / "moveToDesktop" are frozen forever.
    // the in-code rename to switchWorkspace / moveToWorkspace is internal-only.
    // hand-edited configs using the new spellings must still decode — old
    // configs from v0.4.2 must continue decoding indefinitely.

    func testSwitchWorkspaceAliasDecodesAsSwitchDesktop() throws {
        let json = #"{"action":{"switchWorkspace":{"_0":4}},"keyCode":21,"modifiers":1}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .switchWorkspace(4))
    }

    func testMoveToWorkspaceAliasDecodesAsMoveToDesktop() throws {
        let json = #"{"action":{"moveToWorkspace":{"_0":5}},"keyCode":23,"modifiers":3}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .moveToWorkspace(5))
    }

    func testMoveWindowToMonitorAliasDecodes() throws {
        // hand-edited configs may use the new in-code spelling
        let json = #"{"action":{"moveWindowToMonitor":{"_0":"right"}},"keyCode":124,"modifiers":9}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .moveWindowToMonitor(.right))
    }

    func testEncoderProducesMoveWorkspaceToMonitorKey() throws {
        // the legacy wire key is frozen — moveWindowToMonitor must encode
        // under "moveWorkspaceToMonitor" so existing configs see no churn
        let kb = Keybind(keyCode: 124, modifiers: [.hypr, .control], action: .moveWindowToMonitor(.right))
        let s = String(data: try JSONEncoder().encode(kb), encoding: .utf8)!
        XCTAssertTrue(s.contains(#""moveWorkspaceToMonitor":{"_0":"right"}"#),
                      "expected moveWorkspaceToMonitor key in encoded JSON: \(s)")
    }

    func testEncoderDoesNotEmitWorkspaceAliases() throws {
        // canonical form: encoder must always write the v0.4.2 key, never the alias.
        // re-encoding a config decoded via the alias should produce the canonical
        // form so configs converge on stable wire output over time.
        let json = #"{"action":{"switchWorkspace":{"_0":4}},"keyCode":21,"modifiers":1}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        let s = String(data: try JSONEncoder().encode(kb), encoding: .utf8)!
        XCTAssertTrue(s.contains(#""switchDesktop":{"_0":4}"#),
                      "expected canonical switchDesktop key, got: \(s)")
        XCTAssertFalse(s.contains("switchWorkspace"),
                       "encoder must not emit alias keys")
    }

    // MARK: - unknown action keys

    // an unknown case key means this build can't represent the action: a typo
    // in a hand-edited config, or an action a newer build added. Keybind's own
    // decoder throws on it, and that stays true: a single keybind either
    // decodes exactly or not at all.
    //
    // the tolerance lives one level up. SavedConfig decodes its keybinds
    // element by element (see ConfigStore.swift) and drops just the ones that
    // throw, so an unknown action costs the user that one bind instead of
    // their whole config. the tests below pin that.

    func testUnknownActionKeyThrows() throws {
        let json = #"{"action":{"deletEverything":{"_0":42}},"keyCode":99,"modifiers":1}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        )
    }

    // MARK: - SavedConfig per-keybind tolerance

    func testSavedConfigSkipsUnknownActionKeybind() throws {
        // "deletEverything" is what an older build sees when a newer one adds
        // an action. the rest of the config must survive it.
        let json = """
        {"keybinds":[
            {"action":{"deletEverything":{"_0":42}},"keyCode":99,"modifiers":1},
            {"action":{"focusDirection":{"_0":"left"}},"keyCode":123,"modifiers":1}
        ],"gapSize":22,"outerPadding":8,"enabled":true}
        """
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
        XCTAssertEqual(saved.keybinds.count, 1)
        XCTAssertEqual(saved.keybinds.first?.action, .focusDirection(.left))
        XCTAssertEqual(saved.keybinds.first?.keyCode, 123)
        XCTAssertEqual(saved.gapSize, 22)
        XCTAssertEqual(saved.outerPadding, 8)
        XCTAssertEqual(saved.enabled, true)
    }

    func testSavedConfigWithEveryKeybindBadKeepsOtherFields() throws {
        let json = """
        {"keybinds":[
            {"action":{"deletEverything":{"_0":42}},"keyCode":99,"modifiers":1},
            {"action":{"summonKraken":{}},"keyCode":98,"modifiers":1}
        ],"gapSize":22,"outerPadding":4,"enabled":true,
          "excludedBundleIDs":["com.apple.FaceTime"],
          "focusBorderColorHex":"FF00FF","dimIntensity":0.5}
        """
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
        XCTAssertTrue(saved.keybinds.isEmpty)
        XCTAssertEqual(saved.gapSize, 22)
        XCTAssertEqual(saved.outerPadding, 4)
        XCTAssertEqual(saved.excludedBundleIDs, ["com.apple.FaceTime"])
        XCTAssertEqual(saved.focusBorderColorHex, "FF00FF")
        XCTAssertEqual(saved.dimIntensity, 0.5)
    }

    func testSavedConfigSkipsMalformedKeybindElements() throws {
        // elements that aren't keybind objects at all: a number, a string, a
        // null, an object missing keyCode. none of them may abort the decode.
        let json = """
        {"keybinds":[
            42,
            "nonsense",
            null,
            {"action":{"toggleFloating":{}}},
            {"action":{"toggleSplit":{}},"keyCode":38,"modifiers":1}
        ],"gapSize":6,"outerPadding":8,"enabled":false}
        """
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
        XCTAssertEqual(saved.keybinds.count, 1)
        XCTAssertEqual(saved.keybinds.first?.action, .toggleSplit)
        XCTAssertEqual(saved.gapSize, 6)
        XCTAssertEqual(saved.enabled, false)
    }

    func testSavedConfigKeepsEveryGoodKeybind() throws {
        // no bad entries, so the tolerant path must not drop anything.
        let saved = SavedConfig(
            version: nil, keybinds: Keybind.defaults,
            gapSize: 8, outerPadding: 8, enabled: true,
            focusFollowsMouse: nil, hyprKey: nil, excludedBundleIDs: nil,
            showMenuBarIndicator: nil,
            maxSplitsPerMonitor: nil, disabledMonitors: nil,
            showFocusBorder: nil, focusBorderColorHex: nil,
            floatingBorderColorHex: nil, dimInactiveWindows: nil, dimIntensity: nil,
            mouseHoverPollHz: nil, chromeFadeDurationSec: nil,
            windowCornerRadius: nil,
            scratchpadTileByDefault: nil, scratchpadRegionInset: nil)
        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(SavedConfig.self, from: data)
        XCTAssertEqual(decoded.keybinds.count, Keybind.defaults.count)
        XCTAssertEqual(decoded.keybinds.map(\.action), Keybind.defaults.map(\.action))
    }

    // MARK: - SavedConfig wire format is unchanged

    // the custom decoder must not touch what the encoder writes. these pin the
    // key set and the stability of a re-encode, so a renamed or dropped
    // CodingKey shows up here instead of in a user's synced config.

    func testSavedConfigEncodedKeySetUnchanged() throws {
        let saved = SavedConfig(
            version: nil,
            keybinds: [Keybind(keyCode: 18, modifiers: .hypr, action: .switchWorkspace(1))],
            gapSize: 8, outerPadding: 8, enabled: true,
            focusFollowsMouse: true, hyprKey: .capsLock,
            excludedBundleIDs: ["com.apple.FaceTime"],
            showMenuBarIndicator: true,
            maxSplitsPerMonitor: ["Display A": 4], disabledMonitors: ["Display B"],
            showFocusBorder: true,
            focusBorderColorHex: "007AFF", floatingBorderColorHex: "FF9500",
            dimInactiveWindows: true, dimIntensity: 0.5,
            mouseHoverPollHz: 30, chromeFadeDurationSec: 0.15,
            windowCornerRadius: 13,
            scratchpadTileByDefault: true, scratchpadRegionInset: 0.03)
        let data = try JSONEncoder().encode(saved)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(Set(object.keys), [
            "keybinds", "gapSize", "outerPadding", "enabled",
            "focusFollowsMouse", "hyprKey", "excludedBundleIDs", "showMenuBarIndicator",
            "maxSplitsPerMonitor", "disabledMonitors",
            "showFocusBorder", "focusBorderColorHex", "floatingBorderColorHex",
            "dimInactiveWindows", "dimIntensity", "mouseHoverPollHz",
            "chromeFadeDurationSec", "windowCornerRadius",
            "scratchpadTileByDefault", "scratchpadRegionInset",
        ], "encoded key set changed; version stays omitted while it is nil")
    }

    func testSavedConfigEncodeDecodeEncodeIsByteStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let saved = SavedConfig(
            version: nil,
            keybinds: [Keybind(keyCode: 18, modifiers: .hypr, action: .switchWorkspace(1)),
                       Keybind(keyCode: 17, modifiers: [.hypr, .shift], action: .toggleFloating)],
            gapSize: 8, outerPadding: 8, enabled: true,
            focusFollowsMouse: true, hyprKey: .capsLock,
            excludedBundleIDs: ["com.apple.FaceTime"],
            showMenuBarIndicator: true,
            maxSplitsPerMonitor: nil, disabledMonitors: nil,
            showFocusBorder: true,
            focusBorderColorHex: "007AFF", floatingBorderColorHex: nil,
            dimInactiveWindows: true, dimIntensity: 0.5,
            mouseHoverPollHz: 30, chromeFadeDurationSec: 0.15,
            windowCornerRadius: 13,
            scratchpadTileByDefault: true, scratchpadRegionInset: 0.03)
        let first = try encoder.encode(saved)
        let decoded = try JSONDecoder().decode(SavedConfig.self, from: first)
        let second = try encoder.encode(decoded)
        XCTAssertEqual(first, second,
                       "re-encoding a decoded config must be byte-equal: \(String(data: first, encoding: .utf8)!)")
    }
}
