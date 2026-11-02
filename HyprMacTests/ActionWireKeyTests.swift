import XCTest
@testable import HyprMac

// config.json and every synced config hold these keys, so they never change.
// a new Action case will not compile here until it gets a frozen key.
final class ActionWireKeyTests: XCTestCase {
    private static func wireKey(_ action: Action) -> String {
        switch action {
        case .focusDirection: "focusDirection"
        case .swapDirection: "swapDirection"
        case .switchWorkspace: "switchDesktop"
        case .moveToWorkspace: "moveToDesktop"
        case .moveToWorkspaceAndFollow: "moveToWorkspaceAndFollow"
        case .moveWindowToMonitor: "moveWorkspaceToMonitor"
        case .toggleFloating: "toggleFloating"
        case .toggleSplit: "toggleSplit"
        case .showKeybinds: "showKeybinds"
        case .showWorkspaceOverview: "showWorkspaceOverview"
        case .launchApp: "launchApp"
        case .focusMenuBar: "focusMenuBar"
        case .focusFloating: "focusFloating"
        case .moveToNextEmptyWorkspace: "moveToNextEmptyWorkspace"
        case .closeWindow: "closeWindow"
        case .cycleWorkspace: "cycleWorkspace"
        case .toggleScratchpad: "toggleScratchpad"
        case .moveToScratchpad: "moveToScratchpad"
        case .resizeDirection: "resizeDirection"
        case .toggleTiling: "toggleTiling"
        case .runCommand: "runCommand"
        case .saveLayout: "saveLayout"
        case .restoreLayout: "restoreLayout"
        case .retileAll: "retileAll"
        }
    }

    private static let table: [(action: Action, json: String)] = [
        (.focusDirection(.left), #"{"focusDirection":{"_0":"left"}}"#),
        (.swapDirection(.right), #"{"swapDirection":{"_0":"right"}}"#),
        (.switchWorkspace(3), #"{"switchDesktop":{"_0":3}}"#),
        (.moveToWorkspace(4), #"{"moveToDesktop":{"_0":4}}"#),
        (.moveToWorkspaceAndFollow(5), #"{"moveToWorkspaceAndFollow":{"_0":5}}"#),
        (.moveWindowToMonitor(.up), #"{"moveWorkspaceToMonitor":{"_0":"up"}}"#),
        (.toggleFloating, #"{"toggleFloating":{}}"#),
        (.toggleSplit, #"{"toggleSplit":{}}"#),
        (.showKeybinds, #"{"showKeybinds":{}}"#),
        (.showWorkspaceOverview, #"{"showWorkspaceOverview":{}}"#),
        (.launchApp(bundleID: "com.example.app"), #"{"launchApp":{"bundleID":"com.example.app"}}"#),
        (.focusMenuBar, #"{"focusMenuBar":{}}"#),
        (.focusFloating, #"{"focusFloating":{}}"#),
        (.moveToNextEmptyWorkspace, #"{"moveToNextEmptyWorkspace":{}}"#),
        (.closeWindow, #"{"closeWindow":{}}"#),
        (.cycleWorkspace(-1), #"{"cycleWorkspace":{"_0":-1}}"#),
        (.toggleScratchpad, #"{"toggleScratchpad":{}}"#),
        (.moveToScratchpad, #"{"moveToScratchpad":{}}"#),
        (.resizeDirection(.down), #"{"resizeDirection":{"_0":"down"}}"#),
        (.toggleTiling, #"{"toggleTiling":{}}"#),
        (.runCommand(label: "term", command: "ls"), #"{"runCommand":{"command":"ls","label":"term"}}"#),
        (.saveLayout, #"{"saveLayout":{}}"#),
        (.restoreLayout, #"{"restoreLayout":{}}"#),
        (.retileAll, #"{"retileAll":{}}"#),
    ]

    func testTableCoversEveryKeyOnce() {
        XCTAssertEqual(Set(Self.table.map { Self.wireKey($0.action) }).count, Self.table.count)
        XCTAssertEqual(Self.table.count, 24)
    }

    func testEveryActionEncodesToItsFrozenJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for (action, json) in Self.table {
            let encoded = String(decoding: try encoder.encode(action), as: UTF8.self)
            XCTAssertEqual(encoded, json)
            XCTAssertTrue(json.hasPrefix(#"{""# + Self.wireKey(action) + #"":"#), json)
        }
    }

    func testEveryFrozenJSONDecodesToItsAction() throws {
        for (action, json) in Self.table {
            XCTAssertEqual(try JSONDecoder().decode(Action.self, from: Data(json.utf8)), action, json)
        }
    }
}
