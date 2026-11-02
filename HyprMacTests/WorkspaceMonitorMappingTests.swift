import Cocoa
import XCTest
@testable import HyprMac

// #29: workspaces put on monitors by name, the formula for the rest
final class WorkspaceMonitorMappingTests: XCTestCase {
    private let example = ["Left": [1, 2, 3], "Middle": [4, 5], "Right": [6, 7]]

    private func manager(_ screens: [NSScreen], mapping: [String: [Int]] = [:]) -> WorkspaceManager {
        let manager = WorkspaceManager(displayManager: DisplayManager(screenSource: { screens }))
        manager.workspaceMonitors = mapping
        manager.initializeMonitors()
        return manager
    }

    private func desk() -> (left: MappingScreen, middle: MappingScreen, right: MappingScreen) {
        (MappingScreen(x: 0, name: "Left"), MappingScreen(x: 2000, name: "Middle"), MappingScreen(x: 4000, name: "Right"))
    }

    private func homeNames(_ manager: WorkspaceManager) -> [String?] {
        Constants.workspaceRange.map { manager.homeScreenForWorkspace($0)?.localizedName }
    }

    // MARK: - resolver

    func testNothingConfiguredIsTheFormulaOnOneTwoAndThreeScreens() {
        for count in 1...3 {
            let names = (0..<count).map { "Screen \($0)" }
            let formula = Constants.workspaceRange.map { ($0 - 1) % count }
            XCTAssertEqual(WorkspaceHomeResolver.resolve(enabledNames: names, mapping: [:]),
                           .init(homes: formula, mappingIgnored: false))

            let screens = (0..<count).map { MappingScreen(x: CGFloat($0) * 2000, name: names[$0]) }
            let workspaces = manager(screens)
            XCTAssertEqual(homeNames(workspaces), formula.map { names[$0] })
            for (index, screen) in screens.enumerated() {
                XCTAssertEqual(workspaces.workspacesAnchoredTo(screen),
                               Array(stride(from: index + 1, through: Constants.workspaceCount, by: count)))
            }
        }
    }

    func testTheExampleMappingOnThreeScreens() {
        let (left, middle, right) = desk()
        let workspaces = manager([left, middle, right], mapping: example)
        // 8, 9 and 10 are unmapped and keep their formula homes
        XCTAssertEqual(homeNames(workspaces),
                       ["Left", "Left", "Left", "Middle", "Middle", "Right", "Right", "Middle", "Right", "Left"])
        XCTAssertEqual(workspaces.workspacesAnchoredTo(left), [1, 2, 3, 10])
        XCTAssertEqual(workspaces.workspacesAnchoredTo(middle), [4, 5, 8])
        XCTAssertEqual(workspaces.workspacesAnchoredTo(right), [6, 7, 9])
    }

    func testAMissingOrDisabledMappedMonitorsWorkspacesUseTheFormula() {
        let (left, middle, right) = desk()
        let unplugged = manager([left, right], mapping: example)
        // 4 and 5 fall to the formula over two screens: 4 → right, 5 → left
        XCTAssertEqual(homeNames(unplugged),
                       ["Left", "Left", "Left", "Right", "Left", "Right", "Right", "Right", "Left", "Right"])

        let disabled = WorkspaceManager(displayManager: DisplayManager(screenSource: { [left, middle, right] }))
        disabled.disabledMonitors = ["Middle"]
        disabled.workspaceMonitors = example
        disabled.initializeMonitors()
        XCTAssertEqual(homeNames(disabled), homeNames(unplugged))
        XCTAssertEqual(disabled.workspacesAnchoredTo(middle), [])
    }

    func testANumberUnderTwoMonitorsGoesToTheNameThatSortsFirst() {
        let mapping = ["Bravo": [2, 5], "Alpha": [2, 3]]
        XCTAssertEqual(WorkspaceHomeResolver.owners(mapping).duplicates, [2])
        let alpha = MappingScreen(x: 2000, name: "Alpha")
        let bravo = MappingScreen(x: 0, name: "Bravo")
        let workspaces = manager([bravo, alpha], mapping: mapping)
        XCTAssertTrue(workspaces.homeScreenForWorkspace(2) === alpha)
        XCTAssertTrue(workspaces.homeScreenForWorkspace(3) === alpha)
        XCTAssertTrue(workspaces.homeScreenForWorkspace(5) === bravo)
    }

    func testNumbersOutsideOneToTenAreIgnored() {
        let mapping = ["Right": [0, -1, 11, 99, 3]]
        XCTAssertEqual(WorkspaceHomeResolver.owners(mapping).owners, [3: "Right"])
        let left = MappingScreen(x: 0, name: "Left")
        let right = MappingScreen(x: 2000, name: "Right")
        let workspaces = manager([left, right], mapping: mapping)
        XCTAssertEqual(workspaces.workspacesAnchoredTo(left), [1, 5, 7, 9])
        XCTAssertEqual(workspaces.workspacesAnchoredTo(right), [2, 3, 4, 6, 8, 10])
        XCTAssertNil(workspaces.homeScreenForWorkspace(11))
    }

    // rule 4: a monitor never ends up with nothing, falling back to ws1
    func testAMappingThatEmptiesAMonitorIsIgnoredForThatLayout() {
        let left = MappingScreen(x: 0, name: "Left")
        let right = MappingScreen(x: 2000, name: "Right")
        let everything = ["Left": Array(Constants.workspaceRange)]
        XCTAssertTrue(WorkspaceHomeResolver.resolve(enabledNames: ["Left", "Right"], mapping: everything).mappingIgnored)
        // the evens are right's formula homes; taking them all empties it
        let evens = ["Left": [2, 4, 6, 8, 10]]
        XCTAssertTrue(WorkspaceHomeResolver.resolve(enabledNames: ["Left", "Right"], mapping: evens).mappingIgnored)

        let workspaces = manager([left, right], mapping: evens)
        XCTAssertEqual(workspaces.workspacesAnchoredTo(left), [1, 3, 5, 7, 9])
        XCTAssertEqual(workspaces.workspacesAnchoredTo(right), [2, 4, 6, 8, 10])
        XCTAssertEqual(workspaces.workspaceForScreen(right), 2)

        // the same mapping is fine alone on the left screen
        XCTAssertFalse(WorkspaceHomeResolver.resolve(enabledNames: ["Left"], mapping: evens).mappingIgnored)
    }

    // two displays of one model share a name; the leftmost takes the mapping
    func testASharedNameMapsToTheLeftmostDisplay() {
        let first = MappingScreen(x: 0, name: "LG HDR 4K")
        let second = MappingScreen(x: 2000, name: "LG HDR 4K")
        let workspaces = manager([second, first], mapping: ["LG HDR 4K": [2]])
        XCTAssertTrue(workspaces.homeScreenForWorkspace(2) === first)
        XCTAssertEqual(workspaces.workspacesAnchoredTo(second), [4, 6, 8, 10])
    }

    // MARK: - consumers

    func testNextEmptyWorkspaceWalksTheMappedWorkspaces() {
        let (left, middle, right) = desk()
        let workspaces = manager([left, middle, right], mapping: example)
        XCTAssertEqual(workspaces.nextEmptyWorkspace(after: 1, on: left), 2)
        workspaces.assignWindow(21, toWorkspace: 2)
        XCTAssertEqual(workspaces.nextEmptyWorkspace(after: 1, on: left), 3)
        workspaces.assignWindow(31, toWorkspace: 3)
        XCTAssertEqual(workspaces.nextEmptyWorkspace(after: 1, on: left), 10)
        workspaces.assignWindow(101, toWorkspace: 10)
        XCTAssertNil(workspaces.nextEmptyWorkspace(after: 1, on: left))

        XCTAssertEqual(workspaces.nextEmptyWorkspace(after: 4, on: middle), 5)
        XCTAssertEqual(workspaces.nextEmptyWorkspace(after: 6, on: right), 7)
    }

    func testInitializeMonitorsShowsEachMonitorsLowestMappedWorkspace() {
        let (left, middle, right) = desk()
        let workspaces = manager([left, middle, right], mapping: example)
        XCTAssertEqual(workspaces.workspaceForScreen(left), 1)
        XCTAssertEqual(workspaces.workspaceForScreen(middle), 4)
        XCTAssertEqual(workspaces.workspaceForScreen(right), 6)

        let switched = workspaces.switchWorkspace(5, cursorScreen: left)
        XCTAssertTrue(switched.screen === middle, "a switch lands on the mapped home")
        XCTAssertEqual(workspaces.workspaceForScreen(middle), 5)
    }

    // unplug, replug, remap: homes move, window membership never does
    func testHomesFollowTheLayoutAndTheMappingWhileMembershipStays() {
        let (left, middle, right) = desk()
        var live: [NSScreen] = [left, middle, right]
        let display = DisplayManager(screenSource: { live })
        let workspaces = WorkspaceManager(displayManager: display)
        workspaces.workspaceMonitors = example
        workspaces.initializeMonitors()
        workspaces.assignWindow(41, toWorkspace: 4)
        _ = workspaces.switchWorkspace(5, cursorScreen: middle)

        live = [left, right]
        display.refresh()
        workspaces.initializeMonitors()
        XCTAssertTrue(workspaces.homeScreenForWorkspace(4) === right)
        XCTAssertTrue(workspaces.homeScreenForWorkspace(5) === left)
        XCTAssertEqual(workspaces.workspaceFor(41), 4)

        live = [left, middle, right]
        display.refresh()
        workspaces.initializeMonitors()
        XCTAssertTrue(workspaces.homeScreenForWorkspace(4) === middle)
        XCTAssertEqual(workspaces.workspaceForScreen(middle), 5, "back on what it showed")

        // ws5 moves to the left screen: the middle falls back to its own, 4
        workspaces.workspaceMonitors = WorkspaceHomeResolver.setting([1, 2, 3, 5], for: "Left",
                                                                      in: workspaces.workspaceMonitors)
        workspaces.initializeMonitors()
        XCTAssertTrue(workspaces.homeScreenForWorkspace(5) === left)
        XCTAssertEqual(workspaces.workspaceForScreen(middle), 4)
        XCTAssertEqual(workspaces.workspaceForScreen(left), 1)
        XCTAssertEqual(workspaces.workspaceFor(41), 4)

        // cleared: the formula again
        workspaces.workspaceMonitors = [:]
        workspaces.initializeMonitors()
        XCTAssertEqual(workspaces.workspacesAnchoredTo(middle), [2, 5, 8])
        XCTAssertTrue([2, 5, 8].contains(workspaces.workspaceForScreen(middle)))
    }

    // a mapping change re-homes trees the way a monitor change does
    func testDisplayChangeMigratesATreeToItsMappedHome() {
        let (left, middle, right) = desk()
        let screens: [NSScreen] = [left, middle, right]
        let workspaces = manager(screens)
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { screens }))
        // ws4's formula home on three screens is the left one
        XCTAssertTrue(workspaces.homeScreenForWorkspace(4) === left)
        _ = engine.seedTree([makeWindow(id: 501)], onWorkspace: 4, screen: left)
        XCTAssertEqual(engine.windowIDs(inTreeForWorkspace: 4, screen: left), [501])

        workspaces.workspaceMonitors = example
        workspaces.initializeMonitors()
        engine.handleDisplayChange(currentScreens: screens,
                                   homeScreenForWorkspace: workspaces.homeScreenForWorkspace)

        XCTAssertEqual(engine.windowIDs(inTreeForWorkspace: 4, screen: middle), [501])
        XCTAssertEqual(engine.windowIDs(inTreeForWorkspace: 4, screen: left), [])
    }

    // MARK: - settings toggles

    func testTurningANumberOnTakesItOffEveryOtherMonitor() {
        var mapping: [String: [Int]] = [:]
        mapping = WorkspaceHomeResolver.setting([1, 2, 3], for: "Left", in: mapping)
        mapping = WorkspaceHomeResolver.setting([3, 4], for: "Middle", in: mapping)
        XCTAssertEqual(mapping, ["Left": [1, 2], "Middle": [3, 4]])
        mapping = WorkspaceHomeResolver.setting([1, 2], for: "Away", in: mapping)
        XCTAssertEqual(mapping, ["Away": [1, 2], "Middle": [3, 4]], "a monitor left with nothing drops out")
        mapping = WorkspaceHomeResolver.setting([], for: "Away", in: mapping)
        mapping = WorkspaceHomeResolver.setting([], for: "Middle", in: mapping)
        XCTAssertEqual(mapping, [:])
    }

    // MARK: - monitor-config

    func testMonitorConfigRoundTripsTheMapping() throws {
        let original = SavedMonitorConfig(maxSplitsPerMonitor: ["Left": 4], disabledMonitors: [],
                                          workspaceMonitors: example)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SavedMonitorConfig.self, from: data)
        XCTAssertEqual(decoded.workspaceMonitors, example)
        XCTAssertEqual(decoded.maxSplitsPerMonitor, ["Left": 4])

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["workspaceMonitors"] as? [String: [Int]], example)

        // no mapping is left out, not written as null
        let none = try JSONEncoder().encode(SavedMonitorConfig(maxSplitsPerMonitor: nil, disabledMonitors: nil))
        XCTAssertFalse(String(decoding: none, as: UTF8.self).contains("workspaceMonitors"))
    }

    func testAnUnreadableMappingCostsOnlyItsField() throws {
        let badElement = #"{"maxSplitsPerMonitor":{"A":2},"disabledMonitors":["B"],"workspaceMonitors":{"A":[1,"2"]}}"#
        let decoded = try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(badElement.utf8))
        XCTAssertNil(decoded.workspaceMonitors)
        XCTAssertEqual(decoded.maxSplitsPerMonitor, ["A": 2])
        XCTAssertEqual(decoded.disabledMonitors, ["B"])

        let badShape = #"{"outerPaddingPerMonitor":{"A":{"top":37}},"workspaceMonitors":[1,2,3]}"#
        let shape = try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(badShape.utf8))
        XCTAssertNil(shape.workspaceMonitors)
        XCTAssertEqual(shape.outerPaddingPerMonitor, ["A": EdgePadding(top: 37)])

        let badSplits = #"{"maxSplitsPerMonitor":"x","workspaceMonitors":{"A":[4,5]}}"#
        let other = try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(badSplits.utf8))
        XCTAssertNil(other.maxSplitsPerMonitor)
        XCTAssertEqual(other.workspaceMonitors, ["A": [4, 5]])

        let absent = #"{"maxSplitsPerMonitor":{"A":2}}"#
        XCTAssertNil(try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(absent.utf8)).workspaceMonitors)
    }
}

private final class MappingScreen: SyntheticScreen {
    let bounds: NSRect
    let name: String
    init(x: CGFloat, name: String) {
        bounds = NSRect(x: x, y: 0, width: 2000, height: 1200)
        self.name = name
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var frame: NSRect { bounds }
    override var visibleFrame: NSRect { bounds }
    override var localizedName: String { name }
}
