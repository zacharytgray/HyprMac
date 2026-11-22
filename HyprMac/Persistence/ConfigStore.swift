// On-disk persistence for user config. File paths, raw JSON load /
// save, iCloud Drive sync lifecycle (link + repair), a file watcher
// that fires when either file changes externally, and the copies kept
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

    /// How the watcher opens a file: `open(2)` with the given flags. Tests
    /// swap it to make the open fail.
    typealias WatchOpener = (_ path: String, _ flags: Int32) -> Int32

    /// Every path is injectable so tests run against scratch files.
    /// `watchInterval` is how often the watcher looks at what the two paths
    /// reach. `datalessFlag` marks a file iCloud hasn't downloaded; tests
    /// pass a flag they can set themselves.
    init(localConfigURL: URL = ConfigStore.configPath,
         monitorConfigURL: URL = ConfigStore.monitorConfigPath,
         iCloudRootURL: URL = ConfigStore.defaultICloudRootURL,
         watchInterval: TimeInterval = 2,
         watchOpener: @escaping WatchOpener = { Darwin.open($0, $1) },
         datalessFlag: UInt32 = UInt32(SF_DATALESS)) {
        self.localConfigURL = localConfigURL
        self.monitorConfigURL = monitorConfigURL
        self.iCloudRootURL = iCloudRootURL
        self.datalessFlag = datalessFlag
        self.watchInterval = watchInterval
        self.watch = ConfigWatch(urls: [localConfigURL, monitorConfigURL],
                                 interval: watchInterval, opener: watchOpener)
        watch.onObserved = { [weak self] epoch, written in self?.reconcile(epoch: epoch, written: written) }
    }

    var isICloudDriveAvailable: Bool {
        FileManager.default.fileExists(atPath: iCloudRootURL.path)
    }

    private var isLocalSymlink: Bool { Self.isLink(localConfigURL) }

    private static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// True when config.json is the link into iCloud, as found on disk now.
    var isLinkedToICloud: Bool { linksToICloud }

    private var linksToICloud: Bool {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: localConfigURL.path) else {
            return false
        }
        let target = URL(fileURLWithPath: destination, relativeTo: localConfigURL.deletingLastPathComponent())
        return Self.samePath(target, iCloudConfigURL)
    }

    /// True when config.json sits where another tool put it: the file is a
    /// link that doesn't go to the iCloud file, or its folder is itself a
    /// link, as when the whole HyprMac folder lives in a dotfiles checkout.
    /// Saves still go through, but the iCloud switch must never move it.
    var isLinkedByAnotherTool: Bool {
        !linksToICloud && (isLocalSymlink || Self.isLink(localConfigURL.deletingLastPathComponent()))
    }

    // the two spellings of a temp or home folder (/var and /private/var) are one path
    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        func resolved(_ url: URL) -> String {
            url.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(url.lastPathComponent).path
        }
        return a.standardizedFileURL.path == b.standardizedFileURL.path || resolved(a) == resolved(b)
    }

    /// True when HyprMac can't save config.json: the file it resolves to,
    /// or that file's folder, can't be written, as in the Nix store.
    /// Changes made in Settings then last until the next load.
    var isConfigReadOnly: Bool { Self.isReadOnly(localConfigURL) }

    var isMonitorConfigReadOnly: Bool { Self.isReadOnly(monitorConfigURL) }

    // an atomic save renames over the file, which only needs the folder.
    // a file locked on its own must stop it too
    private static func isReadOnly(_ url: URL) -> Bool {
        let file = writeTarget(of: url).path
        let folder = (file as NSString).deletingLastPathComponent
        func locked(_ path: String) -> Bool { access(path, F_OK) == 0 && access(path, W_OK) != 0 }
        return locked(file) || locked(folder)
    }

    // MARK: - file watcher state

    // fired (on main queue) when a watched file changes from disk.
    // owners typically reload state in response.
    var onFileChanged: (() -> Void)?

    fileprivate enum ConfigFile: Int, CaseIterable {
        case config, monitor
    }

    private func url(of file: ConfigFile) -> URL {
        file == .config ? localConfigURL : monitorConfigURL
    }

    private let watch: ConfigWatch
    // bumped by every start and stop, so what a stopped watcher saw is dropped
    private var watchEpoch = 0
    private var watcherWanted = false
    // what memory holds of each file: the mark taken at the last read or
    // save. the watcher reports a file only when it no longer matches, so a
    // change made while nobody was watching is still found. missing from
    // here means never read
    private var baseline: [ConfigFile: FileMark] = [:]
    private var ownWriteReportPending = false
    private let datalessFlag: UInt32
    private let watchInterval: TimeInterval
    // paths a background read is bringing down from iCloud
    private var downloading: Set<String> = []

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
        // marked before the read: a change that lands in between shows up
        // as one more reload, never as a missed one
        baseline[url == localConfigURL ? .config : .monitor] = FileMark.of(url)
        let data: Data
        do {
            data = try bytes(at: url)
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

    private enum FileError: Error {
        case notAFile, notDownloaded
    }

    // a pipe or a device at the path would hold the main thread until
    // something writes to it, and a file iCloud hasn't downloaded would
    // hold it until the network brings it
    private func bytes(at url: URL) throws -> Data {
        var info = stat()
        guard fstatat(AT_FDCWD, url.path, &info, 0) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw FileError.notAFile }
        guard info.st_flags & datalessFlag == 0 else {
            download(url)
            throw FileError.notDownloaded
        }
        return try Data(contentsOf: url)
    }

    // reading the file is what brings it down, so read it off the main
    // thread. once it's here, owners reload, whether or not the watcher saw it
    private func download(_ url: URL) {
        guard downloading.insert(url.path).inserted else { return }
        let flag = datalessFlag
        let interval = watchInterval
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var arrived = false
            for _ in 0..<5 where !arrived {
                _ = try? Data(contentsOf: url)
                var info = stat()
                arrived = fstatat(AT_FDCWD, url.path, &info, 0) == 0 && info.st_flags & flag == 0
                if !arrived { Thread.sleep(forTimeInterval: interval) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.downloading.remove(url.path)
                if arrived { self.onFileChanged?() }
            }
        }
    }

    private static func isFileMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError)
            || (error.domain == NSPOSIXErrorDomain && error.code == ENOENT)
    }

    // the file is hand-editable, so its values stay out of the log
    private static func reason(for error: Error) -> String {
        switch error {
        case FileError.notAFile:
            return "not a regular file"
        case FileError.notDownloaded:
            return "not downloaded from iCloud yet"
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
              keepUnreadableCopy(of: localConfigURL, as: SavedConfig.self),
              writeAtomically(data, to: localConfigURL) else { return }
        adopt(.config)
        reportOwnWrite()
    }

    func writeSavedMonitorConfig(_ mc: SavedMonitorConfig) {
        guard let data = encode(mc, for: monitorConfigURL),
              keepUnreadableCopy(of: monitorConfigURL, as: SavedMonitorConfig.self),
              writeAtomically(data, to: monitorConfigURL) else { return }
        adopt(.monitor)
    }

    // memory holds what this save wrote, so the watcher must not report it
    // as an outside edit
    private func adopt(_ file: ConfigFile) {
        baseline[file] = FileMark.of(url(of: file))
        watch.checkNow()
    }

    /// Keep what a reset is about to replace.
    func keepCopiesBeforeReset() {
        for url in [localConfigURL, monitorConfigURL] {
            if let data = try? bytes(at: url) {
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
        // the file belongs to whoever made it read-only: Nix, a dotfiles
        // tool, the user. changes last until the next load
        guard !Self.isReadOnly(url) else {
            hyprLog(.info, .config, "\(url.lastPathComponent) not saved: it is read-only")
            return false
        }
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
            return .data(try bytes(at: url))
        } catch {
            return Self.isFileMissing(error) ? .missing : .blocked(reason: Self.reason(for: error))
        }
    }

    // never overwrites an older copy: the first one may be the only good
    // version of someone's settings. the same bytes are not copied twice
    @discardableResult
    // `source` is the file the bytes came from, for its mode. a copy is as
    // private as the file it copies
    private func keepCopy(_ data: Data, of url: URL, suffix: String, source: URL? = nil) -> Bool {
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
            Self.copyMode(from: source ?? url, to: copy)
            hyprLog(.warning, .config, "kept a copy of \(url.lastPathComponent) at \(copy.lastPathComponent)")
            return true
        } catch {
            hyprLog(.warning, .config, "couldn't copy \(url.lastPathComponent): \(Self.code(of: error))")
            return false
        }
    }

    // MARK: - iCloud Drive sync

    // enable iCloud sync — puts the local file (or current state via the
    // snapshot closure) in iCloud, then symlinks the local path at it. a
    // readable copy already in iCloud is another Mac's, and wins: this Mac
    // links to it and keeps its own file beside the link. the local file
    // goes only after iCloud holds its data.
    //
    // returns true when the path now reads a different file, so the
    // caller must reload.
    //
    // `cloudWins: false` is the user choosing this Mac's settings: they go
    // up, and the copy in iCloud is kept as config.json.replaced.
    @discardableResult
    func enableICloudSync(snapshot: () -> SavedConfig, cloudWins: Bool = true) -> Bool {
        guard !isLinkedByAnotherTool else {
            hyprLog(.warning, .config, "iCloud sync not set up: another tool put config.json where it is")
            return false
        }
        defer { watch.checkNow() }
        let fm = FileManager.default
        let isLink = isLocalSymlink

        if !isLink, cloudWins, hasReadableICloudCopy { return joinICloud() }

        if !isLink || !fm.fileExists(atPath: localConfigURL.path) {
            let hasLocal = fm.fileExists(atPath: localConfigURL.path)
            let data = hasLocal ? try? bytes(at: localConfigURL) : encode(snapshot(), for: iCloudConfigURL)
            guard let data else {
                hyprLog(.warning, .config, "iCloud sync not set up: couldn't read config.json")
                return false
            }
            do {
                try fm.createDirectory(at: iCloudConfigURL.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
            } catch {
                hyprLog(.warning, .config, "iCloud sync not set up: \(Self.code(of: error))")
                return false
            }
            switch contents(of: iCloudConfigURL) {
            case .missing:
                break
            case .blocked(let reason):
                hyprLog(.warning, .config, "iCloud sync not set up: can't read the file there (\(reason))")
                return false
            case .data(let existing):
                if existing != data,
                   !keepCopy(existing, of: localConfigURL, suffix: "replaced", source: iCloudConfigURL) {
                    return false
                }
            }
            guard writeAtomically(data, to: iCloudConfigURL) else { return false }
            if hasLocal { Self.copyMode(from: localConfigURL, to: iCloudConfigURL) }
        }

        if !isLink, !linkLocalToICloud() { return false }
        writesHeld = false
        return false
    }

    /// True when turning sync on has a choice to make: this Mac has its own
    /// config.json, and iCloud holds a different one that reads.
    var iCloudCopyDiffersFromLocal: Bool {
        guard !isLocalSymlink, hasReadableICloudCopy, let local = try? bytes(at: localConfigURL) else { return false }
        return local != (try? bytes(at: iCloudConfigURL))
    }

    private var hasReadableICloudCopy: Bool {
        guard let data = try? bytes(at: iCloudConfigURL) else { return false }
        return (try? JSONDecoder().decode(SavedConfig.self, from: data)) != nil
    }

    // disable iCloud sync — read data via the symlink and put it over the
    // link as a regular file. snapshot is a fallback if the read fails.
    func disableICloudSync(snapshot: () -> SavedConfig) {
        // only the iCloud link is ours to replace. a hold on another tool's
        // unreadable link stays too, so defaults never reach its file
        guard !isLinkedByAnotherTool else {
            hyprLog(.notice, .config, "another tool put config.json where it is; leaving it alone")
            return
        }
        defer { watch.checkNow() }
        writesHeld = false
        guard isLocalSymlink else { return }
        guard let data = (try? bytes(at: localConfigURL)) ?? encode(snapshot(), for: localConfigURL) else {
            return
        }
        // beside the link so the rename replaces the link, not what it points at
        let temp = URL(fileURLWithPath: "\(localConfigURL.path).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temp)
            Self.copyMode(from: localConfigURL, to: temp)
            try Self.rename(temp, over: localConfigURL)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            hyprLog(.warning, .config, "iCloud link not removed: \(Self.code(of: error))")
        }
    }

    // a new file gets the default mode, so a private file has to stay private by hand
    private static func copyMode(from source: URL, to destination: URL) {
        let fm = FileManager.default
        guard let mode = try? fm.attributesOfItem(atPath: writeTarget(of: source).path)[.posixPermissions] else { return }
        try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: destination.path)
    }

    // verify symlink integrity when iCloudSyncEnabled is set in UserDefaults
    // but the local path is no longer a symlink (e.g. first launch on a new
    // machine, or an editor that saved over the link).
    //
    // returns true when the path now reads a different file, so the caller's
    // values are stale and it must reload before anything saves them over iCloud.
    @discardableResult
    func ensureICloudSymlinkIntegrity(snapshot: () -> SavedConfig) -> Bool {
        guard !isLocalSymlink, !isLinkedByAnotherTool else { return false }

        guard FileManager.default.fileExists(atPath: iCloudConfigURL.path) else {
            // iCloud file doesn't exist — set up fresh
            enableICloudSync(snapshot: snapshot)
            return false
        }
        return joinICloud()
    }

    // link to the copy in iCloud, keeping this Mac's file beside the link
    // when it differs. true when the path now reads that copy
    private func joinICloud() -> Bool {
        switch contents(of: localConfigURL) {
        case .missing:
            break
        case .blocked(let reason):
            hyprLog(.warning, .config, "config.json not linked to iCloud: can't read it to keep a copy (\(reason))")
            return false
        case .data(let local):
            if local != (try? bytes(at: iCloudConfigURL)),
               !keepCopy(local, of: localConfigURL, suffix: "replaced") {
                return false
            }
        }
        guard linkLocalToICloud() else { return false }
        writesHeld = false
        hyprLog(.notice, .config, "config.json linked to the copy in iCloud")
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

    /// Watches both config files, whatever their paths go through: plain
    /// files, links, linked folders. A file that isn't there yet is picked
    /// up when it appears. A change made since the last read is reported
    /// right away, so nothing is lost between a load and the start.
    func startFileWatcher() {
        watchEpoch += 1
        watcherWanted = true
        // never read by anyone: nothing in memory to compare with
        for file in ConfigFile.allCases where baseline[file] == nil {
            baseline[file] = FileMark.of(url(of: file))
        }
        watch.start(epoch: watchEpoch)
    }

    /// True while the watcher runs and has config.json open, so a write in
    /// place is heard at once and not at the next look.
    var isWatchingFile: Bool { watch.isSubscribed(ConfigFile.config.rawValue) }

    var isWatchingMonitorFile: Bool { watch.isSubscribed(ConfigFile.monitor.rawValue) }

    func stopFileWatcher() {
        watchEpoch += 1
        watcherWanted = false
        watch.stop()
    }

    // the watcher saw something change. it only looks; whether memory is
    // out of date is decided here, on the main queue, against the baseline.
    // `written` are files that were written in place: those are reread even
    // when nothing about them looks different
    private func reconcile(epoch: Int, written: Set<Int>) {
        guard epoch == watchEpoch else { return }
        var changed = false
        for file in ConfigFile.allCases {
            let now = FileMark.of(url(of: file))
            guard baseline[file] != now || written.contains(file.rawValue) else { continue }
            baseline[file] = now
            changed = true
        }
        guard changed else { return }
        // main can get here ahead of the watcher's own next look, so have
        // it look now: a file that just appeared is open before the owner hears
        watch.checkNow()
        onFileChanged?()
    }

    // a watcher on the old file would have reported this save, and the
    // reload it starts is how a save has always settled, so keep it. saves
    // in one main-queue turn report once, as the dispatch source did
    private func reportOwnWrite() {
        guard !ownWriteReportPending else { return }
        ownWriteReportPending = true
        let epoch = watchEpoch
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.ownWriteReportPending = false
            if self.watcherWanted, epoch == self.watchEpoch { self.onFileChanged?() }
        }
    }
}

// MARK: - file mark

/// What a path holds right now: the entry at the path, its folder, and the
/// file it reaches. Equal marks mean nothing changed. Three lookups and no
/// link walk: a link or folder swapped on the way changes the file reached.
private struct FileMark: Equatable {
    // one directory entry, not followed
    struct Entry: Equatable {
        let device: dev_t
        let inode: ino_t
        let isLink: Bool
    }

    // ctime moves on every write and can't be set back, so an edit that
    // keeps size and mtime still shows
    struct Content: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modified: Int64
        let changed: Int64
    }

    let entry: Entry?
    let folder: Entry?
    // nil when the path reaches no file
    let content: Content?

    static func of(_ url: URL) -> FileMark {
        of(path: url.path, folder: url.deletingLastPathComponent().path)
    }

    static func of(path: String, folder: String) -> FileMark {
        var info = stat()
        var content: Content?
        if fstatat(AT_FDCWD, path, &info, 0) == 0 {
            content = Content(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                              modified: nanoseconds(info.st_mtimespec), changed: nanoseconds(info.st_ctimespec))
        }
        return FileMark(entry: entry(at: path), folder: entry(at: folder), content: content)
    }

    private static func entry(at path: String) -> Entry? {
        var info = stat()
        guard fstatat(AT_FDCWD, path, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return Entry(device: info.st_dev, inode: info.st_ino, isLink: info.st_mode & S_IFMT == S_IFLNK)
    }

    private static func nanoseconds(_ time: timespec) -> Int64 {
        Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
    }
}

// MARK: - config watch

/// Looks at what the config paths hold on a timer, off the main queue, and
/// tells main when that changed. The timer finds every kind of change: a
/// re-pointed link, a swapped folder, a file that appears or goes. Each
/// reached file is also held open for events, so an edit in place shows at
/// once. If a file won't open, the timer still covers it.
private final class ConfigWatch {
    /// Called on the main queue with the epoch `start` was given, and the
    /// indexes of files that were written in place since the last call.
    var onObserved: ((_ epoch: Int, _ written: Set<Int>) -> Void)?

    // as strings: the timer reads them every look
    private let paths: [(file: String, folder: String)]
    private let interval: TimeInterval
    private let opener: ConfigStore.WatchOpener
    private let queue = DispatchQueue(label: "com.zachgray.HyprMac.config-watch", qos: .utility)

    private struct Leaf {
        let device: dev_t
        let inode: ino_t
        let source: DispatchSourceFileSystemObject
    }

    // everything below is touched only on `queue`
    private var timer: DispatchSourceTimer?
    private var epoch = 0
    private var observed: [FileMark]?
    private var leaves: [Leaf?]

    init(urls: [URL], interval: TimeInterval, opener: @escaping ConfigStore.WatchOpener) {
        self.paths = urls.map { ($0.path, $0.deletingLastPathComponent().path) }
        self.interval = interval
        self.opener = opener
        self.leaves = Array(repeating: nil, count: urls.count)
    }

    deinit {
        timer?.cancel()
        leaves.forEach { $0?.source.cancel() }
    }

    /// Looks once before it returns, so the files are open from here on.
    func start(epoch: Int) {
        queue.sync {
            halt()
            self.epoch = epoch
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.look() }
            timer.resume()
            self.timer = timer
            look()
        }
    }

    func stop() {
        queue.sync { halt() }
    }

    /// Look now, for the caller that just changed a file itself. It doesn't
    /// wait: the look runs on the watch queue, ahead of anything asked after.
    func checkNow() {
        queue.async { [weak self] in
            guard let self, self.timer != nil else { return }
            self.look()
        }
    }

    func isSubscribed(_ index: Int) -> Bool {
        queue.sync { timer != nil && leaves[index] != nil }
    }

    private func halt() {
        timer?.cancel()
        timer = nil
        observed = nil
        for index in leaves.indices {
            leaves[index]?.source.cancel()
            leaves[index] = nil
        }
    }

    // `written` is the file an event just reported a write to, if any. a
    // write is passed on even when the marks came out equal: the bytes changed
    private func look(written: Int? = nil) {
        let marks = paths.map { FileMark.of(path: $0.file, folder: $0.folder) }
        for (index, mark) in marks.enumerated() { follow(index, mark.content) }
        // the first look after a start always reports: the owner checks it
        // against what it last read
        guard observed != marks || written != nil else { return }
        observed = marks
        let epoch = epoch
        let written: Set<Int> = written.map { [$0] } ?? []
        DispatchQueue.main.async { [weak self] in self?.onObserved?(epoch, written) }
    }

    // keep the file the path reaches open for events. an atomic save or a
    // re-pointed link leaves the old one open, so swap when the mark moves on
    private func follow(_ index: Int, _ content: FileMark.Content?) {
        if let leaf = leaves[index], let content, leaf.device == content.device, leaf.inode == content.inode {
            return
        }
        leaves[index]?.source.cancel()
        leaves[index] = nil
        guard content != nil else { return }
        // non-blocking: even an open for events waits on a pipe. and only
        // a regular file is followed
        let fd = opener(paths[index].file, O_EVTONLY | O_NONBLOCK)
        guard fd >= 0 else { return }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self, unowned source] in
            let wasWritten = !source.data.isDisjoint(with: [.write, .extend])
            self?.look(written: wasWritten ? index : nil)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        leaves[index] = Leaf(device: info.st_dev, inode: info.st_ino, source: source)
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
    // nil when there are none, so a config without rules is written as before
    var floatingRules: [FloatingRule]? = nil
    var workspaceNames: [String: String]? = nil
    // nil = the brand cyan and magenta pair
    var overlayAccentHex: String? = nil
    var keepCursorOnWorkspaceSwitch: Bool? = nil
    var animateFocusIndicator: Bool? = nil
    var focusBorderFlash: Bool? = nil
    var doubleTapHyprTogglesCapsLock: Bool? = nil
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
        case floatingRules
        case workspaceNames
        case overlayAccentHex
        case keepCursorOnWorkspaceSwitch
        case animateFocusIndicator
        case focusBorderFlash
        case doubleTapHyprTogglesCapsLock
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
        self.floatingRules = Self.tolerantFloatingRules(c)
        self.workspaceNames = Self.tolerantWorkspaceNames(c)
        self.overlayAccentHex = Self.tolerant(c, .overlayAccentHex)
        self.keepCursorOnWorkspaceSwitch = Self.tolerant(c, .keepCursorOnWorkspaceSwitch)
        self.animateFocusIndicator = Self.tolerant(c, .animateFocusIndicator)
        self.focusBorderFlash = Self.tolerant(c, .focusBorderFlash)
        self.doubleTapHyprTogglesCapsLock = Self.tolerant(c, .doubleTapHyprTogglesCapsLock)
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

    // same per-element tolerance: a rule a newer build wrote, or a hand edit
    // with a bad action or match, costs only that rule
    private static func tolerantFloatingRules(_ c: KeyedDecodingContainer<CodingKeys>) -> [FloatingRule]? {
        guard c.contains(.floatingRules), (try? c.decodeNil(forKey: .floatingRules)) == false else { return nil }
        guard var arr = try? c.nestedUnkeyedContainer(forKey: .floatingRules) else {
            hyprLog(.notice, .config, "config.json has a floatingRules value this build can't read; using no rules")
            return nil
        }
        var kept: [FloatingRule] = []
        while !arr.isAtEnd {
            if (try? arr.decodeNil()) == true { continue }
            guard let element = try? arr.decode(FailableFloatingRule.self) else { break }
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

// one float or tile rule, or nil when it doesn't decode.
private struct FailableFloatingRule: Decodable {
    let rule: FloatingRule?

    init(from decoder: Decoder) throws {
        do {
            rule = try FloatingRule(from: decoder)
        } catch {
            rule = nil
            hyprLog(.warning, .config, "skipping malformed float or tile rule")
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
    // monitor name → workspaces that live there. nil = the formula homes.
    // the fallback for a display set with no entry below
    var workspaceMonitors: [String: [Int]]? = nil
    // the same mapping, saved per set of connected displays. Settings
    // writes here. nil = workspaceMonitors for every set
    var workspaceMonitorsPerDisplaySet: [DisplaySetWorkspaces]? = nil
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
             workspaceMonitorsPerDisplaySet, statusExportEnabled, statusHookCommand, externalControlEnabled
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
                  workspaceMonitorsPerDisplaySet: Self.tolerantDisplaySets(c),
                  statusExportEnabled: tolerant(c, .statusExportEnabled),
                  statusHookCommand: tolerant(c, .statusHookCommand),
                  externalControlEnabled: tolerant(c, .externalControlEnabled))
    }
}

// a bad entry costs only itself, and a second entry for one set loses to
// the first, so what Settings edits is what applies
extension SavedMonitorConfig {
    private static func tolerantDisplaySets(_ c: KeyedDecodingContainer<CodingKeys>) -> [DisplaySetWorkspaces]? {
        guard c.contains(.workspaceMonitorsPerDisplaySet),
              (try? c.decodeNil(forKey: .workspaceMonitorsPerDisplaySet)) == false else { return nil }
        guard var arr = try? c.nestedUnkeyedContainer(forKey: .workspaceMonitorsPerDisplaySet) else {
            hyprLog(.notice, .config,
                    "monitor-config.json has a workspaceMonitorsPerDisplaySet value this build can't read; using workspaceMonitors")
            return nil
        }
        var kept: [DisplaySetWorkspaces] = []
        while !arr.isAtEnd {
            if (try? arr.decodeNil()) == true { continue }
            guard let element = try? arr.decode(FailableDisplaySetWorkspaces.self) else { break }
            guard let entry = element.entry else { continue }
            let key = WorkspaceHomeResolver.displaySet(entry.displays)
            if kept.contains(where: { WorkspaceHomeResolver.displaySet($0.displays) == key }) {
                hyprLog(.notice, .config, "monitor-config.json lists one display set twice; the first entry applies")
                continue
            }
            kept.append(entry)
        }
        return kept
    }
}

// the workspace mapping for one set of connected displays. `displays` is
// every connected display by name, disabled ones too; order doesn't matter
struct DisplaySetWorkspaces: Codable, Equatable {
    var displays: [String]
    var workspaceMonitors: [String: [Int]]
}

extension DisplaySetWorkspaces {
    private enum CodingKeys: String, CodingKey {
        case displays, workspaceMonitors
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let displays = try c.decode([String].self, forKey: .displays)
        guard !displays.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .displays, in: c, debugDescription: "no displays")
        }
        self.init(displays: displays,
                  workspaceMonitors: try c.decode([String: [Int]].self, forKey: .workspaceMonitors))
    }
}

private struct FailableDisplaySetWorkspaces: Decodable {
    let entry: DisplaySetWorkspaces?

    init(from decoder: Decoder) throws {
        do {
            entry = try DisplaySetWorkspaces(from: decoder)
        } catch {
            entry = nil
            hyprLog(.notice, .config, "skipping a workspaceMonitorsPerDisplaySet entry this build can't read")
        }
    }
}
