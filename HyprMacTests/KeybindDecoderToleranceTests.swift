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
        XCTAssertEqual(kb.action, .switchDesktop(3))
    }

    func testMoveToDesktopWireFormatDecodes() throws {
        let json = #"{"action":{"moveToDesktop":{"_0":7}},"keyCode":26,"modifiers":3}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .moveToDesktop(7))
    }

    func testMoveWorkspaceToMonitorWireFormatDecodes() throws {
        let json = #"{"action":{"moveWorkspaceToMonitor":{"_0":"left"}},"keyCode":123,"modifiers":9}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .moveWorkspaceToMonitor(.left))
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
        XCTAssertEqual(kb.action, .moveWorkspaceToMonitor(.right))
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
        let kb = Keybind(keyCode: 18, modifiers: .hypr, action: .switchDesktop(1))
        let s = String(data: try JSONEncoder().encode(kb), encoding: .utf8)!
        XCTAssertTrue(s.contains(#""switchDesktop":{"_0":1}"#),
                      "expected switchDesktop key in encoded JSON: \(s)")
    }

    func testEncoderProducesMoveToDesktopKey() throws {
        let kb = Keybind(keyCode: 18, modifiers: [.hypr, .shift], action: .moveToDesktop(2))
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
        XCTAssertEqual(kb.action, .switchDesktop(4))
    }

    func testMoveToWorkspaceAliasDecodesAsMoveToDesktop() throws {
        let json = #"{"action":{"moveToWorkspace":{"_0":5}},"keyCode":23,"modifiers":3}"#
        let kb = try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        XCTAssertEqual(kb.action, .moveToDesktop(5))
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

    // unknown case keys are real bugs (typos, mismatched plugin builds).
    // Action.init(from:) throws so the offending keybind fails to decode.
    // tolerance for skipping the bad keybind without dropping the whole config
    // lands in the ConfigStore extraction (later commit) — for now the
    // decoder's behavior is to throw, and we pin that.

    func testUnknownActionKeyThrows() throws {
        let json = #"{"action":{"deletEverything":{"_0":42}},"keyCode":99,"modifiers":1}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(Keybind.self, from: Data(json.utf8))
        )
    }
}
