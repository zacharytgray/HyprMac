import XCTest
@testable import HyprMac

// the desk an update relaunch puts back: written once, read once, and only
// while it can still be trusted
final class RelaunchHandoffTests: XCTestCase {

    private var fileURL: URL!
    private var store: RelaunchHandoffStore!
    private let saved = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyprmac-handoff-\(UUID().uuidString).json")
        store = RelaunchHandoffStore(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func handoff(displayKey: String = "Built-in:1512x982") -> RelaunchHandoff {
        let a = RelaunchHandoff.ref(id: 101, pid: 500), b = RelaunchHandoff.ref(id: 102, pid: 501)
        return RelaunchHandoff(
            savedAt: saved, displayKey: displayKey, visibleWorkspaces: [3, 2],
            focused: .init(id: 101, pid: 500),
            workspaces: [
                WorkspaceLayout(workspace: 3, root: .split(override: .vertical, ratio: 0.6, userSet: true,
                                                           left: .leaf(a), right: .leaf(b))),
                WorkspaceLayout(workspace: 5, root: nil, unplaced: [RelaunchHandoff.ref(id: 103, pid: 502)]),
            ],
            floaters: [
                .init(window: .init(id: 201, pid: 600), workspace: 4,
                      frame: CGRect(x: 40, y: 60, width: 800, height: 500)),
                .init(window: .init(id: 202, pid: 601), workspace: 3, frame: nil),
            ],
            scratchpad: [.init(id: 301, pid: 700)])
    }

    func testTheHandoffSurvivesTheFile() throws {
        try store.write(handoff())
        let back = store.take(now: saved.addingTimeInterval(8), displayKey: "Built-in:1512x982")
        XCTAssertEqual(back, handoff())
    }

    func testItAppliesToOneLaunchOnly() throws {
        try store.write(handoff())
        XCTAssertNotNil(store.take(now: saved.addingTimeInterval(8), displayKey: "Built-in:1512x982"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNil(store.take(now: saved.addingTimeInterval(9), displayKey: "Built-in:1512x982"))
    }

    // window ids are reused. an old file may name someone else's windows
    func testAStaleHandoffIsDroppedAndDeleted() throws {
        try store.write(handoff())
        let late = saved.addingTimeInterval(RelaunchHandoff.maxAge + 1)
        XCTAssertNil(store.take(now: late, displayKey: "Built-in:1512x982"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testAHandoffFromTheFutureIsDropped() throws {
        try store.write(handoff())
        XCTAssertNil(store.take(now: saved.addingTimeInterval(-30), displayKey: "Built-in:1512x982"))
    }

    func testAHandoffForOtherDisplaysIsDropped() throws {
        try store.write(handoff())
        XCTAssertNil(store.take(now: saved.addingTimeInterval(8),
                                displayKey: "Built-in:1512x982|DELL U2720Q:2560x1440"))
    }

    func testAnUnreadableFileIsDroppedAndDeleted() throws {
        try Data("not json".utf8).write(to: fileURL)
        XCTAssertNil(store.take(now: saved, displayKey: "Built-in:1512x982"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // the install failed after the desk was written down
    func testADiscardedHandoffIsGone() throws {
        try store.write(handoff())
        store.discard()
        XCTAssertNil(store.take(now: saved.addingTimeInterval(8), displayKey: "Built-in:1512x982"))
        store.discard()
    }

    // the tutorial's desk has no age limit: a tutorial takes minutes
    func testTheTutorialDeskIsKeptAtAnyAge() throws {
        let old = RelaunchHandoff(savedAt: Date(timeIntervalSince1970: 1000), displayKey: "k", visibleWorkspaces: [1],
                                  focused: nil, workspaces: [], floaters: [], scratchpad: [])
        XCTAssertFalse(old.isUsable(now: Date(timeIntervalSince1970: 1000 + 3600), displayKey: "k"))
        XCTAssertTrue(old.isUsable(now: Date(timeIntervalSince1970: 1000 + 3600), displayKey: "k", maxAge: nil))
        XCTAssertFalse(old.isUsable(now: Date(timeIntervalSince1970: 1000 + 3600), displayKey: "other", maxAge: nil))
        // only when it was written differs: the same desk, nothing to put back
        let later = RelaunchHandoff(savedAt: Date(timeIntervalSince1970: 5000), displayKey: "k", visibleWorkspaces: [1],
                                    focused: nil, workspaces: [], floaters: [], scratchpad: [])
        XCTAssertTrue(WindowManager.sameDesk(old, later))
        let moved = RelaunchHandoff(savedAt: Date(timeIntervalSince1970: 5000), displayKey: "k", visibleWorkspaces: [2],
                                    focused: nil, workspaces: [], floaters: [], scratchpad: [])
        XCTAssertFalse(WindowManager.sameDesk(old, moved))
    }

    // the restore reads back the window id each tiled leaf names
    func testALeafGivesBackItsWindowID() {
        XCTAssertEqual(RelaunchHandoff.windowID(RelaunchHandoff.ref(id: 8670, pid: 77)), 8670)
        XCTAssertNil(RelaunchHandoff.windowID(SavedWindowRef(bundleID: "com.apple.Safari", title: "Start Page")))
    }

    // the desk restore never undoes the user: a key that acts on the
    // focused window marks it; HyprMac's bulk moves and views don't
    func testOnlyActionsOnTheWindowMarkItAsTheUsers() {
        for action in [Action.moveToWorkspace(3), .toggleFloating, .swapDirection(.left), .resizeDirection(.right),
                       .moveWindowToMonitor(.right), .toggleMaximize, .moveToScratchpad] {
            XCTAssertTrue(WindowManager.actionTouchesWindow(action), "\(action)")
        }
        for action in [Action.retileAll, .switchWorkspace(2), .focusDirection(.left), .toggleTiling, .showKeybinds,
                       .showWindowRules, .focusFloating] {
            XCTAssertFalse(WindowManager.actionTouchesWindow(action), "\(action)")
        }
    }

    // full-screen windows and the user's own get no restore write
    func testTheRestoreSkipsFullScreenAndTheUsersWindows() {
        XCTAssertEqual(WindowManager.restorableIDs([1, 2, 3, 4], touched: [2], fullScreen: [3]), [1, 4])
    }

    func testNoFileMeansNoHandoff() {
        XCTAssertNil(store.take(now: saved, displayKey: "Built-in:1512x982"))
    }

    func testANewerSchemaIsDropped() throws {
        var newer = handoff()
        newer.schemaVersion = RelaunchHandoff.currentSchemaVersion + 1
        try store.write(newer)
        XCTAssertNil(store.take(now: saved.addingTimeInterval(8), displayKey: "Built-in:1512x982"))
    }

    // exact: the same id under another process is another window
    func testALeafNamesOneWindowOfOneProcess() {
        XCTAssertEqual(RelaunchHandoff.ref(id: 101, pid: 500), SavedWindowRef(bundleID: "pid:500", title: "wid:101"))
        XCTAssertNotEqual(RelaunchHandoff.ref(id: 101, pid: 500), RelaunchHandoff.ref(id: 101, pid: 501))
        XCTAssertNotEqual(RelaunchHandoff.ref(id: 101, pid: 500), RelaunchHandoff.ref(id: 102, pid: 500))
    }

    func testTheTiledPartIsALayoutSnapshotTheRestorerTakes() {
        let snapshot = handoff().layoutSnapshot
        XCTAssertEqual(snapshot.schemaVersion, LayoutSnapshot.currentSchemaVersion)
        XCTAssertEqual(snapshot.workspaces, handoff().workspaces)
        XCTAssertEqual(snapshot.workspaces.flatMap(\.refs).count, 3)
        XCTAssertFalse(snapshot.isManual)
    }

    // the matcher pairs each saved leaf with the one window that has its id
    func testTheMatcherSendsEachWindowBackToItsWorkspace() {
        let candidates = [
            LayoutMatcher.Candidate(windowID: 102, bundleID: "pid:501", title: "wid:102", workspace: 1),
            LayoutMatcher.Candidate(windowID: 101, bundleID: "pid:500", title: "wid:101", workspace: 1),
            LayoutMatcher.Candidate(windowID: 103, bundleID: "pid:502", title: "wid:103", workspace: 2),
            // opened while HyprMac was away: no saved leaf, stays where the launch put it
            LayoutMatcher.Candidate(windowID: 999, bundleID: "pid:900", title: "wid:999", workspace: 1),
        ]
        let plan = LayoutMatcher.plan(handoff().layoutSnapshot, candidates: candidates)
        XCTAssertEqual(plan.workspaceByWindow[101], 3)
        XCTAssertEqual(plan.workspaceByWindow[102], 3)
        XCTAssertEqual(plan.workspaceByWindow[103], 5)
        XCTAssertNil(plan.workspaceByWindow[999])
        XCTAssertTrue(plan.unmatchedRefs.isEmpty)
    }
}
