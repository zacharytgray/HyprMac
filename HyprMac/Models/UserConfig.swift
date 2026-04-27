import Foundation
import Cocoa

class UserConfig: ObservableObject {
    static let shared = UserConfig()

    @Published var keybinds: [Keybind] {
        didSet { if !isReloading { save() } }
    }
    @Published var gapSize: CGFloat {
        didSet { if !isReloading { save() } }
    }
    @Published var outerPadding: CGFloat {
        didSet { if !isReloading { save() } }
    }
    @Published var enabled: Bool {
        didSet { if !isReloading { save() } }
    }
    @Published var focusFollowsMouse: Bool {
        didSet { if !isReloading { save() } }
    }
    @Published var hyprKey: HyprKey {
        didSet { if !isReloading { save() } }
    }
    @Published var excludedBundleIDs: Set<String> {
        didSet { if !isReloading { save() } }
    }
    @Published var animateWindows: Bool {
        didSet { if !isReloading { save() } }
    }
    @Published var animationDuration: Double {
        didSet { if !isReloading { save() } }
    }
    @Published var showMenuBarIndicator: Bool {
        didSet { if !isReloading { save() } }
    }
    @Published var maxSplitsPerMonitor: [String: Int] {
        didSet { if !isReloading { save() } }
    }
    @Published var disabledMonitors: Set<String> {
        didSet { if !isReloading { save() } }
    }
    @Published var showFocusBorder: Bool {
        didSet { if !isReloading { save() } }
    }
    // hex string like "007AFF" — nil means system accent color
    @Published var focusBorderColorHex: String? {
        didSet { if !isReloading { save() } }
    }
    // hex string for floating window border — nil means default orange
    @Published var floatingBorderColorHex: String? {
        didSet { if !isReloading { save() } }
    }
    @Published var dimInactiveWindows: Bool {
        didSet { if !isReloading { save() } }
    }
    // 0..1 alpha of the dimming overlay; 0.2 is subtle, 0.4 is strong
    @Published var dimIntensity: Double {
        didSet { if !isReloading { save() } }
    }

    // iCloud sync state — stored in UserDefaults, not config.json
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

    // isReloading: gates @Published didSet handlers during a programmatic
    // reload (reloadFromDisk + resetToDefaults call sites). every @Published
    // property's didSet calls save() unless this flag is true. without the
    // flag, a single reload would write the file 17 times — once per
    // property update — and worse, the file watcher would observe each
    // write and re-trigger reloadFromDisk in a tight loop.
    //
    // contract: set isReloading = true *before* mass property updates,
    // false after. only the reload + reset paths use it; ordinary user-
    // driven mutations let didSet save through.
    //
    // not thread-safe — UserConfig is implicitly main-thread.
    private var isReloading = false

    private let store: ConfigStore

    // path-shaped accessor used by SettingsView's "Reveal in Finder" affordance
    var configURL: URL { store.localConfigURL }

    var isICloudDriveAvailable: Bool { store.isICloudDriveAvailable }

    init() {
        self.store = ConfigStore()
        self.iCloudSyncEnabled = UserDefaults.standard.bool(forKey: "iCloudSyncEnabled")

        let monitorConfig = store.loadSavedMonitorConfig()
        let savedConfig = store.loadSavedConfig()

        if let saved = savedConfig {
            self.keybinds = Self.mergeNewDefaults(saved: saved.keybinds)
            self.gapSize = saved.gapSize
            self.outerPadding = saved.outerPadding
            self.enabled = saved.enabled
            self.focusFollowsMouse = saved.focusFollowsMouse ?? UserConfigDefaults.focusFollowsMouse
            self.hyprKey = saved.hyprKey ?? UserConfigDefaults.hyprKey
            self.excludedBundleIDs = Set(saved.excludedBundleIDs ?? Self.defaultExcludedBundleIDs)
            self.animateWindows = saved.animateWindows ?? UserConfigDefaults.animateWindows
            self.animationDuration = saved.animationDuration ?? UserConfigDefaults.animationDuration
            self.showMenuBarIndicator = saved.showMenuBarIndicator ?? UserConfigDefaults.showMenuBarIndicator
            self.showFocusBorder = saved.showFocusBorder ?? UserConfigDefaults.showFocusBorder
            self.focusBorderColorHex = saved.focusBorderColorHex
            self.floatingBorderColorHex = saved.floatingBorderColorHex
            self.dimInactiveWindows = saved.dimInactiveWindows ?? UserConfigDefaults.dimInactiveWindows
            self.dimIntensity = saved.dimIntensity ?? UserConfigDefaults.dimIntensity
        } else {
            self.keybinds = Keybind.defaults
            self.gapSize = UserConfigDefaults.gapSize
            self.outerPadding = UserConfigDefaults.outerPadding
            self.enabled = UserConfigDefaults.enabled
            self.focusFollowsMouse = UserConfigDefaults.focusFollowsMouse
            self.hyprKey = UserConfigDefaults.hyprKey
            self.excludedBundleIDs = Set(Self.defaultExcludedBundleIDs)
            self.animateWindows = UserConfigDefaults.animateWindows
            self.animationDuration = UserConfigDefaults.animationDuration
            self.showMenuBarIndicator = UserConfigDefaults.showMenuBarIndicator
            self.showFocusBorder = UserConfigDefaults.showFocusBorder
            self.focusBorderColorHex = nil
            self.floatingBorderColorHex = nil
            self.dimInactiveWindows = UserConfigDefaults.dimInactiveWindows
            self.dimIntensity = UserConfigDefaults.dimIntensity
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
    private static func mergeNewDefaults(saved: [Keybind]) -> [Keybind] {
        let savedActions = Set(saved.map { "\($0.action)" })
        var merged = saved
        for bind in Keybind.defaults {
            if !savedActions.contains("\(bind.action)") {
                merged.append(bind)
            }
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
            animateWindows: animateWindows,
            animationDuration: animationDuration,
            showMenuBarIndicator: showMenuBarIndicator,
            maxSplitsPerMonitor: nil,
            disabledMonitors: nil,
            showFocusBorder: showFocusBorder,
            focusBorderColorHex: focusBorderColorHex,
            floatingBorderColorHex: floatingBorderColorHex,
            dimInactiveWindows: dimInactiveWindows,
            dimIntensity: dimIntensity)
    }

    func resetToDefaults() {
        keybinds = Keybind.defaults
        gapSize = UserConfigDefaults.gapSize
        outerPadding = UserConfigDefaults.outerPadding
        enabled = UserConfigDefaults.enabled
        focusFollowsMouse = UserConfigDefaults.focusFollowsMouse
        hyprKey = UserConfigDefaults.hyprKey
        excludedBundleIDs = Set(Self.defaultExcludedBundleIDs)
        animateWindows = UserConfigDefaults.animateWindows
        animationDuration = UserConfigDefaults.animationDuration
        showMenuBarIndicator = UserConfigDefaults.showMenuBarIndicator
        maxSplitsPerMonitor = [:]
        disabledMonitors = []
        showFocusBorder = UserConfigDefaults.showFocusBorder
        focusBorderColorHex = nil
        floatingBorderColorHex = nil
        dimInactiveWindows = UserConfigDefaults.dimInactiveWindows
        dimIntensity = UserConfigDefaults.dimIntensity
    }

    // resolve the border color — custom hex or system accent
    var resolvedFocusBorderColor: NSColor {
        if let hex = focusBorderColorHex, let c = NSColor.fromHex(hex) { return c }
        return NSColor.controlAccentColor
    }

    // resolve floating border color — custom hex or default orange
    var resolvedFloatingBorderColor: NSColor {
        if let hex = floatingBorderColorHex, let c = NSColor.fromHex(hex) { return c }
        return NSColor.systemOrange
    }

    func reloadFromDisk() {
        guard let saved = store.loadSavedConfig() else { return }

        isReloading = true
        keybinds = saved.keybinds
        gapSize = saved.gapSize
        outerPadding = saved.outerPadding
        enabled = saved.enabled
        focusFollowsMouse = saved.focusFollowsMouse ?? true
        hyprKey = saved.hyprKey ?? .capsLock
        excludedBundleIDs = Set(saved.excludedBundleIDs ?? Self.defaultExcludedBundleIDs)
        animateWindows = saved.animateWindows ?? true
        animationDuration = saved.animationDuration ?? 0.15
        showMenuBarIndicator = saved.showMenuBarIndicator ?? true
        showFocusBorder = saved.showFocusBorder ?? true
        focusBorderColorHex = saved.focusBorderColorHex
        floatingBorderColorHex = saved.floatingBorderColorHex
        dimInactiveWindows = saved.dimInactiveWindows ?? false
        dimIntensity = saved.dimIntensity ?? 0.2

        // monitor settings come from the local file, not the synced config
        if let mc = store.loadSavedMonitorConfig() {
            maxSplitsPerMonitor = mc.maxSplitsPerMonitor ?? [:]
            disabledMonitors = Set(mc.disabledMonitors ?? [])
        }
        // else keep current values — don't overwrite with synced defaults

        isReloading = false
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
            animateWindows: UserConfigDefaults.animateWindows,
            animationDuration: UserConfigDefaults.animationDuration,
            showMenuBarIndicator: UserConfigDefaults.showMenuBarIndicator,
            maxSplitsPerMonitor: nil, disabledMonitors: nil,
            showFocusBorder: UserConfigDefaults.showFocusBorder,
            focusBorderColorHex: nil, floatingBorderColorHex: nil,
            dimInactiveWindows: UserConfigDefaults.dimInactiveWindows,
            dimIntensity: UserConfigDefaults.dimIntensity)
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
