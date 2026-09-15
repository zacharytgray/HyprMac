import XCTest
@testable import HyprMac

// LayoutSnapshotStoreTests run the store against a temp file so the real
// persist()/load() pair is exercised — a fresh instance on the same URL
// must see what the previous one saved. Nothing here touches the shared
// store or ~/Library.

final class LayoutSnapshotStoreTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyprmac-layout-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func ref(_ bundleID: String, _ title: String = "") -> SavedWindowRef {
        SavedWindowRef(bundleID: bundleID, title: title)
    }

    private func single(_ bundleID: String, workspace: Int = 1) -> [WorkspaceLayout] {
        [WorkspaceLayout(workspace: workspace, root: .leaf(ref(bundleID)))]
    }

    // 2×2-ish: horizontal root, right child forced vertical, two same-ref leaves
    private func sampleTree() -> LayoutNode {
        .split(override: nil, ratio: 0.7, userSet: true,
               left: .leaf(ref("com.a", "A")),
               right: .split(override: .vertical, ratio: 0.5, userSet: false,
                             left: .leaf(ref("com.b", "zsh")),
                             right: .leaf(ref("com.b", "zsh"))))
    }

    // MARK: - display key

    func testDisplayKeySortsByName() {
        guard NSScreen.screens.count >= 1 else { return }
        let key = LayoutSnapshotStore.displayKey(screens: NSScreen.screens)
        let parts = key.split(separator: "|").map(String.init)
        XCTAssertEqual(parts, parts.sorted())
    }

    func testDisplayKeyDeterministic() {
        let screens = NSScreen.screens
        XCTAssertEqual(LayoutSnapshotStore.displayKey(screens: screens),
                       LayoutSnapshotStore.displayKey(screens: screens))
    }

    func testDisplayKeyEmptyScreens() {
        XCTAssertEqual(LayoutSnapshotStore.displayKey(screens: []), "")
    }

    // MARK: - disk round-trip through the real store

    func testSaveThenLoadFromDiskRoundTrips() throws {
        let tree = sampleTree()
        let writer = LayoutSnapshotStore(fileURL: fileURL)
        XCTAssertTrue(writer.save(displayKey: "Test:1920x1080",
                                  workspaces: [WorkspaceLayout(workspace: 2, root: tree)],
                                  manual: true))

        let reader = LayoutSnapshotStore(fileURL: fileURL)
        let snap = try XCTUnwrap(reader.snapshot(for: "Test:1920x1080"))
        XCTAssertEqual(snap.schemaVersion, LayoutSnapshot.currentSchemaVersion)
        XCTAssertEqual(snap.displayKey, "Test:1920x1080")
        XCTAssertTrue(snap.isManual)
        XCTAssertEqual(snap.workspaces, [WorkspaceLayout(workspace: 2, root: tree)])
        let written = try XCTUnwrap(writer.snapshot(for: "Test:1920x1080"))
        // iso8601 keeps whole seconds
        XCTAssertEqual(snap.timestamp.timeIntervalSince1970,
                       written.timestamp.timeIntervalSince1970, accuracy: 1)
    }

    func testMissingFileLoadsEmpty() {
        let store = LayoutSnapshotStore(fileURL: fileURL)
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertNil(store.snapshot(for: "Unknown:800x600"))
    }

    func testCorruptFileLoadsEmptyWithoutCrashing() throws {
        try Data("not json".utf8).write(to: fileURL)
        let store = LayoutSnapshotStore(fileURL: fileURL)
        XCTAssertTrue(store.snapshots.isEmpty)
    }

    func testSnapshotFromNewerSchemaIsDropped() throws {
        let future = LayoutSnapshot(schemaVersion: LayoutSnapshot.currentSchemaVersion + 1,
                                    displayKey: "Future:1x1", timestamp: Date(),
                                    isManual: true, workspaces: single("com.a"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(["Future:1x1": future]).write(to: fileURL)

        let store = LayoutSnapshotStore(fileURL: fileURL)
        XCTAssertNil(store.snapshot(for: "Future:1x1"))
    }

    // MARK: - manual vs automatic

    func testAutoSaveSkipsWhenManualExists() {
        let store = LayoutSnapshotStore(fileURL: fileURL)
        let key = "Test:1920x1080"
        XCTAssertTrue(store.save(displayKey: key, workspaces: single("com.a"), manual: true))
        XCTAssertFalse(store.save(displayKey: key, workspaces: single("com.b"), manual: false))

        let snap = store.snapshot(for: key)!
        XCTAssertTrue(snap.isManual)
        XCTAssertEqual(snap.workspaces.first?.root.leaves.first?.bundleID, "com.a")
    }

    func testManualSaveOverwritesManual() {
        let store = LayoutSnapshotStore(fileURL: fileURL)
        let key = "Test:1920x1080"
        store.save(displayKey: key, workspaces: single("com.a"), manual: true)
        store.save(displayKey: key, workspaces: single("com.b"), manual: true)
        XCTAssertEqual(store.snapshot(for: key)?.workspaces.first?.root.leaves.first?.bundleID, "com.b")
    }

    func testAutoSaveOverwritesAuto() {
        let store = LayoutSnapshotStore(fileURL: fileURL)
        let key = "Test:1920x1080"
        store.save(displayKey: key, workspaces: single("com.a"), manual: false)
        store.save(displayKey: key, workspaces: single("com.b"), manual: false)
        XCTAssertEqual(store.snapshot(for: key)?.workspaces.first?.root.leaves.first?.bundleID, "com.b")
    }

    // MARK: - pruning

    func testPruningEvictsOldestAutomatic() {
        let store = LayoutSnapshotStore(fileURL: fileURL)
        for i in 0..<LayoutSnapshotStore.maxSnapshots {
            store.save(displayKey: "Config\(i):100x100", workspaces: single("com.x"), manual: false)
        }
        XCTAssertEqual(store.snapshots.count, LayoutSnapshotStore.maxSnapshots)

        store.save(displayKey: "Overflow:100x100", workspaces: single("com.x"), manual: false)
        XCTAssertEqual(store.snapshots.count, LayoutSnapshotStore.maxSnapshots)
        XCTAssertNotNil(store.snapshot(for: "Overflow:100x100"))
        XCTAssertNil(store.snapshot(for: "Config0:100x100"), "oldest automatic snapshot is evicted")
    }

    func testPruningEvictsAutomaticBeforeManual() {
        let store = LayoutSnapshotStore(fileURL: fileURL)
        store.save(displayKey: "Manual:100x100", workspaces: single("com.x"), manual: true)
        for i in 0..<LayoutSnapshotStore.maxSnapshots {
            store.save(displayKey: "Auto\(i):100x100", workspaces: single("com.x"), manual: false)
        }
        XCTAssertEqual(store.snapshots.count, LayoutSnapshotStore.maxSnapshots)
        XCTAssertNotNil(store.snapshot(for: "Manual:100x100"),
                        "the oldest snapshot is manual and must outlive newer automatic ones")
        XCTAssertNil(store.snapshot(for: "Auto0:100x100"))
    }

    // MARK: - LayoutNode wire format

    func testLayoutNodeRoundTripsNestedSplit() throws {
        let tree = sampleTree()
        let data = try JSONEncoder().encode(tree)
        XCTAssertEqual(try JSONDecoder().decode(LayoutNode.self, from: data), tree)
    }

    func testLayoutNodeWireKeysAreFrozen() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let leaf = String(data: try encoder.encode(LayoutNode.leaf(ref("com.a", "A"))), encoding: .utf8)!
        XCTAssertEqual(leaf, #"{"leaf":{"bundleID":"com.a","title":"A"}}"#)

        let split = String(data: try encoder.encode(LayoutNode.split(
            override: .horizontal, ratio: 0.5, userSet: false,
            left: .leaf(ref("com.a")), right: .leaf(ref("com.b")))), encoding: .utf8)!
        XCTAssertEqual(split,
            #"{"split":{"left":{"leaf":{"bundleID":"com.a","title":""}},"override":"horizontal","ratio":0.5,"right":{"leaf":{"bundleID":"com.b","title":""}},"userSet":false}}"#)
    }

    func testLayoutNodeOmitsNilOverride() throws {
        let node = LayoutNode.split(override: nil, ratio: 0.5, userSet: true,
                                    left: .leaf(ref("com.a")), right: .leaf(ref("com.b")))
        let json = String(data: try JSONEncoder().encode(node), encoding: .utf8)!
        XCTAssertFalse(json.contains("override"))
        XCTAssertEqual(try JSONDecoder().decode(LayoutNode.self, from: Data(json.utf8)), node)
    }

    func testLayoutNodeRejectsUnknownCase() {
        XCTAssertThrowsError(try JSONDecoder().decode(LayoutNode.self, from: Data(#"{"bogus":{}}"#.utf8)))
    }

    func testLeavesAreLeftToRight() {
        XCTAssertEqual(sampleTree().leaves,
                       [ref("com.a", "A"), ref("com.b", "zsh"), ref("com.b", "zsh")])
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
        XCTAssertTrue(hasSave)
        XCTAssertTrue(hasRestore)
    }

    func testSaveRestoreActionsRoundTrip() throws {
        for action in [Action.saveLayout, Action.restoreLayout] {
            let kb = Keybind(keyCode: 1, modifiers: .hypr, action: action)
            let decoded = try JSONDecoder().decode(Keybind.self, from: try JSONEncoder().encode(kb))
            XCTAssertEqual(decoded.action, action)
        }
    }
}
