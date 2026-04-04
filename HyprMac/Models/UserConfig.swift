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

    // iCloud sync state — stored in UserDefaults, not config.json
    @Published var iCloudSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(iCloudSyncEnabled, forKey: "iCloudSyncEnabled")
            if iCloudSyncEnabled { enableICloudSync() } else { disableICloudSync() }
        }
    }

    private var isReloading = false
    private var fileWatcherSource: DispatchSourceFileSystemObject?
    private var fileWatcherFD: Int32 = -1

    // local config path (may become a symlink when iCloud sync is on)
    private let localConfigURL: URL = {
        // .userDomainMask always returns at least one URL
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HyprMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    // iCloud Drive path — no entitlements needed
    private var iCloudConfigURL: URL {
        let iCloudDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/HyprMac", isDirectory: true)
        return iCloudDir.appendingPathComponent("config.json")
    }

    // resolved path — follows symlink if present
    var configURL: URL { localConfigURL }

    init() {
        self.iCloudSyncEnabled = UserDefaults.standard.bool(forKey: "iCloudSyncEnabled")

        if let data = try? Data(contentsOf: localConfigURL),
           let saved = try? JSONDecoder().decode(SavedConfig.self, from: data) {
            self.keybinds = Self.mergeNewDefaults(saved: saved.keybinds)
            self.gapSize = saved.gapSize
            self.outerPadding = saved.outerPadding
            self.enabled = saved.enabled
            self.focusFollowsMouse = saved.focusFollowsMouse ?? true
            self.excludedBundleIDs = Set(saved.excludedBundleIDs ?? Self.defaultExcludedBundleIDs)
            self.animateWindows = saved.animateWindows ?? true
            self.animationDuration = saved.animationDuration ?? 0.15
            self.showMenuBarIndicator = saved.showMenuBarIndicator ?? true
            self.maxSplitsPerMonitor = saved.maxSplitsPerMonitor ?? [:]
            self.disabledMonitors = Set(saved.disabledMonitors ?? [])
            self.showFocusBorder = saved.showFocusBorder ?? true
            self.focusBorderColorHex = saved.focusBorderColorHex
            self.floatingBorderColorHex = saved.floatingBorderColorHex
        } else {
            self.keybinds = Keybind.defaults
            self.gapSize = 8
            self.outerPadding = 8
            self.enabled = true
            self.focusFollowsMouse = true
            self.excludedBundleIDs = Set(Self.defaultExcludedBundleIDs)
            self.animateWindows = true
            self.animationDuration = 0.15
            self.showMenuBarIndicator = true
            self.maxSplitsPerMonitor = [:]
            self.disabledMonitors = []
            self.showFocusBorder = true
            self.focusBorderColorHex = nil
            self.floatingBorderColorHex = nil
        }

        // verify symlink integrity if iCloud sync was enabled
        if iCloudSyncEnabled {
            let fm = FileManager.default
            let isSymlink = (try? localConfigURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
            if !isSymlink {
                // symlink is gone — iCloud sync was broken (maybe different machine's first launch)
                // try to set it up, or disable if iCloud Drive isn't available
                if fm.fileExists(atPath: iCloudConfigURL.path) {
                    try? fm.removeItem(at: localConfigURL)
                    try? fm.createSymbolicLink(at: localConfigURL, withDestinationURL: iCloudConfigURL)
                } else {
                    // iCloud file doesn't exist — set up fresh
                    enableICloudSync()
                }
            }
        }

        startFileWatcher()
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
        let saved = SavedConfig(keybinds: keybinds, gapSize: gapSize,
                                outerPadding: outerPadding, enabled: enabled,
                                focusFollowsMouse: focusFollowsMouse,
                                excludedBundleIDs: Array(excludedBundleIDs),
                                animateWindows: animateWindows,
                                animationDuration: animationDuration,
                                showMenuBarIndicator: showMenuBarIndicator,
                                maxSplitsPerMonitor: maxSplitsPerMonitor,
                                disabledMonitors: Array(disabledMonitors),
                                showFocusBorder: showFocusBorder,
                                focusBorderColorHex: focusBorderColorHex,
                                floatingBorderColorHex: floatingBorderColorHex)
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: localConfigURL)
        }
    }

    func resetToDefaults() {
        keybinds = Keybind.defaults
        gapSize = 8
        outerPadding = 8
        enabled = true
        focusFollowsMouse = true
        excludedBundleIDs = Set(Self.defaultExcludedBundleIDs)
        animateWindows = true
        animationDuration = 0.15
        showMenuBarIndicator = true
        maxSplitsPerMonitor = [:]
        disabledMonitors = []
        showFocusBorder = true
        focusBorderColorHex = nil
        floatingBorderColorHex = nil
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

    // MARK: - iCloud Drive sync

    /// check if iCloud Drive is available (the Mobile Documents folder exists)
    var isICloudDriveAvailable: Bool {
        FileManager.default.fileExists(atPath:
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path)
    }

    private func enableICloudSync() {
        let fm = FileManager.default
        let iCloudDir = iCloudConfigURL.deletingLastPathComponent()

        // create iCloud HyprMac directory
        try? fm.createDirectory(at: iCloudDir, withIntermediateDirectories: true)

        // move config to iCloud (or copy if symlink already exists)
        if fm.fileExists(atPath: localConfigURL.path) {
            let isSymlink = (try? localConfigURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
            if !isSymlink {
                // move local file to iCloud location
                if fm.fileExists(atPath: iCloudConfigURL.path) {
                    try? fm.removeItem(at: iCloudConfigURL)
                }
                try? fm.moveItem(at: localConfigURL, to: iCloudConfigURL)
            }
        } else {
            // no local config — save current state to iCloud
            save() // writes to localConfigURL
            if fm.fileExists(atPath: localConfigURL.path) {
                try? fm.moveItem(at: localConfigURL, to: iCloudConfigURL)
            }
        }

        // create symlink: local path -> iCloud path
        if !fm.fileExists(atPath: localConfigURL.path) {
            try? fm.createSymbolicLink(at: localConfigURL, withDestinationURL: iCloudConfigURL)
        }

        restartFileWatcher()
    }

    private func disableICloudSync() {
        let fm = FileManager.default
        let isSymlink = (try? localConfigURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false

        if isSymlink {
            // read current config from iCloud before removing symlink
            let data = try? Data(contentsOf: localConfigURL)
            try? fm.removeItem(at: localConfigURL) // removes symlink only

            // write config back as a regular file
            if let data = data {
                try? data.write(to: localConfigURL)
            } else {
                save()
            }
        }

        restartFileWatcher()
    }

    // MARK: - File watcher

    private func startFileWatcher() {
        stopFileWatcher()

        // resolve the actual file path (follows symlinks)
        let watchPath = localConfigURL.resolvingSymlinksInPath().path
        let fd = open(watchPath, O_EVTONLY)
        guard fd >= 0 else { return }
        fileWatcherFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.reloadFromDisk()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        fileWatcherSource = source
    }

    private func stopFileWatcher() {
        fileWatcherSource?.cancel()
        fileWatcherSource = nil
        fileWatcherFD = -1
    }

    private func restartFileWatcher() {
        stopFileWatcher()
        // small delay — let filesystem settle after move/symlink
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startFileWatcher()
        }
    }

    func reloadFromDisk() {
        guard let data = try? Data(contentsOf: localConfigURL),
              let saved = try? JSONDecoder().decode(SavedConfig.self, from: data) else { return }

        isReloading = true
        keybinds = saved.keybinds
        gapSize = saved.gapSize
        outerPadding = saved.outerPadding
        enabled = saved.enabled
        focusFollowsMouse = saved.focusFollowsMouse ?? true
        excludedBundleIDs = Set(saved.excludedBundleIDs ?? Self.defaultExcludedBundleIDs)
        animateWindows = saved.animateWindows ?? true
        animationDuration = saved.animationDuration ?? 0.15
        showMenuBarIndicator = saved.showMenuBarIndicator ?? true
        maxSplitsPerMonitor = saved.maxSplitsPerMonitor ?? [:]
        disabledMonitors = Set(saved.disabledMonitors ?? [])
        showFocusBorder = saved.showFocusBorder ?? true
        focusBorderColorHex = saved.focusBorderColorHex
        floatingBorderColorHex = saved.floatingBorderColorHex
        isReloading = false
    }
}

private struct SavedConfig: Codable {
    let keybinds: [Keybind]
    let gapSize: CGFloat
    let outerPadding: CGFloat
    let enabled: Bool
    let focusFollowsMouse: Bool?
    let excludedBundleIDs: [String]?
    let animateWindows: Bool?
    let animationDuration: Double?
    let showMenuBarIndicator: Bool?
    let maxSplitsPerMonitor: [String: Int]?
    let disabledMonitors: [String]?
    let showFocusBorder: Bool?
    let focusBorderColorHex: String?
    let floatingBorderColorHex: String?
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
