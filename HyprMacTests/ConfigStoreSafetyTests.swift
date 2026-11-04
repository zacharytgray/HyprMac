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

    func testEnablingKeepsWhatWasInICloud() throws {
        try good.write(to: local)
        try putInICloud(other)

        store.enableICloudSync(snapshot: { .empty })

        XCTAssertTrue(isLink(local))
        XCTAssertEqual(try Data(contentsOf: iCloudFile), good)
        XCTAssertEqual(copy(local, "replaced"), other)
    }

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

    func testResetWhileHeldStaysOutOfICloud() throws {
        try linkLocalToICloud()
        let config = UserConfig(store: store, iCloudSyncEnabled: true)
        config.resetToDefaults()
        XCTAssertFalse(fm.fileExists(atPath: iCloudFile.path))
    }
}
