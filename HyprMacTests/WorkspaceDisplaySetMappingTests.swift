import Cocoa
import XCTest
@testable import HyprMac

// #89: a workspace mapping per set of connected displays, and proof that a
// config without one resolves as it did before
final class WorkspaceDisplaySetMappingTests: XCTestCase {
    private let builtIn = "Built-in Retina Display"
    private let sidecar = "Sidecar Display (AirPlay)"
    private let portable = "ASUS MB16AC"
    private let dell = "DELL U4021QW"
    private let lg = "LG SDQHD"

    // tioan's three setups
    private var docked: DisplaySetWorkspaces {
        DisplaySetWorkspaces(displays: [dell, lg], workspaceMonitors: [dell: [1, 2, 3, 4, 5, 6], lg: [7, 8, 9, 10]])
    }
    private var road: DisplaySetWorkspaces {
        DisplaySetWorkspaces(displays: [builtIn, sidecar],
                             workspaceMonitors: [builtIn: [1, 2, 3, 4, 5, 6], sidecar: [7, 8, 9, 10]])
    }
    private var roadWithBoth: DisplaySetWorkspaces {
        DisplaySetWorkspaces(displays: [portable, builtIn, sidecar],
                             workspaceMonitors: [builtIn: [1, 2, 3, 4], sidecar: [5, 6, 7], portable: [8, 9, 10]])
    }

    private func manager(_ live: @escaping () -> [NSScreen], fallback: [String: [Int]] = [:],
                         perSet: [DisplaySetWorkspaces] = [], disabled: Set<String> = []) -> (WorkspaceManager, DisplayManager) {
        let display = DisplayManager(screenSource: live)
        let manager = WorkspaceManager(displayManager: display)
        manager.disabledMonitors = disabled
        manager.workspaceMonitors = fallback
        manager.workspaceMonitorsPerDisplaySet = perSet
        manager.initializeMonitors()
        return (manager, display)
    }

    // MARK: - per display set

    func testEachSetupUsesItsOwnMapping() {
        let dellScreen = SetScreen(x: 0, name: dell)
        let lgScreen = SetScreen(x: 3840, name: lg)
        let builtInScreen = SetScreen(x: 0, name: builtIn)
        let sidecarScreen = SetScreen(x: 1512, name: sidecar)
        let portableScreen = SetScreen(x: 3000, name: portable)
        var live: [NSScreen] = [dellScreen, lgScreen]
        let (workspaces, display) = manager({ live }, perSet: [docked, road, roadWithBoth])

        XCTAssertEqual(workspaces.workspacesAnchoredTo(dellScreen), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(workspaces.workspacesAnchoredTo(lgScreen), [7, 8, 9, 10])
        workspaces.assignWindow(81, toWorkspace: 8)

        live = [builtInScreen, sidecarScreen]
        display.refresh()
        workspaces.initializeMonitors()
        XCTAssertEqual(workspaces.workspacesAnchoredTo(builtInScreen), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(workspaces.workspacesAnchoredTo(sidecarScreen), [7, 8, 9, 10])
        XCTAssertEqual(workspaces.workspaceForScreen(sidecarScreen), 7)

        live = [builtInScreen, sidecarScreen, portableScreen]
        display.refresh()
        workspaces.initializeMonitors()
        XCTAssertEqual(workspaces.workspacesAnchoredTo(builtInScreen), [1, 2, 3, 4])
        XCTAssertEqual(workspaces.workspacesAnchoredTo(sidecarScreen), [5, 6, 7])
        XCTAssertEqual(workspaces.workspacesAnchoredTo(portableScreen), [8, 9, 10])

        live = [dellScreen, lgScreen]
        display.refresh()
        workspaces.initializeMonitors()
        XCTAssertEqual(workspaces.workspacesAnchoredTo(lgScreen), [7, 8, 9, 10])
        XCTAssertEqual(workspaces.workspaceFor(81), 8, "membership never moves with the homes")
    }

    func testAnEditOnTheRoadLeavesTheDockedMappingIntact() throws {
        let fallback = [dell: [1, 2], lg: [3]]
        let edited = try XCTUnwrap(WorkspaceHomeResolver.editing(
            [1, 2, 3], for: builtIn, connectedNames: [sidecar, builtIn], perSet: [docked], fallback: fallback))
        XCTAssertEqual(edited.first, docked)
        XCTAssertEqual(edited.count, 2)
        // seeded from the fallback's connected monitors: none, so just the edit
        XCTAssertEqual(edited[1], DisplaySetWorkspaces(displays: [builtIn, sidecar], workspaceMonitors: [builtIn: [1, 2, 3]]))

        // a second edit on the road changes only the road entry
        let again = try XCTUnwrap(WorkspaceHomeResolver.editing(
            [3, 4], for: sidecar, connectedNames: [builtIn, sidecar], perSet: edited, fallback: fallback))
        XCTAssertEqual(again, [docked, DisplaySetWorkspaces(displays: [builtIn, sidecar],
                                                            workspaceMonitors: [builtIn: [1, 2], sidecar: [3, 4]])])
    }

    func testAnUnknownSetUsesWorkspaceMonitors() {
        let dellScreen = SetScreen(x: 0, name: dell)
        let hotel = SetScreen(x: 3840, name: "Hotel TV")
        let fallback = [dell: [1, 2, 3], lg: [4, 5]]
        let (workspaces, _) = manager({ [dellScreen, hotel] }, fallback: fallback, perSet: [docked, road])
        XCTAssertEqual(workspaces.mappingInForce(), fallback)
        // the Dell keeps 1–3; the LG's 4 and 5 and the rest use the formula
        XCTAssertEqual(workspaces.workspacesAnchoredTo(dellScreen), [1, 2, 3, 5, 7, 9])
        XCTAssertEqual(workspaces.workspacesAnchoredTo(hotel), [4, 6, 8, 10])

        // no fallback either: the formula
        let (plain, _) = manager({ [dellScreen, hotel] }, perSet: [docked])
        XCTAssertEqual(plain.workspacesAnchoredTo(dellScreen), [1, 3, 5, 7, 9])
    }

    func testTheSetIsNamesInAnyOrderWithSameNamesCountedTwice() {
        XCTAssertEqual(WorkspaceHomeResolver.displaySet([lg, dell]), WorkspaceHomeResolver.displaySet([dell, lg]))
        let twoLGs = DisplaySetWorkspaces(displays: [lg, lg], workspaceMonitors: [lg: [1, 2]])
        XCTAssertEqual(WorkspaceHomeResolver.mapping(forDisplays: [lg], perSet: [twoLGs], fallback: [lg: [3]]), [lg: [3]])
        XCTAssertEqual(WorkspaceHomeResolver.mapping(forDisplays: [lg, lg], perSet: [twoLGs], fallback: [lg: [3]]), [lg: [1, 2]])
        // a subset or superset is a different set
        XCTAssertEqual(WorkspaceHomeResolver.mapping(forDisplays: [dell], perSet: [docked], fallback: [:]), [:])
        XCTAssertEqual(WorkspaceHomeResolver.mapping(forDisplays: [dell, lg, builtIn], perSet: [docked], fallback: [:]), [:])
    }

    // two of one model: their entry applies, and the leftmost takes the name
    func testTwoMonitorsOfOneModel() {
        let first = SetScreen(x: 0, name: lg)
        let second = SetScreen(x: 2000, name: lg)
        let twoLGs = DisplaySetWorkspaces(displays: [lg, lg], workspaceMonitors: [lg: [2, 4]])
        let (workspaces, _) = manager({ [second, first] }, perSet: [twoLGs])
        XCTAssertEqual(workspaces.workspacesAnchoredTo(first), [1, 2, 3, 4, 5, 7, 9])
        XCTAssertEqual(workspaces.workspacesAnchoredTo(second), [6, 8, 10])
    }

    // the set is what is plugged in: turning tiling off on one monitor
    // keeps the same entry in force
    func testADisabledMonitorStillCountsInTheSet() {
        let dellScreen = SetScreen(x: 0, name: dell)
        let lgScreen = SetScreen(x: 3840, name: lg)
        let builtInScreen = SetScreen(x: -1512, name: builtIn)
        let lidOpen = DisplaySetWorkspaces(displays: [builtIn, dell, lg],
                                           workspaceMonitors: [dell: [1, 2, 3], lg: [4, 5, 6]])
        let (workspaces, _) = manager({ [builtInScreen, dellScreen, lgScreen] }, perSet: [docked, lidOpen],
                                      disabled: [builtIn])
        XCTAssertEqual(workspaces.mappingInForce(), lidOpen.workspaceMonitors)
        XCTAssertEqual(workspaces.workspacesAnchoredTo(dellScreen), [1, 2, 3, 7, 9])
        XCTAssertEqual(workspaces.workspacesAnchoredTo(lgScreen), [4, 5, 6, 8, 10])
        XCTAssertEqual(workspaces.workspacesAnchoredTo(builtInScreen), [])
    }

    // an entry wins over the fallback on its own set, even an empty one
    func testAnEntryWinsOverTheFallbackOnItsSet() {
        let fallback = [dell: [7, 8, 9, 10]]
        XCTAssertEqual(WorkspaceHomeResolver.mapping(forDisplays: [lg, dell], perSet: [docked], fallback: fallback),
                       docked.workspaceMonitors)
        let cleared = DisplaySetWorkspaces(displays: [dell, lg], workspaceMonitors: [:])
        XCTAssertEqual(WorkspaceHomeResolver.mapping(forDisplays: [dell, lg], perSet: [cleared], fallback: fallback), [:])
    }

    // MARK: - first edit

    // the seeded entry gives the homes the set had, except the one checkbox,
    // and matches what the same edit did to workspaceMonitors before #89
    func testTheFirstEditOnASetKeepsEveryOtherHome() throws {
        var rng = SeededGenerator(seed: 89)
        var checked = 0
        for _ in 0..<3000 {
            let (connected, disabled) = randomDesk(&rng)
            let enabled = connected.filter { !disabled.contains($0) }
            guard !enabled.isEmpty else { continue }
            let fallback = randomMapping(&rng)
            guard !partAChanges(fallback, enabled: enabled) else { continue }
            let name = enabled.randomElement(using: &rng)!
            var workspaces = Set(fallback[name] ?? [])
            let n = Int.random(in: 1...10, using: &rng)
            if workspaces.contains(n) { workspaces.remove(n) } else { workspaces.insert(n) }

            guard let perSet = WorkspaceHomeResolver.editing(workspaces, for: name, connectedNames: connected,
                                                             perSet: [], fallback: fallback) else {
                return XCTFail("a changed checkbox is an edit")
            }
            XCTAssertEqual(perSet.count, 1)
            let after = WorkspaceHomeResolver.resolve(
                enabledNames: enabled,
                mapping: WorkspaceHomeResolver.mapping(forDisplays: connected, perSet: perSet, fallback: fallback))
            let legacyAfter = LegacyWorkspaceHomeResolver.resolve(
                enabledNames: enabled, mapping: LegacyWorkspaceHomeResolver.setting(workspaces, for: name, in: fallback))
            XCTAssertEqual(after, legacyAfter, "fallback \(fallback) on \(connected) edit \(name) → \(workspaces)")

            // a number checked on two monitors goes to the one edited, as
            // it always did, so only a mapping without those moves one home
            let before = WorkspaceHomeResolver.resolve(enabledNames: enabled, mapping: fallback)
            let shared = WorkspaceHomeResolver.owners(fallback, among: enabled).duplicates
            if shared.isEmpty && !before.mappingIgnored && !after.mappingIgnored {
                let moved = (1...10).filter { before.homes[$0 - 1] != after.homes[$0 - 1] }
                XCTAssertTrue(moved.allSatisfy { $0 == n }, "only ws\(n) may move, moved \(moved)")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 1000)
    }

    func testAnUnchangedCheckboxIsNoEdit() {
        XCTAssertNil(WorkspaceHomeResolver.editing([1, 2], for: dell, connectedNames: [dell, lg],
                                                   perSet: [], fallback: [dell: [2, 1]]))
        XCTAssertNil(WorkspaceHomeResolver.editing([], for: builtIn, connectedNames: [builtIn],
                                                   perSet: [], fallback: [:]))
        XCTAssertNil(WorkspaceHomeResolver.editing(Set(docked.workspaceMonitors[lg]!), for: lg,
                                                   connectedNames: [dell, lg], perSet: [docked], fallback: [:]))
    }

    // MARK: - upgrade equivalence

    // no per-set field: every desk resolves exactly as before #89, except a
    // number under two monitors whose sorts-first one is not here
    func testWithoutPerSetEntriesEveryDeskResolvesAsBefore() {
        var rng = SeededGenerator(seed: 2026)
        var same = 0
        var changed = 0
        for round in 0..<6000 {
            let (connected, disabled) = randomDesk(&rng)
            let enabled = connected.filter { !disabled.contains($0) }
            // every fourth config has no mapping at all, as most users
            let fallback = round % 4 == 0 ? [:] : randomMapping(&rng)
            let inForce = WorkspaceHomeResolver.mapping(forDisplays: connected, perSet: [], fallback: fallback)
            XCTAssertEqual(inForce, fallback)
            let now = WorkspaceHomeResolver.resolve(enabledNames: enabled, mapping: inForce)
            let before = LegacyWorkspaceHomeResolver.resolve(enabledNames: enabled, mapping: fallback)
            if partAChanges(fallback, enabled: enabled) {
                changed += now == before ? 0 : 1
            } else {
                XCTAssertEqual(now, before, "mapping \(fallback) on \(enabled)")
                same += 1
            }
        }
        XCTAssertGreaterThan(same, 4000)
        XCTAssertGreaterThan(changed, 50, "the generator must reach the one intended difference")
    }

    // the same through WorkspaceManager, screens and all, for every subset
    // and order of a three-monitor desk with and without each disabled
    func testWorkspaceManagerHomesMatchTheOldResolverOnEveryLayout() {
        let names = ["Alpha", "Built-in Retina Display", "Zulu"]
        let mappings: [[String: [Int]]] = [
            [:],
            ["Alpha": [1, 2, 3], "Zulu": [4, 5]],
            ["Built-in Retina Display": [6, 7, 8, 9, 10]],
            ["Alpha": Array(1...10)],
            ["Away": [1, 2], "Zulu": [3]],
        ]
        for mapping in mappings {
            for order in permutations(names) {
                for count in 1...3 {
                    let present = Array(order.prefix(count))
                    for disabledName in [nil] + present.map(Optional.some) {
                        let screens = present.enumerated().map { SetScreen(x: CGFloat($0.offset) * 2000, name: $0.element) }
                        let disabled: Set<String> = disabledName.map { [$0] } ?? []
                        let (workspaces, _) = manager({ screens }, fallback: mapping, disabled: disabled)
                        let enabled = screens.filter { !disabled.contains($0.localizedName) }
                        let before = LegacyWorkspaceHomeResolver.resolve(enabledNames: enabled.map(\.localizedName),
                                                                          mapping: mapping)
                        let homes = Constants.workspaceRange.map { workspaces.homeScreenForWorkspace($0) }
                        if enabled.isEmpty {
                            XCTAssertTrue(homes.allSatisfy { $0 == nil })
                            continue
                        }
                        XCTAssertEqual(homes.map { $0?.localizedName }, before.homes.map { enabled[$0].localizedName },
                                       "mapping \(mapping) on \(present) disabled \(disabled)")
                    }
                }
            }
        }
    }

    // Zach's laptop: no mapping, the built-in display alone or with one
    // external, or lid closed on it
    func testAConfigWithNoMappingIsTheFormulaOnEveryLaptopSetup() {
        let setups: [[String]] = [[builtIn], [builtIn, "BL450"], ["BL450"], [builtIn, sidecar], [builtIn, "BL450", sidecar]]
        for setup in setups {
            let screens = setup.enumerated().map { SetScreen(x: CGFloat($0.offset) * 2000, name: $0.element) }
            let (workspaces, _) = manager({ screens })
            let formula = Constants.workspaceRange.map { setup[($0 - 1) % setup.count] }
            XCTAssertEqual(Constants.workspaceRange.map { workspaces.homeScreenForWorkspace($0)?.localizedName }, formula)
            XCTAssertEqual(LegacyWorkspaceHomeResolver.resolve(enabledNames: setup, mapping: [:]).homes,
                           Constants.workspaceRange.map { ($0 - 1) % setup.count })
        }
    }

    // MARK: - monitor-config

    func testPerSetEntriesRoundTripAndAreLeftOutWhenNil() throws {
        let original = SavedMonitorConfig(maxSplitsPerMonitor: nil, disabledMonitors: nil,
                                          workspaceMonitors: [dell: [1]],
                                          workspaceMonitorsPerDisplaySet: [docked, road,
                                                                           DisplaySetWorkspaces(displays: [lg], workspaceMonitors: [:])])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SavedMonitorConfig.self, from: data)
        XCTAssertEqual(decoded.workspaceMonitorsPerDisplaySet, original.workspaceMonitorsPerDisplaySet)
        XCTAssertEqual(decoded.workspaceMonitors, [dell: [1]])

        let none = try JSONEncoder().encode(SavedMonitorConfig(maxSplitsPerMonitor: nil, disabledMonitors: nil))
        XCTAssertFalse(String(decoding: none, as: UTF8.self).contains("workspaceMonitorsPerDisplaySet"))
        XCTAssertNil(try JSONDecoder().decode(SavedMonitorConfig.self, from: none).workspaceMonitorsPerDisplaySet)
    }

    func testABadEntryCostsOnlyItself() throws {
        let json = #"""
        {"workspaceMonitors":{"A":[1]},"maxSplitsPerMonitor":{"A":2},
         "workspaceMonitorsPerDisplaySet":[
          {"displays":["A","B"],"workspaceMonitors":{"A":[1,2]}},
          {"displays":[],"workspaceMonitors":{"A":[1]}},
          {"workspaceMonitors":{"A":[1]}},
          {"displays":["C"]},
          {"displays":["C"],"workspaceMonitors":{"C":[1,"2"]}},
          {"displays":"C","workspaceMonitors":{"C":[1]}},
          null,
          7,
          {"displays":["B","A"],"workspaceMonitors":{"B":[9]}},
          {"displays":["D"],"workspaceMonitors":{}}
         ]}
        """#
        let decoded = try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(json.utf8))
        // the second A+B entry loses to the first
        XCTAssertEqual(decoded.workspaceMonitorsPerDisplaySet, [
            DisplaySetWorkspaces(displays: ["A", "B"], workspaceMonitors: ["A": [1, 2]]),
            DisplaySetWorkspaces(displays: ["D"], workspaceMonitors: [:]),
        ])
        XCTAssertEqual(decoded.workspaceMonitors, ["A": [1]])
        XCTAssertEqual(decoded.maxSplitsPerMonitor, ["A": 2])
    }

    func testAnUnreadablePerSetValueCostsOnlyThatField() throws {
        for value in [#"{"A":[1]}"#, #""x""#, "3"] {
            let json = #"{"workspaceMonitors":{"A":[1]},"disabledMonitors":["B"],"workspaceMonitorsPerDisplaySet":"# + value + "}"
            let decoded = try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(json.utf8))
            XCTAssertNil(decoded.workspaceMonitorsPerDisplaySet, value)
            XCTAssertEqual(decoded.workspaceMonitors, ["A": [1]])
            XCTAssertEqual(decoded.disabledMonitors, ["B"])
        }
        let null = #"{"workspaceMonitorsPerDisplaySet":null}"#
        XCTAssertNil(try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(null.utf8)).workspaceMonitorsPerDisplaySet)
    }

    // MARK: - helpers

    // part A's only intended change: a number listed under two monitors,
    // the one that sorts first is absent or disabled and another is here
    private func partAChanges(_ mapping: [String: [Int]], enabled: [String]) -> Bool {
        let here = Set(enabled)
        for n in 1...10 {
            let listing = mapping.keys.sorted().filter { mapping[$0]!.contains(n) }
            guard listing.count > 1, let first = listing.first else { continue }
            if !here.contains(first) && listing.contains(where: here.contains) { return true }
        }
        return false
    }

    private let pool = ["Alpha", "Built-in Retina Display", "DELL U4021QW", "LG SDQHD", "Zulu"]

    private func randomDesk(_ rng: inout SeededGenerator) -> (connected: [String], disabled: Set<String>) {
        let count = Int.random(in: 1...4, using: &rng)
        // names repeat sometimes: two monitors of one model
        let connected = (0..<count).map { _ in pool.randomElement(using: &rng)! }
        let disabled = Set(connected.filter { _ in Int.random(in: 0..<5, using: &rng) == 0 })
        return (connected, disabled)
    }

    private func randomMapping(_ rng: inout SeededGenerator) -> [String: [Int]] {
        var mapping: [String: [Int]] = [:]
        for name in pool + ["Away"] where Bool.random(using: &rng) {
            let count = Int.random(in: 0...5, using: &rng)
            mapping[name] = (0..<count).map { _ in Int.random(in: 0...11, using: &rng) }
        }
        return mapping
    }

    private func permutations(_ items: [String]) -> [[String]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { i -> [[String]] in
            var rest = items
            let head = rest.remove(at: i)
            return permutations(rest).map { [head] + $0 }
        }
    }
}

// the resolver as it was at 345cea1, before #89. kept verbatim so the
// equivalence tests compare against the real old answer
private enum LegacyWorkspaceHomeResolver {
    static func owners(_ mapping: [String: [Int]],
                       workspaceCount: Int = Constants.workspaceCount) -> (owners: [Int: String], duplicates: [Int]) {
        var owners: [Int: String] = [:]
        var duplicates: Set<Int> = []
        for name in mapping.keys.sorted() {
            for n in Set(mapping[name] ?? []) where (1...workspaceCount).contains(n) {
                if owners[n] == nil { owners[n] = name } else { duplicates.insert(n) }
            }
        }
        return (owners, duplicates.sorted())
    }

    static func resolve(enabledNames: [String], mapping: [String: [Int]],
                        workspaceCount: Int = Constants.workspaceCount) -> WorkspaceHomeResolver.Resolution {
        let count = enabledNames.count
        guard count > 0 else { return .init(homes: [], mappingIgnored: false) }
        let formula = (1...workspaceCount).map { ($0 - 1) % count }
        let owners = owners(mapping, workspaceCount: workspaceCount).owners
        guard !owners.isEmpty else { return .init(homes: formula, mappingIgnored: false) }

        let homes = (1...workspaceCount).map { n in
            owners[n].flatMap { enabledNames.firstIndex(of: $0) } ?? formula[n - 1]
        }
        if Set(homes).count < min(count, workspaceCount) {
            return .init(homes: formula, mappingIgnored: true)
        }
        return .init(homes: homes, mappingIgnored: false)
    }

    static func setting(_ workspaces: Set<Int>, for name: String,
                        in mapping: [String: [Int]]) -> [String: [Int]] {
        var next = mapping.mapValues { $0.filter { !workspaces.contains($0) } }
        next[name] = workspaces.sorted()
        return next.filter { !$0.value.isEmpty }
    }
}

// deterministic, so a failure reproduces
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private final class SetScreen: SyntheticScreen {
    let bounds: NSRect
    let name: String
    init(x: CGFloat, name: String) {
        bounds = NSRect(x: x, y: 0, width: 1500, height: 1000)
        self.name = name
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var frame: NSRect { bounds }
    override var visibleFrame: NSRect { bounds }
    override var localizedName: String { name }
}
