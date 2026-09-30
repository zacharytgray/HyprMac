import Cocoa
import XCTest
@testable import HyprMac

// LayoutRestorerTests pin what a layout restore reports. A restore that
// moved nothing and rebuilt nothing must not say it restored, and one that
// applied half of the snapshot must say so. Saved windows that simply are
// not open do not make a restore partial.
//
// runs on synthetic screens with frame i/o that accepts every write unless
// a window is told to ignore it, so it executes headless.

private final class RestorerScreen: SyntheticScreen {
    let bounds: NSRect
    let name: String

    init(x: CGFloat, name: String) {
        bounds = NSRect(x: x, y: 0, width: 2400, height: 1600)
        self.name = name
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var frame: NSRect { bounds }
    override var visibleFrame: NSRect { bounds }
    override var localizedName: String { name }
}

private final class RestorerRig {
    let screens: [RestorerScreen]
    let displayManager: DisplayManager
    let workspaceManager: WorkspaceManager
    let engine: TilingEngine
    let cache = WindowStateCache()
    let orchestrator: WorkspaceOrchestrator
    let recovery = AdmissionRecovery()
    var frames: [CGWindowID: CGRect] = [:]
    var ignoresWrites: Set<CGWindowID> = []
    var windows: [CGWindowID: HyprWindow] = [:]
    private var clock: TimeInterval = 0

    init(screenCount: Int = 1, maxDepth: Int = 2, disabled: Set<String> = []) {
        let screens = (0..<screenCount).map {
            RestorerScreen(x: CGFloat($0) * 2400, name: "Restore \($0)")
        }
        self.screens = screens
        displayManager = DisplayManager(screenSource: { screens })
        workspaceManager = WorkspaceManager(displayManager: displayManager)
        workspaceManager.disabledMonitors = disabled
        workspaceManager.initializeMonitors()
        var io: ((@escaping () -> UInt64) -> FrameSizingIO)?
        engine = TilingEngine(displayManager: displayManager,
                              frameSizingIOFactory: { _, generation in io!(generation) })
        for screen in screens { engine.maxSplitsPerMonitor[screen.localizedName] = maxDepth }
        let focusBorder = FocusBorder()
        let revalidation = MinimaRevalidation()
        orchestrator = WorkspaceOrchestrator(
            workspaceManager: workspaceManager,
            tilingEngine: engine,
            accessibility: AccessibilityManager(),
            displayManager: displayManager,
            cursorManager: CursorManager(),
            stateCache: cache,
            focusController: FocusStateController(focusBorder: focusBorder),
            focusBorder: focusBorder,
            dimmingOverlay: DimmingOverlay(),
            suppressions: SuppressionRegistry(),
            revalidation: revalidation)
        revalidation.workspaceFor = { [workspaceManager] in workspaceManager.workspaceFor($0) }
        // the retry timer never fires here; tests read what was recorded
        recovery.schedule = { _, _ in }
        io = { [unowned self] generation in self.frameIO(generation) }
        orchestrator.allWindows = { [unowned self] in self.all }
        orchestrator.tileAllVisibleSpaces = { [unowned self] _ in self.retileVisible() }
    }

    var all: [HyprWindow] { windows.values.sorted { $0.windowID < $1.windowID } }

    var scratchpadIDs: Set<CGWindowID> = []

    var restorer: LayoutRestorer {
        LayoutRestorer(engine: engine, orchestrator: orchestrator, workspaceManager: workspaceManager,
                       stateCache: cache, recovery: recovery,
                       isScratchpad: { [scratchpadIDs] in scratchpadIDs.contains($0) },
                       ref: { Self.ref($0.windowID) })
    }

    static func ref(_ id: CGWindowID) -> SavedWindowRef {
        SavedWindowRef(bundleID: "app.\(id)", title: "w\(id)")
    }

    private func frameIO(_ generation: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { [unowned self] id, size, _ in
                if !ignoresWrites.contains(id) { frames[id]?.size = size }
                return .success
            },
            writePosition: { [unowned self] id, point, _ in
                if !ignoresWrites.contains(id) { frames[id]?.origin = point }
                return .success
            },
            readPosition: { [unowned self] id, _ in (.success, frames[id]?.origin) },
            readSize: { [unowned self] id, _ in (.success, frames[id]?.size) },
            now: { [unowned self] in clock },
            sleep: { [unowned self] in clock += $0 },
            currentGeneration: generation)
    }

    /// assign `ids` to `workspace`, tiled on its home screen unless `tile` is false
    @discardableResult
    func fill(_ workspace: Int, _ ids: [Int], tile: Bool = true, screen: NSScreen? = nil) -> [HyprWindow] {
        let made: [HyprWindow] = ids.map { raw in
            let pid = pid_t(91000 + raw)
            let window = HyprWindow(element: AXUIElementCreateApplication(pid),
                                    windowID: CGWindowID(raw), ownerPID: pid)
            frames[window.windowID] = CGRect(x: 20 + (raw % 50) * 30, y: 20, width: 120, height: 120)
            cache.cachedWindows[window.windowID] = window
            windows[window.windowID] = window
            workspaceManager.assignWindow(window.windowID, toWorkspace: workspace)
            return window
        }
        if tile {
            let screen = screen ?? workspaceManager.homeScreenForWorkspace(workspace)!
            let result = engine.tileWindows(made, onWorkspace: workspace, screen: screen)
            precondition(result.published, "fixture workspace \(workspace) did not tile")
        }
        return made
    }

    func visible(on index: Int) -> Int { workspaceManager.workspaceForScreen(screens[index]) }

    func hidden(on index: Int, skipping: Int = 0) -> Int {
        let visible = visible(on: index)
        return workspaceManager.workspacesAnchoredTo(screens[index]).filter { $0 != visible }[skipping]
    }

    func workspace(of raw: Int) -> Int? { workspaceManager.workspaceFor(CGWindowID(raw)) }

    func treeIDs(_ workspace: Int) -> Set<CGWindowID> {
        screens.reduce(into: Set<CGWindowID>()) { ids, screen in
            ids.formUnion(engine.existingTree(forWorkspace: workspace, screen: screen)?
                .allWindows.map(\.windowID) ?? [])
        }
    }

    func shape(_ workspace: Int) -> LayoutNode? {
        engine.layoutTree(forWorkspace: workspace, ref: { Self.ref($0.windowID) })
    }

    func retileVisible() {
        for screen in screens where !workspaceManager.isMonitorDisabled(screen) {
            let ws = workspaceManager.workspaceForScreen(screen)
            let list = workspaceManager.windowIDs(onWorkspace: ws).sorted().compactMap { windows[$0] }
                .filter { !cache.floatingWindowIDs.contains($0.windowID) }
            engine.tileWindows(list, onWorkspace: ws, screen: screen)
        }
    }

    func restore(_ layouts: [Int: LayoutNode],
                 unplaced: [Int: [SavedWindowRef]] = [:]) -> LayoutRestoreOutcome {
        let workspaces = Set(layouts.keys).union(unplaced.keys).sorted().map {
            WorkspaceLayout(workspace: $0, root: layouts[$0], unplaced: unplaced[$0] ?? [])
        }
        let snapshot = LayoutSnapshot(
            schemaVersion: LayoutSnapshot.currentSchemaVersion, displayKey: "restorer-test",
            timestamp: Date(), isManual: true, workspaces: workspaces)
        return restorer.restore(snapshot, windows: all)
    }

    /// every window in at most one tree, across screens and workspaces
    func assertEachWindowInOneTree(file: StaticString = #filePath, line: UInt = #line) {
        var seen: [CGWindowID: String] = [:]
        for ws in Constants.workspaceRange {
            for screen in screens {
                for w in engine.existingTree(forWorkspace: ws, screen: screen)?.allWindows ?? [] {
                    let here = "ws\(ws)@\(screen.localizedName)"
                    XCTAssertNil(seen[w.windowID], "\(w.windowID) is in \(seen[w.windowID] ?? "") and \(here)",
                                 file: file, line: line)
                    seen[w.windowID] = here
                }
            }
        }
    }
}

private func leaf(_ id: CGWindowID) -> LayoutNode { .leaf(RestorerRig.ref(id)) }

private func split(_ left: LayoutNode, _ right: LayoutNode,
                   _ override: SplitDirection? = nil) -> LayoutNode {
    .split(override: override, ratio: 0.5, userSet: false, left: left, right: right)
}

private func grid(_ a: CGWindowID, _ b: CGWindowID, _ c: CGWindowID, _ d: CGWindowID) -> LayoutNode {
    split(split(leaf(a), leaf(b), .vertical), split(leaf(c), leaf(d), .vertical), .horizontal)
}

final class LayoutRestorerTests: XCTestCase {

    func testNoSnapshotSaysSo() {
        let rig = RestorerRig()
        let outcome = rig.restorer.restore(nil, windows: rig.all)
        XCTAssertEqual(outcome.verdict, .noSnapshot)
        XCTAssertEqual(outcome.message, "No saved layout for this display setup")
    }

    func testCompleteRestoreMovesAndReshapes() {
        let rig = RestorerRig()
        let visible = rig.visible(on: 0)
        let hidden = rig.hidden(on: 0)
        rig.fill(visible, [1, 2, 4])
        rig.fill(hidden, [3])
        let savedVisible = split(leaf(2), leaf(1), .vertical)
        let savedHidden = split(leaf(3), leaf(4), .horizontal)

        let outcome = rig.restore([visible: savedVisible, hidden: savedHidden])

        XCTAssertEqual(outcome.verdict, .complete)
        XCTAssertEqual(outcome.message, "Layout restored")
        XCTAssertEqual(outcome.moved, [4: hidden])
        XCTAssertEqual(outcome.rebuilt.sorted(), [visible, hidden].sorted())
        XCTAssertEqual(rig.shape(visible), savedVisible)
        XCTAssertEqual(rig.shape(hidden), savedHidden)
        rig.assertEachWindowInOneTree()
    }

    func testNothingToDoIsAlreadyInPlace() {
        let rig = RestorerRig()
        let visible = rig.visible(on: 0)
        rig.fill(visible, [1, 2, 3])
        let saved = rig.shape(visible)!

        let outcome = rig.restore([visible: saved])

        XCTAssertEqual(outcome.verdict, .alreadyInPlace)
        XCTAssertEqual(outcome.message, "Layout already in place")
        XCTAssertEqual(outcome.rebuilt, [visible])
        XCTAssertTrue(outcome.reshaped.isEmpty)
    }

    func testMissingSavedWindowAloneIsStillComplete() {
        let rig = RestorerRig()
        let visible = rig.visible(on: 0)
        rig.fill(visible, [1, 2])

        // window 9 was saved but is not open; its leaf collapses
        let outcome = rig.restore([visible: split(leaf(1), split(leaf(2), leaf(9)), .vertical)])

        XCTAssertEqual(outcome.verdict, .complete)
        XCTAssertEqual(outcome.absent, 1)
        XCTAssertEqual(outcome.message, "Layout restored — 1 saved window not open")
        XCTAssertEqual(rig.shape(visible), split(leaf(1), leaf(2), .vertical))
    }

    func testFullDestinationRefusalIsPartial() {
        let rig = RestorerRig()
        let visible = rig.visible(on: 0)
        let hidden = rig.hidden(on: 0)
        rig.fill(visible, [1, 2, 3, 4])
        rig.fill(hidden, [5])

        // 5 belongs on the visible workspace, which is already at its four tiles
        let outcome = rig.restore([visible: split(leaf(1), split(leaf(2), leaf(5)))])

        XCTAssertEqual(outcome.verdict, .partial)
        XCTAssertEqual(outcome.refusedMoves, [5: .full(tiled: 5, capacity: 4)])
        XCTAssertEqual(outcome.message, "Layout partly restored — 1 window didn't fit")
        XCTAssertEqual(rig.workspace(of: 5), hidden)
        XCTAssertEqual(rig.treeIDs(visible), [1, 2, 3, 4])
        rig.assertEachWindowInOneTree()
    }

    func testDepthRejectionBesideARebuildIsPartial() {
        let rig = RestorerRig(maxDepth: 3)
        let visible = rig.visible(on: 0)
        let hidden = rig.hidden(on: 0)
        rig.fill(visible, [1, 2, 3])
        rig.fill(hidden, [4, 5])
        let before = rig.shape(visible)
        rig.engine.maxSplitsPerMonitor[rig.screens[0].localizedName] = 1

        // saved at depth 2 on the visible workspace, which now allows 1
        let outcome = rig.restore([visible: split(leaf(1), split(leaf(2), leaf(3))),
                                   hidden: split(leaf(5), leaf(4))])

        XCTAssertEqual(outcome.verdict, .partial)
        XCTAssertEqual(outcome.shapeFailures, [visible: .exceedsMaxDepth(2)])
        XCTAssertEqual(outcome.rebuilt, [hidden])
        XCTAssertEqual(outcome.message, "Layout partly restored — 1 workspace kept its layout")
        XCTAssertEqual(rig.shape(visible), before)
    }

    func testDepthRejectionAloneIsFailed() {
        let rig = RestorerRig(maxDepth: 3)
        let visible = rig.visible(on: 0)
        rig.fill(visible, [1, 2, 3])
        let before = rig.shape(visible)
        rig.engine.maxSplitsPerMonitor[rig.screens[0].localizedName] = 1

        let outcome = rig.restore([visible: split(leaf(1), split(leaf(2), leaf(3)))])

        XCTAssertEqual(outcome.verdict, .failed)
        XCTAssertEqual(outcome.message, "Couldn't restore layout")
        XCTAssertEqual(rig.shape(visible), before)
    }

    func testFrameVerificationRejectionKeepsLiveTreeAndReports() {
        let rig = RestorerRig()
        let visible = rig.visible(on: 0)
        rig.fill(visible, [1, 2])
        let before = rig.shape(visible)
        rig.ignoresWrites = [1]

        let outcome = rig.restore([visible: split(leaf(2), leaf(1), .vertical)])

        guard case .rejected = outcome.shapeFailures[visible] else {
            return XCTFail("expected a verification rejection, got \(String(describing: outcome.shapeFailures[visible]))")
        }
        XCTAssertEqual(outcome.verdict, .failed)
        XCTAssertTrue(outcome.rebuilt.isEmpty)
        XCTAssertEqual(rig.shape(visible), before)
    }

    func testRefusedIncumbentIsReported() {
        let rig = RestorerRig(maxDepth: 3)
        let visible = rig.visible(on: 0)
        rig.fill(visible, [1, 2, 3, 4, 5])
        let before = rig.shape(visible)
        rig.engine.maxSplitsPerMonitor[rig.screens[0].localizedName] = 2

        let outcome = rig.restore([visible: grid(1, 2, 3, 4)])

        XCTAssertEqual(outcome.shapeFailures, [visible: .refusedIncumbents([5])])
        XCTAssertEqual(outcome.verdict, .failed)
        XCTAssertEqual(rig.shape(visible), before)
        XCTAssertEqual(rig.treeIDs(visible), [1, 2, 3, 4, 5])
    }

    func testRefusedNewcomerIsPartialAndGoesToRecovery() {
        let rig = RestorerRig()
        let visible = rig.visible(on: 0)
        rig.fill(visible, [1, 2, 3, 4])
        // just opened, assigned, never admitted
        rig.fill(visible, [5], tile: false)

        let outcome = rig.restore([visible: grid(4, 3, 2, 1)])

        XCTAssertEqual(outcome.verdict, .partial)
        XCTAssertEqual(outcome.refusedNewcomers, [visible: [5]])
        XCTAssertEqual(outcome.message, "Layout partly restored — 1 window didn't fit")
        XCTAssertEqual(rig.shape(visible), grid(4, 3, 2, 1))
        XCTAssertEqual(rig.recovery.pendingWindowIDs, [5])
        XCTAssertEqual(rig.recovery.phase(of: 5), .awaitingRetry)
    }

    func testEverythingRefusedIsFailed() {
        let rig = RestorerRig()
        let visible = rig.visible(on: 0)
        let hidden = rig.hidden(on: 0)
        rig.fill(visible, [1, 2, 3, 4])
        rig.fill(hidden, [5])
        let before = rig.shape(visible)
        rig.ignoresWrites = [1, 2, 3, 4]

        // 5 can't join a full workspace, and the workspace refuses its new shape
        let outcome = rig.restore([visible: split(leaf(5), grid(4, 3, 2, 1))])

        XCTAssertEqual(outcome.verdict, .failed)
        XCTAssertEqual(outcome.message, "Couldn't restore layout")
        XCTAssertEqual(outcome.refusedMoves, [5: .full(tiled: 5, capacity: 4)])
        XCTAssertTrue(outcome.moved.isEmpty)
        XCTAssertTrue(outcome.rebuilt.isEmpty)
        guard case .rejected = outcome.shapeFailures[visible] else {
            return XCTFail("expected a verification rejection, got \(String(describing: outcome.shapeFailures[visible]))")
        }
        XCTAssertEqual(rig.workspace(of: 5), hidden)
        XCTAssertEqual(rig.shape(visible), before)
    }

    func testFullWorkspaceSwapRestoresEndToEnd() {
        let rig = RestorerRig()
        let visible = rig.visible(on: 0)
        let hidden = rig.hidden(on: 0)
        rig.fill(visible, [1, 2, 3, 4])
        rig.fill(hidden, [5, 6, 7, 8])

        let outcome = rig.restore([visible: grid(5, 2, 3, 4), hidden: grid(1, 6, 7, 8)])

        XCTAssertEqual(outcome.verdict, .complete)
        XCTAssertEqual(outcome.moved, [1: hidden, 5: visible])
        XCTAssertEqual(rig.shape(visible), grid(5, 2, 3, 4))
        XCTAssertEqual(rig.shape(hidden), grid(1, 6, 7, 8))
        XCTAssertEqual(rig.treeIDs(visible), [2, 3, 4, 5])
        XCTAssertEqual(rig.treeIDs(hidden), [1, 6, 7, 8])
        rig.assertEachWindowInOneTree()
    }

    func testStaleTreeOnAnotherScreenDoesNotKeepARestoredWindow() {
        let rig = RestorerRig(screenCount: 2)
        let visible = rig.visible(on: 0)
        rig.fill(visible, [1, 2])
        // a leftover ws tree on the other screen still holding window 1
        rig.engine.tileWindows([rig.windows[1]!], onWorkspace: visible, screen: rig.screens[1])

        let outcome = rig.restore([visible: split(leaf(2), leaf(1), .vertical)])

        XCTAssertEqual(outcome.verdict, .complete)
        XCTAssertEqual(rig.engine.windowIDs(inTreeForWorkspace: visible, screen: rig.screens[0]), [2, 1])
        rig.assertEachWindowInOneTree()
    }

    func testHUDTextNamesEachVerdict() {
        var outcome = LayoutRestoreOutcome()
        outcome.moved = [1: 2]
        outcome.rebuilt = [2]
        XCTAssertEqual(outcome.hud.title, "Restored")
        XCTAssertNil(outcome.hud.detail)
        outcome.refusedMoves = [3: .full(tiled: 5, capacity: 4)]
        XCTAssertEqual(outcome.hud.title, "Partly restored")
        XCTAssertEqual(outcome.hud.detail, "1 window didn't fit")
        XCTAssertFalse(outcome.hud.failed)
        outcome.moved = [:]
        outcome.rebuilt = []
        XCTAssertEqual(outcome.hud.title, "Couldn't restore")
        XCTAssertTrue(outcome.hud.failed)
        XCTAssertEqual(LayoutRestoreOutcome.noSnapshot.hud.title, "No saved layout")
    }

    // a window sent to a hidden workspace joins its tree only when shown;
    // a save still has to know which workspace it is on
    func testCaptureKeepsAWindowParkedOnAHiddenWorkspace() {
        let rig = RestorerRig()
        let visible = rig.visible(on: 0)
        let hidden = rig.hidden(on: 0)
        rig.fill(visible, [1, 2])
        rig.fill(hidden, [3], tile: false)

        let layouts = rig.restorer.capture()

        XCTAssertEqual(layouts.map(\.workspace), [visible, hidden])
        XCTAssertEqual(layouts[0].unplaced, [])
        XCTAssertNil(layouts[1].root)
        XCTAssertEqual(layouts[1].unplaced, [RestorerRig.ref(3)])
    }

    // floaters, scratchpad members and closed-but-alive windows are never saved
    func testCaptureSkipsFloatersScratchpadAndGhosts() {
        let rig = RestorerRig()
        let hidden = rig.hidden(on: 0)
        rig.fill(hidden, [1, 2, 3, 4], tile: false)
        rig.cache.floatingWindowIDs = [1]
        rig.scratchpadIDs = [2]
        rig.cache.hiddenWindowIDs = [3]

        let layouts = rig.restorer.capture()

        XCTAssertEqual(layouts.first { $0.workspace == hidden }?.unplaced, [RestorerRig.ref(4)])
    }

    func testUnplacedSavedWindowMovesBackToItsWorkspace() {
        let rig = RestorerRig()
        let visible = rig.visible(on: 0)
        let hidden = rig.hidden(on: 0)
        rig.fill(visible, [1, 2, 3])

        let outcome = rig.restore([visible: split(leaf(1), leaf(2))],
                                  unplaced: [hidden: [RestorerRig.ref(3)]])

        XCTAssertEqual(outcome.moved, [3: hidden])
        XCTAssertEqual(rig.workspace(of: 3), hidden)
        XCTAssertEqual(outcome.verdict, .complete)
        rig.assertEachWindowInOneTree()
    }

    // mid-transition the key and the trees are in flux; save and restore wait
    func testSaveAndRestoreWaitOutADisplayTransition() {
        XCTAssertTrue(WindowManager.isDroppedMidDisplayTransition(.saveLayout))
        XCTAssertTrue(WindowManager.isDroppedMidDisplayTransition(.restoreLayout))
        XCTAssertTrue(WindowManager.isDroppedMidDisplayTransition(.moveToWorkspace(2)))
        XCTAssertFalse(WindowManager.isDroppedMidDisplayTransition(.focusDirection(.left)))
    }

    // a Dock resize or arrangement drag settles under the same key and must
    // not pull back an older snapshot
    func testOnlyANewDisplaySetRestoresAfterSettle() {
        XCTAssertFalse(WindowManager.restoresAfterSettle(from: "A:1512x982", to: "A:1512x982"))
        XCTAssertTrue(WindowManager.restoresAfterSettle(from: "A:1512x982|B:2560x1440", to: "A:1512x982"))
        XCTAssertTrue(WindowManager.restoresAfterSettle(from: "A:1512x982", to: "A:1512x982|B:2560x1440"))
    }

    // saving changes no layout, so a pending admission retry stays armed
    func testSaveLeavesPendingRecoveryAloneButRestoreCancelsIt() {
        XCTAssertFalse(WindowManager.cancelsPendingRecovery(.saveLayout))
        XCTAssertTrue(WindowManager.cancelsPendingRecovery(.restoreLayout))
    }
}
