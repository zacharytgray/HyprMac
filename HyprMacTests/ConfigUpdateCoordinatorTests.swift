import XCTest
import AppKit
import Combine
@testable import HyprMac

final class ConfigUpdateCoordinatorTests: XCTestCase {
    private func requireIsolatedHome() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HYPRMAC_HEADLESS_TESTS"] == "1",
              let fixedHome = environment["CFFIXED_USER_HOME"] else {
            throw XCTSkip("UserConfig mutation tests require the isolated test home")
        }
        let homePath = URL(fileURLWithPath: fixedHome).standardizedFileURL.path
        let configPath = ConfigStore.configPath.standardizedFileURL.path
        guard configPath.hasPrefix(homePath + "/") else {
            throw XCTSkip("ConfigStore is not rooted under the isolated test home")
        }
    }

    private func restore(_ data: Data?, to url: URL) {
        if let data {
            try? data.write(to: url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func state(
        gap: CGFloat = 8,
        padding: CGFloat = 8,
        splits: [String: Int] = [:],
        disabled: Set<String> = [],
        paddingOverrides: [String: EdgePadding] = [:],
        workspaceMonitors: [String: [Int]] = [:],
        overlayAppearance: OverlayAppearance = .system,
        showBorder: Bool = true,
        focusColor: String? = nil,
        floatingColor: String? = nil,
        bracketStyle: FocusBracketStyle = .rounded,
        bracketColor: String? = nil,
        bracketRadius: CGFloat = 14,
        bracketThickness: CGFloat = 3,
        bracketLength: CGFloat = 14,
        dim: Bool = false,
        intensity: Double = 0.2,
        fade: Double = 0.22,
        radius: CGFloat = 10
    ) -> RuntimeConfigState {
        RuntimeConfigState(
            enabled: true, keybinds: [], hyprKey: .capsLock,
            gapSize: gap, outerPadding: padding,
            maxSplitsPerMonitor: splits, disabledMonitors: disabled,
            outerPaddingPerMonitor: paddingOverrides,
            workspaceMonitors: workspaceMonitors,
            overlayAppearance: overlayAppearance,
            showFocusBorder: showBorder, focusBorderColorHex: focusColor,
            floatingBorderColorHex: floatingColor,
            focusBracketStyle: bracketStyle, focusBracketColorHex: bracketColor,
            focusBracketRadius: bracketRadius,
            focusBracketThickness: bracketThickness,
            focusBracketLength: bracketLength,
            dimInactiveWindows: dim, dimIntensity: intensity,
            chromeFadeDurationSec: fade, windowCornerRadius: radius,
            scratchpadTileByDefault: true, scratchpadRegionInset: 0.06)
    }

    func testUnchangedReloadHasNoRuntimeEffects() {
        let original = state()
        let coordinator = ConfigUpdateCoordinator(initial: original)
        var effects = 0
        coordinator.onEnabled = { _ in effects += 1 }
        coordinator.onKeybinds = { _ in effects += 1 }
        coordinator.onHyprKey = { _ in effects += 1 }
        coordinator.onLayoutGeometry = { _, _ in effects += 1 }
        coordinator.onMaximumSplits = { _ in effects += 1 }
        coordinator.onDisabledMonitors = { _ in effects += 1 }
        coordinator.onOuterPaddingOverride = { _ in effects += 1 }
        coordinator.onWorkspaceMonitors = { _ in effects += 1 }
        coordinator.onChrome = { _, _ in effects += 1 }
        coordinator.onScratchpadRegion = { _ in effects += 1 }
        coordinator.onScratchpadEntryMode = { _ in effects += 1 }

        coordinator.receive(original)

        XCTAssertEqual(effects, 0)
    }

    func testOuterPaddingOverrideChangeReachesOnlyItsRoute() {
        let coordinator = ConfigUpdateCoordinator(initial: state())
        var overrides: [[String: EdgePadding]] = []
        var other = 0
        coordinator.onOuterPaddingOverride = { overrides.append($0) }
        coordinator.onLayoutGeometry = { _, _ in other += 1 }
        coordinator.onMaximumSplits = { _ in other += 1 }
        coordinator.onDisabledMonitors = { _ in other += 1 }
        coordinator.onChrome = { _, _ in other += 1 }

        coordinator.receive(state(paddingOverrides: ["Main": EdgePadding(top: 36)]))
        coordinator.receive(state(paddingOverrides: ["Main": EdgePadding(top: 36)]))
        // another side on the same monitor is a change too
        coordinator.receive(state(paddingOverrides: ["Main": EdgePadding(top: 36, left: 12)]))
        coordinator.receive(state())

        XCTAssertEqual(overrides, [["Main": EdgePadding(top: 36)],
                                   ["Main": EdgePadding(top: 36, left: 12)], [:]])
        XCTAssertEqual(other, 0)
    }

    func testWorkspaceMappingChangeReachesOnlyItsRoute() {
        let coordinator = ConfigUpdateCoordinator(initial: state())
        var mappings: [[String: [Int]]] = []
        var other = 0
        coordinator.onWorkspaceMonitors = { mappings.append($0) }
        coordinator.onLayoutGeometry = { _, _ in other += 1 }
        coordinator.onMaximumSplits = { _ in other += 1 }
        coordinator.onDisabledMonitors = { _ in other += 1 }
        coordinator.onOuterPaddingOverride = { _ in other += 1 }
        coordinator.onChrome = { _, _ in other += 1 }

        coordinator.receive(state(workspaceMonitors: ["Left": [1, 2, 3]]))
        coordinator.receive(state(workspaceMonitors: ["Left": [1, 2, 3]]))
        coordinator.receive(state(workspaceMonitors: ["Left": [1, 2], "Right": [3]]))
        coordinator.receive(state())

        XCTAssertEqual(mappings, [["Left": [1, 2, 3]], ["Left": [1, 2], "Right": [3]], [:]])
        XCTAssertEqual(other, 0)
    }

    // a Settings toggle is one assignment, so one reconcile, and the file
    // holds the mapping until no monitor has a workspace left
    func testSettingsWorkspaceToggleReachesTheRouteOnceAndPersists() throws {
        try requireIsolatedHome()
        let configBefore = try? Data(contentsOf: ConfigStore.configPath)
        let monitorBefore = try? Data(contentsOf: ConfigStore.monitorConfigPath)
        defer {
            restore(configBefore, to: ConfigStore.configPath)
            restore(monitorBefore, to: ConfigStore.monitorConfigPath)
        }
        let config = UserConfig()
        config.workspaceMonitors = [:]
        let coordinator = ConfigUpdateCoordinator(initial: RuntimeConfigState(config))
        var mappings: [[String: [Int]]] = []
        var disabled = 0
        coordinator.onWorkspaceMonitors = { mappings.append($0) }
        coordinator.onDisabledMonitors = { _ in disabled += 1 }
        coordinator.observe(config)

        config.workspaceMonitors = WorkspaceHomeResolver.setting([1, 2, 3], for: "Left", in: config.workspaceMonitors)
        config.workspaceMonitors = WorkspaceHomeResolver.setting([3, 4], for: "Right", in: config.workspaceMonitors)

        XCTAssertEqual(mappings, [["Left": [1, 2, 3]], ["Left": [1, 2], "Right": [3, 4]]])
        XCTAssertEqual(disabled, 0)
        let saved = try JSONDecoder().decode(SavedMonitorConfig.self,
                                             from: Data(contentsOf: ConfigStore.monitorConfigPath))
        XCTAssertEqual(saved.workspaceMonitors, ["Left": [1, 2], "Right": [3, 4]])

        config.workspaceMonitors = WorkspaceHomeResolver.setting([], for: "Left", in: config.workspaceMonitors)
        config.workspaceMonitors = WorkspaceHomeResolver.setting([], for: "Right", in: config.workspaceMonitors)
        XCTAssertEqual(mappings.last, [:])
        let cleared = try JSONDecoder().decode(SavedMonitorConfig.self,
                                               from: Data(contentsOf: ConfigStore.monitorConfigPath))
        XCTAssertNil(cleared.workspaceMonitors)
    }

    func testEveryVisualChangeUsesOnlyChromeRoute() {
        let original = state()
        let variants = [
            state(showBorder: false),
            state(focusColor: "112233"),
            state(floatingColor: "445566"),
            state(bracketStyle: .off),
            state(bracketColor: "778899"),
            state(bracketRadius: 9),
            state(bracketThickness: 5),
            state(dim: true),
            state(intensity: 0.4),
            state(fade: 0.5),
            state(radius: 18),
            state(overlayAppearance: .light),
        ]

        for variant in variants {
            let coordinator = ConfigUpdateCoordinator(initial: original)
            var chrome = 0
            var layout = 0
            var topology = 0
            var workspace = 0
            var focus = 0
            coordinator.onChrome = { state, _ in
                chrome += 1
                XCTAssertEqual(state, variant, "chrome receives current post-change state")
            }
            coordinator.onLayoutGeometry = { _, _ in layout += 1 }
            coordinator.onMaximumSplits = { _ in topology += 1 }
            coordinator.onDisabledMonitors = { _ in workspace += 1 }
            coordinator.onEnabled = { _ in focus += 1 }

            coordinator.receive(variant)

            XCTAssertEqual(chrome, 1)
            XCTAssertEqual(layout, 0)
            XCTAssertEqual(topology, 0)
            XCTAssertEqual(workspace, 0)
            XCTAssertEqual(focus, 0)
        }
    }

    func testGeometryAndTopologyChangesReachTheirProductionRoutes() {
        let original = state()
        let coordinator = ConfigUpdateCoordinator(initial: original)
        var layouts: [(CGFloat, CGFloat)] = []
        var splitUpdates: [[String: Int]] = []
        var monitorUpdates: [Set<String>] = []
        coordinator.onLayoutGeometry = { layouts.append(($0, $1)) }
        coordinator.onMaximumSplits = { splitUpdates.append($0) }
        coordinator.onDisabledMonitors = { monitorUpdates.append($0) }

        coordinator.receive(state(gap: 12, padding: 14))
        coordinator.receive(state(gap: 12, padding: 14, splits: ["Main": 4]))
        coordinator.receive(state(
            gap: 12, padding: 14, splits: ["Main": 4], disabled: ["Side"]))

        XCTAssertEqual(layouts.count, 1)
        XCTAssertEqual(layouts[0].0, 12)
        XCTAssertEqual(layouts[0].1, 14)
        XCTAssertEqual(splitUpdates, [["Main": 4]])
        XCTAssertEqual(monitorUpdates, [["Side"]])
    }

    func testRepeatedUnchangedSnapshotsDoNotMultiplyNextUpdate() {
        let original = state()
        let coordinator = ConfigUpdateCoordinator(initial: original)
        var layoutCount = 0
        coordinator.onLayoutGeometry = { _, _ in layoutCount += 1 }

        coordinator.receive(original)
        coordinator.receive(original)
        coordinator.receive(state(gap: 10))

        XCTAssertEqual(layoutCount, 1)
    }

    func testMultiFieldVisualUpdateReportsExactChromeFlagsOnce() {
        let original = state()
        let coordinator = ConfigUpdateCoordinator(initial: original)
        var received: [ChromeConfigChanges] = []
        coordinator.onChrome = { _, changes in received.append(changes) }

        coordinator.receive(state(
            showBorder: false, focusColor: "112233", bracketStyle: .off,
            dim: true, intensity: 0.4, fade: 0.5, radius: 18))

        XCTAssertEqual(received, [[
            .visibility, .colors, .bracketAppearance, .dimming,
            .fadeDuration, .windowCornerRadius,
        ]])
    }

    func testEnabledKeybindHyprAndScratchpadRoutesHavePositiveCoverage() {
        let original = state()
        let coordinator = ConfigUpdateCoordinator(initial: original)
        var enabled = 0
        var keybinds = 0
        var keys = 0
        var regions = 0
        var modes = 0
        coordinator.onEnabled = { _ in enabled += 1 }
        coordinator.onKeybinds = { _ in keybinds += 1 }
        coordinator.onHyprKey = { _ in keys += 1 }
        coordinator.onScratchpadRegion = { _ in regions += 1 }
        coordinator.onScratchpadEntryMode = { _ in modes += 1 }

        coordinator.receive(RuntimeConfigState(
            enabled: false,
            keybinds: [Keybind(keyCode: 18, modifiers: .hypr, action: .switchWorkspace(1))],
            hyprKey: .tab, gapSize: 8, outerPadding: 8,
            maxSplitsPerMonitor: [:], disabledMonitors: [],
            showFocusBorder: true, focusBorderColorHex: nil, floatingBorderColorHex: nil,
            focusBracketStyle: .rounded, focusBracketColorHex: nil,
            focusBracketRadius: 14,
            focusBracketThickness: 3,
            dimInactiveWindows: false, dimIntensity: 0.2,
            chromeFadeDurationSec: 0.22, windowCornerRadius: 10,
            scratchpadTileByDefault: false, scratchpadRegionInset: 0.1))

        XCTAssertEqual([enabled, keybinds, keys, regions, modes], [1, 1, 1, 1, 1])
    }

    // per machine: lives in monitor-config.json, never config.json, and
    // loading it at launch must not rewrite config.json (the #50 trap)
    func testExternalControlLivesInMonitorConfigOnly() throws {
        try requireIsolatedHome()
        let configBefore = try? Data(contentsOf: ConfigStore.configPath)
        let monitorBefore = try? Data(contentsOf: ConfigStore.monitorConfigPath)
        defer {
            restore(configBefore, to: ConfigStore.configPath)
            restore(monitorBefore, to: ConfigStore.monitorConfigPath)
        }
        UserConfig().save()
        try Data(#"{"externalControlEnabled":true}"#.utf8).write(to: ConfigStore.monitorConfigPath)
        let configOnDisk = try Data(contentsOf: ConfigStore.configPath)

        let config = UserConfig()
        XCTAssertTrue(config.externalControlEnabled)
        XCTAssertEqual(try Data(contentsOf: ConfigStore.configPath), configOnDisk)

        config.externalControlEnabled = false
        let monitor = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: ConfigStore.monitorConfigPath)) as? [String: Any])
        XCTAssertNil(monitor["externalControlEnabled"])
        let synced = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: ConfigStore.configPath)) as? [String: Any])
        XCTAssertNil(synced["externalControlEnabled"])
    }

    func testProductionObservationIsInstalledOnlyOnceAndReadsStoredValue() throws {
        try requireIsolatedHome()
        let configBefore = try? Data(contentsOf: ConfigStore.configPath)
        let monitorBefore = try? Data(contentsOf: ConfigStore.monitorConfigPath)
        defer {
            restore(configBefore, to: ConfigStore.configPath)
            restore(monitorBefore, to: ConfigStore.monitorConfigPath)
        }
        let config = UserConfig()
        let coordinator = ConfigUpdateCoordinator(initial: RuntimeConfigState(config))
        var receivedGaps: [CGFloat] = []
        coordinator.onLayoutGeometry = { gap, _ in receivedGaps.append(gap) }

        coordinator.observe(config)
        coordinator.observe(config)
        config.gapSize += 2

        XCTAssertEqual(receivedGaps, [config.gapSize])
    }

    func testVisualSaveAndUnchangedReloadStayOffLayoutRoutes() throws {
        try requireIsolatedHome()
        let configBefore = try? Data(contentsOf: ConfigStore.configPath)
        let monitorBefore = try? Data(contentsOf: ConfigStore.monitorConfigPath)
        defer {
            restore(configBefore, to: ConfigStore.configPath)
            restore(monitorBefore, to: ConfigStore.monitorConfigPath)
        }
        let config = UserConfig()
        let coordinator = ConfigUpdateCoordinator(initial: RuntimeConfigState(config))
        var chromeStates: [RuntimeConfigState] = []
        var layouts = 0
        var topology = 0
        var workspaces = 0
        coordinator.onChrome = { state, _ in chromeStates.append(state) }
        coordinator.onLayoutGeometry = { _, _ in layouts += 1 }
        coordinator.onMaximumSplits = { _ in topology += 1 }
        coordinator.onDisabledMonitors = { _ in workspaces += 1 }
        coordinator.observe(config)

        config.focusBorderColorHex = "123456"
        config.reloadFromDisk()

        XCTAssertEqual(chromeStates.count, 1)
        XCTAssertEqual(chromeStates.first?.focusBorderColorHex, "123456")
        XCTAssertEqual(layouts, 0)
        XCTAssertEqual(topology, 0)
        XCTAssertEqual(workspaces, 0)
    }

    func testStoppedManagerCannotShowBracketsForAnAppearanceChange() {
        XCTAssertFalse(FocusBracketAppearanceUpdate.shouldShow(
            isRunning: false, hyprHeld: true, style: .rounded, isVisible: false))
    }

    func testTurningBracketsOnWhileHyprHeldRequestsOneVisualShow() {
        XCTAssertTrue(FocusBracketAppearanceUpdate.shouldShow(
            isRunning: true, hyprHeld: true, style: .rounded, isVisible: false))
        XCTAssertFalse(FocusBracketAppearanceUpdate.shouldShow(
            isRunning: true, hyprHeld: false, style: .rounded, isVisible: false))
        XCTAssertFalse(FocusBracketAppearanceUpdate.shouldShow(
            isRunning: true, hyprHeld: true, style: .off, isVisible: false))
        XCTAssertFalse(FocusBracketAppearanceUpdate.shouldShow(
            isRunning: true, hyprHeld: true, style: .rounded, isVisible: true))
    }

    func testWindowAndBracketRadiiHaveIndependentChromeEffects() {
        let original = state()
        let windowCoordinator = ConfigUpdateCoordinator(initial: original)
        let bracketCoordinator = ConfigUpdateCoordinator(initial: original)
        var windowEffects: ChromeConfigChanges = []
        var bracketEffects: ChromeConfigChanges = []
        var statefulRoutes = 0
        windowCoordinator.onChrome = { _, effects in windowEffects = effects }
        bracketCoordinator.onChrome = { _, effects in bracketEffects = effects }
        for coordinator in [windowCoordinator, bracketCoordinator] {
            coordinator.onLayoutGeometry = { _, _ in statefulRoutes += 1 }
            coordinator.onMaximumSplits = { _ in statefulRoutes += 1 }
            coordinator.onDisabledMonitors = { _ in statefulRoutes += 1 }
        }

        windowCoordinator.receive(state(radius: 18))
        bracketCoordinator.receive(state(bracketRadius: 9))

        XCTAssertEqual(windowEffects, [.windowCornerRadius])
        XCTAssertEqual(bracketEffects, [.bracketAppearance])
        XCTAssertEqual(statefulRoutes, 0)
    }

    func testBracketLengthIsChromeOnlyAndIndependentOfThickness() {
        let coordinator = ConfigUpdateCoordinator(initial: state())
        var effects: ChromeConfigChanges = []
        var observed: RuntimeConfigState?
        var layoutChanges = 0
        coordinator.onChrome = { snapshot, changes in observed = snapshot; effects = changes }
        coordinator.onLayoutGeometry = { _, _ in layoutChanges += 1 }
        coordinator.onMaximumSplits = { _ in layoutChanges += 1 }
        coordinator.onDisabledMonitors = { _ in layoutChanges += 1 }

        coordinator.receive(state(bracketLength: 28))

        XCTAssertEqual(effects, [.bracketAppearance])
        XCTAssertEqual(observed?.focusBracketLength, 28)
        XCTAssertEqual(observed?.focusBracketThickness, 3)
        XCTAssertEqual(layoutChanges, 0)
    }

    func testBracketThicknessIsChromeOnly() {
        let coordinator = ConfigUpdateCoordinator(initial: state())
        var effects: ChromeConfigChanges = []
        var statefulRoutes = 0
        coordinator.onChrome = { _, newEffects in effects = newEffects }
        coordinator.onLayoutGeometry = { _, _ in statefulRoutes += 1 }
        coordinator.onMaximumSplits = { _ in statefulRoutes += 1 }
        coordinator.onDisabledMonitors = { _ in statefulRoutes += 1 }

        coordinator.receive(state(bracketThickness: 5))

        XCTAssertEqual(effects, [.bracketAppearance])
        XCTAssertEqual(statefulRoutes, 0)
    }

    func testDiskReloadAppliesHoverRateBeforeItsSingleRuntimeSignal() throws {
        try requireIsolatedHome()
        let configBefore = try? Data(contentsOf: ConfigStore.configPath)
        let monitorBefore = try? Data(contentsOf: ConfigStore.monitorConfigPath)
        defer {
            restore(configBefore, to: ConfigStore.configPath)
            restore(monitorBefore, to: ConfigStore.monitorConfigPath)
        }
        let config = UserConfig()
        config.mouseHoverPollHz = 47
        let savedAt47 = try Data(contentsOf: ConfigStore.configPath)
        config.mouseHoverPollHz = 88

        var observed: [Int] = []
        let observation = config.didApplyRuntimeChange.sink {
            observed.append(config.mouseHoverPollHz)
        }
        defer { observation.cancel() }

        try savedAt47.write(to: ConfigStore.configPath)
        config.reloadFromDisk()

        XCTAssertEqual(config.mouseHoverPollHz, 47)
        XCTAssertEqual(observed, [47])
    }

    func testAppearanceResetIsAtomicAndLeavesLayoutPreferencesAlone() throws {
        try requireIsolatedHome()
        let configBefore = try? Data(contentsOf: ConfigStore.configPath)
        let monitorBefore = try? Data(contentsOf: ConfigStore.monitorConfigPath)
        defer {
            restore(configBefore, to: ConfigStore.configPath)
            restore(monitorBefore, to: ConfigStore.monitorConfigPath)
        }
        let config = UserConfig()
        config.gapSize = 23
        config.focusBracketThicknessOverride = 5
        config.focusBracketLengthOverride = 25
        config.focusBracketRadiusOverride = 2
        config.showFocusBorder = true
        config.dimInactiveWindows = false

        var notifications = 0
        let observation = config.didApplyRuntimeChange.sink { notifications += 1 }
        defer { observation.cancel() }
        config.resetAppearanceToDefaults()

        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(config.gapSize, 23)
        XCTAssertEqual(config.resolvedFocusBracketThickness, 4.5)
        XCTAssertEqual(config.resolvedFocusBracketLength, 15)
        XCTAssertNil(config.focusBracketLengthOverride)
        XCTAssertEqual(config.resolvedFocusBracketRadius, 20)
        XCTAssertEqual(config.focusBracketStyle, .rounded)
        XCTAssertFalse(config.showFocusBorder)
        XCTAssertTrue(config.dimInactiveWindows)
    }

    func testResetToDefaultsRestoresEverySetting() throws {
        try requireIsolatedHome()
        let configBefore = try? Data(contentsOf: ConfigStore.configPath)
        let monitorBefore = try? Data(contentsOf: ConfigStore.monitorConfigPath)
        defer {
            restore(configBefore, to: ConfigStore.configPath)
            restore(monitorBefore, to: ConfigStore.monitorConfigPath)
        }
        let config = UserConfig()
        config.keybinds = []
        config.gapSize = 31
        config.outerPadding = 32
        config.enabled = false
        config.focusFollowsMouse = false
        config.mouseHoverPollHz = 33
        config.hyprKey = .leftOption
        config.excludedBundleIDs = ["com.example.app"]
        config.showMenuBarIndicator = false
        config.overlayAppearance = .dark
        config.maxSplitsPerMonitor = ["Screen": 2]
        config.disabledMonitors = ["Screen"]
        config.outerPaddingPerMonitor = ["Screen": EdgePadding(top: 1, left: 2, bottom: 3, right: 4)]
        config.workspaceMonitors = ["Screen": [1]]
        config.showFocusBorder = true
        config.focusBorderColorHex = "111111"
        config.floatingBorderColorHex = "222222"
        config.focusBracketStyle = .off
        config.focusBracketColorHex = "333333"
        config.focusBracketRadiusOverride = 1
        config.focusBracketThicknessOverride = 2
        config.focusBracketLengthOverride = 3
        config.dimInactiveWindows = false
        config.dimIntensity = 0.5
        config.chromeFadeDurationSec = 0.5
        config.windowCornerRadiusOverride = 4
        config.scratchpadTileByDefault = false
        config.scratchpadRegionInset = 0.2
        config.restoreLayoutOnLaunch = true
        config.windowRules = [WindowRule(bundleID: "com.example.app", workspace: 2)]
        config.workspaceNames = ["1": "one"]
        config.statusExportEnabled = true
        config.statusHookCommand = "true"
        config.externalControlEnabled = true

        config.resetToDefaults()

        XCTAssertEqual(config.keybinds, Keybind.defaults)
        XCTAssertEqual(config.gapSize, UserConfigDefaults.gapSize)
        XCTAssertEqual(config.outerPadding, UserConfigDefaults.outerPadding)
        XCTAssertEqual(config.enabled, UserConfigDefaults.enabled)
        XCTAssertEqual(config.focusFollowsMouse, UserConfigDefaults.focusFollowsMouse)
        XCTAssertEqual(config.mouseHoverPollHz, UserConfigDefaults.mouseHoverPollHz)
        XCTAssertEqual(config.hyprKey, UserConfigDefaults.hyprKey)
        XCTAssertEqual(config.excludedBundleIDs, Set(UserConfig.defaultExcludedBundleIDs))
        XCTAssertEqual(config.showMenuBarIndicator, UserConfigDefaults.showMenuBarIndicator)
        XCTAssertEqual(config.overlayAppearance, UserConfigDefaults.overlayAppearance)
        XCTAssertEqual(config.maxSplitsPerMonitor, [:])
        XCTAssertEqual(config.disabledMonitors, [])
        XCTAssertEqual(config.outerPaddingPerMonitor, [:])
        XCTAssertEqual(config.workspaceMonitors, [:])
        XCTAssertEqual(config.showFocusBorder, UserConfigDefaults.showFocusBorder)
        XCTAssertNil(config.focusBorderColorHex)
        XCTAssertNil(config.floatingBorderColorHex)
        XCTAssertEqual(config.focusBracketStyle, UserConfigDefaults.focusBracketStyle)
        XCTAssertNil(config.focusBracketColorHex)
        XCTAssertNil(config.focusBracketRadiusOverride)
        XCTAssertNil(config.focusBracketThicknessOverride)
        XCTAssertNil(config.focusBracketLengthOverride)
        XCTAssertEqual(config.dimInactiveWindows, UserConfigDefaults.dimInactiveWindows)
        XCTAssertEqual(config.dimIntensity, UserConfigDefaults.dimIntensity)
        XCTAssertEqual(config.chromeFadeDurationSec, UserConfigDefaults.chromeFadeDurationSec)
        XCTAssertNil(config.windowCornerRadiusOverride)
        XCTAssertEqual(config.scratchpadTileByDefault, UserConfigDefaults.scratchpadTileByDefault)
        XCTAssertEqual(config.scratchpadRegionInset, UserConfigDefaults.scratchpadRegionInset)
        XCTAssertEqual(config.restoreLayoutOnLaunch, UserConfigDefaults.restoreLayoutOnLaunch)
        XCTAssertEqual(config.windowRules, [])
        XCTAssertEqual(config.workspaceNames, [:])
        XCTAssertFalse(config.statusExportEnabled)
        XCTAssertNil(config.statusHookCommand)
        XCTAssertFalse(config.externalControlEnabled)

        // the reset reached disk, not just the object
        let saved = try JSONDecoder().decode(
            SavedConfig.self, from: Data(contentsOf: ConfigStore.configPath))
        XCTAssertEqual(saved.keybinds, Keybind.defaults)
        XCTAssertEqual(saved.gapSize, UserConfigDefaults.gapSize)
        XCTAssertNil(saved.windowRules)
        XCTAssertNil(saved.workspaceNames)
    }

    func testHarnessKeepsTheICloudSymlinkOutOfTheIsolatedHome() throws {
        try requireIsolatedHome()
        XCTAssertEqual(UserDefaults.standard.object(forKey: "iCloudSyncEnabled") as? Bool, false)
        let config = UserConfig()
        XCTAssertFalse(config.iCloudSyncEnabled)
        let values = try? ConfigStore.configPath.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertNotEqual(values?.isSymbolicLink, true)
    }

    func testFreshInstallUsesBlackCornersWithCurrentMarkDefaults() throws {
        try requireIsolatedHome()
        let configBefore = try? Data(contentsOf: ConfigStore.configPath)
        let monitorBefore = try? Data(contentsOf: ConfigStore.monitorConfigPath)
        defer {
            restore(configBefore, to: ConfigStore.configPath)
            restore(monitorBefore, to: ConfigStore.monitorConfigPath)
        }
        if FileManager.default.fileExists(atPath: ConfigStore.configPath.path) {
            try FileManager.default.removeItem(at: ConfigStore.configPath)
        }
        let config = UserConfig()
        XCTAssertEqual(config.focusBracketStyle, .rounded)
        XCTAssertFalse(config.showFocusBorder)
        XCTAssertEqual(config.resolvedFocusBracketRadius, 20)
        XCTAssertEqual(config.resolvedFocusBracketThickness, 4.5)
        XCTAssertEqual(config.resolvedFocusBracketLength, 15)
        XCTAssertEqual(config.resolvedFocusBracketColor.usingColorSpace(.sRGB), NSColor.black.usingColorSpace(.sRGB))
        config.save()
        config.reloadFromDisk()
        XCTAssertEqual(config.resolvedFocusBracketLength, 15)
        XCTAssertEqual(config.resolvedFocusBracketThickness, 4.5)
        config.focusBracketColorHex = "123456"
        config.focusBracketRadiusOverride = 8
        config.focusBracketThicknessOverride = 2
        config.focusBracketLengthOverride = 25
        config.reloadFromDisk()
        XCTAssertEqual(config.focusBracketColorHex, "123456")
        XCTAssertEqual(config.resolvedFocusBracketRadius, 8)
        XCTAssertEqual(config.resolvedFocusBracketThickness, 2)
        XCTAssertEqual(config.resolvedFocusBracketLength, 25)
    }

    func testLegacyCornerLengthMigratesOnceAndSavesIndependently() throws {
        try requireIsolatedHome()
        let configBefore = try? Data(contentsOf: ConfigStore.configPath)
        let monitorBefore = try? Data(contentsOf: ConfigStore.monitorConfigPath)
        defer {
            restore(configBefore, to: ConfigStore.configPath)
            restore(monitorBefore, to: ConfigStore.monitorConfigPath)
        }
        let legacy = Data(#"{"keybinds":[],"gapSize":23,"outerPadding":11,"enabled":false,"focusBracketThickness":4.5}"#.utf8)
        try legacy.write(to: ConfigStore.configPath)
        let config = UserConfig()
        XCTAssertEqual(config.overlayAppearance, .system)
        XCTAssertEqual(config.resolvedFocusBracketThickness, 4.5)
        XCTAssertEqual(config.resolvedFocusBracketLength, 21)
        config.focusBracketThicknessOverride = 6
        XCTAssertEqual(config.resolvedFocusBracketLength, 21)
        config.reloadFromDisk()
        XCTAssertEqual(config.resolvedFocusBracketLength, 21)
        XCTAssertEqual(config.resolvedFocusBracketThickness, 6)
        config.focusBracketLengthOverride = 10
        XCTAssertEqual(config.resolvedFocusBracketThickness, 6)
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(contentsOf: ConfigStore.configPath))
        XCTAssertEqual(saved.focusBracketLength, 10)
        XCTAssertEqual(saved.focusBracketThickness, 6)
        XCTAssertEqual(saved.gapSize, 23)
        XCTAssertFalse(saved.enabled)
        config.focusBracketLengthOverride = nil
        config.focusBracketThicknessOverride = 4
        config.reloadFromDisk()
        XCTAssertEqual(config.resolvedFocusBracketLength, 15)
        XCTAssertEqual(config.resolvedFocusBracketThickness, 4)
    }

    func testOverlayAppearancePersistsAndReloads() throws {
        try requireIsolatedHome()
        let configBefore = try? Data(contentsOf: ConfigStore.configPath)
        let monitorBefore = try? Data(contentsOf: ConfigStore.monitorConfigPath)
        defer {
            restore(configBefore, to: ConfigStore.configPath)
            restore(monitorBefore, to: ConfigStore.monitorConfigPath)
        }

        let config = UserConfig()
        config.overlayAppearance = .dark
        let saved = try JSONDecoder().decode(
            SavedConfig.self, from: Data(contentsOf: ConfigStore.configPath))
        XCTAssertEqual(saved.overlayAppearance, .dark)

        config.overlayAppearance = .light
        config.reloadFromDisk()
        XCTAssertEqual(config.overlayAppearance, .light)
    }

    func testFloatMigrationOnStartupReloadAndSave() throws {
        try requireIsolatedHome()
        let configBefore = try? Data(contentsOf: ConfigStore.configPath)
        let monitorBefore = try? Data(contentsOf: ConfigStore.monitorConfigPath)
        defer {
            restore(configBefore, to: ConfigStore.configPath)
            restore(monitorBefore, to: ConfigStore.monitorConfigPath)
        }
        let legacy = Data(#"{"keybinds":[{"keyCode":17,"modifiers":3,"action":{"toggleFloating":{}}}],"gapSize":23,"outerPadding":11,"enabled":false}"#.utf8)
        try legacy.write(to: ConfigStore.configPath)
        let config = UserConfig()
        let expected = Keybind(keyCode: 17, modifiers: .hypr, action: .toggleFloating)
        XCTAssertEqual(config.keybinds.filter { $0.action == .toggleFloating }, [expected])
        XCTAssertEqual(try Data(contentsOf: ConfigStore.configPath), legacy)
        config.reloadFromDisk()
        XCTAssertEqual(config.keybinds.filter { $0.action == .toggleFloating }, [expected])
        XCTAssertEqual(config.gapSize, 23)
        XCTAssertEqual(config.outerPadding, 11)
        XCTAssertFalse(config.enabled)
        config.save()
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(contentsOf: ConfigStore.configPath))
        XCTAssertEqual(saved.keybinds.filter { $0.action == .toggleFloating }, [expected])
        config.reloadFromDisk()
        XCTAssertEqual(config.keybinds, saved.keybinds)
    }

    func testFloatingFocusMigrationOnStartupReloadAndSave() throws {
        try requireIsolatedHome()
        let configBefore = try? Data(contentsOf: ConfigStore.configPath)
        let monitorBefore = try? Data(contentsOf: ConfigStore.monitorConfigPath)
        defer {
            restore(configBefore, to: ConfigStore.configPath)
            restore(monitorBefore, to: ConfigStore.monitorConfigPath)
        }
        let legacy = Data(#"{"keybinds":[{"keyCode":3,"modifiers":1,"action":{"focusFloating":{}}}],"gapSize":23,"outerPadding":11,"enabled":false}"#.utf8)
        try legacy.write(to: ConfigStore.configPath)

        let config = UserConfig()
        let relocated = Keybind(keyCode: 17, modifiers: [.hypr, .shift], action: .focusFloating)
        XCTAssertEqual(config.keybinds.filter { $0.action == .focusFloating }, [relocated])
        XCTAssertTrue(config.keybinds.contains { $0.action == .toggleMaximize })
        XCTAssertEqual(try Data(contentsOf: ConfigStore.configPath), legacy)

        config.reloadFromDisk()
        XCTAssertEqual(config.keybinds.filter { $0.action == .focusFloating }, [relocated])
        XCTAssertTrue(config.keybinds.contains { $0.action == .toggleMaximize })
        config.save()
        let saved = try JSONDecoder().decode(
            SavedConfig.self, from: Data(contentsOf: ConfigStore.configPath))
        XCTAssertEqual(saved.keybinds.filter { $0.action == .focusFloating }, [relocated])
        XCTAssertTrue(saved.keybinds.contains { $0.action == .toggleMaximize })
        config.reloadFromDisk()
        XCTAssertEqual(config.keybinds, saved.keybinds)
    }

    func testDiskReloadInjectsMissingPauseBinding() throws {
        try requireIsolatedHome()
        let configBefore = try? Data(contentsOf: ConfigStore.configPath)
        let monitorBefore = try? Data(contentsOf: ConfigStore.monitorConfigPath)
        defer {
            restore(configBefore, to: ConfigStore.configPath)
            restore(monitorBefore, to: ConfigStore.monitorConfigPath)
        }
        let config = UserConfig()
        let oldCustomBind = Keybind(
            keyCode: 32, modifiers: [.hypr, .shift], action: .showKeybinds)
        config.keybinds = [oldCustomBind]

        config.reloadFromDisk()

        XCTAssertTrue(config.keybinds.contains { $0 == oldCustomBind })
        XCTAssertTrue(config.keybinds.contains { $0.action == .toggleTiling })
    }
}
