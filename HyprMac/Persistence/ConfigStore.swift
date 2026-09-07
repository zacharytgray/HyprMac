// On-disk persistence for user config. File paths, raw JSON load /
// save, iCloud Drive sync lifecycle (move + symlink), and a file
// watcher that fires when the file changes externally.

import Foundation

/// Owns the on-disk representation of `UserConfig`.
///
/// File paths, JSON I/O for `SavedConfig` and `SavedMonitorConfig`,
/// and the iCloud Drive sync lifecycle: enabling sync moves the
/// config to iCloud Drive and replaces the local path with a
/// symlink; disabling sync resolves the symlink, copies the data
/// back, and removes the link. Also runs a file watcher that
/// notifies `UserConfig` when the file changes (iCloud sync from
/// another machine or a manual edit).
///
/// Not responsible for schema migration (lives in `ConfigMigration`),
/// the `@Published` observable surface (lives in `UserConfig`), or
/// building a `SavedConfig` from runtime state (lives in
/// `UserConfig`).
final class ConfigStore {

    // MARK: - paths

    static let configDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HyprMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // main config — may be a symlink to iCloud when sync is on
    static let configPath = configDir.appendingPathComponent("config.json")

    // monitor-specific settings — always local, never synced
    static let monitorConfigPath = configDir.appendingPathComponent("monitor-config.json")

    // iCloud Drive path — no entitlements needed, just plain file access
    var iCloudConfigURL: URL {
        let iCloudDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/HyprMac", isDirectory: true)
        return iCloudDir.appendingPathComponent("config.json")
    }

    var localConfigURL: URL { Self.configPath }
    var monitorConfigURL: URL { Self.monitorConfigPath }

    var isICloudDriveAvailable: Bool {
        FileManager.default.fileExists(atPath:
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path)
    }

    // MARK: - file watcher

    // fired (on main queue) when the watched file changes from disk.
    // owners typically reload state in response.
    var onFileChanged: (() -> Void)?

    private var fileWatcherSource: DispatchSourceFileSystemObject?
    private var fileWatcherFD: Int32 = -1

    // MARK: - load

    func loadSavedConfig() -> SavedConfig? {
        guard let data = try? Data(contentsOf: localConfigURL),
              let saved = try? JSONDecoder().decode(SavedConfig.self, from: data) else { return nil }
        return saved
    }

    func loadSavedMonitorConfig() -> SavedMonitorConfig? {
        guard let data = try? Data(contentsOf: monitorConfigURL),
              let mc = try? JSONDecoder().decode(SavedMonitorConfig.self, from: data) else { return nil }
        return mc
    }

    // MARK: - save

    func writeSavedConfig(_ saved: SavedConfig) {
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: localConfigURL)
        }
    }

    func writeSavedMonitorConfig(_ mc: SavedMonitorConfig) {
        if let data = try? JSONEncoder().encode(mc) {
            try? data.write(to: monitorConfigURL)
        }
    }

    // MARK: - iCloud Drive sync

    // enable iCloud sync — moves the local file (or current state via the
    // snapshot closure) to iCloud, then symlinks the local path at it.
    func enableICloudSync(snapshot: () -> SavedConfig) {
        let fm = FileManager.default
        let iCloudDir = iCloudConfigURL.deletingLastPathComponent()

        try? fm.createDirectory(at: iCloudDir, withIntermediateDirectories: true)

        if fm.fileExists(atPath: localConfigURL.path) {
            let isSymlink = (try? localConfigURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
            if !isSymlink {
                // move local file to iCloud location (overwrite if already present)
                if fm.fileExists(atPath: iCloudConfigURL.path) {
                    try? fm.removeItem(at: iCloudConfigURL)
                }
                try? fm.moveItem(at: localConfigURL, to: iCloudConfigURL)
            }
        } else {
            // no local file — write current state, then move it across
            writeSavedConfig(snapshot())
            if fm.fileExists(atPath: localConfigURL.path) {
                try? fm.moveItem(at: localConfigURL, to: iCloudConfigURL)
            }
        }

        if !fm.fileExists(atPath: localConfigURL.path) {
            try? fm.createSymbolicLink(at: localConfigURL, withDestinationURL: iCloudConfigURL)
        }

        restartFileWatcher()
    }

    // disable iCloud sync — read data via the symlink, remove it, write the
    // data back as a regular file. snapshot is a fallback if the read fails.
    func disableICloudSync(snapshot: () -> SavedConfig) {
        let fm = FileManager.default
        let isSymlink = (try? localConfigURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false

        if isSymlink {
            let data = try? Data(contentsOf: localConfigURL)
            try? fm.removeItem(at: localConfigURL) // removes the symlink only

            if let data = data {
                try? data.write(to: localConfigURL)
            } else {
                writeSavedConfig(snapshot())
            }
        }

        restartFileWatcher()
    }

    // verify symlink integrity when iCloudSyncEnabled is set in UserDefaults
    // but the local path is no longer a symlink (e.g. first launch on a new
    // machine where iCloud Drive hasn't materialized the file yet).
    func ensureICloudSymlinkIntegrity(snapshot: () -> SavedConfig) {
        let fm = FileManager.default
        let isSymlink = (try? localConfigURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
        guard !isSymlink else { return }

        if fm.fileExists(atPath: iCloudConfigURL.path) {
            try? fm.removeItem(at: localConfigURL)
            try? fm.createSymbolicLink(at: localConfigURL, withDestinationURL: iCloudConfigURL)
        } else {
            // iCloud file doesn't exist — set up fresh
            enableICloudSync(snapshot: snapshot)
        }
    }

    // MARK: - file watcher

    func startFileWatcher() {
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
            self?.onFileChanged?()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        fileWatcherSource = source
    }

    func stopFileWatcher() {
        fileWatcherSource?.cancel()
        fileWatcherSource = nil
        fileWatcherFD = -1
    }

    func restartFileWatcher() {
        stopFileWatcher()
        // small delay — let the filesystem settle after move/symlink ops.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startFileWatcher()
        }
    }
}

// MARK: - on-disk schemas

// the keys here are the v0.4.2 wire format. additions go behind Optional<T>
// so older configs decode without throwing; explicit defaults are applied
// in the loader.
//
// `version` was added in phase 6. it's optional so v0.4.2 configs (where the
// field is absent) still decode — ConfigMigration treats nil as version 1.
// the field is intentionally written as nil today so byte-equal round-trip
// holds for unchanged settings; future schema bumps will start emitting a
// concrete value when migration logic actually exists.
struct SavedConfig: Codable {
    let version: Int?
    let keybinds: [Keybind]
    let gapSize: CGFloat
    let outerPadding: CGFloat
    let enabled: Bool
    let focusFollowsMouse: Bool?
    let hyprKey: HyprKey?
    let excludedBundleIDs: [String]?
    let showMenuBarIndicator: Bool?
    let maxSplitsPerMonitor: [String: Int]?
    let disabledMonitors: [String]?
    let showFocusBorder: Bool?
    let focusBorderColorHex: String?
    let floatingBorderColorHex: String?
    let dimInactiveWindows: Bool?
    let dimIntensity: Double?
    let mouseHoverPollHz: Int?
    let chromeFadeDurationSec: Double?
    let windowCornerRadius: CGFloat?
    let scratchpadTileByDefault: Bool?
    let scratchpadRegionInset: CGFloat?
}

// MARK: - per-keybind decode tolerance

// SavedConfig decodes its keybinds one element at a time, so one bad entry
// can't take the whole config with it. config.json is shared between machines
// over iCloud, so an older build will meet actions a newer build wrote and
// knows nothing about. before this, a single unknown action key threw, the
// `try?` in loadSavedConfig returned nil, and every setting on the older
// machine reset to defaults. its next save then pushed the reset back out.
//
// the decoder lives in an extension so the memberwise init stays available to
// callers and tests, and encoding stays synthesized: the wire format does not
// change.
extension SavedConfig {

    enum CodingKeys: String, CodingKey {
        case version, keybinds, gapSize, outerPadding, enabled
        case focusFollowsMouse, hyprKey, excludedBundleIDs, showMenuBarIndicator
        case maxSplitsPerMonitor, disabledMonitors
        case showFocusBorder, focusBorderColorHex, floatingBorderColorHex
        case dimInactiveWindows, dimIntensity, mouseHoverPollHz
        case chromeFadeDurationSec, windowCornerRadius
        case scratchpadTileByDefault, scratchpadRegionInset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // keep every keybind that decodes; skip and log the rest. an empty
        // result is fine: UserConfig.mergeNewDefaults re-injects the defaults.
        var kept: [Keybind] = []
        var arr = try c.nestedUnkeyedContainer(forKey: .keybinds)
        while !arr.isAtEnd {
            // decodeNil advances past a null element; decode() would not.
            if (try? arr.decodeNil()) == true {
                hyprLog(.warning, .config, "skipping null entry in keybinds")
                continue
            }
            guard let element = try? arr.decode(FailableKeybind.self) else {
                // shouldn't happen, FailableKeybind swallows its own errors.
                // bail out rather than spin on an index that never advances.
                hyprLog(.warning, .config, "stopped decoding keybinds early on an unreadable element")
                break
            }
            if let kb = element.keybind { kept.append(kb) }
        }
        self.keybinds = kept

        self.version = try c.decodeIfPresent(Int.self, forKey: .version)
        self.gapSize = try c.decode(CGFloat.self, forKey: .gapSize)
        self.outerPadding = try c.decode(CGFloat.self, forKey: .outerPadding)
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
        self.focusFollowsMouse = try c.decodeIfPresent(Bool.self, forKey: .focusFollowsMouse)
        self.hyprKey = try c.decodeIfPresent(HyprKey.self, forKey: .hyprKey)
        self.excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs)
        self.showMenuBarIndicator = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIndicator)
        self.maxSplitsPerMonitor = try c.decodeIfPresent([String: Int].self, forKey: .maxSplitsPerMonitor)
        self.disabledMonitors = try c.decodeIfPresent([String].self, forKey: .disabledMonitors)
        self.showFocusBorder = try c.decodeIfPresent(Bool.self, forKey: .showFocusBorder)
        self.focusBorderColorHex = try c.decodeIfPresent(String.self, forKey: .focusBorderColorHex)
        self.floatingBorderColorHex = try c.decodeIfPresent(String.self, forKey: .floatingBorderColorHex)
        self.dimInactiveWindows = try c.decodeIfPresent(Bool.self, forKey: .dimInactiveWindows)
        self.dimIntensity = try c.decodeIfPresent(Double.self, forKey: .dimIntensity)
        self.mouseHoverPollHz = try c.decodeIfPresent(Int.self, forKey: .mouseHoverPollHz)
        self.chromeFadeDurationSec = try c.decodeIfPresent(Double.self, forKey: .chromeFadeDurationSec)
        self.windowCornerRadius = try c.decodeIfPresent(CGFloat.self, forKey: .windowCornerRadius)
        self.scratchpadTileByDefault = try c.decodeIfPresent(Bool.self, forKey: .scratchpadTileByDefault)
        self.scratchpadRegionInset = try c.decodeIfPresent(CGFloat.self, forKey: .scratchpadRegionInset)
    }
}

// one keybind, or nil when it doesn't decode. catching the error in here is
// the whole trick: the array's decode() call succeeds, so the unkeyed
// container moves past the bad element instead of throwing out of the array.
private struct FailableKeybind: Decodable {
    let keybind: Keybind?

    init(from decoder: Decoder) throws {
        do {
            keybind = try Keybind(from: decoder)
        } catch {
            keybind = nil
            // the action key is hand-editable text, so it stays out of the log
            hyprLog(.warning, .config, "skipping keybind with an unknown or malformed action")
        }
    }
}

// monitor-specific settings — stored locally, never synced via iCloud
struct SavedMonitorConfig: Codable {
    let maxSplitsPerMonitor: [String: Int]?
    let disabledMonitors: [String]?
}
