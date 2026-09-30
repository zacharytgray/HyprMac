import XCTest
@testable import HyprMac

// the config file watcher must survive an atomic save. editors and
// `mv tmp config.json` replace the file's inode, and a watcher left on the
// old inode goes deaf, so hand-edited window rules stop being picked up.

final class ConfigStoreWatcherTests: XCTestCase {

    private var dir: URL!
    private var store: ConfigStore!
    private var changes = 0

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigStoreWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: url)
        store = ConfigStore(localConfigURL: url)
        store.onFileChanged = { [unowned self] in changes += 1 }
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
        waitUntil("in-place write reported") { self.changes == 1 }
    }

    func testEveryAtomicSaveIsSeenNotJustTheFirst() throws {
        try atomicSave(#"{"a":1}"#)
        waitUntil("first atomic save reported") { self.changes == 1 }
        waitUntil("watcher re-armed on the new file") { self.store.isWatchingFile }

        try atomicSave(#"{"a":2}"#)
        waitUntil("second atomic save reported") { self.changes == 2 }
        waitUntil("watcher re-armed again") { self.store.isWatchingFile }

        try Data(#"{"a":3}"#.utf8).write(to: store.localConfigURL)
        waitUntil("later in-place write reported") { self.changes == 3 }
    }
}
