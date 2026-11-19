import XCTest
@testable import HyprMac

// the config file watcher must survive an atomic save. editors and
// `mv tmp config.json` replace the file's inode, and a watcher left on the
// old inode goes deaf, so hand-edited window rules stop being picked up.

final class ConfigStoreWatcherTests: XCTestCase {

    private var dir: URL!
    private var store: ConfigStore!
    private var changes = 0
    private var lastSeen = ""
    // how often the watcher looks. production uses 2 s
    private let interval: TimeInterval = 0.15

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigStoreWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: url)
        store = ConfigStore(localConfigURL: url,
                            monitorConfigURL: dir.appendingPathComponent("monitor-config.json"),
                            iCloudRootURL: dir.appendingPathComponent("cloud", isDirectory: true),
                            watchInterval: interval)
        store.onFileChanged = { [unowned self] in
            changes += 1
            lastSeen = (try? String(contentsOf: store.localConfigURL, encoding: .utf8)) ?? ""
        }
        store.startFileWatcher()
    }

    override func tearDownWithError() throws {
        store.stopFileWatcher()
        try? FileManager.default.removeItem(at: dir)
    }

    private func waitUntil(_ what: String, _ condition: @escaping () -> Bool) {
        let done = expectation(description: what)
        func poll() {
            if condition() { done.fulfill() } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
            }
        }
        poll()
        wait(for: [done], timeout: 5)
    }

    private func atomicSave(_ text: String) throws {
        try Data(text.utf8).write(to: store.localConfigURL, options: .atomic)
    }

    func testInPlaceWriteIsSeen() throws {
        try Data(#"{"a":1}"#.utf8).write(to: store.localConfigURL)
        waitUntil("in-place write reported") { self.changes >= 1 }
    }

    func testEveryAtomicSaveIsSeenNotJustTheFirst() throws {
        try atomicSave(#"{"a":1}"#)
        waitUntil("first atomic save reported") { self.lastSeen == #"{"a":1}"# }
        waitUntil("watcher re-armed on the new file") { self.store.isWatchingFile }

        try atomicSave(#"{"a":2}"#)
        waitUntil("second atomic save reported") { self.lastSeen == #"{"a":2}"# }
        waitUntil("watcher re-armed again") { self.store.isWatchingFile }

        try Data(#"{"a":3}"#.utf8).write(to: store.localConfigURL)
        waitUntil("later in-place write reported") { self.lastSeen == #"{"a":3}"# }
    }

    // a save that lands while the watcher is between the old fd and the new
    // one still gets read: the re-arm reloads once more.
    func testASaveDuringTheReArmGapIsNotLost() throws {
        try atomicSave(#"{"a":1}"#)
        waitUntil("first atomic save reported") { self.changes >= 1 }
        try atomicSave(#"{"a":2}"#)
        waitUntil("save in the gap read after re-arm") { self.lastSeen == #"{"a":2}"# }
    }

    // some editors rename the old file away and write the new one a bit
    // later. the watcher must not give up when the path is missing at re-arm.
    func testWatcherKeepsTryingWhenTheFileIsBrieflyMissing() throws {
        let url = store.localConfigURL
        try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent("config.json.bak"))
        waitUntil("rename reported") { self.changes >= 1 }

        let wrote = expectation(description: "new file written")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            try? Data(#"{"a":5}"#.utf8).write(to: url)
            wrote.fulfill()
        }
        wait(for: [wrote], timeout: 2)
        waitUntil("new file picked up") { self.lastSeen == #"{"a":5}"# }

        try Data(#"{"a":6}"#.utf8).write(to: url)
        waitUntil("later in-place write reported") { self.lastSeen == #"{"a":6}"# }
    }

    // MARK: a link another tool re-points (Nix, dotfiles)

    private let fm = FileManager.default

    private func file(_ name: String, _ text: String) throws -> URL {
        let target = dir.appendingPathComponent(name)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
        return target
    }

    // a rename swaps the link in one step. remove-then-make leaves a gap
    private func point(_ link: URL, at target: URL, atomically: Bool) throws {
        if atomically {
            let temp = dir.appendingPathComponent("link-\(UUID().uuidString)")
            try fm.createSymbolicLink(at: temp, withDestinationURL: target)
            XCTAssertEqual(rename(temp.path, link.path), 0)
        } else {
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: target)
        }
    }

    // Home Manager swaps config.json for a link to a new store file on every
    // switch. the old file never changes, so a watcher on it alone goes deaf
    private func pointConfig(at text: String, named name: String, atomically: Bool) throws {
        try point(store.localConfigURL, at: file(name, text), atomically: atomically)
    }

    private func settle(_ seconds: TimeInterval = 0.6) {
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { settled.fulfill() }
        wait(for: [settled], timeout: seconds + 2)
    }

    private func watching(_ config: URL, opener: @escaping ConfigStore.WatchOpener = { Darwin.open($0, $1) },
                          seen: @escaping (String) -> Void) -> ConfigStore {
        let other = ConfigStore(localConfigURL: config,
                                monitorConfigURL: config.deletingLastPathComponent()
                                    .appendingPathComponent("monitor-\(config.lastPathComponent)"),
                                iCloudRootURL: dir.appendingPathComponent("cloud", isDirectory: true),
                                watchInterval: interval, watchOpener: opener)
        other.onFileChanged = { seen((try? String(contentsOf: config, encoding: .utf8)) ?? "") }
        other.startFileWatcher()
        addTeardownBlock { other.stopFileWatcher() }
        return other
    }

    func testARepointedLinkIsReloaded() throws {
        store.stopFileWatcher()
        try pointConfig(at: #"{"a":1}"#, named: "first.json", atomically: false)
        store.startFileWatcher()
        settle()

        try pointConfig(at: #"{"a":2}"#, named: "second.json", atomically: true)
        waitUntil("link swapped by rename is read") { self.lastSeen == #"{"a":2}"# }

        try pointConfig(at: #"{"a":3}"#, named: "third.json", atomically: false)
        waitUntil("link removed and made again is read") { self.lastSeen == #"{"a":3}"# }
        settle()

        try Data(#"{"a":4}"#.utf8).write(to: dir.appendingPathComponent("third.json"))
        waitUntil("the new target is watched too") { self.lastSeen == #"{"a":4}"# }
    }

    // config.json -> middle -> file. a dotfiles tool swaps the middle link
    func testAReplacedMiddleLinkIsReloaded() throws {
        let config = dir.appendingPathComponent("chained.json")
        let middle = dir.appendingPathComponent("middle.json")
        try point(middle, at: file("one.json", #"{"a":1}"#), atomically: false)
        try point(config, at: middle, atomically: false)
        var seen = ""
        _ = watching(config) { seen = $0 }
        settle()

        try point(middle, at: file("two.json", #"{"a":2}"#), atomically: true)
        waitUntil("middle link swapped by rename is read") { seen == #"{"a":2}"# }

        try point(middle, at: file("three.json", #"{"a":3}"#), atomically: false)
        waitUntil("middle link made again is read") { seen == #"{"a":3}"# }
    }

    // a link slipped in between two looks: config -> one becomes
    // config -> middle -> one. the same file is reached, and the entry at the
    // path is a new link, so it is read once more. the old watcher had to
    // notice the new link to hear it change later
    func testALinkAddedOnTheWayIsFollowedWhenItChanges() throws {
        let config = dir.appendingPathComponent("grown.json")
        let middle = dir.appendingPathComponent("grown-middle.json")
        let one = try file("grown-one.json", #"{"a":1}"#)
        try point(config, at: one, atomically: false)
        var seen = ""
        var reports = 0
        _ = watching(config) { seen = $0; reports += 1 }
        settle()

        try point(middle, at: one, atomically: false)
        try point(config, at: middle, atomically: true)
        settle()
        XCTAssertLessThanOrEqual(reports, 1, "one reread of the same bytes at most")
        XCTAssertTrue(seen.isEmpty || seen == #"{"a":1}"#)

        try point(middle, at: file("grown-two.json", #"{"a":2}"#), atomically: true)
        waitUntil("a change to the added link is read") { seen == #"{"a":2}"# }
    }

    // the folder that holds config.json is the link, as when a whole
    // generation folder is linked into place
    func testARepointedFolderLinkIsReloaded() throws {
        let live = dir.appendingPathComponent("live")
        let first = try file("gen1/config.json", #"{"a":1}"#).deletingLastPathComponent()
        let second = try file("gen2/config.json", #"{"a":2}"#).deletingLastPathComponent()
        let third = try file("gen3/config.json", #"{"a":3}"#).deletingLastPathComponent()
        try point(live, at: first, atomically: false)
        var seen = ""
        _ = watching(live.appendingPathComponent("config.json")) { seen = $0 }
        settle()

        try point(live, at: second, atomically: true)
        waitUntil("folder link swapped by rename is read") { seen == #"{"a":2}"# }

        try point(live, at: third, atomically: false)
        waitUntil("folder link made again is read") { seen == #"{"a":3}"# }
        settle()

        try Data(#"{"a":4}"#.utf8).write(to: third.appendingPathComponent("config.json"))
        waitUntil("the file in the new folder is watched") { seen == #"{"a":4}"# }
    }

    // a plain folder moved away and made again, with a new file in it. the
    // old file is still open and never changes
    func testAReplacedPlainFolderIsReloaded() throws {
        let folder = dir.appendingPathComponent("HyprMac", isDirectory: true)
        let config = try file("HyprMac/config.json", #"{"a":1}"#)
        var seen = ""
        _ = watching(config) { seen = $0 }
        settle()

        try fm.moveItem(at: folder, to: dir.appendingPathComponent("HyprMac.old"))
        _ = try file("HyprMac/config.json", #"{"a":2}"#)
        waitUntil("the new folder's file is read") { seen == #"{"a":2}"# }
        settle()

        try Data(#"{"a":3}"#.utf8).write(to: config)
        waitUntil("and it is the one watched") { seen == #"{"a":3}"# }
    }

    func testALinkMadeAgainMuchLaterIsReloaded() throws {
        store.stopFileWatcher()
        try pointConfig(at: #"{"a":1}"#, named: "first.json", atomically: false)
        store.startFileWatcher()
        settle()

        try fm.removeItem(at: store.localConfigURL)
        waitUntil("removal reported") { self.changes >= 1 }
        settle(1.2)
        XCTAssertFalse(store.isWatchingFile)

        try pointConfig(at: #"{"a":2}"#, named: "second.json", atomically: false)
        waitUntil("late link is read") { self.lastSeen == #"{"a":2}"# }
        settle()

        try Data(#"{"a":3}"#.utf8).write(to: dir.appendingPathComponent("second.json"))
        waitUntil("its target is watched") { self.lastSeen == #"{"a":3}"# }
    }

    // many swaps with no pause between them. whatever the watcher saw on
    // the way, it must end on the last file and be listening to it
    func testRapidLinkSwapsEndOnTheLastFile() throws {
        store.stopFileWatcher()
        try pointConfig(at: #"{"n":0}"#, named: "swap-0.json", atomically: false)
        store.startFileWatcher()

        for n in 1...120 {
            try pointConfig(at: #"{"n":\#(n)}"#, named: "swap-\(n).json", atomically: n % 3 != 0)
            if n % 20 == 0 { settle(0.05) }
        }
        waitUntil("the last file is read") { self.lastSeen == #"{"n":120}"# }
        settle()

        try Data(#"{"n":"edited"}"#.utf8).write(to: dir.appendingPathComponent("swap-120.json"))
        waitUntil("the last file is the one watched") { self.lastSeen == #"{"n":"edited"}"# }
    }

    // out of descriptors, say. the events are gone, the timer is not
    func testEveryChangeIsStillSeenWhenTheFileWontOpen() throws {
        let config = dir.appendingPathComponent("unopened.json")
        try point(config, at: file("unopened-1.json", #"{"a":1}"#), atomically: false)
        var seen = ""
        var attempts = 0
        let blind = watching(config, opener: { _, _ in
            attempts += 1
            errno = EMFILE
            return -1
        }) { seen = $0 }
        settle()
        XCTAssertFalse(blind.isWatchingFile)
        XCTAssertGreaterThan(attempts, 0)

        try Data(#"{"a":"edited"}"#.utf8).write(to: dir.appendingPathComponent("unopened-1.json"))
        waitUntil("a write in place is read") { seen == #"{"a":"edited"}"# }

        try point(config, at: file("unopened-2.json", #"{"a":2}"#), atomically: true)
        waitUntil("a re-pointed link is read") { seen == #"{"a":2}"# }
    }

    // MARK: start and stop

    func testNothingIsReportedWhileNothingChanges() throws {
        settle(1.0)
        XCTAssertEqual(changes, 0)
        XCTAssertTrue(store.isWatchingFile)
        XCTAssertFalse(store.isWatchingMonitorFile, "no monitor file, nothing to hold open")
    }

    func testAStoppedWatcherReportsNothing() throws {
        store.stopFileWatcher()
        try pointConfig(at: #"{"a":2}"#, named: "second.json", atomically: true)
        settle()

        XCTAssertEqual(changes, 0)
        XCTAssertFalse(store.isWatchingFile)
    }

    // the half second a restart used to wait lost any edit made in it. now
    // a start compares the disk with what was last read
    func testAChangeMadeWhileStoppedIsReportedAtTheNextStart() throws {
        settle()
        store.stopFileWatcher()
        try Data(#"{"a":"while stopped"}"#.utf8).write(to: store.localConfigURL)
        settle()
        XCTAssertEqual(changes, 0)

        store.startFileWatcher()
        waitUntil("the missed edit is reported") { self.lastSeen == #"{"a":"while stopped"}"# }
        settle()
        XCTAssertEqual(changes, 1, "once")
    }

    func testAChangeBetweenALoadAndTheFirstStartIsReported() throws {
        let config = try file("late-start.json", #"{"keybinds":[],"gapSize":23,"outerPadding":11,"enabled":false}"#)
        let late = ConfigStore(localConfigURL: config,
                               monitorConfigURL: dir.appendingPathComponent("late-monitor.json"),
                               iCloudRootURL: dir.appendingPathComponent("cloud", isDirectory: true),
                               watchInterval: interval)
        XCTAssertEqual(late.loadSavedConfig()?.gapSize, 23)
        try Data(#"{"keybinds":[],"gapSize":41,"outerPadding":2,"enabled":true}"#.utf8).write(to: config)

        var gap: CGFloat?
        late.onFileChanged = { gap = late.loadSavedConfig()?.gapSize }
        late.startFileWatcher()
        defer { late.stopFileWatcher() }
        waitUntil("the edit made before the start is read") { gap == 41 }
    }

    func testStartStopStartLeavesOneWorkingWatcher() throws {
        store.stopFileWatcher()
        store.startFileWatcher()
        store.stopFileWatcher()
        store.startFileWatcher()
        XCTAssertTrue(store.isWatchingFile)
        settle()
        XCTAssertEqual(changes, 0, "nothing changed on disk")

        // an atomic save is one event. a write in place is several
        try atomicSave(#"{"a":1}"#)
        waitUntil("edit reported") { self.lastSeen == #"{"a":1}"# }
        settle()
        XCTAssertEqual(changes, 1, "one watcher, one report")
    }

    // MARK: monitor-config.json

    func testAMonitorFileEditIsReported() throws {
        try Data(#"{"m":1}"#.utf8).write(to: store.monitorConfigURL)
        waitUntil("new monitor file reported") { self.changes >= 1 }
        waitUntil("watching it") { self.store.isWatchingMonitorFile }
        let before = changes

        try Data(#"{"m":2}"#.utf8).write(to: store.monitorConfigURL, options: .atomic)
        waitUntil("atomic save reported") { self.changes > before }
        settle()
        let afterAtomic = changes

        try Data(#"{"m":3}"#.utf8).write(to: store.monitorConfigURL)
        waitUntil("in-place write reported") { self.changes > afterAtomic }
    }

    func testARepointedMonitorLinkIsReported() throws {
        try point(store.monitorConfigURL, at: file("monitor-1.json", #"{"m":1}"#), atomically: false)
        waitUntil("watching it") { self.store.isWatchingMonitorFile }
        settle()
        let before = changes

        try point(store.monitorConfigURL, at: file("monitor-2.json", #"{"m":2}"#), atomically: true)
        waitUntil("swap reported") { self.changes > before }
    }

    func testOurOwnMonitorSaveIsNotReportedAsAnEdit() throws {
        try Data(#"{}"#.utf8).write(to: store.monitorConfigURL)
        waitUntil("watching it") { self.store.isWatchingMonitorFile }
        settle()
        let before = changes

        // the app loads a file before it ever saves over it
        _ = store.loadSavedMonitorConfig()
        let saved = SavedMonitorConfig(maxSplitsPerMonitor: ["DELL": 2], disabledMonitors: nil)
        store.writeSavedMonitorConfig(saved)
        store.writeSavedMonitorConfig(saved)
        XCTAssertTrue(store.isWatchingMonitorFile, "the new file is open at once")
        settle()

        XCTAssertEqual(changes, before)
        XCTAssertEqual(store.loadSavedMonitorConfig()?.maxSplitsPerMonitor, ["DELL": 2], "and it was really saved")
    }
}
