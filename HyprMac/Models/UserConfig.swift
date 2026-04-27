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

    // suppresses didSet handlers during a programmatic reload from disk so
    // mass property updates don't kick off a flurry of redundant writes.
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
            self.focusFollowsMouse = saved.focusFollowsMouse ?? true
            self.hyprKey = saved.hyprKey ?? .capsLock
            self.excludedBundleIDs = Set(saved.excludedBundleIDs ?? Self.defaultExcludedBundleIDs)
            self.animateWindows = saved.animateWindows ?? true
            self.animationDuration = saved.animationDuration ?? 0.15
            self.showMenuBarIndicator = saved.showMenuBarIndicator ?? true
            self.showFocusBorder = saved.showFocusBorder ?? true
            self.focusBorderColorHex = saved.focusBorderColorHex
            self.floatingBorderColorHex = saved.floatingBorderColorHex
            self.dimInactiveWindows = saved.dimInactiveWindows ?? false
            self.dimIntensity = saved.dimIntensity ?? 0.2
        } else {
            self.keybinds = Keybind.defaults
            self.gapSize = 8
            self.outerPadding = 8
            self.enabled = true
            self.focusFollowsMouse = true
            self.hyprKey = .capsLock
            self.excludedBundleIDs = Set(Self.defaultExcludedBundleIDs)
            self.animateWindows = true
            self.animationDuration = 0.15
            self.showMenuBarIndicator = true
            self.showFocusBorder = true
            self.focusBorderColorHex = nil
            self.floatingBorderColorHex = nil
            self.dimInactiveWindows = false
            self.dimIntensity = 0.2
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
        gapSize = 8
        outerPadding = 8
        enabled = true
        focusFollowsMouse = true
        hyprKey = .capsLock
        excludedBundleIDs = Set(Self.defaultExcludedBundleIDs)
        animateWindows = true
        animationDuration = 0.15
        showMenuBarIndicator = true
        maxSplitsPerMonitor = [:]
        disabledMonitors = []
        showFocusBorder = true
        focusBorderColorHex = nil
        floatingBorderColorHex = nil
        dimInactiveWindows = false
        dimIntensity = 0.2
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
            keybinds: [], gapSize: 8, outerPadding: 8, enabled: true,
            focusFollowsMouse: true, hyprKey: .capsLock,
            excludedBundleIDs: nil,
            animateWindows: true, animationDuration: 0.15,
            showMenuBarIndicator: true,
            maxSplitsPerMonitor: nil, disabledMonitors: nil,
            showFocusBorder: true,
            focusBorderColorHex: nil, floatingBorderColorHex: nil,
            dimInactiveWindows: false, dimIntensity: 0.2)
    }
}

extension NSColor {
    static func fromHex(_ hex: String) -> NSColor? {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let val = UInt64(h, radix: 16) else { return nil }
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
