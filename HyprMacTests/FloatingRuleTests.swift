import XCTest
@testable import HyprMac

// float and tile rules: the wire format and its tolerance, the precedence,
// the one-click capture, the Settings rows, the admission and late-title
// paths in discovery, Toggle Floating, the live re-apply, and the actions.

final class FloatingRuleTests: XCTestCase {

    private let zoom = "us.zoom.xos"
    private let faceTime = "com.apple.FaceTime"
    private let teams = "com.microsoft.teams2"

    // MARK: - wire format

    private func decodeRules(_ json: String) throws -> SavedConfig {
        let config = #"{"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true,"#
            + #""excludedBundleIDs":["com.apple.FaceTime"],"# + json + "}"
        return try JSONDecoder().decode(SavedConfig.self, from: Data(config.utf8))
    }

    func testEveryRuleKindDecodes() throws {
        let saved = try decodeRules(#""floatingRules":["#
            + #"{"bundleID":"us.zoom.xos","action":"float","match":{"titleIs":"Zoom Meeting"}},"#
            + #"{"bundleID":"com.microsoft.teams2","action":"tile","match":{"titleContains":"Meeting"}},"#
            + #"{"bundleID":"com.apple.FaceTime","action":"float","match":{"titleContains":"Call"}},"#
            + #"{"bundleID":"com.apple.FaceTime","action":"tile"}]"#)
        XCTAssertEqual(saved.floatingRules, [
            FloatingRule(bundleID: zoom, action: .float, match: .titleIs("Zoom Meeting")),
            FloatingRule(bundleID: teams, action: .tile, match: .titleContains("Meeting")),
            FloatingRule(bundleID: faceTime, action: .float, match: .titleContains("Call")),
            FloatingRule(bundleID: faceTime, action: .tile),
        ])
        XCTAssertEqual(saved.excludedBundleIDs, [faceTime])
    }

    // one bad rule costs itself, never the other rules or settings
    func testAMalformedRuleIsDroppedAlone() throws {
        let saved = try decodeRules(#""floatingRules":["#
            + #"{"bundleID":"a","action":"hide"},"#
            + #"{"bundleID":"b","action":"float","match":{"titleIs":"x","raised":true}},"#
            + #"{"bundleID":"c","action":"float","match":{"titleIs":""}},"#
            + #"{"bundleID":"d","action":"float","match":{"raised":false}},"#
            + #"{"bundleID":"e","action":"float","match":{"identifier":"x"}},"#
            + #"{"bundleID":"","action":"float"},"#
            + #"null,"#
            + #"{"bundleID":"ok","action":"float","match":{"titleContains":"Meeting"}}]"#)
        XCTAssertEqual(saved.floatingRules, [FloatingRule(bundleID: "ok", action: .float, match: .titleContains("Meeting"))])
    }

    // the stay-on-top match an unreleased build wrote is an unknown key now:
    // the rule drops, it is not read as a whole-app rule or as its title part
    func testARaisedMatchDropsTheRule() throws {
        let saved = try decodeRules(#""floatingRules":["#
            + #"{"bundleID":"com.apple.FaceTime","action":"float","match":{"raised":true}},"#
            + #"{"bundleID":"com.apple.FaceTime","action":"float","match":{"titleIs":"FaceTime","raised":true}},"#
            + #"{"bundleID":"us.zoom.xos","action":"float"}]"#)
        XCTAssertEqual(saved.floatingRules, [FloatingRule(bundleID: zoom, action: .float)])
        XCTAssertEqual(saved.excludedBundleIDs, [faceTime])
        XCTAssertEqual(saved.gapSize, 8)
    }

    // review: "match": null read as a whole-app rule, so a Nix match = null
    // widened a window rule to the app
    func testANullMatchDropsTheRuleInsteadOfCoveringTheApp() throws {
        let saved = try decodeRules(#""floatingRules":["#
            + #"{"bundleID":"com.microsoft.teams2","action":"float","match":null},"#
            + #"{"bundleID":"us.zoom.xos","action":"float"}]"#)
        XCTAssertEqual(saved.floatingRules, [FloatingRule(bundleID: zoom, action: .float)])
    }

    func testAnUnreadableRulesValueCostsOnlyTheRules() throws {
        let saved = try decodeRules(#""floatingRules":{"future":"value"}"#)
        XCTAssertNil(saved.floatingRules)
        XCTAssertEqual(saved.excludedBundleIDs, [faceTime])
    }

    func testAConfigWithoutTheKeyHasNoRules() throws {
        let saved = try decodeRules(#""showMenuBarIndicator":true"#)
        XCTAssertNil(saved.floatingRules)
    }

    func testRulesRoundTrip() throws {
        let rules = [
            FloatingRule(bundleID: zoom, action: .float, match: .titleIs("Zoom Meeting")),
            FloatingRule(bundleID: faceTime, action: .float, match: .titleContains("Call")),
            FloatingRule(bundleID: teams, action: .tile),
        ]
        let data = try JSONEncoder().encode(rules)
        XCTAssertEqual(try JSONDecoder().decode([FloatingRule].self, from: data), rules)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""titleContains":"Call""#), text)
        XCTAssertFalse(text.contains(#""match":null"#), "an app rule writes no match: \(text)")
    }

    // MARK: - config files: upgrade safety

    private func makeStore() -> (ConfigStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloatingRuleTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(localConfigURL: dir.appendingPathComponent("config.json"),
                                monitorConfigURL: dir.appendingPathComponent("monitor-config.json"),
                                iCloudRootURL: dir.appendingPathComponent("cloud", isDirectory: true))
        return (store, dir)
    }

    /// a config with no rules saves without the key, and Never tile as it was
    func testNoRulesWritesNoKey() throws {
        let (store, dir) = makeStore()
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        config.excludedBundleIDs = [faceTime]
        config.save()
        let text = try String(contentsOf: dir.appendingPathComponent("config.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("floatingRules"), text)
        XCTAssertTrue(text.contains(faceTime), text)
    }

    func testRulesPersistAcrossARelaunch() {
        let (store, _) = makeStore()
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        config.addFloatingRule(FloatingRule(bundleID: zoom, action: .float, match: .titleIs("Zoom Meeting")))
        let reloaded = UserConfig(store: store, iCloudSyncEnabled: false)
        XCTAssertEqual(reloaded.floatingRules, config.floatingRules)
        XCTAssertEqual(reloaded.floatingRules.count, 1)
    }

    /// loading, as opening Settings does, writes nothing
    func testLoadingAConfigWritesNothing() throws {
        let (store, dir) = makeStore()
        let url = dir.appendingPathComponent("config.json")
        let original = #"{"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true,"#
            + #""excludedBundleIDs":["com.apple.FaceTime"],"#
            + #""floatingRules":[{"bundleID":"us.zoom.xos","action":"float","match":{"titleIs":"Zoom Meeting"}}]}"#
        try Data(original.utf8).write(to: url)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        _ = FloatingRuleRow.rows(excludedBundleIDs: config.excludedBundleIDs, rules: config.floatingRules)
        _ = config.floatingRuleBook
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }

    // MARK: - precedence

    private func book(_ rules: [FloatingRule], excluded: Set<String> = []) -> FloatingRuleBook {
        FloatingRuleBook(rules: rules, excludedBundleIDs: excluded)
    }

    func testAWindowRuleBeatsNeverTile() {
        let tileMain = FloatingRule(bundleID: faceTime, action: .tile, match: .titleIs("FaceTime"))
        let b = book([tileMain], excluded: [faceTime])
        XCTAssertEqual(b.verdict(bundleID: faceTime, title: { "FaceTime" }), .tile(tileMain))
        XCTAssertEqual(b.verdict(bundleID: faceTime, title: { "Call" }), .float(nil))
    }

    // a hand edit with both: Never tile wins, as before tile rules existed
    func testNeverTileBeatsAnAppTileRule() {
        let b = book([FloatingRule(bundleID: faceTime, action: .tile)], excluded: [faceTime])
        XCTAssertEqual(b.verdict(bundleID: faceTime, title: { nil }), .float(nil))
    }

    func testAnAppTileRuleAndNoRule() {
        let appTile = FloatingRule(bundleID: teams, action: .tile)
        let b = book([appTile])
        XCTAssertEqual(b.verdict(bundleID: teams, title: { nil }), .tile(appTile))
        XCTAssertNil(b.verdict(bundleID: zoom, title: { nil }))
        XCTAssertNil(b.verdict(bundleID: nil, title: { nil }))
    }

    func testTheFirstMatchingWindowRuleWins() {
        let first = FloatingRule(bundleID: teams, action: .tile, match: .titleContains("meeting"))
        let second = FloatingRule(bundleID: teams, action: .float, match: .titleContains("Teams"))
        let b = book([first, second])
        XCTAssertEqual(b.verdict(bundleID: teams, title: { "Weekly Meeting | Teams" }),
                       .tile(first), "contains ignores case, and the earlier rule wins")
        XCTAssertEqual(b.verdict(bundleID: teams, title: { "Chat | Teams" }), .float(second))
    }

    func testTitleIsIsExact() {
        let rule = FloatingRule(bundleID: zoom, action: .float, match: .titleIs("Zoom Meeting"))
        let b = book([rule])
        XCTAssertEqual(b.verdict(bundleID: zoom, title: { "Zoom Meeting" }), .float(rule))
        XCTAssertNil(b.verdict(bundleID: zoom, title: { "Zoom Meeting 2" }))
        XCTAssertNil(b.verdict(bundleID: zoom, title: { nil }))
    }

    // the live reads happen once at most, and only when a rule needs them
    func testTheReadsAreLazyAndOnce() {
        var titleReads = 0
        let b = book([FloatingRule(bundleID: zoom, action: .float, match: .titleIs("a")),
                      FloatingRule(bundleID: zoom, action: .float, match: .titleContains("b"))],
                     excluded: [faceTime])
        _ = b.verdict(bundleID: faceTime, title: { titleReads += 1; return "x" })
        XCTAssertEqual(titleReads, 0, "no rule of that app needs a read")
        _ = b.verdict(bundleID: zoom, title: { titleReads += 1; return "x" })
        XCTAssertEqual(titleReads, 1)
    }

    func testTitleRulesAreKnown() {
        let b = book([FloatingRule(bundleID: zoom, action: .float, match: .titleIs("a")),
                      FloatingRule(bundleID: faceTime, action: .tile)])
        XCTAssertTrue(b.hasTitleRules(bundleID: zoom))
        XCTAssertFalse(b.hasTitleRules(bundleID: faceTime), "an app rule needs no title")
        XCTAssertFalse(b.hasTitleRules(bundleID: nil))
    }

    // MARK: - admission policy

    func testThePolicyTable() {
        let rule = FloatingRule(bundleID: zoom, action: .float, match: .titleIs("Zoom Meeting"))
        let tile = FloatingRule(bundleID: zoom, action: .tile, match: .titleIs("Zoom Meeting"))
        XCTAssertEqual(FloatingAdmissionPolicy.reason(rule: .tile(tile), isSizeSettable: true,
                                                      isQuickLookPanel: true), .quickLook)
        XCTAssertEqual(FloatingAdmissionPolicy.reason(rule: .float(nil), isSizeSettable: true), .excludedApp)
        XCTAssertEqual(FloatingAdmissionPolicy.reason(rule: .float(rule), isSizeSettable: true), .floatRule)
        XCTAssertEqual(FloatingAdmissionPolicy.reason(rule: .tile(tile), isSizeSettable: false), .fixedSize,
                       "a tile rule can't tile a window HyprMac can't resize")
        XCTAssertNil(FloatingAdmissionPolicy.reason(rule: .tile(tile), isSizeSettable: true))
        XCTAssertNil(FloatingAdmissionPolicy.reason(rule: .tile(tile), isSizeSettable: nil))
        XCTAssertEqual(FloatingAdmissionPolicy.reason(rule: nil, isSizeSettable: false), .fixedSize)
        XCTAssertNil(FloatingAdmissionPolicy.reason(rule: nil, isSizeSettable: true))
    }

    // MARK: - capture and edits

    func testOneClickCapture() {
        XCTAssertEqual(FloatingRule.capture(bundleID: zoom, title: "Zoom Meeting", action: .tile),
                       FloatingRule(bundleID: zoom, action: .tile, match: .titleIs("Zoom Meeting")))
        XCTAssertNil(FloatingRule.capture(bundleID: zoom, title: "", action: .float))
        XCTAssertNil(FloatingRule.capture(bundleID: zoom, title: "  ", action: .float))
        XCTAssertNil(FloatingRule.capture(bundleID: zoom, title: nil, action: .float))
        XCTAssertNil(FloatingRule.capture(bundleID: nil, title: "x", action: .float))
    }

    func testANewRuleGoesAheadOfTheAppsOthersAndAnEqualMatchIsReplaced() {
        let old = FloatingRule(bundleID: teams, action: .float, match: .titleIs("Chat"))
        let other = FloatingRule(bundleID: zoom, action: .float, match: .titleIs("Chat"))
        let new = FloatingRule(bundleID: teams, action: .tile, match: .titleContains("Meeting"))
        XCTAssertEqual(FloatingRule.upserting(new, into: [other, old]), [other, new, old])
        let flipped = FloatingRule(bundleID: teams, action: .tile, match: .titleIs("Chat"))
        XCTAssertEqual(FloatingRule.upserting(flipped, into: [other, old]), [other, flipped])
    }

    func testAppRulesKeepNeverTileAndTileRulesApart() {
        let (store, _) = makeStore()
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        config.excludedBundleIDs = []
        config.addFloatingRule(FloatingRule(bundleID: faceTime, action: .float))
        XCTAssertEqual(config.excludedBundleIDs, [faceTime], "an app float is Never tile")
        XCTAssertTrue(config.floatingRules.isEmpty)
        config.addFloatingRule(FloatingRule(bundleID: faceTime, action: .tile))
        XCTAssertTrue(config.excludedBundleIDs.isEmpty)
        XCTAssertEqual(config.floatingRules, [FloatingRule(bundleID: faceTime, action: .tile)])
        config.addFloatingRule(FloatingRule(bundleID: faceTime, action: .float))
        XCTAssertEqual(config.excludedBundleIDs, [faceTime])
        XCTAssertTrue(config.floatingRules.isEmpty)
    }

    // review: Settings' "Always float an app" inserted into Never tile
    // directly, so an app tile rule stayed beside it: two "All windows" rows
    func testAlwaysFloatingAnAppFromSettingsReplacesItsTileRule() {
        let (store, _) = makeStore()
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        config.excludedBundleIDs = []
        config.floatingRules = [FloatingRule(bundleID: teams, action: .tile)]
        config.addAlwaysFloatApp(teams)
        let rows = FloatingRuleRow.rows(excludedBundleIDs: config.excludedBundleIDs, rules: config.floatingRules)
        XCTAssertEqual(rows.map(\.source), [.neverTile])
        XCTAssertEqual(config.excludedBundleIDs, [teams])
    }

    func testRemovingTheRuleAVerdictNamed() {
        let (store, _) = makeStore()
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        let rule = FloatingRule(bundleID: faceTime, action: .tile, match: .titleIs("FaceTime"))
        config.excludedBundleIDs = [faceTime]
        config.floatingRules = [rule]
        config.removeFloatingRule(decidedBy: .tile(rule), bundleID: faceTime)
        XCTAssertTrue(config.floatingRules.isEmpty)
        XCTAssertEqual(config.excludedBundleIDs, [faceTime])
        config.removeFloatingRule(decidedBy: .float(nil), bundleID: faceTime)
        XCTAssertTrue(config.excludedBundleIDs.isEmpty)
    }

    func testEditingATitleRuleKeepsItsPlace() {
        let (store, _) = makeStore()
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        let a = FloatingRule(bundleID: teams, action: .tile, match: .titleIs("Weekly sync | Microsoft Teams"))
        let b = FloatingRule(bundleID: teams, action: .float, match: .titleIs("Chat"))
        config.floatingRules = [a, b]
        let trimmed = FloatingRule(bundleID: teams, action: .tile, match: .titleContains("Microsoft Teams"))
        config.replaceFloatingRule(a, with: trimmed)
        XCTAssertEqual(config.floatingRules, [trimmed, b])
    }

    // MARK: - Settings rows

    func testRowsGroupByAppWithTheAppRuleFirst() {
        let window = FloatingRule(bundleID: faceTime, action: .tile, match: .titleIs("FaceTime"))
        let appTile = FloatingRule(bundleID: teams, action: .tile)
        let rows = FloatingRuleRow.rows(excludedBundleIDs: [faceTime, "com.apple.systempreferences"],
                                        rules: [window, appTile])
        XCTAssertEqual(rows.map(\.bundleID), [faceTime, faceTime, "com.apple.systempreferences", teams])
        XCTAssertEqual(rows.map(\.source), [.neverTile, .rule(window), .neverTile, .rule(appTile)])
        XCTAssertEqual(rows.map(\.matchDescription),
                       ["All windows", "Windows titled “FaceTime”", "All windows", "All windows"])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    func testTheRowSwitchAndRemoveButton() {
        let (store, _) = makeStore()
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        config.excludedBundleIDs = [faceTime]
        let neverTile = FloatingRuleRow(bundleID: faceTime, source: .neverTile)
        config.setAction(.tile, for: neverTile)
        XCTAssertTrue(config.excludedBundleIDs.isEmpty)
        XCTAssertEqual(config.floatingRules, [FloatingRule(bundleID: faceTime, action: .tile)])

        let window = FloatingRule(bundleID: zoom, action: .float, match: .titleIs("Zoom Meeting"))
        config.floatingRules.append(window)
        config.setAction(.tile, for: FloatingRuleRow(bundleID: zoom, source: .rule(window)))
        XCTAssertEqual(config.floatingRules.last, FloatingRule(bundleID: zoom, action: .tile,
                                                               match: .titleIs("Zoom Meeting")))
        config.remove(FloatingRuleRow(bundleID: zoom, source: .rule(config.floatingRules.last!)))
        XCTAssertEqual(config.floatingRules, [FloatingRule(bundleID: faceTime, action: .tile)])
    }

    // MARK: - rule change step

    func testTheRuleChangeTable() {
        let float = FloatingRule(bundleID: zoom, action: .float, match: .titleIs("Zoom Meeting"))
        let tile = FloatingRule(bundleID: zoom, action: .tile, match: .titleIs("Zoom Meeting"))
        typealias C = FloatingWindowController
        XCTAssertEqual(C.ruleChangeStep(before: nil, after: .float(float), isFloating: false, canTile: true), .float)
        XCTAssertNil(C.ruleChangeStep(before: nil, after: .float(float), isFloating: true, canTile: true))
        XCTAssertEqual(C.ruleChangeStep(before: .float(float), after: nil, isFloating: true, canTile: true), .tile,
                       "forgetting the rule that floated it tiles it")
        XCTAssertNil(C.ruleChangeStep(before: .float(float), after: nil, isFloating: true, canTile: false),
                     "unless it can't take a tile")
        XCTAssertEqual(C.ruleChangeStep(before: nil, after: .tile(tile), isFloating: true, canTile: true), .tile)
        XCTAssertNil(C.ruleChangeStep(before: .tile(tile), after: nil, isFloating: false, canTile: true))
        XCTAssertNil(C.ruleChangeStep(before: .tile(tile), after: nil, isFloating: true, canTile: true),
                     "a floater the user floated by hand stays")
        XCTAssertNil(C.ruleChangeStep(before: .float(float), after: .float(float), isFloating: false, canTile: true),
                     "nothing changed for it")
    }
}

// MARK: - discovery

final class FloatingRuleDiscoveryTests: XCTestCase {

    private let teams = "com.microsoft.teams2"
    private let faceTime = "com.apple.FaceTime"

    private func makeService(titles: @escaping (CGWindowID) -> String?,
                             settable: @escaping (CGWindowID) -> Bool? = { _ in true },
                             bundleID: String)
        -> (WindowDiscoveryService, WindowStateCache, WorkspaceManager) {
        let display = DisplayManager()
        let workspaces = WorkspaceManager(displayManager: display)
        let cache = WindowStateCache()
        let service = WindowDiscoveryService(
            stateCache: cache, accessibility: AccessibilityManager(), displayManager: display,
            workspaceManager: workspaces, bundleIDForPID: { _ in bundleID },
            isWindowSizeSettable: { settable($0.windowID) },
            windowTitle: { titles($0.windowID) })
        return (service, cache, workspaces)
    }

    private func poll(_ service: WindowDiscoveryService, _ windows: [HyprWindow],
                      excluded: Set<String> = [], rules: [FloatingRule]) -> WindowChanges {
        service.computeChanges(snapshot: windows, runningPIDs: [100], excludedBundleIDs: excluded,
                               floatingRules: rules, focusedWindowID: 0)
    }

    func testAWindowRuleFloatsANewWindow() {
        let (svc, cache, _) = makeService(titles: { _ in "Meeting with Sam | Microsoft Teams" }, bundleID: teams)
        let rule = FloatingRule(bundleID: teams, action: .float, match: .titleContains("Meeting"))
        _ = poll(svc, [makeWindow(id: 1, pid: 100)], rules: [rule])
        XCTAssertTrue(cache.floatingWindowIDs.contains(1))
    }

    // FaceTime in Never tile, its main window tiled by a window rule
    func testATileRuleTakesOneWindowOutOfNeverTile() {
        let (svc, cache, _) = makeService(titles: { $0 == 1 ? "FaceTime" : "Call" }, bundleID: faceTime)
        let rule = FloatingRule(bundleID: faceTime, action: .tile, match: .titleIs("FaceTime"))
        _ = poll(svc, [makeWindow(id: 1, pid: 100), makeWindow(id: 2, pid: 100)],
                 excluded: [faceTime], rules: [rule])
        XCTAssertFalse(cache.floatingWindowIDs.contains(1))
        XCTAssertTrue(cache.floatingWindowIDs.contains(2), "the rest of the app floats")
    }

    func testATileRuleDoesNotTileAWindowThatCannotResize() {
        let (svc, cache, _) = makeService(titles: { _ in "FaceTime" }, settable: { _ in false }, bundleID: faceTime)
        let rule = FloatingRule(bundleID: faceTime, action: .tile, match: .titleIs("FaceTime"))
        _ = poll(svc, [makeWindow(id: 1, pid: 100)], rules: [rule])
        XCTAssertTrue(cache.floatingWindowIDs.contains(1))
    }

    func testNoRulesBehavesAsBefore() {
        let (svc, cache, _) = makeService(titles: { _ in "Anything" }, bundleID: teams)
        _ = poll(svc, [makeWindow(id: 1, pid: 100)], rules: [])
        XCTAssertFalse(cache.floatingWindowIDs.contains(1))
        XCTAssertNil(svc.secondsUntilARetryIsDue, "no title re-check without title rules")
        let (excludedSvc, excludedCache, _) = makeService(titles: { _ in "Anything" }, bundleID: faceTime)
        _ = poll(excludedSvc, [makeWindow(id: 1, pid: 100)], excluded: [faceTime], rules: [])
        XCTAssertTrue(excludedCache.floatingWindowIDs.contains(1))
    }

    // MARK: late titles

    private func lateTitleFixture(rule: FloatingRule, startTitle: String?,
                                  excluded: Set<String> = [])
        -> (WindowDiscoveryService, WindowStateCache, HyprWindow, (String?) -> Void, () -> WindowChanges) {
        var title = startTitle
        let (svc, cache, workspaces) = makeService(titles: { _ in title }, bundleID: teams)
        var clock = Date(timeIntervalSinceReferenceDate: 1000)
        svc.now = { clock }
        let w = makeWindow(id: 5, pid: 100)
        _ = poll(svc, [w], excluded: excluded, rules: [rule])
        workspaces.assignWindow(5, toWorkspace: 1)
        let next = { () -> WindowChanges in
            clock += svc.secondsUntilARetryIsDue ?? 100
            return self.poll(svc, [w], excluded: excluded, rules: [rule])
        }
        return (svc, cache, w, { title = $0 }, next)
    }

    func testATitleThatArrivesLateFloatsTheWindowOnce() {
        let rule = FloatingRule(bundleID: teams, action: .float, match: .titleContains("Meeting"))
        let (svc, cache, _, setTitle, next) = lateTitleFixture(rule: rule, startTitle: "")
        XCTAssertFalse(cache.floatingWindowIDs.contains(5))
        XCTAssertEqual(svc.secondsUntilARetryIsDue!, 0.5, accuracy: 0.001)
        setTitle("Meeting with Sam")
        let changes = next()
        XCTAssertEqual(changes.ruleFloated, [5])
        XCTAssertTrue(changes.needsRetile)
        XCTAssertTrue(cache.floatingWindowIDs.contains(5))
        XCTAssertNil(svc.secondsUntilARetryIsDue, "the re-check ends once a rule matched")
    }

    func testALateTitleHandsAFloaterToATileRule() {
        let rule = FloatingRule(bundleID: teams, action: .tile, match: .titleContains("Meeting"))
        let (_, cache, _, setTitle, next) = lateTitleFixture(rule: rule, startTitle: nil, excluded: [teams])
        XCTAssertTrue(cache.floatingWindowIDs.contains(5), "Never tile, before the title")
        setTitle("Meeting with Sam")
        XCTAssertEqual(next().unfloated, [5])
        XCTAssertFalse(cache.floatingWindowIDs.contains(5))
    }

    func testTheUserWinsOverALateTitle() {
        let rule = FloatingRule(bundleID: teams, action: .float, match: .titleContains("Meeting"))
        let (svc, cache, w, setTitle, next) = lateTitleFixture(rule: rule, startTitle: "")
        cache.setFloating(true, window: w) // the user floated it by hand
        setTitle("Meeting with Sam")
        XCTAssertTrue(next().ruleFloated.isEmpty)
        XCTAssertNil(svc.secondsUntilARetryIsDue)
    }

    // review: the fixed-size re-check tiled a window that turned resizable,
    // and the title re-check took that for the user and dropped it, so a
    // title that arrived later never applied
    func testAFixedSizeUnfloatDoesNotEndTheTitleRecheck() {
        var title: String? = ""
        var settable: Bool? = false
        let (svc, cache, workspaces) = makeService(titles: { _ in title }, settable: { _ in settable },
                                                   bundleID: teams)
        var clock = Date(timeIntervalSinceReferenceDate: 1000)
        svc.now = { clock }
        let rule = FloatingRule(bundleID: teams, action: .float, match: .titleContains("Meeting"))
        let w = makeWindow(id: 5, pid: 100)
        _ = poll(svc, [w], rules: [rule])
        workspaces.assignWindow(5, toWorkspace: 1)
        XCTAssertTrue(cache.floatingWindowIDs.contains(5), "fixed size at first sight")

        settable = true
        clock += 0.5
        XCTAssertEqual(poll(svc, [w], rules: [rule]).unfloated, [5])
        XCTAssertNotNil(svc.secondsUntilARetryIsDue, "the title re-check is still pending")

        title = "Meeting with Sam"
        clock += svc.secondsUntilARetryIsDue ?? 100
        XCTAssertEqual(poll(svc, [w], rules: [rule]).ruleFloated, [5])
        XCTAssertTrue(cache.floatingWindowIDs.contains(5))
    }

    // the other order: a title rule floated it first; the fixed-size
    // re-check that finds it resizable must not tile it
    func testAFloatRuleKeepsAWindowTheFixedSizeRecheckFindsResizable() {
        var settable: Bool? = false
        let (svc, cache, workspaces) = makeService(titles: { _ in "Meeting" }, settable: { _ in settable },
                                                   bundleID: teams)
        var clock = Date(timeIntervalSinceReferenceDate: 1000)
        svc.now = { clock }
        let w = makeWindow(id: 5, pid: 100)
        // the rule arrives after the window: it floated for its size
        _ = poll(svc, [w], rules: [])
        workspaces.assignWindow(5, toWorkspace: 1)
        let rule = FloatingRule(bundleID: teams, action: .float, match: .titleContains("Meeting"))
        settable = true
        clock += 0.5
        XCTAssertTrue(poll(svc, [w], rules: [rule]).unfloated.isEmpty)
        XCTAssertTrue(cache.floatingWindowIDs.contains(5))
    }

    // review: a held window kept an overdue entry, so every cycle of the
    // hold asked for a poll half a second later
    func testAHeldWindowReschedulesItsTitleRecheck() {
        let rule = FloatingRule(bundleID: teams, action: .float, match: .titleContains("Meeting"))
        var title: String? = ""
        let (svc, _, workspaces) = makeService(titles: { _ in title }, bundleID: teams)
        var clock = Date(timeIntervalSinceReferenceDate: 1000)
        svc.now = { clock }
        let w = makeWindow(id: 5, pid: 100)
        _ = poll(svc, [w], rules: [rule])
        workspaces.assignWindow(5, toWorkspace: 1)
        title = "Chat"
        clock += 0.5
        _ = poll(svc, [w], rules: [rule])
        XCTAssertEqual(svc.secondsUntilARetryIsDue!, 1, accuracy: 0.001, "second turn, one second on")

        clock += 1
        _ = svc.computeChanges(snapshot: [], runningPIDs: [100], excludedBundleIDs: [],
                               floatingRules: [rule], focusedWindowID: 0, unreadableWindowIDs: [5])
        // an overdue entry reads as overdueRetry every cycle of the hold; the
        // hold's own readiness look may still come sooner than the new turn
        XCTAssertNotEqual(svc.secondsUntilARetryIsDue, WindowDiscoveryService.overdueRetry,
                          "held: same turn, rescheduled, not overdue")
    }

    // review nit: a tick before the window had a workspace dropped it
    func testATitleRecheckWaitsForAWorkspace() {
        let rule = FloatingRule(bundleID: teams, action: .float, match: .titleContains("Meeting"))
        var title: String? = ""
        let (svc, cache, workspaces) = makeService(titles: { _ in title }, bundleID: teams)
        var clock = Date(timeIntervalSinceReferenceDate: 1000)
        svc.now = { clock }
        let w = makeWindow(id: 5, pid: 100)
        _ = poll(svc, [w], rules: [rule])
        clock += 0.5
        _ = poll(svc, [w], rules: [rule])
        XCTAssertNotNil(svc.secondsUntilARetryIsDue, "still pending without a workspace")

        workspaces.assignWindow(5, toWorkspace: 1)
        title = "Meeting with Sam"
        clock += svc.secondsUntilARetryIsDue ?? 100
        XCTAssertEqual(poll(svc, [w], rules: [rule]).ruleFloated, [5])
        XCTAssertTrue(cache.floatingWindowIDs.contains(5))
    }

    func testTheRecheckGivesUpAfterItsDelays() {
        let rule = FloatingRule(bundleID: teams, action: .float, match: .titleContains("Meeting"))
        let (svc, cache, _, setTitle, next) = lateTitleFixture(rule: rule, startTitle: "Loading")
        for index in 0..<WindowDiscoveryService.titleRuleRecheckDelays.count {
            setTitle("Chat \(index)")
            XCTAssertTrue(next().ruleFloated.isEmpty)
        }
        XCTAssertNil(svc.secondsUntilARetryIsDue)
        setTitle("Meeting")
        XCTAssertTrue(next().ruleFloated.isEmpty, "later title changes are ignored")
        XCTAssertFalse(cache.floatingWindowIDs.contains(5))
    }
}

// MARK: - Toggle Floating, live re-apply, actions

final class FloatingRuleControllerTests: XCTestCase {

    private let faceTime = "com.apple.FaceTime"
    private let zoom = "us.zoom.xos"

    private final class TitledWindow: HyprWindow {
        var fakeTitle: String?
        init(id: CGWindowID, title: String?) {
            fakeTitle = title
            super.init(element: AXUIElementCreateApplication(0), windowID: id, ownerPID: 0)
        }
        override var title: String? { fakeTitle }
        override func readPosition() -> (AXError, CGPoint?) { (.success, CGPoint(x: 100, y: 100)) }
        override func readSize() -> (AXError, CGSize?) { (.success, CGSize(width: 600, height: 400)) }
    }

    private final class Harness {
        let screen = RuleTestScreen()
        let workspaces: WorkspaceManager
        let cache = WindowStateCache()
        let engine: TilingEngine
        let controller: FloatingWindowController
        var rules: [FloatingRule] = []
        var excluded: Set<String> = []
        var retiles = 0
        var shakes: [String] = []
        let border = FocusBorder()

        /// `refusing`: every window keeps a 300x200 size, like an app that
        /// won't take its tile
        init(refusing: Bool = false) {
            let screen = self.screen
            let display = DisplayManager(screenSource: { [screen] })
            workspaces = WorkspaceManager(displayManager: display)
            workspaces.initializeMonitors()
            engine = TilingEngine(displayManager: display,
                                  frameSizingIOFactory: refusing ? Self.refusingFactory() : acceptingFrameSizingIOFactory())
            controller = FloatingWindowController(
                stateCache: cache, suppressions: SuppressionRegistry(), workspaceManager: workspaces,
                tilingEngine: engine, displayManager: display, accessibility: AccessibilityManager(),
                cursorManager: CursorManager(), focusController: FocusStateController(focusBorder: border),
                focusBorder: border, dimmingOverlay: DimmingOverlay())
            controller.excludedBundleIDs = { [unowned self] in excluded }
            controller.floatingRules = { [unowned self] in rules }
            controller.retile = { [unowned self] body in retiles += 1; body() }
            controller.isWindowSizeSettable = { _ in true }
        }

        var workspace: Int { workspaces.workspaceForScreen(screen) }

        static func refusingFactory() -> ([CGWindowID: HyprWindow], @escaping () -> UInt64) -> FrameSizingIO {
            var positions: [CGWindowID: CGPoint] = [:]
            return { _, generation in
                FrameSizingIO(
                    setMessagingTimeout: { _, _ in .success },
                    writeSize: { _, _, _ in .success },
                    writePosition: { id, position, _ in positions[id] = position; return .success },
                    readPosition: { id, _ in (.success, positions[id] ?? .zero) },
                    readSize: { _, _ in (.success, CGSize(width: 300, height: 200)) },
                    now: { 0 }, sleep: { _ in }, currentGeneration: generation)
            }
        }

        func window(_ id: CGWindowID, bundleID: String, title: String?, floating: Bool) -> HyprWindow {
            let w = TitledWindow(id: id, title: title)
            w.bundleID = bundleID
            cache.knownWindowIDs.insert(id)
            cache.cachedWindows[id] = w
            workspaces.assignWindow(id, toWorkspace: workspace)
            if floating { cache.setFloating(true, window: w) }
            return w
        }
    }

    // Zach's rule: Hypr+T is never refused for a rule. it tiles a window a
    // float rule covers, and from then on no rule moves that window
    func testHyprTTilesAWindowAFloatRuleCoversAndRulesLeaveItAlone() {
        let h = Harness()
        h.rules = [FloatingRule(bundleID: zoom, action: .float, match: .titleIs("Zoom Meeting"))]
        let w = h.window(1, bundleID: zoom, title: "Zoom Meeting", floating: true)
        h.controller.markRulesApplied()
        h.controller.toggle(w, on: h.screen, in: h.workspace)
        XCTAssertFalse(h.cache.floatingWindowIDs.contains(1))
        XCTAssertEqual(h.retiles, 1)
        XCTAssertEqual(h.controller.manualChoice(for: 1), false)
        XCTAssertNil(h.controller.floatRule(for: w))

        // a later rule edit doesn't take it back
        h.rules.append(FloatingRule(bundleID: zoom, action: .float))
        XCTAssertEqual(h.controller.rulesChanged(windows: [w])?.floated, [])
        XCTAssertFalse(h.cache.floatingWindowIDs.contains(1))
    }

    // floating it by hand is remembered too; a tile rule leaves it floating
    func testFloatingByHandBeatsATileRule() {
        let h = Harness()
        let w = h.window(1, bundleID: zoom, title: "Zoom", floating: false)
        h.controller.markRulesApplied()
        h.controller.toggle(w, on: h.screen, in: h.workspace)
        XCTAssertTrue(h.cache.floatingWindowIDs.contains(1))
        XCTAssertEqual(h.controller.manualChoice(for: 1), true)
        h.rules = [FloatingRule(bundleID: zoom, action: .tile)]
        XCTAssertEqual(h.controller.rulesChanged(windows: [w])?.tiled, [])
        XCTAssertTrue(h.cache.floatingWindowIDs.contains(1))
    }

    // only a window that can't take a tile still fails, with the shake
    func testHyprTOnAWindowThatCannotTileStillShakes() {
        let h = Harness(refusing: true)
        h.excluded = [faceTime]
        var refused = 0
        h.controller.rejectFloatToTile = { _, _ in refused += 1 }
        let w = h.window(1, bundleID: faceTime, title: "FaceTime", floating: true)
        h.controller.toggle(w, on: h.screen, in: h.workspace)
        XCTAssertEqual(refused, 1)
        XCTAssertTrue(h.cache.floatingWindowIDs.contains(1), "floats in place, no loop")
        XCTAssertNil(h.controller.manualChoice(for: 1), "a failed tile is not a choice")
    }

    // the FaceTime example: the app floats, its main window tiles
    func testAWindowTileRuleInsideNeverTileAllowsHyprT() {
        let h = Harness()
        h.excluded = [faceTime]
        h.rules = [FloatingRule(bundleID: faceTime, action: .tile, match: .titleIs("FaceTime"))]
        let main = h.window(1, bundleID: faceTime, title: "FaceTime", floating: true)
        let call = h.window(2, bundleID: faceTime, title: "Call", floating: true)
        XCTAssertFalse(h.controller.isNeverTile(main))
        XCTAssertTrue(h.controller.isNeverTile(call))
        XCTAssertNil(h.controller.autoFloatReason(main, excludedBundleIDs: h.excluded, floatingRules: h.rules))
        XCTAssertEqual(h.controller.autoFloatReason(call, excludedBundleIDs: h.excluded, floatingRules: h.rules),
                       .excludedApp)
        h.controller.toggle(main, on: h.screen, in: h.workspace)
        XCTAssertEqual(h.retiles, 1, "not refused up front")
    }

    func testANewFloatRuleFloatsTheOpenWindowItCoversAndForgettingTilesItAgain() {
        let h = Harness()
        let meeting = h.window(1, bundleID: zoom, title: "Zoom Meeting", floating: false)
        let other = h.window(2, bundleID: zoom, title: "Zoom Workplace", floating: false)
        let byHand = h.window(3, bundleID: zoom, title: "Settings", floating: true)
        let windows = [meeting, other, byHand]

        let before = h.controller.ruleBook
        h.rules = [FloatingRule(bundleID: zoom, action: .float, match: .titleIs("Zoom Meeting"))]
        let added = h.controller.applyRuleChange(from: before, windows: windows)
        XCTAssertEqual(added.floated, [1])
        XCTAssertEqual(added.tiled, [])
        XCTAssertEqual(h.retiles, 1, "one retile for the change")
        XCTAssertTrue(h.cache.floatingWindowIDs.contains(1))
        XCTAssertFalse(h.cache.floatingWindowIDs.contains(2))

        let withRule = h.controller.ruleBook
        h.rules = []
        let forgot = h.controller.applyRuleChange(from: withRule, windows: windows)
        XCTAssertEqual(forgot.tiled, [1])
        XCTAssertFalse(h.cache.floatingWindowIDs.contains(1))
        XCTAssertTrue(h.cache.floatingWindowIDs.contains(3), "the hand-floated window is untouched")
    }

    func testANewTileRuleTilesAFloaterButNotOneThatCannotResize() {
        let h = Harness()
        h.excluded = [faceTime]
        let main = h.window(1, bundleID: faceTime, title: "FaceTime", floating: true)
        let fixed = h.window(2, bundleID: faceTime, title: "FaceTime", floating: true)
        h.controller.isWindowSizeSettable = { $0.windowID == 2 ? false : true }
        let before = h.controller.ruleBook
        h.rules = [FloatingRule(bundleID: faceTime, action: .tile, match: .titleIs("FaceTime"))]
        let result = h.controller.applyRuleChange(from: before, windows: [main, fixed])
        XCTAssertEqual(result.tiled, [1])
        XCTAssertTrue(h.cache.floatingWindowIDs.contains(2))
    }

    // parked in the corner on a hidden workspace: the reveal restores a saved
    // frame, so a window floated there gets one on its home screen
    func testAWindowFloatedOnAHiddenWorkspaceGetsAFrameForTheReveal() {
        let h = Harness()
        let hidden = h.workspace == 2 ? 3 : 2
        let w = h.window(1, bundleID: zoom, title: "Zoom Meeting", floating: false)
        h.workspaces.moveWindow(1, toWorkspace: hidden)
        XCTAssertFalse(h.workspaces.isWorkspaceVisible(hidden))
        let before = h.controller.ruleBook
        h.rules = [FloatingRule(bundleID: zoom, action: .float, match: .titleIs("Zoom Meeting"))]
        XCTAssertEqual(h.controller.applyRuleChange(from: before, windows: [w]).floated, [1])
        let saved = h.workspaces.savedFloatingFrame(for: 1)
        XCTAssertNotNil(saved)
        if let saved, let home = h.workspaces.homeScreenForWorkspace(hidden) {
            XCTAssertTrue(saved.isSubstantiallyVisible(on: DisplayManager(screenSource: { [home] })
                .cgRect(for: home)))
        }
    }

    // review: a rule change from Settings or the menu skipped the display
    // transition hold the actions have
    func testARuleChangeWaitsOutADisplayTransition() {
        let h = Harness()
        var pending = true
        h.controller.isDisplayTransitionPending = { pending }
        h.controller.markRulesApplied()
        let w = h.window(1, bundleID: zoom, title: "Zoom Meeting", floating: false)
        h.rules = [FloatingRule(bundleID: zoom, action: .float, match: .titleIs("Zoom Meeting"))]
        XCTAssertNil(h.controller.rulesChanged(windows: [w]))
        XCTAssertFalse(h.cache.floatingWindowIDs.contains(1))
        XCTAssertEqual(h.retiles, 0)

        pending = false
        XCTAssertEqual(h.controller.rulesChanged(windows: [w])?.floated, [1], "the difference is still there")
        XCTAssertEqual(h.controller.rulesChanged(windows: [w])?.floated, [], "and applied once")
    }

    // review: a maximized floater a new tile rule tiled kept its maximized
    // frames, as no endsMaximize ran
    func testARuleChangeEndsTheMaximizeOfAWindowItMoves() {
        let h = Harness()
        h.excluded = [faceTime]
        let w = h.window(1, bundleID: faceTime, title: "FaceTime", floating: true)
        _ = h.controller.toggleMaximized(w, fullFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055), on: h.screen)
        XCTAssertTrue(h.controller.isMaximized(1))
        var ended = 0
        h.controller.onMaximizeEnded = { _ in ended += 1 }
        let before = h.controller.ruleBook
        h.rules = [FloatingRule(bundleID: faceTime, action: .tile, match: .titleIs("FaceTime"))]
        XCTAssertEqual(h.controller.applyRuleChange(from: before, windows: [w]).tiled, [1])
        XCTAssertFalse(h.controller.isMaximized(1))
        XCTAssertEqual(ended, 1)
    }

    // Zach's call: an edit on this Mac moves open windows; the same change
    // arriving by reload (iCloud, Nix, a hand edit) moves nothing open, as
    // a Never tile edit never did
    private func syncedConfig(_ h: Harness) -> (UserConfig, URL, FloatingRuleSync) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloatingRuleSync-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let config = UserConfig(store: ConfigStore(
            localConfigURL: dir.appendingPathComponent("config.json"),
            monitorConfigURL: dir.appendingPathComponent("monitor-config.json"),
            iCloudRootURL: dir.appendingPathComponent("cloud", isDirectory: true)), iCloudSyncEnabled: false)
        config.excludedBundleIDs = []
        config.floatingRules = []
        h.controller.excludedBundleIDs = { config.excludedBundleIDs }
        h.controller.floatingRules = { config.floatingRules }
        h.controller.markRulesApplied()
        let windows = { [h] in Array(h.cache.cachedWindows.values) }
        let sync = FloatingRuleSync(config: config, schedule: { $0() },
                                    applyLocalEdit: { [h] in h.controller.rulesChanged(windows: windows()) },
                                    rebase: { [h] in h.controller.markRulesApplied() })
        return (config, dir.appendingPathComponent("config.json"), sync)
    }

    func testALocalRuleEditMovesTheOpenWindow() {
        let h = Harness()
        let (config, _, sync) = syncedConfig(h)
        _ = h.window(1, bundleID: zoom, title: "Zoom Meeting", floating: false)
        config.addFloatingRule(FloatingRule(bundleID: zoom, action: .float, match: .titleIs("Zoom Meeting")))
        XCTAssertTrue(h.cache.floatingWindowIDs.contains(1))
        withExtendedLifetime(sync) {}
    }

    func testALocalNeverTileEditMovesTheOpenWindow() {
        let h = Harness()
        let (config, _, sync) = syncedConfig(h)
        _ = h.window(1, bundleID: zoom, title: "Zoom", floating: false)
        config.addAlwaysFloatApp(zoom)
        XCTAssertTrue(h.cache.floatingWindowIDs.contains(1))
        withExtendedLifetime(sync) {}
    }

    func testTheSameChangeByReloadMovesNothingOpen() throws {
        let h = Harness()
        let (config, url, sync) = syncedConfig(h)
        _ = h.window(1, bundleID: zoom, title: "Zoom Meeting", floating: false)
        let text = #"{"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true,"#
            + #""excludedBundleIDs":["com.apple.FaceTime"],"#
            + #""floatingRules":[{"bundleID":"us.zoom.xos","action":"float","match":{"titleIs":"Zoom Meeting"}}]}"#
        try Data(text.utf8).write(to: url)
        config.reloadFromDisk()
        XCTAssertEqual(config.floatingRules.count, 1, "the reload took the rule")
        XCTAssertFalse(h.cache.floatingWindowIDs.contains(1), "nothing open moved")
        XCTAssertEqual(h.retiles, 0)

        // a later local edit about another app doesn't sweep the reload in
        config.addFloatingRule(FloatingRule(bundleID: faceTime, action: .tile, match: .titleIs("FaceTime")))
        XCTAssertFalse(h.cache.floatingWindowIDs.contains(1))
        // new windows and Retile All do see the reloaded rule
        let late = h.window(2, bundleID: zoom, title: "Zoom Meeting", floating: false)
        XCTAssertEqual(h.controller.autoFloatReason(late, excludedBundleIDs: config.excludedBundleIDs,
                                                    floatingRules: config.floatingRules), .floatRule)
        withExtendedLifetime(sync) {}
    }

    // live check: a window parked on a hidden workspace is not in the
    // cache, so the rule edit never reached it until the walk was added
    func testARuleEditReachesWindowsOnHiddenWorkspacesThroughTheWalk() {
        let visible = makeWindow(id: 1), parked = makeWindow(id: 2), unknown = makeWindow(id: 3)
        let freshVisible = makeWindow(id: 1)
        let windows = FloatingRuleSync.windowsToReapply(cached: [visible], walked: [freshVisible, parked, unknown],
                                                        known: [1, 2])
        XCTAssertEqual(windows.map(\.windowID), [1, 2])
        XCTAssertTrue(windows[0] === freshVisible, "the walk's newer element wins")
    }

    func testARuleChangeLeavesScratchpadAndHiddenWindowsAlone() {
        let h = Harness()
        let stashed = h.window(1, bundleID: zoom, title: "Zoom Meeting", floating: false)
        h.workspaces.moveWindow(1, toWorkspace: ScratchpadController.workspace)
        let ghost = h.window(2, bundleID: zoom, title: "Zoom Meeting", floating: false)
        h.cache.hiddenWindowIDs.insert(2)
        let before = h.controller.ruleBook
        h.rules = [FloatingRule(bundleID: zoom, action: .float, match: .titleIs("Zoom Meeting"))]
        let result = h.controller.applyRuleChange(from: before, windows: [stashed, ghost])
        XCTAssertEqual(result.floated, [])
        XCTAssertEqual(h.retiles, 0)
    }

    // MARK: commands, on the window they were opened for

    private final class CommandFixture {
        let config: UserConfig
        let commands: FloatingRuleCommands
        var windows: [CGWindowID: HyprWindow] = [:]
        var floating: Set<CGWindowID> = []
        var refusals: [String] = []
        var toggled: [CGWindowID] = []
        var cleared: [CGWindowID] = []
        var settable: Bool? = true

        init(dir: URL) {
            config = UserConfig(store: ConfigStore(
                localConfigURL: dir.appendingPathComponent("config.json"),
                monitorConfigURL: dir.appendingPathComponent("monitor-config.json"),
                iCloudRootURL: dir.appendingPathComponent("cloud", isDirectory: true)), iCloudSyncEnabled: false)
            config.excludedBundleIDs = []
            commands = FloatingRuleCommands(config: config)
            commands.window = { [unowned self] in self.windows[$0] }
            commands.isFloating = { [unowned self] in self.floating.contains($0) }
            commands.refuse = { [unowned self] _, message in self.refusals.append(message) }
            commands.toggle = { [unowned self] in self.toggled.append($0.windowID) }
            commands.clearManualChoice = { [unowned self] in self.cleared.append($0) }
            commands.isSizeSettable = { [unowned self] _ in self.settable }
            commands.appName = { _ in "Microsoft Teams" }
        }

        func add(_ id: CGWindowID, bundleID: String, title: String) -> HyprWindow {
            let w = TitledWindow(id: id, title: title)
            w.bundleID = bundleID
            windows[id] = w
            return w
        }
    }

    private func fixture() -> CommandFixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloatingRuleCommands-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return CommandFixture(dir: dir)
    }

    private let teams = "com.microsoft.teams2"

    // the live bug: the menu named Teams, hover moved focus to Dia, and the
    // click wrote a Dia rule. the commands take the window id the menu or
    // the overlay was opened for; focus doesn't enter into it
    func testACommandActsOnTheWindowItWasOpenedFor() {
        let f = fixture()
        _ = f.add(8905, bundleID: teams, title: "Chat | Someone")
        _ = f.add(28823, bundleID: "company.thebrowser.dia", title: "New Tab")
        let info = f.commands.info(for: 8905)
        XCTAssertEqual(info?.bundleID, teams)
        f.commands.setAppRule(info!.windowID, action: .tile)
        XCTAssertEqual(f.config.floatingRules, [FloatingRule(bundleID: teams, action: .tile)])
        XCTAssertEqual(f.cleared, [8905], "the rule is the newest word about that window")
    }

    func testAGoneWindowGetsNothing() {
        let f = fixture()
        XCTAssertNil(f.commands.info(for: 7))
        f.commands.setAppRule(7, action: .float)
        f.commands.toggleOnce(7)
        XCTAssertTrue(f.config.excludedBundleIDs.isEmpty)
        XCTAssertTrue(f.toggled.isEmpty)
    }

    func testTheOneOffIsAToggle() {
        let f = fixture()
        _ = f.add(1, bundleID: teams, title: "Chat")
        f.commands.toggleOnce(1)
        XCTAssertEqual(f.toggled, [1])
        XCTAssertTrue(f.config.floatingRules.isEmpty)
    }

    func testATitleRuleFromTheEditedText() {
        let f = fixture()
        _ = f.add(1, bundleID: teams, title: "Weekly sync | Meeting | Microsoft Teams")
        f.commands.setTitleRule(1, match: .titleContains("Meeting"), action: .float)
        XCTAssertEqual(f.config.floatingRules,
                       [FloatingRule(bundleID: teams, action: .float, match: .titleContains("Meeting"))])
        XCTAssertEqual(f.commands.info(for: 1)?.currentRule, "Always float: windows with “Meeting” in the title")
    }

    func testATileRuleForAWindowThatCannotResizeIsRefused() {
        let f = fixture()
        _ = f.add(1, bundleID: teams, title: "Meeting")
        f.settable = false
        f.commands.setTitleRule(1, match: .titleIs("Meeting"), action: .tile)
        f.commands.setAppRule(1, action: .tile)
        XCTAssertTrue(f.config.floatingRules.isEmpty)
        XCTAssertEqual(f.refusals, [FloatingRuleCommands.cannotTileMessage, FloatingRuleCommands.cannotTileMessage])
    }

    func testAQuickLookPreviewIsRefused() {
        let f = fixture()
        let w = f.add(1, bundleID: teams, title: "photo.jpg")
        w.isQuickLookPanel = true
        XCTAssertNil(f.commands.info(for: 1))
        f.commands.setAppRule(1, action: .float)
        XCTAssertTrue(f.config.excludedBundleIDs.isEmpty)
        XCTAssertEqual(f.refusals, [FloatingRuleCommands.quickLookMessage])
    }

    func testForgetRemovesTheRuleThatDecides() {
        let f = fixture()
        _ = f.add(1, bundleID: teams, title: "Meeting")
        f.commands.setTitleRule(1, match: .titleIs("Meeting"), action: .float)
        f.commands.forget(1)
        XCTAssertTrue(f.config.floatingRules.isEmpty)
        f.commands.forget(1)
        XCTAssertEqual(f.refusals, [FloatingRuleCommands.noRuleMessage])

        f.commands.setAppRule(1, action: .float)
        XCTAssertEqual(f.config.excludedBundleIDs, [teams])
        XCTAssertEqual(f.commands.info(for: 1)?.currentRule, "Never tile: all windows")
        XCTAssertEqual(f.commands.info(for: 1)?.appFloats, true)
        f.commands.forget(1)
        XCTAssertTrue(f.config.excludedBundleIDs.isEmpty)
    }

    func testShowWindowRulesIsAWindowManagementBindOncePerPress() {
        XCTAssertEqual(KeybindCategory.from(.showWindowRules), .windowManagement)
        XCTAssertTrue(HotkeyManager.ignoresAutorepeat(.showWindowRules))
        XCTAssertFalse(ActionPolicy.cancelsPendingRecovery(.showWindowRules))
        XCTAssertTrue(Keybind.defaults.contains(Keybind(keyCode: 34, modifiers: .hypr, action: .showWindowRules)))
    }
}

private final class RuleTestScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 1920, height: 1080) }
    override var visibleFrame: NSRect { NSRect(x: 0, y: 0, width: 1920, height: 1055) }
}
