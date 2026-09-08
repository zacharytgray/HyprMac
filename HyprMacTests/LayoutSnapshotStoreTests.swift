import XCTest
@testable import HyprMac

final class LayoutSnapshotStoreTests: XCTestCase {

    // MARK: - display key

    func testDisplayKeySortsByName() {
        guard NSScreen.screens.count >= 1 else { return }
        let key = LayoutSnapshotStore.displayKey(screens: NSScreen.screens)
        let parts = key.split(separator: "|").map(String.init)
        XCTAssertEqual(parts, parts.sorted(),
                       "display key segments should be sorted")
    }

    func testDisplayKeyDeterministic() {
        let screens = NSScreen.screens
        let a = LayoutSnapshotStore.displayKey(screens: screens)
        let b = LayoutSnapshotStore.displayKey(screens: screens)
        XCTAssertEqual(a, b)
    }

    func testDisplayKeyEmptyScreens() {
        let key = LayoutSnapshotStore.displayKey(screens: [])
        XCTAssertEqual(key, "")
    }

    // MARK: - save and retrieve

    func testSaveAndRetrieve() {
        let store = LayoutSnapshotStore(testSnapshots: [:])
        let assignments = [
            WindowAssignment(bundleID: "com.test.a", windowTitle: "A",
                             workspace: 1, x: 0, y: 0, w: 960, h: 1080),
            WindowAssignment(bundleID: "com.test.b", windowTitle: "B",
                             workspace: 2, x: 960, y: 0, w: 960, h: 1080)
        ]
        store.save(displayKey: "Test:1920x1080", assignments: assignments, manual: true)

        let snap = store.snapshot(for: "Test:1920x1080")
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.assignments.count, 2)
        XCTAssertTrue(snap!.isManual)
    }

    func testRetrieveUnknownKeyReturnsNil() {
        let store = LayoutSnapshotStore(testSnapshots: [:])
        XCTAssertNil(store.snapshot(for: "Unknown:800x600"))
    }

    // MARK: - manual vs auto-save protection

    func testAutoSaveSkipsWhenManualExists() {
        let store = LayoutSnapshotStore(testSnapshots: [:])
        let key = "Test:1920x1080"
        let manual = [WindowAssignment(bundleID: "com.a", windowTitle: "A",
                                       workspace: 1, x: 0, y: 0, w: 960, h: 1080)]
        let auto = [WindowAssignment(bundleID: "com.b", windowTitle: "B",
                                     workspace: 2, x: 0, y: 0, w: 960, h: 1080)]

        store.save(displayKey: key, assignments: manual, manual: true)
        store.save(displayKey: key, assignments: auto, manual: false)

        let snap = store.snapshot(for: key)!
        XCTAssertEqual(snap.assignments.first?.bundleID, "com.a",
                       "auto-save should not overwrite manual save")
        XCTAssertTrue(snap.isManual)
    }

    func testManualSaveOverwritesManual() {
        let store = LayoutSnapshotStore(testSnapshots: [:])
        let key = "Test:1920x1080"
        let first = [WindowAssignment(bundleID: "com.a", windowTitle: "A",
                                      workspace: 1, x: 0, y: 0, w: 960, h: 1080)]
        let second = [WindowAssignment(bundleID: "com.b", windowTitle: "B",
                                       workspace: 2, x: 0, y: 0, w: 960, h: 1080)]

        store.save(displayKey: key, assignments: first, manual: true)
        store.save(displayKey: key, assignments: second, manual: true)

        let snap = store.snapshot(for: key)!
        XCTAssertEqual(snap.assignments.first?.bundleID, "com.b",
                       "manual save should overwrite previous manual save")
    }

    func testAutoSaveOverwritesAuto() {
        let store = LayoutSnapshotStore(testSnapshots: [:])
        let key = "Test:1920x1080"
        let first = [WindowAssignment(bundleID: "com.a", windowTitle: "A",
                                      workspace: 1, x: 0, y: 0, w: 960, h: 1080)]
        let second = [WindowAssignment(bundleID: "com.b", windowTitle: "B",
                                       workspace: 2, x: 0, y: 0, w: 960, h: 1080)]

        store.save(displayKey: key, assignments: first, manual: false)
        store.save(displayKey: key, assignments: second, manual: false)

        let snap = store.snapshot(for: key)!
        XCTAssertEqual(snap.assignments.first?.bundleID, "com.b",
                       "auto-save should overwrite previous auto-save")
    }

    // MARK: - pruning

    func testPruningEvictsOldest() {
        let store = LayoutSnapshotStore(testSnapshots: [:])
        let a = [WindowAssignment(bundleID: "com.x", windowTitle: "X",
                                  workspace: 1, x: 0, y: 0, w: 100, h: 100)]

        for i in 0..<LayoutSnapshotStore.maxSnapshots {
            store.save(displayKey: "Config\(i):100x100", assignments: a, manual: true)
        }
        XCTAssertEqual(store.snapshots.count, LayoutSnapshotStore.maxSnapshots)

        store.save(displayKey: "Overflow:100x100", assignments: a, manual: true)
        XCTAssertEqual(store.snapshots.count, LayoutSnapshotStore.maxSnapshots,
                       "snapshot count should not exceed maxSnapshots")
        XCTAssertNotNil(store.snapshot(for: "Overflow:100x100"))
        // Config0 was saved first → oldest → evicted
        XCTAssertNil(store.snapshot(for: "Config0:100x100"),
                     "oldest snapshot should be evicted")
    }

    // MARK: - Codable round-trip

    func testWindowAssignmentCodable() throws {
        let a = WindowAssignment(bundleID: "com.test", windowTitle: "Win",
                                 workspace: 3, x: 10, y: 20, w: 800, h: 600)
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(WindowAssignment.self, from: data)
        XCTAssertEqual(a, decoded)
    }

    func testLayoutSnapshotCodable() throws {
        let snap = LayoutSnapshot(
            displayKey: "Test:1920x1080",
            timestamp: Date(),
            assignments: [
                WindowAssignment(bundleID: "com.a", windowTitle: "A",
                                 workspace: 1, x: 0, y: 0, w: 960, h: 1080)
            ],
            isManual: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(snap)
        let decoded = try decoder.decode(LayoutSnapshot.self, from: data)
        XCTAssertEqual(decoded.displayKey, snap.displayKey)
        XCTAssertEqual(decoded.isManual, snap.isManual)
        XCTAssertEqual(decoded.assignments, snap.assignments)
    }

    // MARK: - disk round-trip (persist/load pairing)

    func testPersistLoadRoundTripViaRealEncoderDecoder() throws {
        let snap = LayoutSnapshot(
            displayKey: "Test:1920x1080",
            timestamp: Date(),
            assignments: [
                WindowAssignment(bundleID: "com.a", windowTitle: "A",
                                 workspace: 1, x: 0, y: 0, w: 960, h: 1080)
            ],
            isManual: true
        )
        let dict: [String: LayoutSnapshot] = ["Test:1920x1080": snap]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(dict)

        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-test-\(UUID().uuidString).json")
        try data.write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let loaded = try Data(contentsOf: tmpFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([String: LayoutSnapshot].self, from: loaded)

        XCTAssertEqual(decoded.count, 1)
        let restored = try XCTUnwrap(decoded["Test:1920x1080"])
        XCTAssertEqual(restored.displayKey, snap.displayKey)
        XCTAssertEqual(restored.isManual, snap.isManual)
        XCTAssertEqual(restored.assignments, snap.assignments)
    }

    // MARK: - pruning protects manual snapshots

    func testPruningEvictsAutoBeforeManual() {
        let store = LayoutSnapshotStore(testSnapshots: [:])
        let a = [WindowAssignment(bundleID: "com.x", windowTitle: "X",
                                  workspace: 1, x: 0, y: 0, w: 100, h: 100)]

        store.save(displayKey: "Manual:100x100", assignments: a, manual: true)
        for i in 0..<LayoutSnapshotStore.maxSnapshots {
            store.save(displayKey: "Auto\(i):100x100", assignments: a, manual: false)
        }

        XCTAssertEqual(store.snapshots.count, LayoutSnapshotStore.maxSnapshots)
        XCTAssertNotNil(store.snapshot(for: "Manual:100x100"),
                        "manual snapshot should survive pruning when auto snapshots exist")
    }

    // MARK: - keybind defaults

    func testDefaultsContainSaveAndRestore() {
        var hasSave = false
        var hasRestore = false
        for kb in Keybind.defaults {
            switch kb.action {
            case .saveLayout: hasSave = true
            case .restoreLayout: hasRestore = true
            default: break
            }
        }
        XCTAssertTrue(hasSave, "defaults should include saveLayout")
        XCTAssertTrue(hasRestore, "defaults should include restoreLayout")
    }

    func testSaveRestoreActionsRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for action in [Action.saveLayout, Action.restoreLayout] {
            let kb = Keybind(keyCode: 1, modifiers: .hypr, action: action)
            let data = try encoder.encode(kb)
            let decoded = try decoder.decode(Keybind.self, from: data)
            XCTAssertEqual(decoded.action, kb.action)
        }
    }
}
