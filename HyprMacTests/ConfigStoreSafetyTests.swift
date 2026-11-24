import XCTest
@testable import HyprMac

// no config save may destroy settings it can't get back. every test runs on
// scratch files through injected paths, so nothing here touches real config.

final class ConfigStoreSafetyTests: XCTestCase {

    private var dir: URL!
    private var local: URL!
    private var monitor: URL!
    private var iCloudRoot: URL!
    private var iCloudFile: URL!
    private var store: ConfigStore!
    private let fm = FileManager.default

    private let good = Data(#"{"keybinds":[],"gapSize":23,"outerPadding":11,"enabled":false}"#.utf8)
    private let other = Data(#"{"keybinds":[],"gapSize":41,"outerPadding":2,"enabled":true}"#.utf8)
    private let garbage = Data("not json at all".utf8)

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("ConfigStoreSafety-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        local = dir.appendingPathComponent("config.json")
        monitor = dir.appendingPathComponent("monitor-config.json")
        iCloudRoot = dir.appendingPathComponent("cloud", isDirectory: true)
        try fm.createDirectory(at: iCloudRoot, withIntermediateDirectories: true)
        store = ConfigStore(localConfigURL: local, monitorConfigURL: monitor, iCloudRootURL: iCloudRoot)
        iCloudFile = store.iCloudConfigURL
    }

    override func tearDownWithError() throws {
        store.stopFileWatcher()
        store = nil
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? fm.removeItem(at: dir)
    }

    // MARK: helpers

    private func putInICloud(_ data: Data) throws {
        try fm.createDirectory(at: iCloudFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: iCloudFile)
    }

    private func linkLocalToICloud() throws {
        try fm.createSymbolicLink(at: local, withDestinationURL: iCloudFile)
    }

    private func isLink(_ url: URL) -> Bool {
        (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func copy(_ url: URL, _ suffix: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: "\(url.path).\(suffix)"))
    }

    private func savedGap(_ url: URL) throws -> CGFloat {
        try JSONDecoder().decode(SavedConfig.self, from: Data(contentsOf: url)).gapSize
    }

    private func waitUntil(_ what: String, _ condition: @escaping () -> Bool) {
        let done = expectation(description: what)
        func poll() {
            if condition() { done.fulfill() } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
            }
        }
        poll()
        wait(for: [done], timeout: 6)
    }

    // MARK: missing vs unreadable

    func testAbsentFileIsMissing() {
        guard case .missing = store.readSavedConfig() else { return XCTFail("expected missing") }
        guard case .missing = store.readSavedMonitorConfig() else { return XCTFail("expected missing") }
    }

    func testDamagedFilesAreUnreadableNotMissing() throws {
        let damaged: [(String, Data, String)] = [
            ("truncated", good.prefix(20), "not valid JSON"),
            ("garbage", garbage, "not valid JSON"),
            ("empty", Data(), "not valid JSON"),
            ("wrong core type", Data(#"{"keybinds":[],"gapSize":"big","outerPadding":1,"enabled":true}"#.utf8),
             "wrong type at gapSize"),
            ("missing core field", Data(#"{"keybinds":[],"outerPadding":1,"enabled":true}"#.utf8), "missing gapSize"),
            ("wrong shape", Data("[1,2]".utf8), "wrong type at top level"),
        ]
        for (name, data, expected) in damaged {
            try data.write(to: local)
            guard case .unreadable(let reason) = store.readSavedConfig() else {
                XCTFail("\(name) should be unreadable")
                continue
            }
            XCTAssertEqual(reason, expected, name)
        }
    }

    // the log line carries the reason, so it must not carry the file's text
    func testReasonLeavesTheFilesValuesOut() throws {
        try Data(#"{"keybinds":[],"gapSize":"my secret note","outerPadding":1,"enabled":true}"#.utf8).write(to: local)
        guard case .unreadable(let reason) = store.readSavedConfig() else { return XCTFail("expected unreadable") }
        XCTAssertFalse(reason.contains("secret"))
    }

    func testGoodFileLoads() throws {
        try good.write(to: local)
        XCTAssertEqual(store.loadSavedConfig()?.gapSize, 23)
    }

    // MARK: onboarding sign

    // any config.json, even one that can't be read, means this Mac ran
    // HyprMac before, so onboarding stays away
    func testAConfigFileAtLoadMarksTheMacAsSetUp() throws {
        XCTAssertFalse(UserConfig(store: store, iCloudSyncEnabled: false).hadConfigFileAtLoad)
        try good.write(to: local)
        XCTAssertTrue(UserConfig(store: store, iCloudSyncEnabled: false).hadConfigFileAtLoad)
        try garbage.write(to: local)
        XCTAssertTrue(UserConfig(store: store, iCloudSyncEnabled: false).hadConfigFileAtLoad)
    }

    // a new Mac with iCloud sync on links to another Mac's config: set up
    func testAConfigTheICloudRelinkBringsInMarksTheMacAsSetUp() throws {
        try putInICloud(good)
        let config = UserConfig(store: store, iCloudSyncEnabled: true)
        XCTAssertTrue(isLink(local))
        XCTAssertTrue(config.hadConfigFileAtLoad)
    }

    // sync on with nothing in iCloud yet: the fresh copy HyprMac writes there
    // isn't a sign of an earlier launch
    func testAFreshICloudCopyIsNotASignOfAnEarlierLaunch() {
        XCTAssertFalse(UserConfig(store: store, iCloudSyncEnabled: true).hadConfigFileAtLoad)
    }

    // MARK: unreadable at launch

    func testUnreadableConfigIsLeftAloneUntilTheFirstSaveThenCopied() throws {
        try garbage.write(to: local)

        let config = UserConfig(store: store, iCloudSyncEnabled: false)

        XCTAssertEqual(config.gapSize, UserConfigDefaults.gapSize)
        XCTAssertEqual(try Data(contentsOf: local), garbage, "launch must not touch the file")
        XCTAssertNil(copy(local, "unreadable"), "a read mid sync can look unreadable, so no copy yet")

        config.gapSize = 31

        XCTAssertEqual(copy(local, "unreadable"), garbage)
        XCTAssertEqual(try savedGap(local), 31)
    }

    func testAFileWithOneBadCoreFieldKeepsAllItsText() throws {
        let edited = Data(#"{"keybinds":[{"keyCode":17,"modifiers":3,"action":{"retileAll":{}}}],"gapSize":"8","outerPadding":1,"enabled":true}"#.utf8)
        try edited.write(to: local)
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        config.outerPadding = 5
        XCTAssertEqual(copy(local, "unreadable"), edited)
    }

    func testEmptyFileHasNothingToCopy() throws {
        try Data().write(to: local)
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        config.gapSize = 31
        XCTAssertNil(copy(local, "unreadable"))
        XCTAssertEqual(try savedGap(local), 31)
    }

    func testAnOlderCopyIsNeverOverwritten() throws {
        try garbage.write(to: local)
        store.writeSavedConfig(.empty)
        let second = Data("different damage".utf8)
        try second.write(to: local)
        store.writeSavedConfig(.empty)

        XCTAssertEqual(copy(local, "unreadable"), garbage)
        XCTAssertEqual(copy(local, "unreadable.2"), second)
    }

    func testTheSameBytesAreNotCopiedTwice() throws {
        try garbage.write(to: local)
        store.writeSavedConfig(.empty)
        try garbage.write(to: local)
        store.writeSavedConfig(.empty)

        XCTAssertEqual(copy(local, "unreadable"), garbage)
        XCTAssertNil(copy(local, "unreadable.2"))
    }

    func testAGoodFileIsNotCopied() throws {
        try good.write(to: local)
        store.writeSavedConfig(.empty)
        XCTAssertNil(copy(local, "unreadable"))
    }

    // MARK: unreadable while running

    func testBadEditWhileRunningKeepsSettingsAndTheEdit() throws {
        try good.write(to: local)
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        XCTAssertEqual(config.gapSize, 23)

        try garbage.write(to: local)
        config.reloadFromDisk()

        XCTAssertEqual(config.gapSize, 23, "settings in memory stay")
        XCTAssertEqual(try Data(contentsOf: local), garbage, "the edit stays")
        XCTAssertNil(copy(local, "unreadable"))

        config.outerPadding = 4
        XCTAssertEqual(copy(local, "unreadable"), garbage, "the next save keeps the edit")
        XCTAssertEqual(try savedGap(local), 23)
    }

    // MARK: monitor config

    func testUnreadableMonitorConfigIsCopiedBeforeTheNextSave() throws {
        try good.write(to: local)
        try garbage.write(to: monitor)
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        XCTAssertEqual(try Data(contentsOf: monitor), garbage)

        config.gapSize = 31

        XCTAssertEqual(copy(monitor, "unreadable"), garbage)
        XCTAssertNotNil(store.loadSavedMonitorConfig())
    }

    // the old-config migration writes the monitor file during launch
    func testMonitorMigrationAtLaunchDoesNotEatAnUnreadableFile() throws {
        try Data(#"{"keybinds":[],"gapSize":1,"outerPadding":1,"enabled":true,"maxSplitsPerMonitor":{"DELL":2}}"#.utf8)
            .write(to: local)
        try garbage.write(to: monitor)

        let config = UserConfig(store: store, iCloudSyncEnabled: false)

        XCTAssertEqual(config.maxSplitsPerMonitor, ["DELL": 2])
        XCTAssertEqual(copy(monitor, "unreadable"), garbage)
    }

    // MARK: failed and interrupted saves

    func testAFailedSaveLeavesTheOldFile() throws {
        try good.write(to: local)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        store.writeSavedConfig(.empty)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertEqual(try Data(contentsOf: local), good)
    }

    // copying fails the same way, and the unreadable file has to survive it
    func testAFailedCopyLeavesTheUnreadableFile() throws {
        try garbage.write(to: local)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        store.writeSavedConfig(.empty)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertEqual(try Data(contentsOf: local), garbage)
    }

    // MARK: can't be opened

    private func lock(_ url: URL) throws {
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    }

    private func unlock(_ url: URL) throws {
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    func testAConfigThatWontOpenIsNotOverwritten() throws {
        try garbage.write(to: local)
        try lock(local)
        store.writeSavedConfig(try XCTUnwrap(try? JSONDecoder().decode(SavedConfig.self, from: good)))
        try unlock(local)
        XCTAssertEqual(try Data(contentsOf: local), garbage)
        XCTAssertNil(copy(local, "unreadable"))
    }

    func testSavingResumesOnceTheConfigOpensAgain() throws {
        try garbage.write(to: local)
        try lock(local)
        let saved = try XCTUnwrap(try? JSONDecoder().decode(SavedConfig.self, from: good))
        store.writeSavedConfig(saved)
        try unlock(local)
        store.writeSavedConfig(saved)
        XCTAssertEqual(copy(local, "unreadable"), garbage)
        XCTAssertNotNil(store.readSavedConfig().value)
    }

    func testAMonitorConfigThatWontOpenIsNotOverwritten() throws {
        try garbage.write(to: monitor)
        try lock(monitor)
        store.writeSavedMonitorConfig(SavedMonitorConfig(maxSplitsPerMonitor: nil, disabledMonitors: nil))
        try unlock(monitor)
        XCTAssertEqual(try Data(contentsOf: monitor), garbage)
    }

    func testEnablingSyncLeavesAnICloudFileThatWontOpen() throws {
        try good.write(to: local)
        try putInICloud(other)
        try lock(iCloudFile)
        store.enableICloudSync { try! JSONDecoder().decode(SavedConfig.self, from: self.good) }
        try unlock(iCloudFile)
        XCTAssertEqual(try Data(contentsOf: iCloudFile), other)
        XCTAssertFalse(isLink(local))
        XCTAssertEqual(try Data(contentsOf: local), good)
    }

    func testRepairLeavesALocalFileThatWontOpen() throws {
        try other.write(to: local)
        try putInICloud(good)
        try lock(local)
        let stale = store.ensureICloudSymlinkIntegrity { try! JSONDecoder().decode(SavedConfig.self, from: self.good) }
        try unlock(local)
        XCTAssertFalse(stale)
        XCTAssertFalse(isLink(local))
        XCTAssertEqual(try Data(contentsOf: local), other)
    }

    func testSavingLeavesOnlyTheConfigFilesBehind() throws {
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        config.gapSize = 31
        config.gapSize = 32
        let names = try fm.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, ["cloud", "config.json", "monitor-config.json"])
    }

    func testSaveReplacesTheFileInOneStep() throws {
        try good.write(to: local)
        let before = try fm.attributesOfItem(atPath: local.path)[.systemFileNumber] as? Int
        store.writeSavedConfig(.empty)
        let after = try fm.attributesOfItem(atPath: local.path)[.systemFileNumber] as? Int
        XCTAssertNotEqual(before, after, "an in-place write can be cut short and truncate the file")
    }

    // MARK: saving through the iCloud link

    func testSaveThroughTheLinkKeepsTheLink() throws {
        try putInICloud(good)
        try linkLocalToICloud()

        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(#"{"keybinds":[],"gapSize":77,"outerPadding":1,"enabled":true}"#.utf8))
        store.writeSavedConfig(saved)

        XCTAssertTrue(isLink(local), "the Mac would lose iCloud without saying so")
        XCTAssertEqual(try savedGap(iCloudFile), 77)
    }

    func testWriteTargetFollowsRelativeAndChainedLinks() throws {
        let real = dir.appendingPathComponent("real.json")
        let middle = dir.appendingPathComponent("middle.json")
        try good.write(to: real)
        try fm.createSymbolicLink(atPath: middle.path, withDestinationPath: "real.json")
        try fm.createSymbolicLink(at: local, withDestinationURL: middle)

        XCTAssertEqual(ConfigStore.writeTarget(of: local).standardizedFileURL.path, real.standardizedFileURL.path)

        store.writeSavedConfig(.empty)
        XCTAssertTrue(isLink(local))
        XCTAssertTrue(isLink(middle))
        XCTAssertEqual(try savedGap(real), SavedConfig.empty.gapSize)
    }

    func testAPlainFileIsItsOwnWriteTarget() throws {
        try good.write(to: local)
        XCTAssertEqual(ConfigStore.writeTarget(of: local), local)
    }

    // MARK: not pushing defaults through the link

    func testDanglingLinkDoesNotPushDefaultsToICloud() throws {
        try linkLocalToICloud()

        let config = UserConfig(store: store, iCloudSyncEnabled: true)
        XCTAssertTrue(store.writesHeld)

        config.gapSize = 31

        XCTAssertFalse(fm.fileExists(atPath: iCloudFile.path), "defaults must not reach other Macs")
        XCTAssertTrue(isLink(local))
    }

    func testChangesStillSaveToTheLocalMonitorFileWhileHeld() throws {
        try linkLocalToICloud()
        let config = UserConfig(store: store, iCloudSyncEnabled: true)
        config.maxSplitsPerMonitor = ["DELL": 2]
        XCTAssertEqual(store.loadSavedMonitorConfig()?.maxSplitsPerMonitor, ["DELL": 2])
    }

    func testWhenTheSyncedFileArrivesItLoadsAndSavingResumes() throws {
        try linkLocalToICloud()
        let config = UserConfig(store: store, iCloudSyncEnabled: true)
        config.gapSize = 31

        try putInICloud(good)
        waitUntil("the arriving file loads") { config.gapSize == 23 }

        XCTAssertFalse(store.writesHeld)
        config.gapSize = 44
        XCTAssertEqual(try savedGap(iCloudFile), 44)
    }

    func testUnreadableLinkedFileAtLaunchIsNotOverwrittenWithDefaults() throws {
        try putInICloud(garbage)
        try linkLocalToICloud()

        let config = UserConfig(store: store, iCloudSyncEnabled: true)
        XCTAssertTrue(store.writesHeld)
        config.gapSize = 31

        XCTAssertEqual(try Data(contentsOf: iCloudFile), garbage)
    }

    func testAGoodSyncAfterAnUnreadableOneEndsTheHold() throws {
        try putInICloud(garbage)
        try linkLocalToICloud()
        let config = UserConfig(store: store, iCloudSyncEnabled: true)
        config.gapSize = 31

        try good.write(to: iCloudFile)
        waitUntil("the good file loads") { config.gapSize == 23 }
        XCTAssertFalse(store.writesHeld)
    }

    func testAGoodLinkIsNotHeld() throws {
        try putInICloud(good)
        try linkLocalToICloud()
        let config = UserConfig(store: store, iCloudSyncEnabled: true)
        XCTAssertFalse(store.writesHeld)
        XCTAssertEqual(config.gapSize, 23)
        config.gapSize = 31
        XCTAssertEqual(try savedGap(iCloudFile), 31)
    }

    // a real config in memory is safe to write if the file goes away later
    func testLosingTheFileWhileRunningStillSaves() throws {
        try putInICloud(good)
        try linkLocalToICloud()
        let config = UserConfig(store: store, iCloudSyncEnabled: true)
        try fm.removeItem(at: iCloudFile)

        config.gapSize = 31

        XCTAssertEqual(try savedGap(iCloudFile), 31)
    }

    func testPlainMissingFileIsNotHeld() {
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        XCTAssertFalse(store.writesHeld)
        config.gapSize = 31
        XCTAssertEqual(try savedGap(local), 31)
    }

    // MARK: repair at launch

    func testRepairLoadsTheICloudValuesAndCannotWriteOldOnesOver() throws {
        try good.write(to: local)
        try putInICloud(other)

        let config = UserConfig(store: store, iCloudSyncEnabled: true)

        XCTAssertTrue(isLink(local))
        XCTAssertEqual(config.gapSize, 41, "the values must be iCloud's, not the replaced file's")
        XCTAssertEqual(copy(local, "replaced"), good, "the replaced file keeps a copy")

        config.outerPadding = 9
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(contentsOf: iCloudFile))
        XCTAssertEqual(saved.gapSize, 41)
        XCTAssertEqual(saved.outerPadding, 9)
    }

    func testRepairOfIdenticalFilesMakesNoCopy() throws {
        try good.write(to: local)
        try putInICloud(good)
        _ = UserConfig(store: store, iCloudSyncEnabled: true)
        XCTAssertTrue(isLink(local))
        XCTAssertNil(copy(local, "replaced"))
    }

    func testRepairWithNoLocalFileLinksAndLoads() throws {
        try putInICloud(other)
        let config = UserConfig(store: store, iCloudSyncEnabled: true)
        XCTAssertTrue(isLink(local))
        XCTAssertEqual(config.gapSize, 41)
    }

    func testRepairWithNoICloudFileMovesTheLocalFileUp() throws {
        try good.write(to: local)
        let config = UserConfig(store: store, iCloudSyncEnabled: true)
        XCTAssertTrue(isLink(local))
        XCTAssertEqual(try Data(contentsOf: iCloudFile), good)
        XCTAssertEqual(config.gapSize, 23)
    }

    func testRepairWithUnreadableICloudFileKeepsTheLocalValuesInMemoryAndHolds() throws {
        try good.write(to: local)
        try putInICloud(garbage)

        let config = UserConfig(store: store, iCloudSyncEnabled: true)

        XCTAssertEqual(config.gapSize, 23)
        XCTAssertEqual(copy(local, "replaced"), good)
        XCTAssertTrue(store.writesHeld)
        config.outerPadding = 9
        XCTAssertEqual(try Data(contentsOf: iCloudFile), garbage)
    }

    // MARK: turning sync on and off

    func testEnablingWithNoLocalFileWritesTheSnapshot() throws {
        store.enableICloudSync(snapshot: { .empty })
        XCTAssertTrue(isLink(local))
        XCTAssertEqual(try savedGap(iCloudFile), SavedConfig.empty.gapSize)
    }

    func testEnablingWhenICloudCantBeWrittenLeavesTheLocalFile() throws {
        try good.write(to: local)
        // a file where the HyprMac folder should be
        try Data().write(to: iCloudRoot.appendingPathComponent("HyprMac"))

        store.enableICloudSync(snapshot: { .empty })

        XCTAssertFalse(isLink(local))
        XCTAssertEqual(try Data(contentsOf: local), good)
    }

    // the local file is the only copy until iCloud holds its data
    func testEnablingWhenTheICloudWriteFailsLeavesTheLocalFile() throws {
        try good.write(to: local)
        let folder = iCloudFile.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        store.enableICloudSync(snapshot: { .empty })

        XCTAssertFalse(isLink(local))
        XCTAssertEqual(try Data(contentsOf: local), good)
    }

    func testEnablingOverADanglingLinkEndsTheHold() throws {
        try linkLocalToICloud()
        store.holdWritesIfLinkUnusable()
        XCTAssertTrue(store.writesHeld)

        store.enableICloudSync(snapshot: { .empty })

        XCTAssertFalse(store.writesHeld)
        XCTAssertTrue(isLink(local))
        XCTAssertEqual(try savedGap(local), SavedConfig.empty.gapSize)
    }

    func testDisablingCopiesICloudBackAndLeavesICloudAlone() throws {
        try putInICloud(good)
        try linkLocalToICloud()

        store.disableICloudSync(snapshot: { .empty })

        XCTAssertFalse(isLink(local))
        XCTAssertEqual(try Data(contentsOf: local), good)
        XCTAssertEqual(try Data(contentsOf: iCloudFile), good)
        let names = try fm.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, ["cloud", "config.json"], "no temp file left")
    }

    func testDisablingADanglingLinkWritesTheSnapshotAndEndsTheHold() throws {
        try linkLocalToICloud()
        store.holdWritesIfLinkUnusable()

        store.disableICloudSync(snapshot: { .empty })

        XCTAssertFalse(store.writesHeld)
        XCTAssertFalse(isLink(local))
        XCTAssertEqual(try savedGap(local), SavedConfig.empty.gapSize)
        XCTAssertFalse(fm.fileExists(atPath: iCloudFile.path))
    }

    // MARK: watcher

    func testOwnSaveStaysWatchedAndReportsOnce() throws {
        try good.write(to: local)
        var reports = 0
        store.onFileChanged = { reports += 1 }
        store.startFileWatcher()

        store.writeSavedConfig(.empty)
        store.writeSavedConfig(.empty)
        XCTAssertTrue(store.isWatchingFile, "no re-arm gap after our own save")

        waitUntil("the saves report") { reports >= 1 }
        // past the 0.5 s re-arm an outside replace would run
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(reports, 1)
    }

    func testOutsideEditAfterOwnSaveIsSeen() throws {
        try good.write(to: local)
        var lastGap: CGFloat?
        store.onFileChanged = { [unowned self] in lastGap = store.loadSavedConfig()?.gapSize }
        store.startFileWatcher()

        store.writeSavedConfig(.empty)
        try other.write(to: local)

        waitUntil("the edit is seen") { lastGap == 41 }
    }

    func testSaveDoesNotStartAWatcherNobodyAskedFor() throws {
        store.writeSavedConfig(.empty)
        XCTAssertFalse(store.isWatchingFile)
    }

    func testWatcherStartedBeforeTheFileExistsPicksItUp() throws {
        var lastGap: CGFloat?
        store.onFileChanged = { [unowned self] in lastGap = store.loadSavedConfig()?.gapSize }
        store.startFileWatcher()
        XCTAssertFalse(store.isWatchingFile)

        try good.write(to: local)
        waitUntil("the new file is read") { lastGap == 23 }
        XCTAssertTrue(store.isWatchingFile)

        try other.write(to: local)
        waitUntil("later edits are seen") { lastGap == 41 }
    }

    func testStoppingEndsTheRetries() throws {
        var reports = 0
        store.onFileChanged = { reports += 1 }
        store.startFileWatcher()
        store.stopFileWatcher()
        try good.write(to: local)

        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(reports, 0)
        XCTAssertFalse(store.isWatchingFile)
    }

    // MARK: reset

    func testResetIsOneUpdateAndKeepsWhatItReplaced() throws {
        try good.write(to: local)
        let monitorText = Data(#"{"maxSplitsPerMonitor":{"DELL":2}}"#.utf8)
        try monitorText.write(to: monitor)
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        var signals = 0
        var gapAtSignal: [CGFloat] = []
        var windowRulesAtSignal: [Int] = []
        let observation = config.didApplyRuntimeChange.sink {
            signals += 1
            gapAtSignal.append(config.gapSize)
            windowRulesAtSignal.append(config.windowRules.count)
        }
        defer { observation.cancel() }

        config.resetToDefaults()

        XCTAssertEqual(signals, 1, "one signal, with the whole reset already applied")
        XCTAssertEqual(gapAtSignal, [UserConfigDefaults.gapSize])
        XCTAssertEqual(try savedGap(local), UserConfigDefaults.gapSize)
        XCTAssertEqual(try JSONDecoder().decode(SavedConfig.self, from: Data(contentsOf: local)).keybinds,
                       Keybind.defaults)
        XCTAssertEqual(store.loadSavedMonitorConfig()?.maxSplitsPerMonitor, [:])
        XCTAssertEqual(copy(local, "replaced"), good)
        XCTAssertEqual(copy(monitor, "replaced"), monitorText)
    }

    func testKeybindResetKeepsTheLaunchersItDrops() throws {
        try good.write(to: local)
        let monitorText = Data(#"{"maxSplitsPerMonitor":{"DELL":2}}"#.utf8)
        try monitorText.write(to: monitor)
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        config.keybinds.append(Keybind(keyCode: 11, modifiers: .hypr,
                                       action: .launchApp(bundleID: "com.apple.Safari")))
        let withLauncher = try Data(contentsOf: local)

        config.resetKeybindsToDefaults()

        XCTAssertEqual(config.keybinds, Keybind.defaults)
        XCTAssertEqual(try JSONDecoder().decode(SavedConfig.self, from: Data(contentsOf: local)).keybinds,
                       Keybind.defaults)
        XCTAssertEqual(copy(local, "replaced"), withLauncher)
        XCTAssertNil(copy(monitor, "replaced"), "the keybind reset leaves the monitor file alone")
        XCTAssertEqual(config.gapSize, 23, "only the keybinds reset")
        XCTAssertTrue(config.doubleTapHyprTogglesCapsLock, "double tap is on, as on a new install")
    }

    // What's New and the notes promise every reset keeps a copy first
    func testAppearanceResetKeepsCopiesFirst() throws {
        try good.write(to: local)
        try Data(#"{"maxSplitsPerMonitor":{"DELL":2}}"#.utf8).write(to: monitor)
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        config.dimIntensity = 0.2
        let before = try Data(contentsOf: local)
        let monitorBefore = try Data(contentsOf: monitor)

        config.resetAppearanceToDefaults()

        XCTAssertEqual(config.dimIntensity, UserConfigDefaults.dimIntensity)
        XCTAssertEqual(copy(local, "replaced"), before)
        XCTAssertEqual(copy(monitor, "replaced"), monitorBefore)
    }

    func testKeybindResetOnDefaultsKeepsNoCopy() throws {
        try good.write(to: local)
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        config.keybinds = Keybind.defaults
        config.doubleTapHyprTogglesCapsLock = UserConfigDefaults.freshInstallDoubleTapHyprTogglesCapsLock
        config.resetKeybindsToDefaults()
        XCTAssertNil(copy(local, "replaced"))
    }

    // config.json links into a writable folder, so the save would land while
    // the copy next to the link can't be written
    private func makeCopyFailButSaveWork() throws {
        let real = dir.appendingPathComponent("real", isDirectory: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let target = real.appendingPathComponent("config.json")
        try fm.moveItem(at: local, to: target)
        try fm.createSymbolicLink(at: local, withDestinationURL: target)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    }

    func testKeybindResetStopsWhenTheCopyFails() throws {
        try good.write(to: local)
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        let launcher = Keybind(keyCode: 11, modifiers: .hypr, action: .launchApp(bundleID: "com.apple.Safari"))
        config.keybinds.append(launcher)
        let withLauncher = try Data(contentsOf: local)
        try makeCopyFailButSaveWork()

        config.resetKeybindsToDefaults()

        XCTAssertTrue(config.keybinds.contains(launcher), "no copy, no reset")
        XCTAssertEqual(try Data(contentsOf: local), withLauncher)
        XCTAssertNil(copy(local, "replaced"))
    }

    func testResetStopsWhenTheCopyFails() throws {
        try good.write(to: local)
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        try makeCopyFailButSaveWork()
        var signals = 0
        let observation = config.didApplyRuntimeChange.sink { signals += 1 }
        defer { observation.cancel() }

        config.resetToDefaults()

        XCTAssertEqual(config.gapSize, 23, "no copy, no reset")
        XCTAssertEqual(try Data(contentsOf: local), good)
        XCTAssertEqual(signals, 0)
    }

    // a file that is there and won't open can't be copied either
    func testResetStopsWhenTheConfigWontOpen() throws {
        try good.write(to: local)
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        let launcher = Keybind(keyCode: 11, modifiers: .hypr, action: .launchApp(bundleID: "com.apple.Safari"))
        config.keybinds.append(launcher)
        try lock(local)
        defer { try? unlock(local) }

        config.resetKeybindsToDefaults()
        config.resetToDefaults()

        XCTAssertTrue(config.keybinds.contains(launcher))
        XCTAssertEqual(config.gapSize, 23)
    }

    func testResetWhileHeldStaysOutOfICloud() throws {
        try linkLocalToICloud()
        let config = UserConfig(store: store, iCloudSyncEnabled: true)
        config.resetToDefaults()
        XCTAssertFalse(fm.fileExists(atPath: iCloudFile.path))
    }

    // MARK: files another tool manages (Nix, dotfiles)

    private func mode(_ url: URL) throws -> Int {
        ((try fm.attributesOfItem(atPath: url.path))[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func inode(_ url: URL) throws -> UInt64 {
        ((try fm.attributesOfItem(atPath: url.path))[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    private func settle(_ seconds: TimeInterval) {
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { settled.fulfill() }
        wait(for: [settled], timeout: seconds + 2)
    }

    private func goodConfig() -> SavedConfig {
        try! JSONDecoder().decode(SavedConfig.self, from: good)
    }

    // config.json -> generation link -> a file in a folder nobody can write,
    // the way Home Manager links into the Nix store
    @discardableResult
    private func linkLocalToReadOnlyFile(_ data: Data, named name: String = "store") throws -> URL {
        let folder = dir.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("hyprmac-config.json")
        try data.write(to: file)
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        addTeardownBlock { [fm] in
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
        let generation = dir.appendingPathComponent("\(name)-generation.json")
        try? fm.removeItem(at: generation)
        try fm.createSymbolicLink(at: generation, withDestinationURL: file)
        let temp = dir.appendingPathComponent("link-\(UUID().uuidString)")
        try fm.createSymbolicLink(at: temp, withDestinationURL: generation)
        XCTAssertEqual(rename(temp.path, local.path), 0)
        return file
    }

    // its folder can be written, the file itself can't. a rename would get
    // around that, so it must not be used
    func testAReadOnlyFileInAWritableFolderIsNotReplaced() throws {
        try good.write(to: local)
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: local.path)
        let before = try inode(local)
        let config = UserConfig(store: store, iCloudSyncEnabled: false)

        config.gapSize = 31

        XCTAssertEqual(try Data(contentsOf: local), good)
        XCTAssertEqual(try inode(local), before, "the read-only file was swapped for a new one")
        XCTAssertEqual(try mode(local), 0o444)
        XCTAssertEqual(config.gapSize, 31, "the change still applies until the next load")
    }

    func testSavingToAReadOnlyLinkLeavesTheLinkAndTheFile() throws {
        let file = try linkLocalToReadOnlyFile(good)
        let config = UserConfig(store: store, iCloudSyncEnabled: false)

        config.gapSize = 31

        XCTAssertTrue(isLink(local))
        XCTAssertEqual(try Data(contentsOf: file), good)
        XCTAssertNil(copy(local, "unreadable"))
    }

    // what a Nix or dotfiles config has to hold at the least. the Nix
    // module fills in exactly these four keys
    func testTheSmallestConfigAnotherToolCanWriteLoads() throws {
        try linkLocalToReadOnlyFile(Data(#"{"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true}"#.utf8))
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        XCTAssertEqual(config.keybinds, Keybind.defaults, "an empty list gets every default")
        XCTAssertEqual(config.gapSize, UserConfigDefaults.gapSize)
        XCTAssertEqual(config.outerPadding, UserConfigDefaults.outerPadding)
        XCTAssertEqual(config.enabled, UserConfigDefaults.enabled)
    }

    // succeeds only while a reader is waiting, and lets it go
    private func unblockReaders(of pipe: URL, after seconds: TimeInterval) {
        let path = pipe.path
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            for _ in 0..<100 {
                let descriptor = open(path, O_WRONLY | O_NONBLOCK)
                if descriptor >= 0 { close(descriptor) }
                usleep(50_000)
            }
        }
    }

    // a named pipe at the path. opening it to read waits for a writer,
    // and launch reads on the main thread
    func testAPipeAtTheConfigPathDoesNotHoldUpALaunch() throws {
        XCTAssertEqual(mkfifo(local.path, 0o600), 0)
        XCTAssertEqual(mkfifo(monitor.path, 0o600), 0)
        unblockReaders(of: local, after: 1.5)
        unblockReaders(of: monitor, after: 1.5)

        let started = Date()
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        config.gapSize = 31
        let took = Date().timeIntervalSince(started)

        XCTAssertLessThan(took, 1, "launch waited on a pipe")
        var info = stat()
        XCTAssertEqual(lstat(local.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFIFO, "the pipe was replaced")
        settle(0.4)
        XCTAssertFalse(store.isWatchingFile, "a pipe is not a file to watch")
    }

    // a private config.json stays private into iCloud and back out
    func testTurningSyncOnAndOffKeepsTheFilePrivate() throws {
        try good.write(to: local)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: local.path)

        store.enableICloudSync { self.goodConfig() }
        XCTAssertTrue(isLink(local))
        XCTAssertEqual(try mode(iCloudFile), 0o600, "the copy in iCloud was opened up to others")

        store.disableICloudSync { self.goodConfig() }
        XCTAssertFalse(isLink(local))
        XCTAssertEqual(try mode(local), 0o600, "the file that came back was opened up to others")
        XCTAssertEqual(try Data(contentsOf: local), good)
    }

    // the iCloud switch must not take a link it didn't make. turning it on
    // and off again replaced a Nix or dotfiles link with a regular file,
    // and the next Home Manager switch then refused to run
    func testTurningSyncOnAndOffLeavesAnotherToolsLinkAlone() throws {
        let file = try linkLocalToReadOnlyFile(good)
        let before = try fm.destinationOfSymbolicLink(atPath: local.path)

        store.enableICloudSync { self.goodConfig() }
        store.disableICloudSync { self.goodConfig() }

        XCTAssertEqual(try? fm.destinationOfSymbolicLink(atPath: local.path), before)
        XCTAssertEqual(try Data(contentsOf: file), good)
        XCTAssertFalse(fm.fileExists(atPath: iCloudFile.path), "nothing of theirs goes to iCloud either")
    }

    func testRepairAtLaunchLeavesAnotherToolsLinkAlone() throws {
        try linkLocalToReadOnlyFile(good)
        try putInICloud(other)
        let before = try fm.destinationOfSymbolicLink(atPath: local.path)

        let config = UserConfig(store: store, iCloudSyncEnabled: true)

        XCTAssertEqual(try? fm.destinationOfSymbolicLink(atPath: local.path), before)
        XCTAssertEqual(config.gapSize, 23)
        XCTAssertFalse(config.iCloudSyncEnabled, "the switch shows a sync that isn't happening")
        XCTAssertEqual(try Data(contentsOf: iCloudFile), other)
    }

    // HyprMac -> dotfiles/hyprmac, with a regular config.json inside
    private func storeInALinkedFolder() throws -> (store: ConfigStore, real: URL) {
        let repo = dir.appendingPathComponent("dotfiles/hyprmac", isDirectory: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try good.write(to: repo.appendingPathComponent("config.json"))
        let folder = dir.appendingPathComponent("HyprMac")
        try fm.createSymbolicLink(at: folder, withDestinationURL: repo)
        let linked = ConfigStore(localConfigURL: folder.appendingPathComponent("config.json"),
                                 monitorConfigURL: folder.appendingPathComponent("monitor-config.json"),
                                 iCloudRootURL: iCloudRoot)
        addTeardownBlock { linked.stopFileWatcher() }
        return (linked, repo.appendingPathComponent("config.json"))
    }

    // turning sync on used to swap the checkout's own config.json for a
    // link into iCloud
    func testSyncDoesNotTakeAFileOutOfALinkedFolder() throws {
        let (linked, real) = try storeInALinkedFolder()

        linked.enableICloudSync { self.goodConfig() }

        XCTAssertFalse(isLink(real), "the checkout's file became a link into iCloud")
        XCTAssertEqual(try Data(contentsOf: real), good)
        XCTAssertFalse(fm.fileExists(atPath: iCloudFile.path))
    }

    func testTheSyncSwitchGoesBackOffInALinkedFolder() throws {
        let (linked, real) = try storeInALinkedFolder()
        let config = UserConfig(store: linked, iCloudSyncEnabled: false)

        config.iCloudSyncEnabled = true

        XCTAssertFalse(config.iCloudSyncEnabled)
        XCTAssertFalse(isLink(real))
        XCTAssertFalse(fm.fileExists(atPath: iCloudFile.path))
    }

    func testRepairAtLaunchLeavesALinkedFolderAlone() throws {
        let (linked, real) = try storeInALinkedFolder()
        try putInICloud(other)

        let config = UserConfig(store: linked, iCloudSyncEnabled: true)

        XCTAssertFalse(config.iCloudSyncEnabled)
        XCTAssertFalse(isLink(real))
        XCTAssertEqual(config.gapSize, 23)
        XCTAssertEqual(try Data(contentsOf: iCloudFile), other)
    }

    // a link into iCloud is ours wherever its folder lives, so off still works
    func testAnICloudLinkInALinkedFolderIsStillOurs() throws {
        let (linked, real) = try storeInALinkedFolder()
        try putInICloud(good)
        try fm.removeItem(at: real)
        try fm.createSymbolicLink(at: real, withDestinationURL: iCloudFile)

        linked.disableICloudSync { self.goodConfig() }

        XCTAssertFalse(isLink(real))
        XCTAssertEqual(try Data(contentsOf: real), good)
    }

    // MARK: joining a copy already in iCloud

    // a second Mac turns sync on. the copy in iCloud is the shared one, so
    // it stays, and this Mac's file is kept beside the link
    func testASecondMacJoiningKeepsTheCopyInICloud() throws {
        try good.write(to: local)
        try putInICloud(other)

        store.enableICloudSync { self.goodConfig() }

        XCTAssertTrue(isLink(local))
        XCTAssertEqual(try Data(contentsOf: iCloudFile), other, "the copy in iCloud was overwritten")
        XCTAssertEqual(copy(local, "replaced"), good)
    }

    // the settings that are live after joining are the shared ones
    func testJoiningLoadsTheSettingsInICloud() throws {
        try good.write(to: local)
        try putInICloud(other)
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        XCTAssertEqual(config.gapSize, 23)
        var signals = 0
        let observation = config.didApplyRuntimeChange.sink { signals += 1 }
        defer { observation.cancel() }

        config.iCloudSyncEnabled = true

        XCTAssertTrue(config.iCloudSyncEnabled)
        XCTAssertEqual(config.gapSize, 41, "the shared settings were linked to and not loaded")
        XCTAssertTrue(config.enabled)
        XCTAssertGreaterThanOrEqual(signals, 1, "the window manager is told")

        // a change made now goes to the shared copy, not over it with old values
        config.outerPadding = 7
        XCTAssertEqual(try savedGap(iCloudFile), 41)
        XCTAssertEqual(copy(local, "replaced"), good)
    }

    // a copy in iCloud that won't decode isn't anyone's settings to join.
    // this Mac's file goes up, and the bad copy is kept
    func testJoiningOverADamagedCopyInICloudUploadsThisMacsFile() throws {
        try good.write(to: local)
        try putInICloud(garbage)

        store.enableICloudSync { self.goodConfig() }

        XCTAssertTrue(isLink(local))
        XCTAssertEqual(try Data(contentsOf: iCloudFile), good)
        XCTAssertEqual(copy(local, "replaced"), garbage)
    }

    // MARK: outside changes reach the running config

    // a Home Manager switch: the link now goes to a new read-only file
    func testANewLinkTargetReachesTheRunningConfig() throws {
        try linkLocalToReadOnlyFile(good)
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        settle(0.5)

        try linkLocalToReadOnlyFile(other, named: "store2")

        waitUntil("new file loaded") { config.gapSize == 41 }
        XCTAssertTrue(config.enabled, "every value comes from the new file")
    }

    // a Home Manager switch that changes only monitorSettings
    func testANewMonitorLinkTargetReachesTheRunningConfig() throws {
        try linkLocalToReadOnlyFile(good)
        let folder = dir.appendingPathComponent("monitor-store", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("one.json")
        let second = folder.appendingPathComponent("two.json")
        try Data(#"{"maxSplitsPerMonitor":{"DELL":2}}"#.utf8).write(to: first)
        try Data(#"{"maxSplitsPerMonitor":{"DELL":3},"externalControlEnabled":true}"#.utf8).write(to: second)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        addTeardownBlock { [fm] in try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        try fm.createSymbolicLink(at: monitor, withDestinationURL: first)

        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        XCTAssertEqual(config.maxSplitsPerMonitor, ["DELL": 2])
        settle(0.5)

        let temp = dir.appendingPathComponent("monitor-link-new")
        try fm.createSymbolicLink(at: temp, withDestinationURL: second)
        XCTAssertEqual(rename(temp.path, monitor.path), 0)

        waitUntil("new monitor file loaded") { config.maxSplitsPerMonitor == ["DELL": 3] }
        XCTAssertTrue(config.externalControlEnabled)
        XCTAssertEqual(config.gapSize, 23)
    }

    // monitorSettings alone, with no config.json at all
    func testAMonitorEditLoadsWithNoMainConfig() throws {
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        settle(0.5)

        try Data(#"{"maxSplitsPerMonitor":{"DELL":2}}"#.utf8).write(to: monitor)

        waitUntil("monitor settings loaded") { config.maxSplitsPerMonitor == ["DELL": 2] }
        XCTAssertFalse(fm.fileExists(atPath: local.path), "loading one file doesn't create the other")
    }

    // MARK: who owns the file

    func testOnlyAFileOrFolderThatCantBeWrittenIsReadOnly() throws {
        XCTAssertFalse(store.isConfigReadOnly, "no file yet")
        try good.write(to: local)
        XCTAssertFalse(store.isConfigReadOnly)
        XCTAssertFalse(store.isLinkedByAnotherTool)
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: local.path)
        XCTAssertTrue(store.isConfigReadOnly, "a locked file in a writable folder")

        try fm.removeItem(at: local)
        try putInICloud(good)
        try linkLocalToICloud()
        XCTAssertFalse(store.isConfigReadOnly)
        XCTAssertFalse(store.isLinkedByAnotherTool, "the iCloud link is ours")

        try linkLocalToReadOnlyFile(good)
        XCTAssertTrue(store.isConfigReadOnly)
        XCTAssertTrue(store.isLinkedByAnotherTool)
        XCTAssertFalse(store.isMonitorConfigReadOnly, "each file is judged on its own")
    }

    // a dotfiles link to a file the user can write is theirs, and saves go through
    func testAWritableLinkFromAnotherToolIsNotReadOnly() throws {
        let real = dir.appendingPathComponent("dotfiles.json")
        try good.write(to: real)
        try fm.createSymbolicLink(at: local, withDestinationURL: real)
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        XCTAssertTrue(store.isLinkedByAnotherTool)
        XCTAssertFalse(config.isConfigReadOnly)
        XCTAssertTrue(config.isICloudSyncLocked)

        config.gapSize = 31

        XCTAssertTrue(isLink(local))
        XCTAssertEqual(try savedGap(real), 31)
    }

    func testAFolderLinkIsAnotherToolsButAnICloudLinkInItIsNot() throws {
        let (linked, real) = try storeInALinkedFolder()
        XCTAssertTrue(linked.isLinkedByAnotherTool)
        try putInICloud(good)
        try fm.removeItem(at: real)
        try fm.createSymbolicLink(at: real, withDestinationURL: iCloudFile)
        XCTAssertFalse(linked.isLinkedByAnotherTool)
    }

    func testTheICloudSwitchIsLockedOnlyForAManagedConfig() throws {
        try good.write(to: local)
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        XCTAssertFalse(config.isICloudSyncLocked)
        XCTAssertFalse(config.isConfigReadOnly)

        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: local.path)
        XCTAssertTrue(config.isICloudSyncLocked)
        XCTAssertTrue(config.isConfigReadOnly)
    }

    // MARK: a file iCloud hasn't downloaded

    // reading a dataless file waits on the network, and launch reads on the
    // main thread. UF_NODUMP stands in for SF_DATALESS, which only the
    // system can set
    func testAFileNotDownloadedIsNotReadAtLaunchAndLoadsWhenItArrives() throws {
        let cloudStore = ConfigStore(localConfigURL: local, monitorConfigURL: monitor, iCloudRootURL: iCloudRoot,
                                     watchInterval: 0.15, datalessFlag: UInt32(UF_NODUMP))
        addTeardownBlock { cloudStore.stopFileWatcher() }
        try putInICloud(other)
        try linkLocalToICloud()
        XCTAssertEqual(chflags(iCloudFile.path, UInt32(UF_NODUMP)), 0)

        let config = UserConfig(store: cloudStore, iCloudSyncEnabled: true)

        XCTAssertEqual(config.gapSize, UserConfigDefaults.gapSize, "launch read a file that isn't there yet")
        XCTAssertTrue(cloudStore.writesHeld, "defaults could reach the other Macs")
        config.gapSize = 5
        XCTAssertEqual(try Data(contentsOf: iCloudFile), other)

        // the download lands
        XCTAssertEqual(chflags(iCloudFile.path, 0), 0)
        waitUntil("the downloaded file loads") { config.gapSize == 41 }
        XCTAssertFalse(cloudStore.writesHeld)
    }

    // the download lands while the watcher sees nothing: the background
    // read itself has the owner reload
    func testADownloadedFileLoadsWithoutTheWatcher() throws {
        let blind = ConfigStore(localConfigURL: local, monitorConfigURL: monitor, iCloudRootURL: iCloudRoot,
                                watchInterval: 0.15, watchOpener: { _, _ in -1 },
                                datalessFlag: UInt32(UF_NODUMP))
        addTeardownBlock { blind.stopFileWatcher() }
        try putInICloud(other)
        try linkLocalToICloud()
        XCTAssertEqual(chflags(iCloudFile.path, UInt32(UF_NODUMP)), 0)
        let config = UserConfig(store: blind, iCloudSyncEnabled: true)
        // stopped, so only the background read can report it
        blind.stopFileWatcher()
        XCTAssertEqual(config.gapSize, UserConfigDefaults.gapSize)

        XCTAssertEqual(chflags(iCloudFile.path, 0), 0)

        waitUntil("the downloaded file loads") { config.gapSize == 41 }
    }

    // MARK: the sync switch shows what is on disk

    func testTheSwitchGoesBackOffWhenNothingWasSetUp() throws {
        let cloudStore = ConfigStore(localConfigURL: local, monitorConfigURL: monitor, iCloudRootURL: iCloudRoot,
                                     datalessFlag: UInt32(UF_NODUMP))
        addTeardownBlock { cloudStore.stopFileWatcher() }
        try good.write(to: local)
        try putInICloud(other)
        XCTAssertEqual(chflags(iCloudFile.path, UInt32(UF_NODUMP)), 0)
        let config = UserConfig(store: cloudStore, iCloudSyncEnabled: false)

        config.iCloudSyncEnabled = true

        XCTAssertFalse(isLink(local))
        XCTAssertFalse(config.iCloudSyncEnabled, "the switch shows a sync that isn't happening")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "iCloudSyncEnabled"))
        XCTAssertEqual(try savedGap(local), 23)
    }

    // MARK: choosing a side when both differ

    func testOnlyDifferentFilesOnBothSidesAskWhichToKeep() throws {
        XCTAssertFalse(store.iCloudCopyDiffersFromLocal, "nothing on either side")
        try good.write(to: local)
        XCTAssertFalse(store.iCloudCopyDiffersFromLocal, "nothing in iCloud")
        try putInICloud(good)
        XCTAssertFalse(store.iCloudCopyDiffersFromLocal, "the same bytes")
        try putInICloud(garbage)
        XCTAssertFalse(store.iCloudCopyDiffersFromLocal, "a damaged copy is not a choice")
        try putInICloud(other)
        XCTAssertTrue(store.iCloudCopyDiffersFromLocal)
    }

    // sync off, an edit here, sync on: the user can keep the edit
    func testChoosingThisMacsSettingsUploadsThemAndKeepsTheICloudCopy() throws {
        try good.write(to: local)
        try putInICloud(other)
        let config = UserConfig(store: store, iCloudSyncEnabled: false)

        config.turnOnICloudSync(usingThisMac: true)

        XCTAssertTrue(config.iCloudSyncEnabled)
        XCTAssertTrue(isLink(local))
        XCTAssertEqual(config.gapSize, 23)
        XCTAssertEqual(try Data(contentsOf: iCloudFile), good)
        XCTAssertEqual(copy(local, "replaced"), other, "the iCloud side is kept")
    }

    func testChoosingTheICloudSettingsJoinsAndKeepsThisMacsFile() throws {
        try good.write(to: local)
        try putInICloud(other)
        let config = UserConfig(store: store, iCloudSyncEnabled: false)

        config.turnOnICloudSync(usingThisMac: false)

        XCTAssertTrue(config.iCloudSyncEnabled)
        XCTAssertEqual(config.gapSize, 41)
        XCTAssertEqual(try Data(contentsOf: iCloudFile), other)
        XCTAssertEqual(copy(local, "replaced"), good, "this Mac's side is kept")
    }

    // MARK: the switch follows the link at runtime

    // sync on, then a dotfiles tool or Home Manager takes the path while
    // the app runs. the locked switch must not still read on
    func testTheSwitchTurnsOffWhenAnotherToolTakesThePathWhileRunning() throws {
        let watched = ConfigStore(localConfigURL: local, monitorConfigURL: monitor, iCloudRootURL: iCloudRoot,
                                  watchInterval: 0.15)
        addTeardownBlock { watched.stopFileWatcher() }
        try putInICloud(good)
        try linkLocalToICloud()
        let config = UserConfig(store: watched, iCloudSyncEnabled: true)
        XCTAssertTrue(config.iCloudSyncEnabled)

        let file = try linkLocalToReadOnlyFile(other)

        waitUntil("the switch follows the link") { !config.iCloudSyncEnabled }
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "iCloudSyncEnabled"))
        XCTAssertTrue(watched.isLinkedByAnotherTool, "the tool's link was replaced")
        XCTAssertEqual(try Data(contentsOf: file), other)
        XCTAssertEqual(try Data(contentsOf: iCloudFile), good)
    }

    // MARK: copies stay as private as what they copy

    func testAResetCopyKeepsTheFilesMode() throws {
        try good.write(to: local)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: local.path)
        let config = UserConfig(store: store, iCloudSyncEnabled: false)

        config.resetToDefaults()

        XCTAssertEqual(copy(local, "replaced"), good)
        XCTAssertEqual(try mode(URL(fileURLWithPath: "\(local.path).replaced")), 0o600)
    }

    // both sides of a join are kept, each as private as it was
    func testJoinCopiesKeepTheModeOfTheSideTheyCameFrom() throws {
        try good.write(to: local)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: local.path)
        try putInICloud(other)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: iCloudFile.path)
        store.enableICloudSync(snapshot: { self.goodConfig() })
        XCTAssertEqual(try mode(URL(fileURLWithPath: "\(local.path).replaced")), 0o600, "this Mac's file")

        store.disableICloudSync(snapshot: { self.goodConfig() })
        try good.write(to: local)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: local.path)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: iCloudFile.path)
        store.enableICloudSync(snapshot: { self.goodConfig() }, cloudWins: false)
        XCTAssertEqual(copy(local, "replaced.2"), other)
        XCTAssertEqual(try mode(URL(fileURLWithPath: "\(local.path).replaced.2")), 0o640, "the iCloud copy")
    }
}
