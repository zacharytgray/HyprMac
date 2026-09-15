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
/// `ConfigStore` (debounce by `isReloading` during programmatic
/// reloads) and emits notifications to drive `WindowManager`'s live
/// re-tile / re-bind paths.
///
/// Threading: main-thread only. The shared singleton is accessed
/// directly across SwiftUI and orchestration code.
class UserConfig: ObservableObject {
    /// Process-wide singleton bound by SwiftUI views and the
    /// orchestration layer.
    static let shared = UserConfig()
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
    @Published var mouseHoverPollHz: Int {
        didSet { persistRuntimeChange() }
    }
    @Published var hyprKey: HyprKey {
        didSet { persistRuntimeChange() }
    }
    @Published var excludedBundleIDs: Set<String> {
        didSet { persistRuntimeChange() }
    }
    @Published var showMenuBarIndicator: Bool {
        didSet { persistRuntimeChange() }
    }
    @Published var maxSplitsPerMonitor: [String: Int] {
        didSet { persistRuntimeChange() }
    }
    @Published var disabledMonitors: Set<String> {
        didSet { persistRuntimeChange() }
    }
    @Published var showFocusBorder: Bool {
        didSet { persistRuntimeChange() }
    }
    // hex string like "007AFF" — nil means system accent color
    @Published var focusBorderColorHex: String? {
        didSet { persistRuntimeChange() }
    }
    // hex string for floating window border — nil means default orange
    @Published var floatingBorderColorHex: String? {
        didSet { persistRuntimeChange() }
    }
    @Published var focusBracketStyle: FocusBracketStyle {
        didSet { persistRuntimeChange() }
    }
    // nil means neutral monochrome brackets
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

    // iCloud sync state — stored in UserDefaults, not config.json
    @Published var restoreLayoutOnLaunch: Bool {
        didSet { guard !isReloading else { return }; save() }
    }
    @Published var iCloudSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(iCloudSyncEnabled, forKey: "iCloudSyncEnabled")
            if iCloudSyncEnabled {
                store.enableICloudSync(snapshot: { [weak self] in self?.makeSavedConfig() ?? .empty })
            } else {
                store.disableICloudSync(snapshot: { [weak self] in self?.makeSavedConfig() ?? .empty })
            }
        }
    }

    /// Gates `didSet` save handlers during a programmatic reload.
    ///
    /// Every `@Published` property writes to disk in its `didSet`
    /// unless this flag is `true`. Without the flag, a single
    /// `reloadFromDisk` would rewrite the file 17 times — once per
    /// property update — and the file watcher would observe each
    /// write and re-fire reload in a tight loop. Set `true` *before*
    /// mass property updates, then `false`. Main-thread only.
    private var isReloading = false

    private let store: ConfigStore

    // path-shaped accessor used by SettingsView's "Reveal in Finder" affordance
    var configURL: URL { store.localConfigURL }

    var isICloudDriveAvailable: Bool { store.isICloudDriveAvailable }

    init() {
        self.store = ConfigStore()
        self.iCloudSyncEnabled = RuntimeVariant.inheritedBool(forKey: "iCloudSyncEnabled")

        let monitorConfig = store.loadSavedMonitorConfig()
        let savedConfig = store.loadSavedConfig()

        if let saved = savedConfig {
            self.keybinds = Self.mergeNewDefaults(saved: saved.keybinds)
            self.gapSize = saved.gapSize
            self.outerPadding = saved.outerPadding
            self.enabled = saved.enabled
            self.focusFollowsMouse = saved.focusFollowsMouse ?? UserConfigDefaults.focusFollowsMouse
            self.mouseHoverPollHz = saved.mouseHoverPollHz ?? UserConfigDefaults.mouseHoverPollHz
            self.hyprKey = saved.hyprKey ?? UserConfigDefaults.hyprKey
            self.excludedBundleIDs = Set(saved.excludedBundleIDs ?? Self.defaultExcludedBundleIDs)
            self.showMenuBarIndicator = saved.showMenuBarIndicator ?? UserConfigDefaults.showMenuBarIndicator
            self.showFocusBorder = saved.showFocusBorder ?? UserConfigDefaults.showFocusBorder
            self.focusBorderColorHex = saved.focusBorderColorHex
            self.floatingBorderColorHex = saved.floatingBorderColorHex
            self.focusBracketStyle = saved.focusBracketStyle ?? UserConfigDefaults.focusBracketStyle
            // Before bracket color had its own field it followed the focus
            // border. Preserve an explicit legacy color during migration.
            self.focusBracketColorHex = ConfigMigration.resolveFocusBracketColor(saved: saved)
            self.focusBracketRadiusOverride = saved.focusBracketRadius
            self.focusBracketThicknessOverride = saved.focusBracketThickness
            self.dimInactiveWindows = saved.dimInactiveWindows ?? UserConfigDefaults.dimInactiveWindows
            self.dimIntensity = saved.dimIntensity ?? UserConfigDefaults.dimIntensity
            self.chromeFadeDurationSec = saved.chromeFadeDurationSec ?? UserConfigDefaults.chromeFadeDurationSec
            self.windowCornerRadiusOverride = saved.windowCornerRadius
            self.scratchpadTileByDefault = saved.scratchpadTileByDefault ?? UserConfigDefaults.scratchpadTileByDefault
            self.scratchpadRegionInset = saved.scratchpadRegionInset ?? UserConfigDefaults.scratchpadRegionInset
            self.restoreLayoutOnLaunch = saved.restoreLayoutOnLaunch ?? UserConfigDefaults.restoreLayoutOnLaunch
        } else {
            self.keybinds = Keybind.defaults
            self.gapSize = UserConfigDefaults.gapSize
            self.outerPadding = UserConfigDefaults.outerPadding
            self.enabled = UserConfigDefaults.enabled
            self.focusFollowsMouse = UserConfigDefaults.focusFollowsMouse
            self.mouseHoverPollHz = UserConfigDefaults.mouseHoverPollHz
            self.hyprKey = UserConfigDefaults.hyprKey
            self.excludedBundleIDs = Set(Self.defaultExcludedBundleIDs)
            self.showMenuBarIndicator = UserConfigDefaults.showMenuBarIndicator
            self.showFocusBorder = UserConfigDefaults.showFocusBorder
            self.focusBorderColorHex = nil
            self.floatingBorderColorHex = nil
            self.focusBracketStyle = UserConfigDefaults.focusBracketStyle
            self.focusBracketColorHex = nil
            self.focusBracketRadiusOverride = nil
            self.focusBracketThicknessOverride = nil
            self.dimInactiveWindows = UserConfigDefaults.dimInactiveWindows
            self.dimIntensity = UserConfigDefaults.dimIntensity
            self.chromeFadeDurationSec = UserConfigDefaults.chromeFadeDurationSec
            self.windowCornerRadiusOverride = nil
            self.scratchpadTileByDefault = UserConfigDefaults.scratchpadTileByDefault
            self.scratchpadRegionInset = UserConfigDefaults.scratchpadRegionInset
            self.restoreLayoutOnLaunch = UserConfigDefaults.restoreLayoutOnLaunch
        }

        // monitor settings: prefer the local file; fall back to (and migrate
        // from) the synced config if the local file isn't there yet.
        let resolved = ConfigMigration.resolveMonitorConfig(local: monitorConfig, embedded: savedConfig)
        self.maxSplitsPerMonitor = resolved.maxSplits
        self.disabledMonitors = resolved.disabled

        if iCloudSyncEnabled {
            store.ensureICloudSymlinkIntegrity(snapshot: { [weak self] in self?.makeSavedConfig() ?? .empty })
        }

        if resolved.needsLocalWrite {
            store.writeSavedMonitorConfig(SavedMonitorConfig(
                maxSplitsPerMonitor: resolved.maxSplits,
                disabledMonitors: Array(resolved.disabled)))
        }

        store.onFileChanged = { [weak self] in self?.reloadFromDisk() }
        store.startFileWatcher()
    }

    // inject any default keybinds whose action doesn't exist in the saved set.
    // handles upgrades where new actions are added (e.g. focusFloating).
    // never inject onto a chord the user already bound — the injected bind
    // would silently shadow (or be shadowed by) the user's, and neither is
    // discoverable. the user can bind the new action manually in Settings.
    static func mergeNewDefaults(saved: [Keybind]) -> [Keybind] {
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

    func save() {
        store.writeSavedConfig(makeSavedConfig())
        store.writeSavedMonitorConfig(SavedMonitorConfig(
            maxSplitsPerMonitor: maxSplitsPerMonitor,
            disabledMonitors: Array(disabledMonitors)))
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
            version: nil,
            keybinds: keybinds, gapSize: gapSize,
            outerPadding: outerPadding, enabled: enabled,
            focusFollowsMouse: focusFollowsMouse,
            hyprKey: hyprKey,
            excludedBundleIDs: Array(excludedBundleIDs),
            showMenuBarIndicator: showMenuBarIndicator,
            maxSplitsPerMonitor: nil,
            disabledMonitors: nil,
            showFocusBorder: showFocusBorder,
            focusBorderColorHex: focusBorderColorHex,
            floatingBorderColorHex: floatingBorderColorHex,
            focusBracketStyle: focusBracketStyle,
            focusBracketColorHex: focusBracketColorHex,
            focusBracketRadius: focusBracketRadiusOverride,
            focusBracketThickness: focusBracketThicknessOverride,
            dimInactiveWindows: dimInactiveWindows,
            dimIntensity: dimIntensity,
            mouseHoverPollHz: mouseHoverPollHz,
            chromeFadeDurationSec: chromeFadeDurationSec,
            windowCornerRadius: windowCornerRadiusOverride,
            scratchpadTileByDefault: scratchpadTileByDefault,
            scratchpadRegionInset: scratchpadRegionInset,
            restoreLayoutOnLaunch: restoreLayoutOnLaunch)
    }

    func resetToDefaults() {
        keybinds = Keybind.defaults
        gapSize = UserConfigDefaults.gapSize
        outerPadding = UserConfigDefaults.outerPadding
        enabled = UserConfigDefaults.enabled
        focusFollowsMouse = UserConfigDefaults.focusFollowsMouse
        mouseHoverPollHz = UserConfigDefaults.mouseHoverPollHz
        hyprKey = UserConfigDefaults.hyprKey
        excludedBundleIDs = Set(Self.defaultExcludedBundleIDs)
        showMenuBarIndicator = UserConfigDefaults.showMenuBarIndicator
        maxSplitsPerMonitor = [:]
        disabledMonitors = []
        showFocusBorder = UserConfigDefaults.showFocusBorder
        focusBorderColorHex = nil
        floatingBorderColorHex = nil
        focusBracketStyle = UserConfigDefaults.focusBracketStyle
        focusBracketColorHex = nil
        focusBracketRadiusOverride = nil
        focusBracketThicknessOverride = nil
        dimInactiveWindows = UserConfigDefaults.dimInactiveWindows
        dimIntensity = UserConfigDefaults.dimIntensity
        chromeFadeDurationSec = UserConfigDefaults.chromeFadeDurationSec
        windowCornerRadiusOverride = nil
        scratchpadTileByDefault = UserConfigDefaults.scratchpadTileByDefault
        scratchpadRegionInset = UserConfigDefaults.scratchpadRegionInset
        restoreLayoutOnLaunch = UserConfigDefaults.restoreLayoutOnLaunch
    }

    /// Restore the controls in Focus Chrome without changing layout,
    /// keybind, monitor, or scratchpad preferences.
    func resetAppearanceToDefaults() {
        isReloading = true
        dimInactiveWindows = UserConfigDefaults.dimInactiveWindows
        dimIntensity = UserConfigDefaults.dimIntensity
        focusBracketStyle = UserConfigDefaults.focusBracketStyle
        focusBracketColorHex = nil
        focusBracketRadiusOverride = nil
        focusBracketThicknessOverride = nil
        windowCornerRadiusOverride = nil
        showFocusBorder = UserConfigDefaults.showFocusBorder
        focusBorderColorHex = nil
        floatingBorderColorHex = nil
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
        return .white
    }

    func reloadFromDisk() {
        guard let saved = store.loadSavedConfig() else { return }

        isReloading = true
        keybinds = Self.mergeNewDefaults(saved: saved.keybinds)
        gapSize = saved.gapSize
        outerPadding = saved.outerPadding
        enabled = saved.enabled
        focusFollowsMouse = saved.focusFollowsMouse ?? UserConfigDefaults.focusFollowsMouse
        mouseHoverPollHz = saved.mouseHoverPollHz ?? UserConfigDefaults.mouseHoverPollHz
        hyprKey = saved.hyprKey ?? UserConfigDefaults.hyprKey
        excludedBundleIDs = Set(saved.excludedBundleIDs ?? Self.defaultExcludedBundleIDs)
        showMenuBarIndicator = saved.showMenuBarIndicator ?? UserConfigDefaults.showMenuBarIndicator
        showFocusBorder = saved.showFocusBorder ?? UserConfigDefaults.showFocusBorder
        focusBorderColorHex = saved.focusBorderColorHex
        floatingBorderColorHex = saved.floatingBorderColorHex
        focusBracketStyle = saved.focusBracketStyle ?? UserConfigDefaults.focusBracketStyle
        focusBracketColorHex = ConfigMigration.resolveFocusBracketColor(saved: saved)
        focusBracketRadiusOverride = saved.focusBracketRadius
        focusBracketThicknessOverride = saved.focusBracketThickness
        dimInactiveWindows = saved.dimInactiveWindows ?? UserConfigDefaults.dimInactiveWindows
        dimIntensity = saved.dimIntensity ?? UserConfigDefaults.dimIntensity
        chromeFadeDurationSec = saved.chromeFadeDurationSec ?? UserConfigDefaults.chromeFadeDurationSec
        windowCornerRadiusOverride = saved.windowCornerRadius
        scratchpadTileByDefault = saved.scratchpadTileByDefault ?? UserConfigDefaults.scratchpadTileByDefault
        scratchpadRegionInset = saved.scratchpadRegionInset ?? UserConfigDefaults.scratchpadRegionInset
        restoreLayoutOnLaunch = saved.restoreLayoutOnLaunch ?? UserConfigDefaults.restoreLayoutOnLaunch

        // monitor settings come from the local file, not the synced config
        if let mc = store.loadSavedMonitorConfig() {
            maxSplitsPerMonitor = mc.maxSplitsPerMonitor ?? [:]
            disabledMonitors = Set(mc.disabledMonitors ?? [])
        }
        // else keep current values — don't overwrite with synced defaults

        isReloading = false
        didApplyRuntimeChange.send()
    }
}

// fallback used by ConfigStore's iCloud snapshot closure when the UserConfig
// reference has been deallocated — empty defaults are acceptable because the
// only call site is "user just toggled iCloud on a machine that's already
// shutting down," and we'd rather write a well-formed empty config than
// crash on a force-unwrap.
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
            maxSplitsPerMonitor: nil, disabledMonitors: nil,
            showFocusBorder: UserConfigDefaults.showFocusBorder,
            focusBorderColorHex: nil, floatingBorderColorHex: nil,
            focusBracketStyle: UserConfigDefaults.focusBracketStyle,
            focusBracketColorHex: nil,
            focusBracketRadius: nil,
            focusBracketThickness: nil,
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

extension NSColor {
    // returns nil + logs at .warning on malformed input. callers fall back
    // to a system color (controlAccentColor / systemOrange) so a corrupt or
    // empty hex string can't take down the focus-border / floating-border
    // pipeline. retained as `fromHex` for compat with existing call sites;
    // the logging is the phase-6 hardening per §11.1.
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
