// On-disk persistence for user config. File paths, raw JSON load /
// save, iCloud Drive sync lifecycle (link + repair), a file watcher
// that fires when the file changes externally, and the copies kept
// before a config file is replaced.

import Foundation

/// What a read of a config file found. A missing file is normal on a
/// first run. An unreadable one holds somebody's settings.
enum ConfigRead<Value> {
    case loaded(Value)
    case missing
    case unreadable(reason: String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}

/// Owns the on-disk representation of `UserConfig`.
///
/// File paths, JSON I/O for `SavedConfig` and `SavedMonitorConfig`,
/// and the iCloud Drive sync lifecycle: enabling sync puts the config
/// in iCloud Drive and makes the local path a symlink; disabling sync
/// copies the data back over the link. Also runs a file watcher that
/// notifies `UserConfig` when the file changes (iCloud sync from
/// another machine or a manual edit).
///
/// Saves are atomic and failures are logged. Nothing is destroyed
/// without a copy: a file that can't be decoded goes to
/// `<name>.unreadable` right before it is overwritten, and a readable
/// config that is about to be replaced by iCloud set up or a reset goes
/// to `<name>.replaced`. Copies stay beside the local path, never in
/// iCloud, and older copies are never overwritten.
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
    static var defaultICloudRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    let localConfigURL: URL
    let monitorConfigURL: URL
    let iCloudRootURL: URL

    var iCloudConfigURL: URL {
        iCloudRootURL
            .appendingPathComponent("HyprMac", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    /// Every path is injectable so tests run against scratch files.
    init(localConfigURL: URL = ConfigStore.configPath,
         monitorConfigURL: URL = ConfigStore.monitorConfigPath,
         iCloudRootURL: URL = ConfigStore.defaultICloudRootURL) {
        self.localConfigURL = localConfigURL
        self.monitorConfigURL = monitorConfigURL
        self.iCloudRootURL = iCloudRootURL
    }

    var isICloudDriveAvailable: Bool {
        FileManager.default.fileExists(atPath: iCloudRootURL.path)
    }

    private var isLocalSymlink: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: localConfigURL.path)) != nil
    }

    // MARK: - file watcher state

    // fired (on main queue) when the watched file changes from disk.
    // owners typically reload state in response.
    var onFileChanged: (() -> Void)?

    private var fileWatcherSource: DispatchSourceFileSystemObject?
    private var fileWatcherFD: Int32 = -1
    // start asked for a watcher and stop hasn't cancelled it. a save closes
    // the watcher around its rename, and reopens only when this is set
    private var watcherWanted = false
    // bumped whenever the watcher closes so a pending re-arm retry knows it's stale
    private var rearmGeneration = 0
    private static let rearmMaxDelay: TimeInterval = 4
    private var ownWriteReportPending = false

    // MARK: - load

    func readSavedConfig() -> ConfigRead<SavedConfig> {
        let result = read(localConfigURL, as: SavedConfig.self)
        if writesHeld, result.value != nil {
            writesHeld = false
            hyprLog(.notice, .config, "config.json arrived, saving again")
        }
        return result
    }

    func loadSavedConfig() -> SavedConfig? {
        readSavedConfig().value
    }

    func readSavedMonitorConfig() -> ConfigRead<SavedMonitorConfig> {
        read(monitorConfigURL, as: SavedMonitorConfig.self)
    }

    func loadSavedMonitorConfig() -> SavedMonitorConfig? {
        readSavedMonitorConfig().value
    }

    // only logs. a read mid iCloud sync can look unreadable, so the file is
    // left alone until something is about to overwrite it
    private func read<Value: Decodable>(_ url: URL, as type: Value.Type) -> ConfigRead<Value> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if Self.isFileMissing(error) { return .missing }
            return unreadable(url, Self.reason(for: error))
        }
        do {
            return .loaded(try JSONDecoder().decode(type, from: data))
        } catch {
            return unreadable(url, Self.reason(for: error))
        }
    }

    private func unreadable<Value>(_ url: URL, _ reason: String) -> ConfigRead<Value> {
        hyprLog(.warning, .config,
                "\(url.lastPathComponent) unreadable (\(reason)); not using it. a copy is kept before it is overwritten")
        return .unreadable(reason: reason)
    }

    private static func isFileMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError)
            || (error.domain == NSPOSIXErrorDomain && error.code == ENOENT)
    }

    // the file is hand-editable, so its values stay out of the log
    private static func reason(for error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted:
            return "not valid JSON"
        case DecodingError.keyNotFound(let key, _):
            return "missing \(key.stringValue)"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "wrong type at \(path.isEmpty ? "top level" : path)"
        default:
            return code(of: error)
        }
    }

    private static func code(of error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }

    // MARK: - save

    /// True while the local path is a link and this launch could not read
    /// what it points at: nothing there yet, a garbled sync, or an evicted
    /// file with no network. Memory holds defaults then, and writing them
    /// through the link would push them to every other Mac. Ends when a good
    /// file arrives or the user turns sync off or on.
    private(set) var writesHeld = false

    func holdWritesIfLinkUnusable() {
        guard isLocalSymlink, readSavedConfig().value == nil else { return }
        writesHeld = true
        hyprLog(.warning, .config,
                "config.json links to a file this launch can't read; changes won't be saved until a good one arrives. turning iCloud sync off and on ends this")
    }

    func writeSavedConfig(_ saved: SavedConfig) {
        guard !writesHeld,
              let data = encode(saved, for: localConfigURL),
              keepUnreadableCopy(of: localConfigURL, as: SavedConfig.self) else { return }
        // the rename below would look like an outside replace to a watcher on
        // the old file. reopen on the new file now, with no re-arm gap
        let reopen = watcherWanted
        closeWatcher()
        let wrote = writeAtomically(data, to: localConfigURL)
        guard reopen else { return }
        if !openWatcher() { rearmAfterReplace() }
        if wrote { reportOwnWrite() }
    }

    func writeSavedMonitorConfig(_ mc: SavedMonitorConfig) {
        guard let data = encode(mc, for: monitorConfigURL),
              keepUnreadableCopy(of: monitorConfigURL, as: SavedMonitorConfig.self) else { return }
        writeAtomically(data, to: monitorConfigURL)
    }

    /// Keep what a reset is about to replace.
    func keepCopiesBeforeReset() {
        for url in [localConfigURL, monitorConfigURL] {
            if let data = try? Data(contentsOf: url) {
                keepCopy(data, of: url, suffix: "replaced")
            }
        }
    }

    private func encode<Value: Encodable>(_ value: Value, for url: URL) -> Data? {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            hyprLog(.warning, .config, "\(url.lastPathComponent) not saved, encoding failed: \(Self.code(of: error))")
            return nil
        }
    }

    @discardableResult
    private func writeAtomically(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: Self.writeTarget(of: url), options: .atomic)
            return true
        } catch {
            hyprLog(.warning, .config, "\(url.lastPathComponent) not saved: \(Self.code(of: error))")
            return false
        }
    }

    // an atomic write renames over its path, which would swap a symlink for a
    // regular file and cut the Mac off from iCloud. write to the real file.
    // hand-made links (dotfiles) get the same treatment
    static func writeTarget(of url: URL) -> URL {
        var current = url
        for _ in 0..<8 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else {
                return current
            }
            current = URL(fileURLWithPath: destination, relativeTo: current.deletingLastPathComponent()).absoluteURL
        }
        return current
    }

    // false means the caller must not overwrite the file: the copy failed,
    // or the file exists and can't be read to copy
    private func keepUnreadableCopy<Value: Decodable>(of url: URL, as type: Value.Type) -> Bool {
        switch contents(of: url) {
        case .missing:
            return true
        case .blocked(let reason):
            hyprLog(.warning, .config, "\(url.lastPathComponent) not saved: can't read it to keep a copy (\(reason))")
            return false
        case .data(let data):
            guard (try? JSONDecoder().decode(type, from: data)) == nil else { return true }
            return keepCopy(data, of: url, suffix: "unreadable")
        }
    }

    private enum FileContents {
        case missing
        case data(Data)
        case blocked(reason: String)
    }

    // tells a file that isn't there from one that is there and won't open.
    // only the first is safe to replace with no copy
    private func contents(of url: URL) -> FileContents {
        do {
            return .data(try Data(contentsOf: url))
        } catch {
            return Self.isFileMissing(error) ? .missing : .blocked(reason: Self.reason(for: error))
        }
    }

    // never overwrites an older copy: the first one may be the only good
    // version of someone's settings. the same bytes are not copied twice
    @discardableResult
    private func keepCopy(_ data: Data, of url: URL, suffix: String) -> Bool {
        guard !data.isEmpty else { return true }
        let base = "\(url.path).\(suffix)"
        var path = base
        var number = 1
        while FileManager.default.fileExists(atPath: path) {
            if (try? Data(contentsOf: URL(fileURLWithPath: path))) == data { return true }
            number += 1
            path = "\(base).\(number)"
        }
        let copy = URL(fileURLWithPath: path)
        do {
            try data.write(to: copy, options: .atomic)
            hyprLog(.warning, .config, "kept a copy of \(url.lastPathComponent) at \(copy.lastPathComponent)")
            return true
        } catch {
            hyprLog(.warning, .config, "couldn't copy \(url.lastPathComponent): \(Self.code(of: error))")
            return false
        }
    }

    // MARK: - iCloud Drive sync

    // enable iCloud sync — puts the local file (or current state via the
    // snapshot closure) in iCloud, then symlinks the local path at it. the
    // last Mac to enable wins, so whatever was in iCloud gets a copy. the
    // local file goes only after iCloud holds its data.
    func enableICloudSync(snapshot: () -> SavedConfig) {
        defer { restartFileWatcher() }
        let fm = FileManager.default
        let isLink = isLocalSymlink

        if !isLink || !fm.fileExists(atPath: localConfigURL.path) {
            let data = fm.fileExists(atPath: localConfigURL.path)
                ? try? Data(contentsOf: localConfigURL)
                : encode(snapshot(), for: iCloudConfigURL)
            guard let data else {
                hyprLog(.warning, .config, "iCloud sync not set up: couldn't read config.json")
                return
            }
            do {
                try fm.createDirectory(at: iCloudConfigURL.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
            } catch {
                hyprLog(.warning, .config, "iCloud sync not set up: \(Self.code(of: error))")
                return
            }
            switch contents(of: iCloudConfigURL) {
            case .missing:
                break
            case .blocked(let reason):
                hyprLog(.warning, .config, "iCloud sync not set up: can't read the file there (\(reason))")
                return
            case .data(let existing):
                if existing != data, !keepCopy(existing, of: localConfigURL, suffix: "replaced") {
                    return
                }
            }
            guard writeAtomically(data, to: iCloudConfigURL) else { return }
        }

        if !isLink, !linkLocalToICloud() { return }
        writesHeld = false
    }

    // disable iCloud sync — read data via the symlink and put it over the
    // link as a regular file. snapshot is a fallback if the read fails.
    func disableICloudSync(snapshot: () -> SavedConfig) {
        defer { restartFileWatcher() }
        writesHeld = false
        guard isLocalSymlink else { return }
        guard let data = (try? Data(contentsOf: localConfigURL)) ?? encode(snapshot(), for: localConfigURL) else {
            return
        }
        // beside the link so the rename replaces the link, not what it points at
        let temp = URL(fileURLWithPath: "\(localConfigURL.path).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temp)
            try Self.rename(temp, over: localConfigURL)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            hyprLog(.warning, .config, "iCloud link not removed: \(Self.code(of: error))")
        }
    }

    // verify symlink integrity when iCloudSyncEnabled is set in UserDefaults
    // but the local path is no longer a symlink (e.g. first launch on a new
    // machine, or an editor that saved over the link).
    //
    // returns true when the path now reads a different file, so the caller's
    // values are stale and it must reload before anything saves them over iCloud.
    @discardableResult
    func ensureICloudSymlinkIntegrity(snapshot: () -> SavedConfig) -> Bool {
        guard !isLocalSymlink else { return false }

        guard FileManager.default.fileExists(atPath: iCloudConfigURL.path) else {
            // iCloud file doesn't exist — set up fresh
            enableICloudSync(snapshot: snapshot)
            return false
        }
        switch contents(of: localConfigURL) {
        case .missing:
            break
        case .blocked(let reason):
            hyprLog(.warning, .config, "config.json not linked to iCloud: can't read it to keep a copy (\(reason))")
            return false
        case .data(let local):
            if local != (try? Data(contentsOf: iCloudConfigURL)),
               !keepCopy(local, of: localConfigURL, suffix: "replaced") {
                return false
            }
        }
        guard linkLocalToICloud() else { return false }
        hyprLog(.notice, .config, "config.json linked back to iCloud")
        return true
    }

    // the link appears in one rename, so a failure leaves the old file in place
    private func linkLocalToICloud() -> Bool {
        let fm = FileManager.default
        let temp = URL(fileURLWithPath: "\(localConfigURL.path).link-\(UUID().uuidString)")
        do {
            try fm.createSymbolicLink(at: temp, withDestinationURL: iCloudConfigURL)
            try Self.rename(temp, over: localConfigURL)
            return true
        } catch {
            try? fm.removeItem(at: temp)
            hyprLog(.warning, .config, "couldn't link config.json to iCloud: \(Self.code(of: error))")
            return false
        }
    }

    private static func rename(_ source: URL, over destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    // MARK: - file watcher

    /// Keeps trying when the file isn't there yet: a first run before any
    /// save, or a link waiting on iCloud. When it appears, owners reload.
    func startFileWatcher() {
        closeWatcher()
        watcherWanted = true
        if !openWatcher() { rearmAfterReplace() }
    }

    private func openWatcher() -> Bool {
        // resolve the actual file path (follows symlinks)
        let watchPath = localConfigURL.resolvingSymlinksInPath().path
        let fd = open(watchPath, O_EVTONLY)
        guard fd >= 0 else { return false }
        fileWatcherFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self, unowned source] in
            guard let self else { return }
            let replaced = !source.data.isDisjoint(with: [.rename, .delete])
            self.onFileChanged?()
            // an atomic save (most editors, `mv tmp config.json`) swaps in a
            // new inode and leaves this fd on the unlinked old one, which
            // never fires again. re-open the path so later edits still land
            if replaced {
                hyprLog(.notice, .config, "config file replaced on disk, re-arming watcher")
                self.rearmAfterReplace()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        fileWatcherSource = source
        return true
    }

    var isWatchingFile: Bool { fileWatcherSource != nil }

    func stopFileWatcher() {
        closeWatcher()
        watcherWanted = false
    }

    private func closeWatcher() {
        fileWatcherSource?.cancel()
        fileWatcherSource = nil
        fileWatcherFD = -1
        rearmGeneration += 1
    }

    // re-open the path after the file was replaced, or when it isn't there
    // yet. editors that rename the old file away before writing the new one
    // leave nothing to open for a moment, so keep retrying with backoff. once
    // the new file is watched, reload again: a save that landed in the gap
    // fired no event.
    private func rearmAfterReplace(delay: TimeInterval = 0.5) {
        closeWatcher()
        let generation = rearmGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.rearmGeneration else { return }
            if self.openWatcher() {
                self.onFileChanged?()
            } else {
                if delay == 0.5 {
                    hyprLog(.notice, .config, "config file missing at re-arm, retrying")
                }
                self.rearmAfterReplace(delay: min(delay * 2, Self.rearmMaxDelay))
            }
        }
    }

    // a watcher on the old file would have reported this save, and the
    // reload it starts is how a save has always settled, so keep it. saves
    // in one main-queue turn report once, as the dispatch source did
    private func reportOwnWrite() {
        guard !ownWriteReportPending else { return }
        ownWriteReportPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.ownWriteReportPending = false
            if self.watcherWanted { self.onFileChanged?() }
        }
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
// `version` is optional so old configs without it still decode — ConfigMigration
// treats nil as version 1. it is written as nil today; a real value starts with
// the first schema bump.
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
    var overlayAppearance: OverlayAppearance? = nil
    let maxSplitsPerMonitor: [String: Int]?
    let disabledMonitors: [String]?
    let showFocusBorder: Bool?
    let focusBorderColorHex: String?
    let floatingBorderColorHex: String?
    let focusBracketStyle: FocusBracketStyle?
    let focusBracketColorHex: String?
    let focusBracketRadius: CGFloat?
    let focusBracketThickness: CGFloat?
    var focusBracketLength: CGFloat? = nil
    let dimInactiveWindows: Bool?
    let dimIntensity: Double?
    let mouseHoverPollHz: Int?
    let chromeFadeDurationSec: Double?
    let windowCornerRadius: CGFloat?
    let scratchpadTileByDefault: Bool?
    let scratchpadRegionInset: CGFloat?
    // `var` with a default so the synthesized memberwise init takes it as a
    // trailing optional — existing `SavedConfig(...)` call sites keep compiling.
    var restoreLayoutOnLaunch: Bool? = nil
    var windowRules: [WindowRule]? = nil
    var workspaceNames: [String: String]? = nil
    // nil = the brand cyan and magenta pair
    var overlayAccentHex: String? = nil
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
        case focusFollowsMouse, hyprKey, excludedBundleIDs, showMenuBarIndicator, overlayAppearance
        case maxSplitsPerMonitor, disabledMonitors
        case showFocusBorder, focusBorderColorHex, floatingBorderColorHex
        case focusBracketStyle, focusBracketColorHex, focusBracketRadius, focusBracketThickness
        case focusBracketLength
        case dimInactiveWindows, dimIntensity, mouseHoverPollHz
        case chromeFadeDurationSec, windowCornerRadius
        case scratchpadTileByDefault, scratchpadRegionInset
        case restoreLayoutOnLaunch
        case windowRules
        case workspaceNames
        case overlayAccentHex
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

        // the core fields stay strict: every build since v0.4.2 writes them,
        // with these types. version too, since it will pick which migrations run.
        self.version = try c.decodeIfPresent(Int.self, forKey: .version)
        self.gapSize = try c.decode(CGFloat.self, forKey: .gapSize)
        self.outerPadding = try c.decode(CGFloat.self, forKey: .outerPadding)
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
        self.focusFollowsMouse = Self.tolerant(c, .focusFollowsMouse)
        // an unknown value, like a case a newer build added, is the default Hypr key
        self.hyprKey = Self.tolerant(c, .hyprKey)
        self.excludedBundleIDs = Self.tolerant(c, .excludedBundleIDs)
        self.showMenuBarIndicator = Self.tolerant(c, .showMenuBarIndicator)
        self.overlayAppearance = c.contains(.overlayAppearance)
            ? ((try? c.decode(OverlayAppearance.self, forKey: .overlayAppearance))
                ?? UserConfigDefaults.overlayAppearance)
            : nil
        self.maxSplitsPerMonitor = Self.tolerant(c, .maxSplitsPerMonitor)
        self.disabledMonitors = Self.tolerant(c, .disabledMonitors)
        self.showFocusBorder = Self.tolerant(c, .showFocusBorder)
        self.focusBorderColorHex = Self.tolerant(c, .focusBorderColorHex)
        self.floatingBorderColorHex = Self.tolerant(c, .floatingBorderColorHex)
        // A style added by a newer build must not invalidate the whole config.
        // Key presence also marks the new bracket schema, so an unknown value
        // cannot accidentally reimport the old focus-border color.
        if c.contains(.focusBracketStyle) {
            self.focusBracketStyle = (try? c.decode(
                FocusBracketStyle.self,
                forKey: .focusBracketStyle)) ?? UserConfigDefaults.focusBracketStyle
        } else {
            self.focusBracketStyle = nil
        }
        self.focusBracketColorHex = Self.tolerant(c, .focusBracketColorHex)
        self.focusBracketRadius = Self.tolerant(c, .focusBracketRadius)
        self.focusBracketThickness = Self.tolerant(c, .focusBracketThickness)
        self.focusBracketLength = Self.tolerant(c, .focusBracketLength)
        self.dimInactiveWindows = Self.tolerant(c, .dimInactiveWindows)
        self.dimIntensity = Self.tolerant(c, .dimIntensity)
        self.mouseHoverPollHz = Self.tolerant(c, .mouseHoverPollHz)
        self.chromeFadeDurationSec = Self.tolerant(c, .chromeFadeDurationSec)
        self.windowCornerRadius = Self.tolerant(c, .windowCornerRadius)
        self.scratchpadTileByDefault = Self.tolerant(c, .scratchpadTileByDefault)
        self.scratchpadRegionInset = Self.tolerant(c, .scratchpadRegionInset)
        self.restoreLayoutOnLaunch = Self.tolerant(c, .restoreLayoutOnLaunch)
        self.windowRules = Self.tolerantWindowRules(c)
        self.workspaceNames = Self.tolerantWorkspaceNames(c)
        self.overlayAccentHex = Self.tolerant(c, .overlayAccentHex)
    }

    // keys "1"…"10" with a non-empty name; anything else is dropped, so a
    // hand edit can't leave a stray key that nothing ever shows
    private static func tolerantWorkspaceNames(_ c: KeyedDecodingContainer<CodingKeys>) -> [String: String]? {
        let valid = Set(Constants.workspaceRange.map(String.init))
        let names: [String: String]? = tolerant(c, .workspaceNames)
        let kept = names?.filter { valid.contains($0.key) && !$0.value.isEmpty }
        return kept?.isEmpty == false ? kept : nil
    }

    // same per-element tolerance as keybinds: the rules are hand-editable
    // and travel between builds over iCloud, so a bad rule costs only itself
    private static func tolerantWindowRules(_ c: KeyedDecodingContainer<CodingKeys>) -> [WindowRule]? {
        guard c.contains(.windowRules), (try? c.decodeNil(forKey: .windowRules)) == false else { return nil }
        guard var arr = try? c.nestedUnkeyedContainer(forKey: .windowRules) else {
            hyprLog(.notice, .config, "config.json has a windowRules value this build can't read; using no rules")
            return nil
        }
        var kept: [WindowRule] = []
        while !arr.isAtEnd {
            if (try? arr.decodeNil()) == true { continue }
            guard let element = try? arr.decode(FailableWindowRule.self) else { break }
            if let rule = element.rule { kept.append(rule) }
        }
        return kept
    }

    // one optional field. a value this build can't read (a case a newer
    // build added, a changed type, a hand-edit typo) costs just that field,
    // which is treated as missing, instead of the whole config. the value
    // stays out of the log because it is hand-editable text.
    private static func tolerant<T: Decodable>(_ c: KeyedDecodingContainer<CodingKeys>,
                                               _ key: CodingKeys) -> T? {
        do {
            return try c.decodeIfPresent(T.self, forKey: key)
        } catch {
            hyprLog(.notice, .config,
                    "config.json has a \(key.stringValue) value this build can't read; using the default")
            return nil
        }
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

// one window rule, or nil when it doesn't decode. same trick as FailableKeybind.
private struct FailableWindowRule: Decodable {
    let rule: WindowRule?

    init(from decoder: Decoder) throws {
        do {
            rule = try WindowRule(from: decoder)
        } catch {
            rule = nil
            hyprLog(.warning, .config, "skipping malformed window rule")
        }
    }
}

// per-side outer padding override for one monitor. a nil side uses the
// shared outerPadding
struct EdgePadding: Codable, Equatable {
    var top: CGFloat? = nil
    var left: CGFloat? = nil
    var bottom: CGFloat? = nil
    var right: CGFloat? = nil

    var isEmpty: Bool { top == nil && left == nil && bottom == nil && right == nil }
}

// tolerant per side: a hand-edited bad value costs only that side
extension EdgePadding {
    private enum CodingKeys: String, CodingKey {
        case top, left, bottom, right
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func side(_ key: CodingKeys) -> CGFloat? {
            do {
                return try c.decodeIfPresent(CGFloat.self, forKey: key)
            } catch {
                hyprLog(.notice, .config,
                        "monitor-config.json has a \(key.stringValue) padding this build can't read; using outer padding")
                return nil
            }
        }
        self.init(top: side(.top), left: side(.left), bottom: side(.bottom), right: side(.right))
    }
}

// monitor-specific settings — stored locally, never synced via iCloud
struct SavedMonitorConfig: Codable {
    let maxSplitsPerMonitor: [String: Int]?
    let disabledMonitors: [String]?
    // a monitor without an entry pads every edge with outerPadding
    var outerPaddingPerMonitor: [String: EdgePadding]? = nil
    // monitor name → workspaces that live there. nil = the formula homes
    var workspaceMonitors: [String: [Int]]? = nil
    // status bar export, see docs/status-bar.md. per machine since the bar
    // and its hook are set up per Mac. no Settings UI, hand-edited
    var statusExportEnabled: Bool? = nil
    var statusHookCommand: String? = nil
    // hyprmac://action/… links, see docs/external-control.md. per machine
    var externalControlEnabled: Bool? = nil
}

// per-field tolerant like SavedConfig: a hand-edited bad value costs only
// its field. strict decoding failed the whole file, and the next save then
// wrote every monitor setting away.
extension SavedMonitorConfig {
    private enum CodingKeys: String, CodingKey {
        case maxSplitsPerMonitor, disabledMonitors, outerPaddingPerMonitor, workspaceMonitors,
             statusExportEnabled, statusHookCommand, externalControlEnabled
    }

    // unreleased top-only shape from PR #51. read once, never written back
    private enum LegacyKeys: String, CodingKey {
        case topPaddingPerMonitor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func tolerant<T: Decodable, K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> T? {
            do {
                return try c.decodeIfPresent(T.self, forKey: key)
            } catch {
                hyprLog(.notice, .config,
                        "monitor-config.json has a \(key.stringValue) value this build can't read; using the default")
                return nil
            }
        }
        var padding: [String: EdgePadding]? = tolerant(c, .outerPaddingPerMonitor)
        if !c.contains(.outerPaddingPerMonitor) {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let top: [String: CGFloat]? = tolerant(legacy, .topPaddingPerMonitor)
            padding = top?.mapValues { EdgePadding(top: $0) }
        }
        self.init(maxSplitsPerMonitor: tolerant(c, .maxSplitsPerMonitor),
                  disabledMonitors: tolerant(c, .disabledMonitors),
                  outerPaddingPerMonitor: padding,
                  workspaceMonitors: tolerant(c, .workspaceMonitors),
                  statusExportEnabled: tolerant(c, .statusExportEnabled),
                  statusHookCommand: tolerant(c, .statusHookCommand),
                  externalControlEnabled: tolerant(c, .externalControlEnabled))
    }
}
