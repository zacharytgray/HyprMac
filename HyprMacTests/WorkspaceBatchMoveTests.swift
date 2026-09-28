import Cocoa
import XCTest
@testable import HyprMac

private final class BatchMoveScreen: SyntheticScreen {
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

/// synthetic desktop for batch moves: fake windows, frame i/o that
/// accepts every write unless the window is told to ignore them.
private final class BatchMoveRig {
    let screens: [BatchMoveScreen]
    let displayManager: DisplayManager
    let workspaceManager: WorkspaceManager
    let engine: TilingEngine
    let cache = WindowStateCache()
    let orchestrator: WorkspaceOrchestrator
    var frames: [CGWindowID: CGRect] = [:]
    // windows that take every write and never move, like an app refusing its slot
    var ignoresWrites: Set<CGWindowID> = []
    // windows that will not be moved onto the second screen
    var refusesSecondScreen: Set<CGWindowID> = []
    var windows: [CGWindowID: HyprWindow] = [:]
    private var clock: TimeInterval = 0

    init(screenCount: Int = 1, maxDepth: Int = 2, disabled: Set<String> = []) {
        let screens = (0..<screenCount).map {
            BatchMoveScreen(x: CGFloat($0) * 2400, name: "Batch \($0)")
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
        io = { [unowned self] generation in self.frameIO(generation) }
        orchestrator.allWindows = { [unowned self] in self.windows.values.sorted { $0.windowID < $1.windowID } }
        orchestrator.tileAllVisibleSpaces = { [unowned self] in self.retileVisible() }
    }

    private func frameIO(_ generation: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { [unowned self] id, size, _ in
                if !ignoresWrites.contains(id) { frames[id]?.size = size }
                return .success
            },
            writePosition: { [unowned self] id, point, _ in
                let refused = ignoresWrites.contains(id)
                    || (refusesSecondScreen.contains(id) && point.x >= 2400)
                if !refused { frames[id]?.origin = point }
                return .success
            },
            readPosition: { [unowned self] id, _ in (.success, frames[id]?.origin) },
            readSize: { [unowned self] id, _ in (.success, frames[id]?.size) },
            now: { [unowned self] in clock },
            sleep: { [unowned self] in clock += $0 },
            currentGeneration: generation)
    }

    /// assign `ids` to `workspace` and tile them on its home screen, the
    /// way a workspace looks after it has been shown once.
    @discardableResult
    func fill(_ workspace: Int, _ ids: [Int]) -> [HyprWindow] {
        let made: [HyprWindow] = ids.map { raw in
            let pid = pid_t(90000 + raw)
            let window = HyprWindow(element: AXUIElementCreateApplication(pid),
                                    windowID: CGWindowID(raw), ownerPID: pid)
            frames[window.windowID] = CGRect(x: 20 + (raw % 50) * 30, y: 20, width: 120, height: 120)
            cache.cachedWindows[window.windowID] = window
            windows[window.windowID] = window
            workspaceManager.assignWindow(window.windowID, toWorkspace: workspace)
            return window
        }
        let screen = workspaceManager.homeScreenForWorkspace(workspace)!
        let result = engine.tileWindows(made, onWorkspace: workspace, screen: screen)
        precondition(result.published, "fixture workspace \(workspace) did not tile")
        return made
    }

    func window(_ raw: Int) -> HyprWindow { windows[CGWindowID(raw)]! }

    func workspace(of raw: Int) -> Int? { workspaceManager.workspaceFor(CGWindowID(raw)) }

    func assigned(_ workspace: Int) -> Set<CGWindowID> { workspaceManager.windowIDs(onWorkspace: workspace) }

    func visible(on index: Int) -> Int { workspaceManager.workspaceForScreen(screens[index]) }

    func hidden(on index: Int, skipping: Int = 0) -> Int {
        let visible = visible(on: index)
        return workspaceManager.workspacesAnchoredTo(screens[index]).filter { $0 != visible }[skipping]
    }

    func treeIDs(_ workspace: Int) -> Set<CGWindowID> {
        screens.reduce(into: Set<CGWindowID>()) { ids, screen in
            ids.formUnion(engine.existingTree(forWorkspace: workspace, screen: screen)?
                .allWindows.map(\.windowID) ?? [])
        }
    }

    /// what the app's retile does for every enabled screen
    func retileVisible() {
        for screen in screens where !workspaceManager.isMonitorDisabled(screen) {
            let ws = workspaceManager.workspaceForScreen(screen)
            let list = assigned(ws).sorted().compactMap { windows[$0] }
                .filter { !cache.floatingWindowIDs.contains($0.windowID) }
            engine.tileWindows(list, onWorkspace: ws, screen: screen)
        }
    }

    /// no window in two trees, and no tree holding a window assigned elsewhere
    func assertNoHalfMoves(file: StaticString = #filePath, line: UInt = #line) {
        var seen: [CGWindowID: Int] = [:]
        for ws in Constants.workspaceRange {
            for id in treeIDs(ws) {
                XCTAssertNil(seen[id], "\(id) is in the trees of ws\(seen[id]!) and ws\(ws)", file: file, line: line)
                seen[id] = ws
                XCTAssertEqual(workspaceManager.workspaceFor(id), ws,
                               "\(id) sits in ws\(ws)'s tree but is assigned elsewhere", file: file, line: line)
            }
        }
    }
}

final class WorkspaceBatchMoveTests: XCTestCase {

    // the owner's probe: two full four-window workspaces at depth 2
    func testSwapBetweenFullVisibleAndHiddenWorkspacesMoves() {
        let rig = BatchMoveRig()
        let visible = rig.visible(on: 0)
        let hidden = rig.hidden(on: 0)
        rig.fill(visible, [1001, 1002, 1003, 1004])
        rig.fill(hidden, [2001, 2002, 2003, 2004])

        let result = rig.orchestrator.moveWindows([(rig.window(1001), hidden), (rig.window(2001), visible)])

        XCTAssertEqual(result.moved, [1001: hidden, 2001: visible])
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(rig.workspace(of: 1001), hidden)
        XCTAssertEqual(rig.workspace(of: 2001), visible)
        XCTAssertEqual(rig.assigned(visible), [1002, 1003, 1004, 2001])
        XCTAssertEqual(rig.assigned(hidden), [1001, 2002, 2003, 2004])
        // visible tree holds the arrival; the hidden one admits 1001 on reveal
        XCTAssertEqual(rig.treeIDs(visible), [1002, 1003, 1004, 2001])
        XCTAssertEqual(rig.treeIDs(hidden), [2002, 2003, 2004])
        rig.assertNoHalfMoves()
    }

    func testSwapBetweenTwoFullHiddenWorkspacesMoves() {
        let rig = BatchMoveRig()
        let first = rig.hidden(on: 0)
        let second = rig.hidden(on: 0, skipping: 1)
        rig.fill(rig.visible(on: 0), [1001])
        rig.fill(first, [2001, 2002, 2003, 2004])
        rig.fill(second, [3001, 3002, 3003, 3004])

        let result = rig.orchestrator.moveWindows([(rig.window(2001), second), (rig.window(3001), first)])

        XCTAssertEqual(result.moved, [2001: second, 3001: first])
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(rig.workspace(of: 2001), second)
        XCTAssertEqual(rig.workspace(of: 3001), first)
        XCTAssertEqual(rig.assigned(first), [2002, 2003, 2004, 3001])
        XCTAssertEqual(rig.assigned(second), [2001, 3002, 3003, 3004])
        rig.assertNoHalfMoves()
    }

    // two visible destinations on two screens plus a hidden one
    func testThreeCycleAcrossFullWorkspacesOnTwoScreensMoves() {
        let rig = BatchMoveRig(screenCount: 2)
        let left = rig.visible(on: 0)
        let right = rig.visible(on: 1)
        let hidden = rig.hidden(on: 0)
        rig.fill(left, [1001, 1002, 1003, 1004])
        rig.fill(right, [2001, 2002, 2003, 2004])
        rig.fill(hidden, [3001, 3002, 3003, 3004])

        let result = rig.orchestrator.moveWindows([
            (rig.window(1001), right), (rig.window(2001), hidden), (rig.window(3001), left),
        ])

        XCTAssertEqual(result.moved, [1001: right, 2001: hidden, 3001: left])
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(rig.workspace(of: 1001), right)
        XCTAssertEqual(rig.workspace(of: 2001), hidden)
        XCTAssertEqual(rig.workspace(of: 3001), left)
        XCTAssertEqual(rig.treeIDs(left), [1002, 1003, 1004, 3001])
        XCTAssertEqual(rig.treeIDs(right), [1001, 2002, 2003, 2004])
        XCTAssertEqual(rig.assigned(hidden), [2001, 3002, 3003, 3004])
        rig.assertNoHalfMoves()
    }

    func testOverCapacityPlanMovesNothing() {
        let rig = BatchMoveRig()
        let visible = rig.visible(on: 0)
        let hidden = rig.hidden(on: 0)
        rig.fill(visible, [1001, 1002, 1003, 1004])
        rig.fill(hidden, [2001, 2002, 2003])
        let visibleTree = rig.treeIDs(visible)
        let hiddenTree = rig.treeIDs(hidden)

        // hidden would end on five, and once those three stay put the
        // visible one would too
        let result = rig.orchestrator.moveWindows([
            (rig.window(1001), hidden), (rig.window(1002), hidden), (rig.window(1003), hidden),
            (rig.window(2001), visible),
        ])

        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.refused[1001], .full(tiled: 5, capacity: 4))
        XCTAssertEqual(result.refused[1002], .full(tiled: 5, capacity: 4))
        XCTAssertEqual(result.refused[1003], .full(tiled: 5, capacity: 4))
        XCTAssertEqual(result.refused[2001], .full(tiled: 5, capacity: 4))
        XCTAssertEqual(rig.assigned(visible), [1001, 1002, 1003, 1004])
        XCTAssertEqual(rig.assigned(hidden), [2001, 2002, 2003])
        XCTAssertEqual(rig.treeIDs(visible), visibleTree)
        XCTAssertEqual(rig.treeIDs(hidden), hiddenTree)
        rig.assertNoHalfMoves()
    }

    func testVisibleDestinationRefusingSizingRollsTheSwapBack() {
        let rig = BatchMoveRig()
        let visible = rig.visible(on: 0)
        let hidden = rig.hidden(on: 0)
        rig.fill(visible, [1001, 1002, 1003, 1004])
        rig.fill(hidden, [2001, 2002, 2003, 2004])
        let before = rig.frames
        rig.ignoresWrites = [2001]

        let result = rig.orchestrator.moveWindows([(rig.window(1001), hidden), (rig.window(2001), visible)])

        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.refused[2001], .sizingRefused)
        // 1001 staying home leaves the hidden workspace one over
        XCTAssertEqual(result.refused[1001], .full(tiled: 5, capacity: 4))
        XCTAssertEqual(rig.assigned(visible), [1001, 1002, 1003, 1004])
        XCTAssertEqual(rig.assigned(hidden), [2001, 2002, 2003, 2004])
        XCTAssertEqual(rig.treeIDs(visible), [1001, 1002, 1003, 1004])
        XCTAssertEqual(rig.treeIDs(hidden), [2001, 2002, 2003, 2004])
        for id: CGWindowID in [1001, 1002, 1003, 1004] {
            XCTAssertEqual(rig.frames[id], before[id], "\(id) was left off its tile")
        }
        rig.assertNoHalfMoves()
    }

    // an arrival parked on a hidden workspace sits outside the screen, so the
    // engine can't roll back to its frame; the destination still has to
    // come back to its old tiles
    func testParkedArrivalRefusingItsSlotPutsTheDestinationBack() {
        let rig = BatchMoveRig()
        let visible = rig.visible(on: 0)
        let hidden = rig.hidden(on: 0)
        rig.fill(visible, [1001, 1002, 1003])
        rig.fill(hidden, [2001])
        let park = rig.workspaceManager.hidePosition()
        rig.frames[2001]?.origin = park
        let before = rig.frames
        rig.ignoresWrites = [2001]

        let result = rig.orchestrator.moveWindows([(rig.window(2001), visible)])

        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.refused[2001], .sizingRefused)
        XCTAssertEqual(rig.assigned(visible), [1001, 1002, 1003])
        XCTAssertEqual(rig.treeIDs(visible), [1001, 1002, 1003])
        XCTAssertEqual(rig.treeIDs(hidden), [2001])
        for id: CGWindowID in [1001, 1002, 1003] {
            XCTAssertEqual(rig.frames[id], before[id], "\(id) was left off its tile")
        }
        rig.assertNoHalfMoves()
    }

    // an unrelated destination still lands when another group overflows
    func testOverflowingGroupDoesNotHoldBackAnotherDestination() {
        let rig = BatchMoveRig()
        let visible = rig.visible(on: 0)
        let full = rig.hidden(on: 0)
        let roomy = rig.hidden(on: 0, skipping: 1)
        rig.fill(visible, [1001, 1002, 1003])
        rig.fill(full, [2001, 2002, 2003, 2004])
        rig.fill(roomy, [3001])

        let result = rig.orchestrator.moveWindows([
            (rig.window(1001), full), (rig.window(1002), roomy),
        ])

        XCTAssertEqual(result.moved, [1002: roomy])
        XCTAssertEqual(result.refused, [1001: .full(tiled: 5, capacity: 4)])
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(rig.assigned(visible), [1001, 1003])
        XCTAssertEqual(rig.treeIDs(visible), [1001, 1003])
        XCTAssertEqual(rig.assigned(roomy), [1002, 3001])
        rig.assertNoHalfMoves()
    }

    // the second visible destination refuses after the first already took
    // its arrival; the first is laid out again without it
    func testLaterVisibleRefusalPutsEarlierVisibleDestinationBack() {
        let rig = BatchMoveRig(screenCount: 2)
        let left = rig.visible(on: 0)
        let right = rig.visible(on: 1)
        rig.fill(left, [1001, 1002, 1003, 1004])
        rig.fill(right, [2001, 2002, 2003, 2004])
        let before = rig.frames
        rig.refusesSecondScreen = [1001]

        let result = rig.orchestrator.moveWindows([(rig.window(1001), right), (rig.window(2001), left)])

        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.refused[1001], .sizingRefused)
        XCTAssertEqual(result.refused[2001], .full(tiled: 5, capacity: 4))
        XCTAssertEqual(rig.treeIDs(left), [1001, 1002, 1003, 1004])
        XCTAssertEqual(rig.treeIDs(right), [2001, 2002, 2003, 2004])
        for id: CGWindowID in [2001, 2002, 2003, 2004] {
            XCTAssertEqual(rig.frames[id], before[id], "\(id) kept a failed layout")
        }
        // left is laid out again from a tree 1001 had left, so it can land
        // in another leaf; the same four tiles are covered either way
        let leftIDs: [CGWindowID] = [1001, 1002, 1003, 1004]
        XCTAssertEqual(Set(leftIDs.compactMap { rig.frames[$0].map(NSStringFromRect) }),
                       Set(leftIDs.compactMap { before[$0].map(NSStringFromRect) }))
        rig.assertNoHalfMoves()
    }

    func testFloaterMovesWithoutEnteringATreeOrTakingASlot() {
        let rig = BatchMoveRig()
        let visible = rig.visible(on: 0)
        let hidden = rig.hidden(on: 0)
        rig.fill(visible, [1001, 1002, 1003, 1004])
        rig.fill(hidden, [2001, 2002])
        // floaters live outside every tree
        rig.engine.removeWindowMembershipOnly(rig.window(2001), fromWorkspace: hidden)
        rig.cache.floatingWindowIDs.insert(2001)
        rig.window(2001).isFloating = true

        let result = rig.orchestrator.moveWindows([(rig.window(2001), visible)])

        XCTAssertEqual(result.moved, [2001: visible])
        XCTAssertEqual(rig.treeIDs(visible), [1001, 1002, 1003, 1004])
        rig.assertNoHalfMoves()
    }

    func testScratchpadIsNeverInvolved() {
        let rig = BatchMoveRig()
        let visible = rig.visible(on: 0)
        rig.fill(visible, [1001, 1002])
        rig.fill(rig.hidden(on: 0), [2001])
        rig.workspaceManager.moveWindow(2001, toWorkspace: TilingEngine.scratchpadWorkspace)

        let result = rig.orchestrator.moveWindows([
            (rig.window(1001), TilingEngine.scratchpadWorkspace), (rig.window(2001), visible),
        ])

        XCTAssertEqual(result.refused, [1001: .scratchpad, 2001: .scratchpad])
        XCTAssertEqual(rig.workspace(of: 1001), visible)
        XCTAssertEqual(rig.workspace(of: 2001), TilingEngine.scratchpadWorkspace)
    }

    // homes are drawn from enabled screens only, so a workspace that lived
    // on a disabled monitor re-homes onto an enabled one and is judged
    // there. not a live gap; the explicit refusal covers no enabled screen.
    func testDestinationOfDisabledMonitorIsJudgedOnItsEnabledHome() {
        let rig = BatchMoveRig(screenCount: 2, disabled: ["Batch 1"])
        let enabled = rig.screens[0]
        XCTAssertTrue(rig.workspaceManager.homeScreenForWorkspace(2) === enabled)
        rig.fill(rig.visible(on: 0), [1001, 1002])
        rig.fill(2, [2001, 2002, 2003, 2004])

        let result = rig.orchestrator.moveWindows([(rig.window(1001), 2)])

        XCTAssertEqual(result.refused, [1001: .full(tiled: 5, capacity: 4)])
        XCTAssertEqual(rig.workspace(of: 1001), 1)
    }

    func testNoEnabledMonitorRefusesTheDestination() {
        let rig = BatchMoveRig()
        rig.fill(rig.visible(on: 0), [1001])
        rig.workspaceManager.disabledMonitors = ["Batch 0"]

        let result = rig.orchestrator.moveWindows([(rig.window(1001), 3)])

        XCTAssertEqual(result.refused, [1001: .destinationMonitorDisabled])
        XCTAssertEqual(rig.workspace(of: 1001), 1)
    }
}
