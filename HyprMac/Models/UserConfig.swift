// User-facing configuration. SwiftUI views bind to the published
// properties; mutations write through to disk via `ConfigStore` and
// notify observers. Persists to
// `~/Library/Application Support/HyprMac/config.json`.

import Foundation
import Cocoa
import Combine

/// Persisted user preferences exposed as a SwiftUI-observable model.
///
/// Each public field is `@Published` so SwiftUI views and Combine
/// subscribers re-render on change. Every mutation writes through to
/// `ConfigStore` (except while `isReloading` is set during programmatic
/// reloads) and emits notifications to drive `WindowManager`'s live
/// re-tile / re-bind paths.
///
/// Threading: main-thread only. The shared singleton is accessed
/// directly across SwiftUI and orchestration code.
class UserConfig: ObservableObject {
    /// Process-wide singleton bound by SwiftUI views and the
    /// orchestration layer.
    static let shared: UserConfig = {
        #if DEBUG
        // the overlay preview only reads the config
        if OverlayPreview.isRequested { return UserConfig(repairsOnLaunch: false) }
        #endif
        return UserConfig()
    }()
    let didApplyRuntimeChange = PassthroughSubject<Void, Never>()

    @Published var keybinds: [Keybind] {
        didSet { persistRuntimeChange() }
    }
    @Published var gapSize: CGFloat {
        didSet { persistRuntimeChange() }
    }
    @Published var outerPadding: CGFloat {
        didSet { persistRuntimeChange() }
    }
    @Published var enabled: Bool {
        didSet { persistRuntimeChange() }
    }
    @Published var focusFollowsMouse: Bool {
        didSet { persistRuntimeChange() }
    }
    @Published var keepCursorOnWorkspaceSwitch: Bool {
        didSet { persistRuntimeChange() }
    }
    /// Two quick taps of the Hypr key alone toggle Caps Lock. Off by default.
    @Published var doubleTapHyprTogglesCapsLock: Bool {
        didSet { persistRuntimeChange() }
    }
    @Published var animateFocusIndicator: Bool {
        didSet { persistRuntimeChange() }
    }
    @Published var mouseHoverPollHz: Int {
        didSet { persistRuntimeChange() }
    }
    @Published var hyprKey: HyprKey {
        didSet { persistRuntimeChange() }
    }
    @Published var excludedBundleIDs: Set<String> {
        didSet {
            guard !isReloading else { return }
            persistRuntimeChange()
            floatingRulesEdited.send()
        }
    }
    @Published var showMenuBarIndicator: Bool {
        didSet { persistRuntimeChange() }
    }
    @Published var overlayAppearance: OverlayAppearance {
        didSet { persistRuntimeChange() }
    }
    @Published var maxSplitsPerMonitor: [String: Int] {
        didSet { persistRuntimeChange() }
    }
    @Published var disabledMonitors: Set<String> {
        didSet { persistRuntimeChange() }
    }
    @Published var outerPaddingPerMonitor: [String: EdgePadding] {
        didSet { persistRuntimeChange() }
    }
    // monitor name → workspaces that live there. empty = the formula homes.
    // hand-written or Nix only now; the fallback for display sets below
    @Published var workspaceMonitors: [String: [Int]] {
        didSet { persistRuntimeChange() }
    }
    // the mapping per set of connected displays. Settings edits this
    @Published var workspaceMonitorsPerDisplaySet: [DisplaySetWorkspaces] {
        didSet { persistRuntimeChange() }
    }
    @Published var showFocusBorder: Bool {
        didSet { persistRuntimeChange() }
    }
    // the window border tints the window briefly when focus lands on it
    @Published var focusBorderFlash: Bool {
        didSet { persistRuntimeChange() }
    }
    // hex string like "007AFF" — nil means brand cyan
    @Published var focusBorderColorHex: String? {
        didSet { persistRuntimeChange() }
    }
    // hex string for floating window border — nil means brand magenta
    @Published var floatingBorderColorHex: String? {
        didSet { persistRuntimeChange() }
    }
    @Published var focusBracketStyle: FocusBracketStyle {
        didSet { persistRuntimeChange() }
    }
    // nil means the default black brackets
    @Published var focusBracketColorHex: String? {
        didSet { persistRuntimeChange() }
    }
    @Published var focusBracketRadiusOverride: CGFloat? {
        didSet { persistRuntimeChange() }
    }
    var resolvedFocusBracketRadius: CGFloat {
        focusBracketRadiusOverride ?? UserConfigDefaults.focusBracketRadius
    }
    @Published var focusBracketThicknessOverride: CGFloat? {
        didSet { persistRuntimeChange() }
    }
    var resolvedFocusBracketThickness: CGFloat {
        focusBracketThicknessOverride ?? UserConfigDefaults.focusBracketThickness
    }
    @Published var focusBracketLengthOverride: CGFloat? {
        didSet { persistRuntimeChange() }
    }
    var resolvedFocusBracketLength: CGFloat {
        focusBracketLengthOverride ?? UserConfigDefaults.focusBracketLength
    }
    @Published var dimInactiveWindows: Bool {
        didSet { persistRuntimeChange() }
    }
    // 0..1 alpha of the dimming overlay; 0.2 is subtle, 0.4 is strong
    @Published var dimIntensity: Double {
        didSet { persistRuntimeChange() }
    }
    // shared fade duration for the focus border show/hide and the dim
    // overlay opacity transitions. Settings slider clamps to a sensible
    // range; both subsystems read from this on every animation start.
    @Published var chromeFadeDurationSec: Double {
        didSet { persistRuntimeChange() }
    }
    // nil follows the OS-version-dependent default; a value is an explicit
    // user override shared by focus borders and dim cut-outs
    @Published var windowCornerRadiusOverride: CGFloat? {
        didSet { persistRuntimeChange() }
    }
    var windowCornerRadius: CGFloat {
        UserConfigDefaults.resolvedWindowCornerRadius(
            override: windowCornerRadiusOverride,
            forOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
    // windows sent to the scratchpad tile into the layer by default;
    // ones that don't fit stay floating members either way
    @Published var scratchpadTileByDefault: Bool {
        didSet { persistRuntimeChange() }
    }
    // per-edge inset fraction of the scratchpad's tiled region (0 = edge
    // to edge, 0.06 = classic scrimmed border)
    @Published var scratchpadRegionInset: CGFloat {
        didSet { persistRuntimeChange() }
    }

    // restore the saved layout for this display setup at launch. saved to
    // config.json; read once at startup, so nothing live needs re-applying
    @Published var restoreLayoutOnLaunch: Bool {
        didSet { guard !isReloading else { return }; save() }
    }

    // per-app workspace pins. read when a window is placed, so nothing
    // live needs re-applying on change
    @Published var windowRules: [WindowRule] {
        didSet { guard !isReloading else { return }; save() }
    }

    // float and tile rules beyond the app-wide float list in
    // excludedBundleIDs. WindowManager watches both lists and re-applies a
    // change to the open windows it touches
    @Published var floatingRules: [FloatingRule] {
        didSet {
            guard !isReloading else { return }
            save()
            floatingRulesEdited.send()
        }
    }

    /// A float or tile rule edit made on this Mac (Settings, the menu bar,
    /// an action). Open windows follow it at once.
    let floatingRulesEdited = PassthroughSubject<Void, Never>()
    /// The rules were replaced by a reload from disk (iCloud, Nix, a hand
    /// edit) or a reset. As before rules existed, that reaches new windows,
    /// Hypr+T and Retile All, and moves nothing open.
    let floatingRulesReloaded = PassthroughSubject<Void, Never>()

    // custom names for workspaces 1–10, keyed "1"…"10". display only:
    // every reader looks it up through `workspaceDisplayName`
    // one accent for the overlays. nil keeps the brand cyan and magenta pair
    @Published var overlayAccentHex: String? {
        didSet { persistRuntimeChange() }
    }
    @Published var workspaceNames: [String: String] {
        didSet { guard !isReloading else { return }; save() }
    }

    // status bar export: state.json, the change hook and hyprmac:// URLs.
    // read on every change, so nothing live needs re-applying. kept in
    // monitor-config.json (per machine), set by hand, no Settings UI
    @Published var statusExportEnabled: Bool {
        didSet { guard !isReloading else { return }; save() }
    }
    // run after each state.json write, like a runCommand keybind (no shell)
    @Published var statusHookCommand: String? {
        didSet { guard !isReloading else { return }; save() }
    }
    // hyprmac://action/… links from other apps. per machine like the export,
    // so turning it on here doesn't turn it on for every synced Mac
    @Published var externalControlEnabled: Bool {
        didSet { guard !isReloading else { return }; save() }
    }

    // iCloud sync state — stored in UserDefaults, not config.json
    @Published var iCloudSyncEnabled: Bool {
        didSet {
            // another tool's link or folder is not ours to move into iCloud.
            // the switch goes back off, so it never shows a sync that isn't
            // happening. setting it here doesn't run didSet again
            if iCloudSyncEnabled, store.isLinkedByAnotherTool {
                iCloudSyncEnabled = false
            }
            if iCloudSyncEnabled {
                // joined a copy already in iCloud: its settings are the live ones now
                if store.enableICloudSync(snapshot: { [weak self] in self?.makeSavedConfig() ?? .empty },
                                          cloudWins: !joinUsesThisMac) {
                    reloadFromDisk()
                }
                // nothing set up, say a copy in iCloud not downloaded yet. the
                // switch must not show a sync that isn't happening
                if !store.isLinkedToICloud { iCloudSyncEnabled = false }
            } else {
                store.disableICloudSync(snapshot: { [weak self] in self?.makeSavedConfig() ?? .empty })
            }
            UserDefaults.standard.set(iCloudSyncEnabled, forKey: "iCloudSyncEnabled")
        }
    }

    private var joinUsesThisMac = false

    // the path changed while running: another tool's link, or a file that
    // can't be written, took the place of the iCloud link. the switch and
    // its preference follow the disk, as at launch
    private func matchSyncSwitchToDisk() {
        guard iCloudSyncEnabled, isICloudSyncLocked, !store.isLinkedToICloud else { return }
        iCloudSyncEnabled = false
    }

    /// Turns sync on after the user picked a side, when this Mac and iCloud
    /// hold different settings. The other side is kept as config.json.replaced.
    func turnOnICloudSync(usingThisMac: Bool) {
        joinUsesThisMac = usingThisMac
        iCloudSyncEnabled = true
        joinUsesThisMac = false
    }

    /// True when turning sync on should ask which settings to keep.
    var iCloudCopyDiffersFromLocal: Bool { store.iCloudCopyDiffersFromLocal }

    static let showDockIconKey = "showDockIcon"
    // old per Mac on/off for the menu bar item. only read to migrate
    static let showMenuBarIconKey = "showMenuBarIcon"
    // per Mac too. read through @AppStorage by the menu bar scene and the
    // Settings picker; a direct UserDefaults write can miss the first update
    static let menuBarStyleKey = "menuBarStyle"

    // per Mac like iCloud sync: stored in UserDefaults, not config.json.
    // off (the default) keeps HyprMac out of the Dock; AppDelegate applies it
    @Published var showDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(showDockIcon, forKey: Self.showDockIconKey)
            NotificationCenter.default.post(name: .hyprMacDockIconChanged, object: nil)
        }
    }

    /// Gates `didSet` save handlers during a programmatic reload.
    ///
    /// Every `@Published` property writes to disk in its `didSet`
    /// unless this flag is `true`. Without the flag, a single
    /// `reloadFromDisk` would rewrite the file once per
    /// property update, and the file watcher would observe each
    /// write and re-fire reload in a tight loop. Set `true` *before*
    /// mass property updates, then `false`. Main-thread only.
    private var isReloading = false

    private let store: ConfigStore

    var configURL: URL { store.localConfigURL }

    var isICloudDriveAvailable: Bool { store.isICloudDriveAvailable }

    /// True when a config file can't be saved, as when Nix manages it.
    /// Changes made in Settings then last until the next load.
    var isConfigReadOnly: Bool { store.isConfigReadOnly || store.isMonitorConfigReadOnly }

    /// True when the iCloud switch can't be used: the config is read-only,
    /// or another tool put it where it is.
    var isICloudSyncLocked: Bool { store.isConfigReadOnly || store.isLinkedByAnotherTool }

    /// `repairsOnLaunch: false` skips the iCloud relink and the monitor-file
    /// migration, the only writes a launch makes before anything changes.
    init(store: ConfigStore = ConfigStore(),
         iCloudSyncEnabled: Bool = RuntimeVariant.inheritedBool(forKey: "iCloudSyncEnabled"),
         showDockIcon: Bool = RuntimeVariant.inheritedBool(forKey: UserConfig.showDockIconKey),
         repairsOnLaunch: Bool = true) {
        self.store = store
        self.iCloudSyncEnabled = iCloudSyncEnabled && !store.isLinkedByAnotherTool
        self.showDockIcon = showDockIcon

        let monitorConfig = store.loadSavedMonitorConfig()
        let savedConfig = store.loadSavedConfig()
        // local-only from the start, so the synced config has nothing to migrate.
        // set before the other stored properties: once init is complete, the
        // optional hook command goes through its setter and didSet saves
        self.statusExportEnabled = monitorConfig?.statusExportEnabled ?? false
        self.statusHookCommand = monitorConfig?.statusHookCommand
        self.externalControlEnabled = monitorConfig?.externalControlEnabled ?? false

        if let saved = savedConfig {
            self.keybinds = Self.mergeNewDefaults(saved: saved.keybinds,
                                                 fromVersion: ConfigMigration.schemaVersion(of: saved))
            self.gapSize = saved.gapSize
            self.outerPadding = saved.outerPadding
            self.enabled = saved.enabled
            self.focusFollowsMouse = saved.focusFollowsMouse ?? UserConfigDefaults.focusFollowsMouse
            self.keepCursorOnWorkspaceSwitch = saved.keepCursorOnWorkspaceSwitch ?? UserConfigDefaults.keepCursorOnWorkspaceSwitch
            self.doubleTapHyprTogglesCapsLock = saved.doubleTapHyprTogglesCapsLock ?? UserConfigDefaults.doubleTapHyprTogglesCapsLock
            self.animateFocusIndicator = saved.animateFocusIndicator ?? UserConfigDefaults.animateFocusIndicator
            self.mouseHoverPollHz = saved.mouseHoverPollHz ?? UserConfigDefaults.mouseHoverPollHz
            self.hyprKey = saved.hyprKey ?? UserConfigDefaults.hyprKey
            self.excludedBundleIDs = Set(saved.excludedBundleIDs ?? Self.defaultExcludedBundleIDs)
            self.showMenuBarIndicator = saved.showMenuBarIndicator ?? UserConfigDefaults.showMenuBarIndicator
            self.overlayAppearance = saved.overlayAppearance ?? UserConfigDefaults.overlayAppearance
            self.showFocusBorder = saved.showFocusBorder ?? UserConfigDefaults.showFocusBorder
            self.focusBorderFlash = saved.focusBorderFlash ?? UserConfigDefaults.focusBorderFlash
            self.focusBorderColorHex = saved.focusBorderColorHex
            self.floatingBorderColorHex = saved.floatingBorderColorHex
            self.focusBracketStyle = saved.focusBracketStyle ?? UserConfigDefaults.focusBracketStyle
            // Before bracket color had its own field it followed the focus
            // border. Preserve an explicit legacy color during migration.
            self.focusBracketColorHex = ConfigMigration.resolveFocusBracketColor(saved: saved)
            self.focusBracketRadiusOverride = saved.focusBracketRadius
            self.focusBracketThicknessOverride = saved.focusBracketThickness
            self.focusBracketLengthOverride = Self.resolveSavedFocusBracketLength(saved)
            self.dimInactiveWindows = saved.dimInactiveWindows ?? UserConfigDefaults.dimInactiveWindows
            self.dimIntensity = saved.dimIntensity ?? UserConfigDefaults.dimIntensity
            self.chromeFadeDurationSec = saved.chromeFadeDurationSec ?? UserConfigDefaults.chromeFadeDurationSec
            self.windowCornerRadiusOverride = saved.windowCornerRadius
            self.scratchpadTileByDefault = saved.scratchpadTileByDefault ?? UserConfigDefaults.scratchpadTileByDefault
            self.scratchpadRegionInset = saved.scratchpadRegionInset ?? UserConfigDefaults.scratchpadRegionInset
            self.restoreLayoutOnLaunch = saved.restoreLayoutOnLaunch ?? UserConfigDefaults.restoreLayoutOnLaunch
            self.windowRules = saved.windowRules ?? []
            self.floatingRules = saved.floatingRules ?? []
            self.overlayAccentHex = saved.overlayAccentHex
            self.workspaceNames = saved.workspaceNames ?? [:]
        } else {
            self.keybinds = Keybind.defaults
            self.gapSize = UserConfigDefaults.gapSize
            self.outerPadding = UserConfigDefaults.outerPadding
            self.enabled = UserConfigDefaults.enabled
            self.focusFollowsMouse = UserConfigDefaults.focusFollowsMouse
            self.keepCursorOnWorkspaceSwitch = UserConfigDefaults.keepCursorOnWorkspaceSwitch
            self.doubleTapHyprTogglesCapsLock = UserConfigDefaults.doubleTapHyprTogglesCapsLock
            self.animateFocusIndicator = UserConfigDefaults.animateFocusIndicator
            self.mouseHoverPollHz = UserConfigDefaults.mouseHoverPollHz
            self.hyprKey = UserConfigDefaults.hyprKey
            self.excludedBundleIDs = Set(Self.defaultExcludedBundleIDs)
            self.showMenuBarIndicator = UserConfigDefaults.showMenuBarIndicator
            self.overlayAppearance = UserConfigDefaults.overlayAppearance
            self.showFocusBorder = UserConfigDefaults.showFocusBorder
            self.focusBorderFlash = UserConfigDefaults.focusBorderFlash
            self.focusBorderColorHex = nil
            self.floatingBorderColorHex = nil
            self.focusBracketStyle = UserConfigDefaults.focusBracketStyle
            self.focusBracketColorHex = nil
            self.focusBracketRadiusOverride = nil
            self.focusBracketThicknessOverride = nil
            self.focusBracketLengthOverride = nil
            self.dimInactiveWindows = UserConfigDefaults.dimInactiveWindows
            self.dimIntensity = UserConfigDefaults.dimIntensity
            self.chromeFadeDurationSec = UserConfigDefaults.chromeFadeDurationSec
            self.windowCornerRadiusOverride = nil
            self.scratchpadTileByDefault = UserConfigDefaults.scratchpadTileByDefault
            self.scratchpadRegionInset = UserConfigDefaults.scratchpadRegionInset
            self.restoreLayoutOnLaunch = UserConfigDefaults.restoreLayoutOnLaunch
            self.windowRules = []
            self.floatingRules = []
            self.overlayAccentHex = nil
            self.workspaceNames = [:]
        }

        // monitor settings: prefer the local file; fall back to (and migrate
        // from) the synced config if the local file isn't there yet.
        let resolved = ConfigMigration.resolveMonitorConfig(local: monitorConfig, embedded: savedConfig)
        self.maxSplitsPerMonitor = resolved.maxSplits
        self.disabledMonitors = resolved.disabled
        // local-only from the start, so the synced config has nothing to migrate
        self.outerPaddingPerMonitor = monitorConfig?.outerPaddingPerMonitor ?? [:]
        self.workspaceMonitors = monitorConfig?.workspaceMonitors ?? [:]
        self.workspaceMonitorsPerDisplaySet = monitorConfig?.workspaceMonitorsPerDisplaySet ?? []

        var relinked = false
        if iCloudSyncEnabled, repairsOnLaunch {
            relinked = store.ensureICloudSymlinkIntegrity(snapshot: { [weak self] in self?.makeSavedConfig() ?? .empty })
        }
        store.holdWritesIfLinkUnusable()

        if resolved.needsLocalWrite, repairsOnLaunch {
            store.writeSavedMonitorConfig(makeSavedMonitorConfig())
        }

        // the values above came from the local file the link just replaced.
        // saving them would write old settings over iCloud
        if relinked {
            reloadFromDisk()
        }

        store.onFileChanged = { [weak self] in
            self?.matchSyncSwitchToDisk()
            self?.reloadFromDisk()
        }
        store.startFileWatcher()
    }

    // inject any default keybinds whose action doesn't exist in the saved set.
    // handles upgrades where new actions are added (e.g. focusFloating).
    // never inject onto a chord the user already bound — the injected bind
    // would silently shadow (or be shadowed by) the user's, and neither is
    // discoverable. the user can bind the new action manually in Settings.
    static func mergeNewDefaults(saved: [Keybind],
                                 fromVersion version: Int = ConfigMigration.currentVersion) -> [Keybind] {
        let toggleMigrated = ConfigMigration.migrateToggleFloating(saved: saved)
        let floatingMigrated = ConfigMigration.migrateFocusFloating(saved: toggleMigrated)
        let saved = ConfigMigration.migrateHyprFToMaximize(saved: floatingMigrated, fromVersion: version)
        let savedActions = Set(saved.map { "\($0.action)" })
        let takenChords = Set(saved.map { "\($0.modifiers.rawValue)-\($0.keyCode)" })
        var merged = saved
        for bind in Keybind.defaults {
            guard !savedActions.contains("\(bind.action)") else { continue }
            guard !takenChords.contains("\(bind.modifiers.rawValue)-\(bind.keyCode)") else {
                hyprLog(.notice, .config, "default keybind for \(bind.action) not injected — chord already bound by user")
                continue
            }
            merged.append(bind)
        }
        return merged
    }

    static let defaultExcludedBundleIDs: [String] = [
        "com.apple.FaceTime",
        "com.apple.systempreferences",
    ]

    private static func resolveSavedFocusBracketLength(_ saved: SavedConfig) -> CGFloat {
        if let length = saved.focusBracketLength { return max(4, min(40, length)) }
        let savedThickness = saved.focusBracketThickness ?? 3
        let thickness = max(1, min(6, savedThickness))
        let legacyLength: CGFloat = 14 * (thickness / 3)
        return max(4, min(40, legacyLength))
    }

    func save() {
        store.writeSavedConfig(makeSavedConfig())
        store.writeSavedMonitorConfig(makeSavedMonitorConfig())
    }

    private func makeSavedMonitorConfig() -> SavedMonitorConfig {
        // an entry with no side set is dropped, not saved
        let savedPadding = outerPaddingPerMonitor.filter { !$0.value.isEmpty }
        // same for a monitor with no workspaces; none at all is no mapping
        let savedWorkspaces = workspaceMonitors.filter { !$0.value.isEmpty }
        // an entry with an empty mapping stays: it means the formula on that set
        let savedSets = workspaceMonitorsPerDisplaySet.map {
            DisplaySetWorkspaces(displays: $0.displays, workspaceMonitors: $0.workspaceMonitors.filter { !$0.value.isEmpty })
        }
        return SavedMonitorConfig(
            maxSplitsPerMonitor: maxSplitsPerMonitor,
            disabledMonitors: Array(disabledMonitors),
            outerPaddingPerMonitor: savedPadding.isEmpty ? nil : savedPadding,
            workspaceMonitors: savedWorkspaces.isEmpty ? nil : savedWorkspaces,
            workspaceMonitorsPerDisplaySet: savedSets.isEmpty ? nil : savedSets,
            // off and empty write no key, so a machine that never opts in is unchanged
            statusExportEnabled: statusExportEnabled ? true : nil,
            statusHookCommand: statusHookCommand?.isEmpty == false ? statusHookCommand : nil,
            externalControlEnabled: externalControlEnabled ? true : nil)
    }

    private func persistRuntimeChange() {
        guard !isReloading else { return }
        save()
        didApplyRuntimeChange.send()
    }

    // build a SavedConfig snapshot from the current @Published state.
    // monitor settings stay nil here — they're written separately to the
    // local-only monitor file via ConfigStore.writeSavedMonitorConfig.
    private func makeSavedConfig() -> SavedConfig {
        SavedConfig(
            version: ConfigMigration.currentVersion,
            keybinds: keybinds, gapSize: gapSize,
            outerPadding: outerPadding, enabled: enabled,
            focusFollowsMouse: focusFollowsMouse,
            hyprKey: hyprKey,
            excludedBundleIDs: Array(excludedBundleIDs),
            showMenuBarIndicator: showMenuBarIndicator,
            overlayAppearance: overlayAppearance,
            maxSplitsPerMonitor: nil,
            disabledMonitors: nil,
            showFocusBorder: showFocusBorder,
            focusBorderColorHex: focusBorderColorHex,
            floatingBorderColorHex: floatingBorderColorHex,
            focusBracketStyle: focusBracketStyle,
            focusBracketColorHex: focusBracketColorHex,
            focusBracketRadius: focusBracketRadiusOverride,
            focusBracketThickness: focusBracketThicknessOverride,
            focusBracketLength: resolvedFocusBracketLength,
            dimInactiveWindows: dimInactiveWindows,
            dimIntensity: dimIntensity,
            mouseHoverPollHz: mouseHoverPollHz,
            chromeFadeDurationSec: chromeFadeDurationSec,
            windowCornerRadius: windowCornerRadiusOverride,
            scratchpadTileByDefault: scratchpadTileByDefault,
            scratchpadRegionInset: scratchpadRegionInset,
            restoreLayoutOnLaunch: restoreLayoutOnLaunch,
            windowRules: windowRules.isEmpty ? nil : windowRules,
            floatingRules: floatingRules.isEmpty ? nil : floatingRules,
            workspaceNames: workspaceNames.isEmpty ? nil : workspaceNames,
            overlayAccentHex: overlayAccentHex,
            keepCursorOnWorkspaceSwitch: keepCursorOnWorkspaceSwitch,
            animateFocusIndicator: animateFocusIndicator,
            focusBorderFlash: focusBorderFlash,
            doubleTapHyprTogglesCapsLock: doubleTapHyprTogglesCapsLock)
    }

    // one update: one save and one runtime signal, like resetAppearanceToDefaults.
    // the button has no confirmation, so what it replaces gets a copy
    func resetToDefaults() {
        store.keepCopiesBeforeReset()
        isReloading = true
        keybinds = Keybind.defaults
        gapSize = UserConfigDefaults.gapSize
        outerPadding = UserConfigDefaults.outerPadding
        enabled = UserConfigDefaults.enabled
        focusFollowsMouse = UserConfigDefaults.focusFollowsMouse
        keepCursorOnWorkspaceSwitch = UserConfigDefaults.keepCursorOnWorkspaceSwitch
        doubleTapHyprTogglesCapsLock = UserConfigDefaults.doubleTapHyprTogglesCapsLock
        animateFocusIndicator = UserConfigDefaults.animateFocusIndicator
        mouseHoverPollHz = UserConfigDefaults.mouseHoverPollHz
        hyprKey = UserConfigDefaults.hyprKey
        excludedBundleIDs = Set(Self.defaultExcludedBundleIDs)
        showMenuBarIndicator = UserConfigDefaults.showMenuBarIndicator
        overlayAppearance = UserConfigDefaults.overlayAppearance
        maxSplitsPerMonitor = [:]
        disabledMonitors = []
        outerPaddingPerMonitor = [:]
        workspaceMonitors = [:]
        workspaceMonitorsPerDisplaySet = []
        showFocusBorder = UserConfigDefaults.showFocusBorder
        focusBorderFlash = UserConfigDefaults.focusBorderFlash
        focusBorderColorHex = nil
        floatingBorderColorHex = nil
        overlayAccentHex = nil
        focusBracketStyle = UserConfigDefaults.focusBracketStyle
        focusBracketColorHex = nil
        focusBracketRadiusOverride = nil
        focusBracketThicknessOverride = nil
        focusBracketLengthOverride = nil
        dimInactiveWindows = UserConfigDefaults.dimInactiveWindows
        dimIntensity = UserConfigDefaults.dimIntensity
        chromeFadeDurationSec = UserConfigDefaults.chromeFadeDurationSec
        windowCornerRadiusOverride = nil
        scratchpadTileByDefault = UserConfigDefaults.scratchpadTileByDefault
        scratchpadRegionInset = UserConfigDefaults.scratchpadRegionInset
        restoreLayoutOnLaunch = UserConfigDefaults.restoreLayoutOnLaunch
        windowRules = []
        floatingRules = []
        workspaceNames = [:]
        statusExportEnabled = false
        statusHookCommand = nil
        externalControlEnabled = false
        isReloading = false
        save()
        didApplyRuntimeChange.send()
        floatingRulesReloaded.send()
    }

    // Keys → Reset to defaults. it drops every launcher and command bind with
    // no confirmation, so keep config.json.replaced first, like resetToDefaults
    func resetKeybindsToDefaults() {
        guard keybinds != Keybind.defaults else { return }
        store.keepCopiesBeforeReset(includingMonitorConfig: false)
        keybinds = Keybind.defaults
    }

    /// Restore the controls in Layout → Focus appearance without changing
    /// layout, keybind, monitor, or scratchpad preferences. Overlay
    /// appearance is in General → System, so it stays.
    func resetAppearanceToDefaults() {
        isReloading = true
        animateFocusIndicator = UserConfigDefaults.animateFocusIndicator
        dimInactiveWindows = UserConfigDefaults.dimInactiveWindows
        dimIntensity = UserConfigDefaults.dimIntensity
        focusBracketStyle = UserConfigDefaults.focusBracketStyle
        focusBracketColorHex = nil
        focusBracketRadiusOverride = nil
        focusBracketThicknessOverride = nil
        focusBracketLengthOverride = nil
        windowCornerRadiusOverride = nil
        showFocusBorder = UserConfigDefaults.showFocusBorder
        focusBorderFlash = UserConfigDefaults.focusBorderFlash
        focusBorderColorHex = nil
        floatingBorderColorHex = nil
        overlayAccentHex = nil
        chromeFadeDurationSec = UserConfigDefaults.chromeFadeDurationSec
        isReloading = false
        save()
        didApplyRuntimeChange.send()
    }

    func setFocusIndicators(showCorners: Bool, showBorders: Bool) {
        isReloading = true
        focusBracketStyle = showCorners ? .rounded : .off
        showFocusBorder = showBorders
        isReloading = false
        save()
        didApplyRuntimeChange.send()
    }

    // the drop preview wears the focus color the user picked: the bracket's
    // when brackets are on, else the border's when it is on. dim-only or
    // default colors keep brand cyan
    var resolvedDropPreviewColor: NSColor {
        Self.dropPreviewColorHex(bracketStyle: focusBracketStyle, bracketHex: focusBracketColorHex,
                                 showBorder: showFocusBorder, borderHex: focusBorderColorHex)
            .flatMap(NSColor.fromHex) ?? NSColor.hyprCyan
    }

    static func dropPreviewColorHex(bracketStyle: FocusBracketStyle, bracketHex: String?,
                                    showBorder: Bool, borderHex: String?) -> String? {
        if bracketStyle != .off, let bracketHex, NSColor.fromHex(bracketHex) != nil { return bracketHex }
        if showBorder, let borderHex, NSColor.fromHex(borderHex) != nil { return borderHex }
        return nil
    }

    // resolve the border color — custom hex or brand cyan
    var resolvedFocusBorderColor: NSColor {
        if let hex = focusBorderColorHex, let c = NSColor.fromHex(hex) { return c }
        return NSColor.hyprCyan
    }

    // resolve floating border color — custom hex or brand magenta
    var resolvedFloatingBorderColor: NSColor {
        if let hex = floatingBorderColorHex, let c = NSColor.fromHex(hex) { return c }
        return NSColor.hyprMagenta
    }

    var resolvedFocusBracketColor: NSColor {
        if let hex = focusBracketColorHex, let color = NSColor.fromHex(hex) { return color }
        return UserConfigDefaults.focusBracketColor
    }

    func reloadFromDisk() {
        // each file loads on its own. Nix can manage monitor-config.json
        // with no config.json at all
        guard let saved = store.loadSavedConfig() else {
            guard let mc = store.loadSavedMonitorConfig() else { return }
            isReloading = true
            applyMonitorConfig(mc)
            isReloading = false
            didApplyRuntimeChange.send()
            return
        }

        isReloading = true
        keybinds = Self.mergeNewDefaults(saved: saved.keybinds,
                                                 fromVersion: ConfigMigration.schemaVersion(of: saved))
        gapSize = saved.gapSize
        outerPadding = saved.outerPadding
        enabled = saved.enabled
        focusFollowsMouse = saved.focusFollowsMouse ?? UserConfigDefaults.focusFollowsMouse
        keepCursorOnWorkspaceSwitch = saved.keepCursorOnWorkspaceSwitch ?? UserConfigDefaults.keepCursorOnWorkspaceSwitch
        doubleTapHyprTogglesCapsLock = saved.doubleTapHyprTogglesCapsLock ?? UserConfigDefaults.doubleTapHyprTogglesCapsLock
        animateFocusIndicator = saved.animateFocusIndicator ?? UserConfigDefaults.animateFocusIndicator
        mouseHoverPollHz = saved.mouseHoverPollHz ?? UserConfigDefaults.mouseHoverPollHz
        hyprKey = saved.hyprKey ?? UserConfigDefaults.hyprKey
        excludedBundleIDs = Set(saved.excludedBundleIDs ?? Self.defaultExcludedBundleIDs)
        showMenuBarIndicator = saved.showMenuBarIndicator ?? UserConfigDefaults.showMenuBarIndicator
        overlayAppearance = saved.overlayAppearance ?? UserConfigDefaults.overlayAppearance
        showFocusBorder = saved.showFocusBorder ?? UserConfigDefaults.showFocusBorder
        focusBorderFlash = saved.focusBorderFlash ?? UserConfigDefaults.focusBorderFlash
        focusBorderColorHex = saved.focusBorderColorHex
        floatingBorderColorHex = saved.floatingBorderColorHex
        focusBracketStyle = saved.focusBracketStyle ?? UserConfigDefaults.focusBracketStyle
        focusBracketColorHex = ConfigMigration.resolveFocusBracketColor(saved: saved)
        focusBracketRadiusOverride = saved.focusBracketRadius
        focusBracketThicknessOverride = saved.focusBracketThickness
        focusBracketLengthOverride = Self.resolveSavedFocusBracketLength(saved)
        dimInactiveWindows = saved.dimInactiveWindows ?? UserConfigDefaults.dimInactiveWindows
        dimIntensity = saved.dimIntensity ?? UserConfigDefaults.dimIntensity
        chromeFadeDurationSec = saved.chromeFadeDurationSec ?? UserConfigDefaults.chromeFadeDurationSec
        windowCornerRadiusOverride = saved.windowCornerRadius
        scratchpadTileByDefault = saved.scratchpadTileByDefault ?? UserConfigDefaults.scratchpadTileByDefault
        scratchpadRegionInset = saved.scratchpadRegionInset ?? UserConfigDefaults.scratchpadRegionInset
        restoreLayoutOnLaunch = saved.restoreLayoutOnLaunch ?? UserConfigDefaults.restoreLayoutOnLaunch
        windowRules = saved.windowRules ?? []
        floatingRules = saved.floatingRules ?? []
        overlayAccentHex = saved.overlayAccentHex
        workspaceNames = saved.workspaceNames ?? [:]

        // monitor settings come from the local file, not the synced config
        if let mc = store.loadSavedMonitorConfig() {
            applyMonitorConfig(mc)
        }
        // else keep current values — don't overwrite with synced defaults

        isReloading = false
        didApplyRuntimeChange.send()
        floatingRulesReloaded.send()
    }

    private func applyMonitorConfig(_ mc: SavedMonitorConfig) {
        maxSplitsPerMonitor = mc.maxSplitsPerMonitor ?? [:]
        disabledMonitors = Set(mc.disabledMonitors ?? [])
        outerPaddingPerMonitor = mc.outerPaddingPerMonitor ?? [:]
        workspaceMonitors = mc.workspaceMonitors ?? [:]
        workspaceMonitorsPerDisplaySet = mc.workspaceMonitorsPerDisplaySet ?? []
        statusExportEnabled = mc.statusExportEnabled ?? false
        statusHookCommand = mc.statusHookCommand
        externalControlEnabled = mc.externalControlEnabled ?? false
    }
}

// fallback for the iCloud snapshot closures if UserConfig is gone. unreachable
// in practice, since UserConfig.shared lives for the whole process. test
// fixtures read it too.
extension SavedConfig {
    static var empty: SavedConfig {
        SavedConfig(
            version: nil,
            keybinds: [],
            gapSize: UserConfigDefaults.gapSize,
            outerPadding: UserConfigDefaults.outerPadding,
            enabled: UserConfigDefaults.enabled,
            focusFollowsMouse: UserConfigDefaults.focusFollowsMouse,
            hyprKey: UserConfigDefaults.hyprKey,
            excludedBundleIDs: nil,
            showMenuBarIndicator: UserConfigDefaults.showMenuBarIndicator,
            overlayAppearance: UserConfigDefaults.overlayAppearance,
            maxSplitsPerMonitor: nil, disabledMonitors: nil,
            showFocusBorder: UserConfigDefaults.showFocusBorder,
            focusBorderColorHex: nil, floatingBorderColorHex: nil,
            focusBracketStyle: UserConfigDefaults.focusBracketStyle,
            focusBracketColorHex: nil,
            focusBracketRadius: nil,
            focusBracketThickness: nil,
            focusBracketLength: UserConfigDefaults.focusBracketLength,
            dimInactiveWindows: UserConfigDefaults.dimInactiveWindows,
            dimIntensity: UserConfigDefaults.dimIntensity,
            mouseHoverPollHz: UserConfigDefaults.mouseHoverPollHz,
            chromeFadeDurationSec: UserConfigDefaults.chromeFadeDurationSec,
            windowCornerRadius: nil,
            scratchpadTileByDefault: UserConfigDefaults.scratchpadTileByDefault,
            scratchpadRegionInset: UserConfigDefaults.scratchpadRegionInset,
            restoreLayoutOnLaunch: UserConfigDefaults.restoreLayoutOnLaunch)
    }
}

extension UserConfig {
    /// The custom name of `workspace`, or `fallback` ("Workspace N" by
    /// default) when it has none. A blank name counts as none.
    static func workspaceDisplayName(_ workspace: Int, names: [String: String],
                                     fallback: String? = nil) -> String {
        let name = names[String(workspace)]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? fallback ?? "Workspace \(workspace)" : name
    }
}

extension NSColor {
    // returns nil + logs at .warning on malformed input. callers fall back
    // to the brand colors, so a corrupt or empty hex string can't take down
    // the focus-border / floating-border pipeline.
    static func fromHex(_ hex: String) -> NSColor? {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let val = UInt64(h, radix: 16) else {
            hyprLog(.warning, .config,
                    "malformed hex color '\(hex)'; falling back to system default")
            return nil
        }
        return NSColor(red: CGFloat((val >> 16) & 0xFF) / 255,
                       green: CGFloat((val >> 8) & 0xFF) / 255,
                       blue: CGFloat(val & 0xFF) / 255, alpha: 1.0)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "007AFF" }
        return String(format: "%02X%02X%02X",
                      Int(c.redComponent * 255),
                      Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255))
    }
}

// MARK: - workspace homes in Settings

extension UserConfig {
    /// The workspaces Settings shows on `name` with `connectedNames`
    /// connected. A read: it writes nothing.
    func workspaces(on name: String, connectedNames: [String]) -> Set<Int> {
        Set(WorkspaceHomeResolver.mapping(forDisplays: connectedNames,
                                          perSet: workspaceMonitorsPerDisplaySet,
                                          fallback: workspaceMonitors)[name] ?? [])
    }

    /// A Settings edit: `name` holds exactly `workspaces` on the connected
    /// display set. Only that set's entry changes; `workspaceMonitors` never
    /// does. No change, no write.
    func setWorkspaces(_ workspaces: Set<Int>, on name: String, connectedNames: [String]) {
        guard let next = WorkspaceHomeResolver.editing(workspaces, for: name, connectedNames: connectedNames,
                                                       perSet: workspaceMonitorsPerDisplaySet,
                                                       fallback: workspaceMonitors) else { return }
        workspaceMonitorsPerDisplaySet = next
    }
}
