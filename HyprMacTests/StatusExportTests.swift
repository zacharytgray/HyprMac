import XCTest
@testable import HyprMac

final class StatusExportTests: XCTestCase {

    // MARK: - settings

    // per machine in monitor-config.json, never in the synced config.json
    private func decode(_ json: String) throws -> SavedMonitorConfig {
        try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(json.utf8))
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    func testSettingsRoundTripThroughSavedMonitorConfig() throws {
        let saved = try decode("""
        {"maxSplitsPerMonitor":{"DELL":2},"disabledMonitors":["LG"],
         "statusExportEnabled":true,"statusHookCommand":"sketchybar --trigger hyprmac_change"}
        """)
        XCTAssertEqual(saved.statusExportEnabled, true)
        XCTAssertEqual(saved.statusHookCommand, "sketchybar --trigger hyprmac_change")
        let reloaded = try JSONDecoder().decode(SavedMonitorConfig.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(reloaded.statusExportEnabled, true)
        XCTAssertEqual(reloaded.statusHookCommand, saved.statusHookCommand)
        XCTAssertEqual(reloaded.maxSplitsPerMonitor, ["DELL": 2])
        XCTAssertEqual(reloaded.disabledMonitors, ["LG"])
    }

    func testMissingSettingsDecodeAsOffAndWriteNoKey() throws {
        let saved = try decode(#"{"maxSplitsPerMonitor":{"DELL":2},"disabledMonitors":[]}"#)
        XCTAssertNil(saved.statusExportEnabled)
        XCTAssertNil(saved.statusHookCommand)
        let object = try jsonObject(saved)
        XCTAssertNil(object["statusExportEnabled"])
        XCTAssertNil(object["statusHookCommand"])
    }

    func testUnreadableSettingsCostOnlyThemselves() throws {
        let saved = try decode("""
        {"maxSplitsPerMonitor":{"DELL":2},"disabledMonitors":["LG"],
         "statusExportEnabled":"yes","statusHookCommand":["sketchybar"]}
        """)
        XCTAssertNil(saved.statusExportEnabled)
        XCTAssertNil(saved.statusHookCommand)
        XCTAssertEqual(saved.maxSplitsPerMonitor, ["DELL": 2])
        XCTAssertEqual(saved.disabledMonitors, ["LG"])

        // and the other way round: a bad monitor field keeps the export on
        let other = try decode("""
        {"maxSplitsPerMonitor":{"DELL":"two"},"disabledMonitors":"LG",
         "statusExportEnabled":true,"statusHookCommand":"sketchybar --trigger hyprmac_change"}
        """)
        XCTAssertNil(other.maxSplitsPerMonitor)
        XCTAssertNil(other.disabledMonitors)
        XCTAssertEqual(other.statusExportEnabled, true)
        XCTAssertEqual(other.statusHookCommand, "sketchybar --trigger hyprmac_change")
    }

    // config.json can sync over iCloud, so the keys must not ride along
    func testSyncedConfigCarriesNoStatusKeys() throws {
        XCTAssertNil(SavedConfig.CodingKeys(stringValue: "statusExportEnabled"))
        XCTAssertNil(SavedConfig.CodingKeys(stringValue: "statusHookCommand"))
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data("""
        {"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true,
         "statusExportEnabled":true,"statusHookCommand":"sketchybar --trigger hyprmac_change"}
        """.utf8))
        let object = try jsonObject(saved)
        XCTAssertNil(object["statusExportEnabled"])
        XCTAssertNil(object["statusHookCommand"])
    }

    // MARK: - snapshot builder

    private typealias Input = StatusSnapshot.Input

    /// Two screens: DELL shows 4, LG shows 2. Workspace 4 holds Ghostty
    /// (focused) and a floating Finder, workspace 7 a ghost, workspace 2 Safari.
    private func input(focused: CGWindowID = 11, names: [String: String] = ["4": "term"]) -> Input {
        Input(
            screens: [.init(name: "DELL", visibleWorkspace: 4), .init(name: "LG", visibleWorkspace: 2)],
            homeScreens: Dictionary(uniqueKeysWithValues: Constants.workspaceRange.map {
                ($0, $0 % 2 == 1 ? "DELL" : "LG")
            }),
            assigned: [4: [11, 12], 7: [70], 2: [20]],
            scratchpad: [90, 91],
            scratchpadVisible: false,
            hidden: [70, 91],
            floating: [12],
            focusedWindowID: focused,
            cursorScreen: "LG",
            apps: [11: .init(name: "Ghostty", bundleID: "com.mitchellh.ghostty"),
                   12: .init(name: "Finder", bundleID: "com.apple.finder"),
                   20: .init(name: "Safari", bundleID: "com.apple.Safari"),
                   70: .init(name: "Mail", bundleID: "com.apple.mail"),
                   90: .init(name: "Notes", bundleID: "com.apple.Notes")],
            names: names)
    }

    private func workspace(_ id: Int, in snapshot: StatusSnapshot) throws -> StatusSnapshot.Workspace {
        try XCTUnwrap(snapshot.workspaces.first { $0.id == id })
    }

    func testFocusedWindowDecidesFocusedWorkspaceAndMonitor() throws {
        let snapshot = StatusSnapshot.build(input())
        XCTAssertEqual(snapshot.version, 1)
        XCTAssertEqual(snapshot.focusedWorkspace, 4)
        XCTAssertEqual(snapshot.focusedMonitor, "DELL")
        XCTAssertEqual(snapshot.monitors, [
            .init(name: "DELL", visibleWorkspace: 4, focused: true),
            .init(name: "LG", visibleWorkspace: 2, focused: false),
        ])
        XCTAssertEqual(try workspace(4, in: snapshot).windows, [
            .init(id: 11, app: "Ghostty", bundleID: "com.mitchellh.ghostty", floating: false, focused: true),
            .init(id: 12, app: "Finder", bundleID: "com.apple.finder", floating: true, focused: false),
        ])
        XCTAssertEqual(try workspace(2, in: snapshot).windows.map(\.focused), [false])
    }

    func testGhostWindowsAreLeftOut() throws {
        let snapshot = StatusSnapshot.build(input())
        XCTAssertEqual(try workspace(7, in: snapshot).windows, [])
        XCTAssertEqual(snapshot.scratchpad, [.init(id: 90, app: "Notes", bundleID: "com.apple.Notes")])
    }

    func testNamesOnlyWhenSet() throws {
        let snapshot = StatusSnapshot.build(input(names: ["4": "term", "2": "  "]))
        XCTAssertEqual(try workspace(4, in: snapshot).name, "term")
        XCTAssertNil(try workspace(2, in: snapshot).name)
        XCTAssertNil(try workspace(1, in: snapshot).name)
        XCTAssertEqual(snapshot.workspaces.map(\.id), Array(Constants.workspaceRange))
        XCTAssertEqual(try workspace(4, in: snapshot).visible, true)
        XCTAssertEqual(try workspace(7, in: snapshot).visible, false)
        XCTAssertEqual(try workspace(7, in: snapshot).monitor, "DELL")

        let json = try XCTUnwrap(String(data: JSONEncoder().encode(snapshot), encoding: .utf8))
        XCTAssertEqual(json.components(separatedBy: "\"name\":\"").count - 1, 2 + 1,
                       "two monitor names and one workspace name, no title anywhere")
        XCTAssertFalse(json.contains("title"))
    }

    // two monitors of the same model can share a name. only the one showing
    // the focused workspace is focused.
    func testSameNamedMonitorsAreNotBothFocused() throws {
        var twins = input()
        twins.screens = [.init(name: "DELL", visibleWorkspace: 4), .init(name: "DELL", visibleWorkspace: 2)]
        twins.focusedWindowID = 20
        let snapshot = StatusSnapshot.build(twins)
        XCTAssertEqual(snapshot.focusedWorkspace, 2)
        XCTAssertEqual(snapshot.monitors.map(\.focused), [false, true])
    }

    // a focused window on a hidden workspace (a switch to an empty one) or a
    // ghost is not focus: the cursor's screen is
    func testFocusFallsBackToCursorScreen() throws {
        for focused: CGWindowID in [70, 0, 999] {
            let snapshot = StatusSnapshot.build(input(focused: focused))
            XCTAssertEqual(snapshot.focusedMonitor, "LG", "focused \(focused)")
            XCTAssertEqual(snapshot.focusedWorkspace, 2)
            XCTAssertFalse(snapshot.workspaces.flatMap(\.windows).contains { $0.focused == true })
        }
    }

    // the menu bar reads the focused screen without app names
    func testFocusedScreenMatchesTheSnapshotWithoutAppNames() {
        for focused: CGWindowID in [11, 20, 70, 0] {
            var bare = input(focused: focused)
            bare.apps = [:]
            XCTAssertEqual(StatusSnapshot.focusedScreen(bare)?.visibleWorkspace,
                           StatusSnapshot.build(input(focused: focused)).focusedWorkspace,
                           "focused \(focused)")
        }
        XCTAssertEqual(StatusSnapshot.focusedScreen(input(focused: 20))?.name, "LG")
        var none = input()
        none.screens = []
        XCTAssertNil(StatusSnapshot.focusedScreen(none))
    }

    func testHookEnvironment() {
        let url = URL(fileURLWithPath: "/tmp/state.json")
        XCTAssertEqual(StatusSnapshot.build(input()).hookEnvironment(stateFile: url), [
            "HYPRMAC_STATE_FILE": "/tmp/state.json",
            "HYPRMAC_FOCUSED_WORKSPACE": "4",
            "HYPRMAC_FOCUSED_WORKSPACE_NAME": "term",
            "HYPRMAC_FOCUSED_MONITOR": "DELL",
        ])
        let unnamed = StatusSnapshot.build(input(focused: 20)).hookEnvironment(stateFile: url)
        XCTAssertEqual(unnamed["HYPRMAC_FOCUSED_WORKSPACE_NAME"], "")
    }

    // MARK: - coalescing

    private final class FakeClock {
        var pending: [(TimeInterval, () -> Void)] = []
        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) { pending.append((delay, work)) }
        func fire() {
            let due = pending
            pending = []
            due.forEach { $0.1() }
        }
    }

    private func exporter(clock: FakeClock, enabled: @escaping () -> Bool = { true },
                          snapshot: @escaping () -> StatusSnapshot,
                          cleared: @escaping (String?, Bool) -> Void = { _, _ in },
                          published: @escaping (StatusSnapshot, String?) -> Void) -> StatusExporter {
        let exporter = StatusExporter(schedule: clock.schedule, publish: published, clear: cleared)
        exporter.isEnabled = enabled
        exporter.snapshot = snapshot
        exporter.hookCommand = { "hook" }
        return exporter
    }

    func testBurstOfChangesPublishesOnceWithTheLatestState() {
        let clock = FakeClock()
        var current = StatusSnapshot.build(input())
        var published: [StatusSnapshot] = []
        let exporter = exporter(clock: clock, snapshot: { current }) { snapshot, hook in
            published.append(snapshot)
            XCTAssertEqual(hook, "hook")
        }

        exporter.noteChange()
        current = StatusSnapshot.build(input(focused: 12))
        exporter.noteChange()
        exporter.noteChange()
        XCTAssertEqual(clock.pending.count, 1)
        XCTAssertEqual(clock.pending.first?.0, StatusExporter.coalesceDelay)
        clock.fire()
        XCTAssertEqual(published, [current])

        // nothing changed: no write, no hook
        exporter.noteChange()
        clock.fire()
        XCTAssertEqual(published.count, 1)

        current = StatusSnapshot.build(input(focused: 20))
        exporter.noteChange()
        clock.fire()
        XCTAssertEqual(published.count, 2)
    }

    func testDisabledExportDoesNothingAndRepublishesWhenTurnedBackOn() {
        let clock = FakeClock()
        var enabled = false
        var published = 0
        let exporter = exporter(clock: clock, enabled: { enabled },
                                snapshot: { StatusSnapshot.build(self.input()) }) { _, _ in published += 1 }

        exporter.noteChange()
        XCTAssertTrue(clock.pending.isEmpty)

        enabled = true
        exporter.noteChange()
        clock.fire()
        XCTAssertEqual(published, 1)

        // turned off while a flush was pending: it publishes nothing
        exporter.noteChange()
        enabled = false
        clock.fire()
        exporter.noteChange()
        enabled = true
        exporter.noteChange()
        clock.fire()
        XCTAssertEqual(published, 2, "the same state is written again after a toggle")
    }

    // pause or quit: the file goes, the hook runs once, and a write still
    // pending can't bring the file back
    func testStopClearsOnceAndDropsThePendingWrite() {
        let clock = FakeClock()
        var current = StatusSnapshot.build(input())
        var published = 0
        var cleared: [(String?, Bool)] = []
        let exporter = exporter(clock: clock, snapshot: { current },
                                cleared: { cleared.append(($0, $1)) }) { _, _ in published += 1 }

        exporter.noteChange()
        clock.fire()
        current = StatusSnapshot.build(input(focused: 12))
        exporter.noteChange()
        exporter.clear(quitting: false)
        XCTAssertEqual(cleared.count, 1)
        XCTAssertEqual(cleared.first?.0, "hook")
        XCTAssertEqual(cleared.first?.1, false)
        clock.fire()
        XCTAssertEqual(published, 1, "the pending write was dropped")

        // a later start writes the same state again
        exporter.noteChange()
        XCTAssertEqual(clock.pending.count, 1)
        clock.fire()
        XCTAssertEqual(published, 2)

        exporter.clear(quitting: true)
        XCTAssertEqual(cleared.last?.1, true)
    }

    func testStopWithExportOffClearsNothing() {
        let clock = FakeClock()
        var cleared = 0
        let exporter = exporter(clock: clock, enabled: { false }, snapshot: { StatusSnapshot.build(self.input()) },
                                cleared: { _, _ in cleared += 1 }) { _, _ in }
        exporter.clear(quitting: false)
        exporter.clear(quitting: true)
        XCTAssertEqual(cleared, 0)
    }

    func testClearedHookEnvironmentHasOnlyTheFile() {
        let url = URL(fileURLWithPath: "/tmp/state.json")
        XCTAssertEqual(StatusSnapshot.hookEnvironment(nil, stateFile: url), [
            "HYPRMAC_STATE_FILE": "/tmp/state.json",
            "HYPRMAC_FOCUSED_WORKSPACE": "",
            "HYPRMAC_FOCUSED_WORKSPACE_NAME": "",
            "HYPRMAC_FOCUSED_MONITOR": "",
        ])
    }

    // at quit the clear runs before returning, so nothing is left to land later
    func testQuitRemovesTheStateFileBeforeReturning() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("state.json")
        let publisher = StatusFilePublisher(stateFile: file)

        publisher.publish(StatusSnapshot.build(input()), hookCommand: nil)
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: file.path), Date() < deadline { usleep(10_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        publisher.clear(hookCommand: nil, quitting: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        // no file to remove is fine too
        publisher.clear(hookCommand: nil, quitting: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - hook runner

    private final class FakeLauncher {
        var launches: [[String: String]] = []
        var exits: [() -> Void] = []
        var kills = 0
        var timers: [() -> Void] = []
        var startFails = false

        lazy var runner = StatusHookRunner(
            launch: { [unowned self] _, environment, onExit in
                guard !self.startFails else { return nil }
                self.launches.append(environment)
                self.exits.append(onExit)
                return { self.kills += 1 }
            },
            after: { [unowned self] delay, work in
                XCTAssertEqual(delay, StatusHookRunner.timeout)
                self.timers.append(work)
            })
    }

    func testOneHookInFlightAndOneRerunWithTheLatestState() {
        let fake = FakeLauncher()
        fake.runner.request(command: "hook", environment: ["N": "1"])
        fake.runner.request(command: "hook", environment: ["N": "2"])
        fake.runner.request(command: "hook", environment: ["N": "3"])
        XCTAssertEqual(fake.launches, [["N": "1"]])

        fake.exits[0]()
        XCTAssertEqual(fake.launches, [["N": "1"], ["N": "3"]])

        fake.exits[1]()
        fake.exits[1]() // a second exit report changes nothing
        XCTAssertEqual(fake.launches.count, 2)

        // the timeout of a run that already ended kills nothing
        fake.timers.forEach { $0() }
        XCTAssertEqual(fake.kills, 0)
    }

    func testHungHookIsKilledAndDoesNotBlockTheNextRun() {
        let fake = FakeLauncher()
        fake.runner.request(command: "hook", environment: ["N": "1"])
        fake.runner.request(command: "hook", environment: ["N": "2"])
        fake.timers[0]()
        XCTAssertEqual(fake.kills, 1)
        XCTAssertEqual(fake.launches, [["N": "1"], ["N": "2"]], "the queued run starts without waiting for the exit")

        // the killed child's late exit doesn't end the run that replaced it
        fake.exits[0]()
        fake.runner.request(command: "hook", environment: ["N": "3"])
        XCTAssertEqual(fake.launches.count, 2)
        fake.exits[1]()
        XCTAssertEqual(fake.launches.last, ["N": "3"])
    }

    func testHookThatNeverStartsLeavesTheRunnerFree() {
        let fake = FakeLauncher()
        fake.startFails = true
        fake.runner.request(command: "missing", environment: [:])
        fake.startFails = false
        fake.runner.request(command: "hook", environment: ["N": "1"])
        XCTAssertEqual(fake.launches, [["N": "1"]])
    }

    // at quit nothing would start a queued run, so the last one starts now
    func testRunNowKillsTheHookInFlightAndStartsAtOnce() {
        let fake = FakeLauncher()
        fake.runner.request(command: "hook", environment: ["N": "1"])
        fake.runner.request(command: "hook", environment: ["N": "2"])
        fake.runner.runNow(command: "hook", environment: ["N": "cleared"])
        XCTAssertEqual(fake.kills, 1)
        XCTAssertEqual(fake.launches, [["N": "1"], ["N": "cleared"]])

        // the killed child's exit and timer don't start the dropped request
        fake.exits[0]()
        fake.timers[0]()
        XCTAssertEqual(fake.launches.count, 2)
        XCTAssertEqual(fake.kills, 1)

        // nothing in flight: it just starts
        let idle = FakeLauncher()
        idle.runner.runNow(command: "hook", environment: ["N": "1"])
        XCTAssertEqual(idle.launches, [["N": "1"]])
        XCTAssertEqual(idle.kills, 0)
    }

    // MARK: - URLs

    func testRepeatFocusCyclesTheWorkspaceWindows() {
        let onFour = StatusSnapshot.build(input(focused: 11))
        XCTAssertEqual(ExternalCommand.nextFocusTarget(on: 4, in: onFour), 12)
        XCTAssertEqual(ExternalCommand.nextFocusTarget(on: 4, in: StatusSnapshot.build(input(focused: 12))), 11)
        // not on that workspace yet: an ordinary switch
        XCTAssertNil(ExternalCommand.nextFocusTarget(on: 2, in: onFour))
        XCTAssertNil(ExternalCommand.nextFocusTarget(on: 7, in: onFour))
        // on it, but no window holds focus
        XCTAssertNil(ExternalCommand.nextFocusTarget(on: 2, in: StatusSnapshot.build(input(focused: 0))))
    }
}
