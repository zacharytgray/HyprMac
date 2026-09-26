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
        let json = #"{"action":{"toggleFloating":{}},"keyCode":17,"modifiers":1}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .toggleFloating)
    }

    func testToggleSplitWireFormatDecodes() throws {
        let json = #"{"action":{"toggleSplit":{}},"keyCode":38,"modifiers":1}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .toggleSplit)
    }

    func testRunCommandWireFormatDecodes() throws {
        let json = #"{"action":{"runCommand":{"label":"Screenshot","command":"/usr/sbin/screencapture -i ~/Desktop/shot.png"}},"keyCode":1,"modifiers":1}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .runCommand(label: "Screenshot",
                                              command: "/usr/sbin/screencapture -i ~/Desktop/shot.png"))
        XCTAssertEqual(kb.keyCode, 1)
    }

    func testRunCommandMissingLabelDecodesAsEmpty() throws {
        // a hand-edited config may omit the label; that is not an error
        let json = #"{"action":{"runCommand":{"command":"/usr/bin/true"}},"keyCode":1,"modifiers":1}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .runCommand(label: "", command: "/usr/bin/true"))
    }

    func testRunCommandMissingCommandThrows() {
        // no command means no action — same treatment launchApp gives a
        // missing bundleID
        let json = #"{"action":{"runCommand":{"label":"Screenshot"}},"keyCode":1,"modifiers":1}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Keybind.self, from: Data(json.utf8)))
    }

    func testRunCommandEncodesLabelAndCommandKeys() throws {
        let kb = Keybind(keyCode: 1, modifiers: .hypr,
                         action: .runCommand(label: "Screenshot", command: "/usr/bin/true -x"))
        let s = String(data: try JSONEncoder().encode(kb), encoding: .utf8)!
        XCTAssertTrue(s.contains(#""runCommand":{"#), "expected runCommand key in: \(s)")
        XCTAssertTrue(s.contains(#""label":"Screenshot""#), "expected label key in: \(s)")
        XCTAssertTrue(s.contains(#""command":"\/usr\/bin\/true -x""#)
                      || s.contains(#""command":"/usr/bin/true -x""#),
                      "expected command key in: \(s)")
    }

    func testRunCommandRoundTripsThroughSavedConfig() throws {
        let kb = Keybind(keyCode: 1, modifiers: [.hypr, .shift],
                         action: .runCommand(label: "", command: #"/usr/bin/true "two words""#))
        let json = """
        {"keybinds":[\(String(data: try JSONEncoder().encode(kb), encoding: .utf8)!)],
         "gapSize":8,"outerPadding":8,"enabled":true}
        """
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
        XCTAssertEqual(saved.keybinds.count, 1)
        // re-encode the whole config and read it back — the shape has to be
        // stable across a save/load cycle, not just one decode
        let reloaded = try JSONDecoder().decode(
            SavedConfig.self, from: try JSONEncoder().encode(saved))
        XCTAssertEqual(reloaded.keybinds.first?.action, kb.action)
        XCTAssertEqual(reloaded.keybinds.first?.keyCode, kb.keyCode)
        XCTAssertEqual(reloaded.keybinds.first?.modifiers, kb.modifiers)
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

    func testMoveToNextEmptyWorkspaceWireFormatDecodes() throws {
        let json = #"{"action":{"moveToNextEmptyWorkspace":{}},"keyCode":3,"modifiers":1}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .moveToNextEmptyWorkspace)
        XCTAssertEqual(kb.keyCode, 3)
        XCTAssertEqual(kb.modifiers, .hypr)
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

    func testLayoutSnapshotWireFormatsDecode() throws {
        let save = #"{"action":{"saveLayout":{}},"keyCode":1,"modifiers":1}"#
        let restore = #"{"action":{"restoreLayout":{}},"keyCode":15,"modifiers":1}"#
        XCTAssertEqual(try JSONDecoder().decode(Keybind.self, from: Data(save.utf8)).action, .saveLayout)
        XCTAssertEqual(try JSONDecoder().decode(Keybind.self, from: Data(restore.utf8)).action, .restoreLayout)
    }

    func testLayoutSnapshotActionsRoundTripThroughSavedConfig() throws {
        let binds = [Keybind(keyCode: 1, modifiers: [.hypr, .control], action: .saveLayout),
                     Keybind(keyCode: 15, modifiers: [.hypr, .control], action: .restoreLayout)]
        let encoded = try binds.map { String(data: try JSONEncoder().encode($0), encoding: .utf8)! }
        XCTAssertTrue(encoded[0].contains(#""saveLayout":{}"#), encoded[0])
        XCTAssertTrue(encoded[1].contains(#""restoreLayout":{}"#), encoded[1])
        let json = """
        {"keybinds":[\(encoded.joined(separator: ","))],"gapSize":8,"outerPadding":8,"enabled":true}
        """
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
        let reloaded = try JSONDecoder().decode(SavedConfig.self, from: try JSONEncoder().encode(saved))
        XCTAssertEqual(reloaded.keybinds.map(\.action), [.saveLayout, .restoreLayout])
    }

    // a build from before these actions sees an unknown key; it must drop
    // just that bind. this is the shape such a build reads.
    func testUnknownLayoutActionBesideKnownOnesKeepsTheRest() throws {
        let json = """
        {"keybinds":[
            {"action":{"futureLayoutThing":{}},"keyCode":1,"modifiers":1},
            {"action":{"restoreLayout":{}},"keyCode":15,"modifiers":1}
        ],"gapSize":8,"outerPadding":8,"enabled":true,"restoreLayoutOnLaunch":true}
        """
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
        XCTAssertEqual(saved.keybinds.map(\.action), [.restoreLayout])
        XCTAssertEqual(saved.restoreLayoutOnLaunch, true)
    }

    func testMoveToWorkspaceAndFollowWireFormatDecodes() throws {
        let json = #"{"action":{"moveToWorkspaceAndFollow":{"_0":10}},"keyCode":29,"modifiers":11}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .moveToWorkspaceAndFollow(10))
        XCTAssertEqual(kb.keyCode, 29)
        XCTAssertEqual(kb.modifiers, [.hypr, .control, .shift])
    }

    // its own frozen key with the same {"_0": N} payload as moveToDesktop,
    // never the silent move's key
    func testMoveToWorkspaceAndFollowEncodesUnderItsOwnKey() throws {
        let kb = Keybind(keyCode: 20, modifiers: [.hypr, .control, .shift],
                         action: .moveToWorkspaceAndFollow(3))
        let s = String(data: try JSONEncoder().encode(kb), encoding: .utf8)!
        XCTAssertTrue(s.contains(#""moveToWorkspaceAndFollow":{"_0":3}"#), s)
        XCTAssertFalse(s.contains("moveToDesktop"), s)

        let json = #"{"keybinds":[\#(s)],"gapSize":8,"outerPadding":8,"enabled":true}"#
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
        let reloaded = try JSONDecoder().decode(SavedConfig.self, from: try JSONEncoder().encode(saved))
        XCTAssertEqual(reloaded.keybinds, [kb])
    }

    // a build from before this action reads it as an unknown key, the way
    // this build reads the made-up one below. only those binds go: the
    // silent move, the valid follow bind and every setting survive. a follow
    // bind with no workspace number is dropped the same way.
    func testUnknownOrBrokenFollowBindBesideKnownOnesKeepsTheRest() throws {
        let json = """
        {"keybinds":[
            {"action":{"moveToDesktop":{"_0":3}},"keyCode":20,"modifiers":3},
            {"action":{"moveToWorkspaceAndFollowLater":{"_0":3}},"keyCode":21,"modifiers":11},
            {"action":{"moveToWorkspaceAndFollow":{}},"keyCode":23,"modifiers":11},
            {"action":{"moveToWorkspaceAndFollow":{"_0":3}},"keyCode":20,"modifiers":11}
        ],"gapSize":14,"outerPadding":6,"enabled":true,"focusFollowsMouse":false,
          "excludedBundleIDs":["com.apple.FaceTime"]}
        """
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
        XCTAssertEqual(saved.keybinds.map(\.action), [.moveToWorkspace(3), .moveToWorkspaceAndFollow(3)])
        XCTAssertEqual(saved.gapSize, 14)
        XCTAssertEqual(saved.outerPadding, 6)
        XCTAssertEqual(saved.focusFollowsMouse, false)
        XCTAssertEqual(saved.excludedBundleIDs, ["com.apple.FaceTime"])
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
            {"action":{"toggleFloating":{}},"keyCode":17,"modifiers":1},
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
        let kb = Keybind(keyCode: 17, modifiers: .hypr, action: .toggleFloating)
        let s = String(data: try JSONEncoder().encode(kb), encoding: .utf8)!
        XCTAssertTrue(s.contains(#""toggleFloating":{}"#),
                      "expected toggleFloating:{} in encoded JSON: \(s)")
    }

    func testEncoderProducesMoveToNextEmptyWorkspaceKey() throws {
        let kb = Keybind(keyCode: 3, modifiers: .hypr, action: .moveToNextEmptyWorkspace)
        let s = String(data: try JSONEncoder().encode(kb), encoding: .utf8)!
        XCTAssertTrue(s.contains(#""moveToNextEmptyWorkspace":{}"#),
                      "expected moveToNextEmptyWorkspace:{} in encoded JSON: \(s)")
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
            floatingBorderColorHex: nil, focusBracketStyle: nil, focusBracketColorHex: nil,
            focusBracketRadius: nil,
            focusBracketThickness: nil,
            dimInactiveWindows: nil, dimIntensity: nil,
            mouseHoverPollHz: nil, chromeFadeDurationSec: nil,
            windowCornerRadius: nil,
            scratchpadTileByDefault: nil, scratchpadRegionInset: nil)
        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(SavedConfig.self, from: data)
        XCTAssertEqual(decoded.keybinds.count, Keybind.defaults.count)
        XCTAssertEqual(decoded.keybinds.map(\.action), Keybind.defaults.map(\.action))
    }

    // MARK: - documented hand-edit examples

    // the hand-edit section of docs/keybinds-and-actions.md once showed
    // "modifiers": { "rawValue": 1 }. ModifierFlags is an OptionSet with the
    // standard RawRepresentable coding, so the wire format is a bare number.
    // the object form fails that one keybind, and the per-keybind tolerance
    // drops it without a word to the user.
    func testRawValueObjectModifiersAreDropped() throws {
        let documented = #"{ "keyCode": 123, "modifiers": { "rawValue": 1 }, "action": { "focusDirection": { "_0": "left" } } }"#
        XCTAssertThrowsError(try JSONDecoder().decode(Keybind.self, from: Data(documented.utf8)))

        let json = """
        {"keybinds":[\(documented)],"gapSize":8,"outerPadding":8,"enabled":true}
        """
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
        XCTAssertTrue(saved.keybinds.isEmpty)
    }

    // every line of every ```json block in docs/keybinds-and-actions.md must
    // decode: a line with keyCode as a Keybind (alone and inside a config,
    // where the tolerance would hide a bad one), any other line as an Action.
    // this keeps the documented examples from drifting off the wire format.
    func testDocumentedJSONExamplesDecode() throws {
        let doc = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/keybinds-and-actions.md")
        let text = try String(contentsOf: doc, encoding: .utf8)

        var examples: [String] = []
        var inJSONBlock = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inJSONBlock = !inJSONBlock && trimmed == "```json"
                continue
            }
            if inJSONBlock && !trimmed.isEmpty { examples.append(trimmed) }
        }
        XCTAssertGreaterThanOrEqual(examples.count, 8, "found only \(examples.count) examples")

        for example in examples {
            if example.contains(#""keyCode""#) {
                let kb = try JSONDecoder().decode(Keybind.self, from: Data(example.utf8))
                let json = """
                {"keybinds":[\(example)],"gapSize":8,"outerPadding":8,"enabled":true}
                """
                let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
                XCTAssertEqual(saved.keybinds, [kb], example)
            } else {
                XCTAssertNoThrow(try JSONDecoder().decode(Action.self, from: Data(example.utf8)), example)
            }
        }
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
            focusBracketStyle: .rounded, focusBracketColorHex: "FFFFFF",
            focusBracketRadius: 14,
            focusBracketThickness: 3,
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
            "focusBracketStyle", "focusBracketColorHex",
            "focusBracketRadius", "focusBracketThickness",
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
                       Keybind(keyCode: 17, modifiers: .hypr, action: .toggleFloating)],
            gapSize: 8, outerPadding: 8, enabled: true,
            focusFollowsMouse: true, hyprKey: .capsLock,
            excludedBundleIDs: ["com.apple.FaceTime"],
            showMenuBarIndicator: true,
            maxSplitsPerMonitor: nil, disabledMonitors: nil,
            showFocusBorder: true,
            focusBorderColorHex: "007AFF", floatingBorderColorHex: nil,
            focusBracketStyle: .rounded, focusBracketColorHex: nil,
            focusBracketRadius: nil,
            focusBracketThickness: nil,
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
