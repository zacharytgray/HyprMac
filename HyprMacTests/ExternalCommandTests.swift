import XCTest
@testable import HyprMac

final class ExternalCommandTests: XCTestCase {

    private func parse(_ s: String) -> ExternalCommand? {
        URL(string: s).flatMap(ExternalCommand.parse)
    }

    // MARK: - status bar links

    func testStatusLinksParse() {
        XCTAssertEqual(parse("hyprmac://workspace?n=4"), .workspace(4))
        XCTAssertEqual(parse("hyprmac://workspace/?n=10"), .workspace(10))
        XCTAssertEqual(parse("HYPRMAC://Focus?workspace=1"), .focus(1))
        XCTAssertEqual(parse("hyprmac://focus?workspace=7&x=1"), .focus(7))
        for bad in ["hyprmac://workspace?n=0", "hyprmac://workspace?n=11", "hyprmac://workspace?n=-1",
                    "hyprmac://workspace?n=+4", "hyprmac://workspace?n=4.0", "hyprmac://workspace?n=",
                    "hyprmac://workspace?n=abc", "hyprmac://workspace?n=4&n=5", "hyprmac://workspace",
                    "hyprmac://workspace?workspace=4", "hyprmac://focus?n=4", "hyprmac://close?n=4",
                    "hyprmac://workspace/extra?n=4", "https://workspace?n=4",
                    "hyprmac://workspace?n=99999999999999999999"] {
            XCTAssertNil(parse(bad), bad)
        }
    }

    // MARK: - action links

    func testEveryActionLinkParses() {
        let cases: [(String, Action)] = [
            ("focusDirection?dir=left", .focusDirection(.left)),
            ("swapDirection?dir=right", .swapDirection(.right)),
            ("resizeDirection?dir=up", .resizeDirection(.up)),
            ("moveWindowToMonitor?dir=down", .moveWindowToMonitor(.down)),
            ("switchWorkspace?n=3", .switchWorkspace(3)),
            ("moveToWorkspace?n=10", .moveToWorkspace(10)),
            ("moveToWorkspaceAndFollow?n=1", .moveToWorkspaceAndFollow(1)),
            ("cycleWorkspace?delta=1", .cycleWorkspace(1)),
            ("cycleWorkspace?delta=-1", .cycleWorkspace(-1)),
            ("toggleFloating", .toggleFloating),
            ("toggleSplit", .toggleSplit),
            ("showKeybinds", .showKeybinds),
            ("showWorkspaceOverview", .showWorkspaceOverview),
            ("focusMenuBar", .focusMenuBar),
            ("focusFloating", .focusFloating),
            ("moveToNextEmptyWorkspace", .moveToNextEmptyWorkspace),
            ("toggleMaximize", .toggleMaximize),
            ("closeWindow", .closeWindow),
            ("toggleScratchpad", .toggleScratchpad),
            ("moveToScratchpad", .moveToScratchpad),
            ("toggleTiling", .toggleTiling),
            ("restoreLayout", .restoreLayout),
            ("retileAll", .retileAll),
        ]
        for (link, action) in cases {
            XCTAssertEqual(parse("hyprmac://action/\(link)"), .action(action), link)
        }
        // names and direction values ignore case; unknown query keys are ignored
        XCTAssertEqual(parse("hyprmac://ACTION/CycleWorkspace?delta=1"), .action(.cycleWorkspace(1)))
        XCTAssertEqual(parse("hyprmac://action/focusDirection?dir=LEFT"), .action(.focusDirection(.left)))
        XCTAssertEqual(parse("hyprmac://action/toggleSplit?from=btt"), .action(.toggleSplit))
    }

    // the link names are a public API: adding or renaming one fails here first
    func testLinkNamesArePinned() {
        XCTAssertEqual(ExternalCommand.actionNames, [
            "focusDirection", "swapDirection", "resizeDirection", "moveWindowToMonitor",
            "switchWorkspace", "moveToWorkspace", "moveToWorkspaceAndFollow",
            "cycleWorkspace",
            "toggleFloating", "toggleSplit", "showKeybinds", "showWorkspaceOverview",
            "focusMenuBar", "focusFloating", "moveToNextEmptyWorkspace", "closeWindow",
            "toggleScratchpad", "moveToScratchpad", "toggleTiling", "restoreLayout", "retileAll",
            "toggleMaximize",
        ])
    }

    func testActionsThatRunProgramsOrOverwriteStateHaveNoLink() {
        for name in ["runCommand?label=x&command=/bin/ls", "runCommand", "launchApp?bundleID=com.apple.Safari",
                     "launchApp", "saveLayout"] {
            XCTAssertNil(parse("hyprmac://action/\(name)"), name)
        }
    }

    func testMalformedActionLinksAreNil() {
        for bad in ["hyprmac://action", "hyprmac://action/", "hyprmac://action/unknownThing",
                    // wire keys are not link names
                    "hyprmac://action/switchDesktop?n=3", "hyprmac://action/moveToDesktop?n=3",
                    "hyprmac://action/toggleSplit/extra", "hyprmac://action//toggleSplit",
                    "hyprmac://action/focusDirection", "hyprmac://action/focusDirection?dir=sideways",
                    "hyprmac://action/focusDirection?dir=left&dir=right",
                    "hyprmac://action/switchWorkspace", "hyprmac://action/switchWorkspace?n=0",
                    "hyprmac://action/switchWorkspace?n=11", "hyprmac://action/switchWorkspace?workspace=3",
                    "hyprmac://action/cycleWorkspace", "hyprmac://action/cycleWorkspace?delta=2",
                    "hyprmac://action/cycleWorkspace?delta=+1", "hyprmac://action/cycleWorkspace?delta=0",
                    "https://action/toggleSplit"] {
            XCTAssertNil(parse(bad), bad)
        }
    }

    // MARK: - gates

    func testActionLinksNeedExternalControlAndStatusLinksTakeEither() {
        let action = ExternalCommand.action(.toggleSplit)
        XCTAssertFalse(ExternalCommand.isAllowed(action, externalControl: false, statusExport: false))
        XCTAssertFalse(ExternalCommand.isAllowed(action, externalControl: false, statusExport: true))
        XCTAssertTrue(ExternalCommand.isAllowed(action, externalControl: true, statusExport: false))
        for status in [ExternalCommand.workspace(2), .focus(2)] {
            XCTAssertFalse(ExternalCommand.isAllowed(status, externalControl: false, statusExport: false))
            XCTAssertTrue(ExternalCommand.isAllowed(status, externalControl: false, statusExport: true))
            XCTAssertTrue(ExternalCommand.isAllowed(status, externalControl: true, statusExport: false))
        }
    }

    // keybinds and links share this rule, so they can't drift apart
    func testOnlyPauseAndTheOverlaysRunWhilePaused() {
        XCTAssertTrue(WindowManager.runsWhilePaused(.toggleTiling))
        XCTAssertTrue(WindowManager.runsWhilePaused(.showKeybinds))
        XCTAssertTrue(WindowManager.runsWhilePaused(.showWorkspaceOverview))
        for action: Action in [.switchWorkspace(1), .cycleWorkspace(1), .closeWindow, .toggleScratchpad, .retileAll] {
            XCTAssertFalse(WindowManager.runsWhilePaused(action), "\(action)")
        }
    }

    // MARK: - setting

    func testSettingRoundTripsThroughMonitorConfigAndOffWritesNoKey() throws {
        let saved = try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(#"""
        {"maxSplitsPerMonitor":{},"disabledMonitors":[],"externalControlEnabled":true}
        """#.utf8))
        XCTAssertEqual(saved.externalControlEnabled, true)
        let reloaded = try JSONDecoder().decode(SavedMonitorConfig.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(reloaded.externalControlEnabled, true)

        let off = SavedMonitorConfig(maxSplitsPerMonitor: nil, disabledMonitors: nil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(off)) as? [String: Any])
        XCTAssertNil(object["externalControlEnabled"])

        // a bad hand edit costs only this field
        let bad = try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(#"""
        {"maxSplitsPerMonitor":{"DELL":2},"externalControlEnabled":"yes"}
        """#.utf8))
        XCTAssertNil(bad.externalControlEnabled)
        XCTAssertEqual(bad.maxSplitsPerMonitor, ["DELL": 2])
    }
}
