import Cocoa
import XCTest
@testable import HyprMac

// pins where focus and the cursor land when a move follows its window.
// ensureFocus picks from the screen under the cursor, so a follow that warps
// to the window's live frame while that frame still reads the source screen
// hands the next Hypr press to a tile on the wrong monitor. the warp has to
// aim at the destination.
//
// also pins move-and-follow (Hypr+Ctrl+Shift+N): the move goes through the
// same checks as Hypr+Shift+N, then switches to the destination with the
// moved window focused. a refused move never switches.

private final class FollowScreen: NSScreen {
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

/// a window whose live AX frame is whatever the test says, like one whose
/// frame reads have not caught up with the layout yet
private final class StuckWindow: HyprWindow {
    var live: CGRect

    init(id: CGWindowID, live: CGRect) {
        self.live = live
        let pid = pid_t(95000 + Int(id))
        super.init(element: AXUIElementCreateApplication(pid), windowID: id, ownerPID: pid)
    }

    override var frame: CGRect? { live }
}

/// two side-by-side screens, fake windows, and frame i/o that takes every
/// write unless the window is told to ignore them
private final class FollowRig {
    let screens: [FollowScreen]
    let displayManager: DisplayManager
    let workspaceManager: WorkspaceManager
    let engine: TilingEngine
    let cache = WindowStateCache()
    let focusController: FocusStateController
    let orchestrator: WorkspaceOrchestrator
    var frames: [CGWindowID: CGRect] = [:]
    // windows that take every write and never move, so their layout fails
    var ignoresWrites: Set<CGWindowID> = []
    var windows: [CGWindowID: HyprWindow] = [:]
    var focused: HyprWindow?
    var warps: [CGPoint] = []
    var bordered: [CGWindowID] = []
    var announced: [String] = []
    private var clock: TimeInterval = 0

    init() {
        let screens = [FollowScreen(x: 0, name: "Follow 0"), FollowScreen(x: 2400, name: "Follow 1")]
        self.screens = screens
        displayManager = DisplayManager(screenSource: { screens })
        workspaceManager = WorkspaceManager(displayManager: displayManager)
        workspaceManager.initializeMonitors()
        var io: ((@escaping () -> UInt64) -> FrameSizingIO)?
        engine = TilingEngine(displayManager: displayManager,
                              frameSizingIOFactory: { _, generation in io!(generation) })
        let focusBorder = FocusBorder()
        focusController = FocusStateController(focusBorder: focusBorder)
        let revalidation = MinimaRevalidation()
        orchestrator = WorkspaceOrchestrator(
            workspaceManager: workspaceManager,
            tilingEngine: engine,
            accessibility: AccessibilityManager(),
            displayManager: displayManager,
            cursorManager: CursorManager(),
            stateCache: cache,
            focusController: focusController,
            focusBorder: focusBorder,
            dimmingOverlay: DimmingOverlay(),
            suppressions: SuppressionRegistry(),
            revalidation: revalidation)
        revalidation.workspaceFor = { [workspaceManager] in workspaceManager.workspaceFor($0) }
        io = { [unowned self] generation in self.frameIO(generation) }
        orchestrator.currentFocusedWindow = { [unowned self] in self.focused }
        orchestrator.allWindows = { [unowned self] in self.windows.values.sorted { $0.windowID < $1.windowID } }
        orchestrator.tileAllVisibleSpaces = { [unowned self] in self.retileVisible() }
        orchestrator.animatedRetile = { [unowned self] prepare, completion in
            prepare?()
            self.retileVisible()
            completion?()
        }
        orchestrator.screenUnderCursor = { [unowned self] in self.screens[0] }
        orchestrator.warpCursor = { [unowned self] in self.warps.append($0) }
        orchestrator.updateFocusBorder = { [unowned self] in self.bordered.append($0.windowID) }
        orchestrator.onWillSwitch = { [unowned self] workspace, screen in
            self.announced.append("will:\(workspace)@\(screen.localizedName)")
        }
        orchestrator.onDidSwitch = { [unowned self] workspace, screen in
            self.announced.append("did:\(workspace)@\(screen.localizedName)")
        }
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

    func rect(_ index: Int) -> CGRect { displayManager.cgRect(for: screens[index]) }

    func visible(on index: Int) -> Int { workspaceManager.workspaceForScreen(screens[index]) }

    /// a workspace anchored to screen `index` that is not showing
    func hidden(on index: Int) -> Int {
        let up = visible(on: index)
        return workspaceManager.workspacesAnchoredTo(screens[index]).first { $0 != up }!
    }

    /// assign a window to `workspace`, standing on screen 0 until a layout
    /// moves it. `window` stands in for the plain fake one.
    @discardableResult
    func add(_ raw: Int, to workspace: Int, floating: Bool = false,
             window: HyprWindow? = nil) -> HyprWindow {
        let pid = pid_t(90000 + raw)
        let made = window ?? HyprWindow(element: AXUIElementCreateApplication(pid),
                                        windowID: CGWindowID(raw), ownerPID: pid)
        frames[made.windowID] = CGRect(x: 20 + (raw % 50) * 30, y: 20, width: 600, height: 400)
        cache.cachedWindows[made.windowID] = made
        windows[made.windowID] = made
        workspaceManager.assignWindow(made.windowID, toWorkspace: workspace)
        if floating {
            cache.floatingWindowIDs.insert(made.windowID)
            made.isFloating = true
        }
        return made
    }

    /// lay a visible workspace out the way a retile would
    func tile(_ workspace: Int) {
        let screen = workspaceManager.homeScreenForWorkspace(workspace)!
        let list = assigned(workspace)
        let result = engine.tileWindows(list, onWorkspace: workspace, screen: screen)
        precondition(result.published, "fixture workspace \(workspace) did not tile")
    }

    func assigned(_ workspace: Int) -> [HyprWindow] {
        workspaceManager.windowIDs(onWorkspace: workspace).sorted().compactMap { windows[$0] }
            .filter { !cache.floatingWindowIDs.contains($0.windowID) }
    }

    func treeIDs(_ workspace: Int) -> Set<CGWindowID> {
        screens.reduce(into: Set<CGWindowID>()) { ids, screen in
            ids.formUnion(engine.existingTree(forWorkspace: workspace, screen: screen)?
                .allWindows.map(\.windowID) ?? [])
        }
    }

    /// what the app's retile does for every screen
    func retileVisible() {
        for screen in screens {
            let ws = workspaceManager.workspaceForScreen(screen)
            engine.tileWindows(assigned(ws), onWorkspace: ws, screen: screen)
        }
    }
}

private func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

final class WorkspaceFollowTests: XCTestCase {

    private var rig: FollowRig!

    override func setUp() {
        rig = FollowRig()
    }

    /// a tiled window on screen 0 beside a sibling, whose live frame stays
    /// on screen 0 whatever the layout does; and a tenant on screen 1
    private func seedVisibleMove() -> (mover: StuckWindow, tenant: HyprWindow, destination: Int) {
        let source = rig.visible(on: 0)
        let destination = rig.visible(on: 1)
        let live = CGRect(x: 100, y: 100, width: 600, height: 400)
        let mover = StuckWindow(id: 11, live: live)
        rig.add(11, to: source, window: mover)
        rig.add(12, to: source)
        rig.tile(source)
        let tenant = rig.add(21, to: destination)
        rig.tile(destination)
        rig.focused = mover
        XCTAssertTrue(rig.rect(0).contains(center(live)), "the live frame reads the source screen")
        return (mover, tenant, destination)
    }

    func testAMoveToAVisibleWorkspaceWarpsToTheDestinationSlot() throws {
        let (mover, tenant, destination) = seedVisibleMove()

        rig.orchestrator.moveToWorkspace(destination)

        XCTAssertEqual(rig.workspaceManager.workspaceFor(mover.windowID), destination)
        XCTAssertEqual(rig.treeIDs(destination), [mover.windowID, tenant.windowID])
        let slot = try XCTUnwrap(rig.engine.intendedRect(
            for: mover.windowID, onWorkspace: destination, screen: rig.screens[1]))
        XCTAssertEqual(rig.warps, [center(slot)], "the slot, not the stale live frame")
        XCTAssertTrue(rig.rect(1).contains(rig.warps[0]))
        XCTAssertEqual(rig.focusController.lastFocusedID, mover.windowID)
        XCTAssertEqual(rig.bordered, [mover.windowID])
    }

    func testAMoveWhoseFirstLayoutFailsStillWarpsOntoTheDestinationScreen() {
        let (mover, tenant, destination) = seedVisibleMove()
        rig.ignoresWrites = [mover.windowID]

        rig.orchestrator.moveToWorkspace(destination)

        XCTAssertEqual(rig.workspaceManager.workspaceFor(mover.windowID), destination,
                       "the move stands; recovery owns the layout from here")
        XCTAssertEqual(rig.treeIDs(destination), [tenant.windowID], "no slot to aim at")
        XCTAssertEqual(rig.warps, [center(rig.rect(1))], "the middle of the destination screen")
        XCTAssertEqual(rig.focusController.lastFocusedID, mover.windowID,
                       "ensureFocus keeps the moved window once the cursor is on its screen")
        XCTAssertEqual(rig.bordered, [mover.windowID])
    }

    func testACarriedFloaterWarpsToWhereItWasPut() {
        let source = rig.visible(on: 0)
        let destination = rig.visible(on: 1)
        let live = CGRect(x: 600, y: 300, width: 800, height: 500)
        let mover = StuckWindow(id: 11, live: live)
        rig.add(11, to: source, floating: true, window: mover)
        rig.focused = mover

        rig.orchestrator.moveToWorkspace(destination)

        // carried with its relative position: same spot, one screen over,
        // so its middle is (3400, 550). the live frame never moved.
        XCTAssertEqual(rig.workspaceManager.workspaceFor(mover.windowID), destination)
        XCTAssertEqual(rig.warps.count, 1)
        XCTAssertEqual(rig.warps.first?.x ?? 0, 3400, accuracy: 0.01)
        XCTAssertEqual(rig.warps.first?.y ?? 0, 550, accuracy: 0.01)
        XCTAssertEqual(rig.focusController.lastFocusedID, mover.windowID)
    }

    // MARK: - move and follow

    /// a tiled window on screen 0 beside a sibling, both laid out
    private func seedSource() -> (mover: HyprWindow, sibling: HyprWindow, source: Int) {
        let source = rig.visible(on: 0)
        let mover = rig.add(11, to: source)
        let sibling = rig.add(12, to: source)
        rig.tile(source)
        rig.focused = mover
        return (mover, sibling, source)
    }

    func testASilentMoveToAHiddenWorkspaceStaysOnTheSource() {
        let (mover, sibling, source) = seedSource()
        let destination = rig.hidden(on: 0)

        rig.orchestrator.moveToWorkspace(destination)

        XCTAssertEqual(rig.workspaceManager.workspaceFor(mover.windowID), destination)
        XCTAssertEqual(rig.visible(on: 0), source)
        XCTAssertTrue(rig.announced.isEmpty)
        XCTAssertEqual(rig.focusController.lastFocusedID, sibling.windowID)
        XCTAssertEqual(rig.bordered, [sibling.windowID])
        XCTAssertTrue(rig.warps.isEmpty)
    }

    func testFollowToAHiddenWorkspaceOnTheSameScreenSwitchesWithTheWindowFocused() throws {
        let (mover, sibling, source) = seedSource()
        let destination = rig.hidden(on: 0)
        let siblingFrame = rig.frames[sibling.windowID]

        rig.orchestrator.moveToWorkspace(destination, follow: true)

        XCTAssertEqual(rig.workspaceManager.workspaceFor(mover.windowID), destination)
        XCTAssertEqual(rig.visible(on: 0), destination)
        XCTAssertEqual(rig.announced, ["will:\(destination)@Follow 0", "did:\(destination)@Follow 0"])
        XCTAssertEqual(rig.treeIDs(destination), [mover.windowID])
        XCTAssertEqual(rig.treeIDs(source), [sibling.windowID])
        XCTAssertEqual(rig.focusController.lastFocusedID, mover.windowID)
        XCTAssertEqual(rig.bordered, [mover.windowID], "focus never goes back to the source")
        XCTAssertEqual(rig.frames[sibling.windowID], siblingFrame,
                       "the source is hidden as it stood, not laid out again first")
        let slot = try XCTUnwrap(rig.engine.intendedRect(
            for: mover.windowID, onWorkspace: destination, screen: rig.screens[0]))
        XCTAssertEqual(rig.warps, [center(slot)])
    }

    func testFollowToAHiddenWorkspaceOnTheOtherScreenLeavesTheSourceShowing() throws {
        let (mover, sibling, source) = seedSource()
        let destination = rig.hidden(on: 1)
        let siblingWidth = try XCTUnwrap(rig.frames[sibling.windowID]?.width)

        rig.orchestrator.moveToWorkspace(destination, follow: true)

        XCTAssertEqual(rig.visible(on: 1), destination)
        XCTAssertEqual(rig.visible(on: 0), source, "the source monitor keeps its workspace")
        XCTAssertEqual(rig.announced, ["will:\(destination)@Follow 1", "did:\(destination)@Follow 1"])
        XCTAssertEqual(rig.treeIDs(destination), [mover.windowID])
        let moverFrame = try XCTUnwrap(rig.frames[mover.windowID])
        XCTAssertTrue(rig.rect(1).contains(center(moverFrame)), "laid out on the destination screen")
        XCTAssertEqual(rig.treeIDs(source), [sibling.windowID])
        XCTAssertGreaterThan(try XCTUnwrap(rig.frames[sibling.windowID]?.width), siblingWidth,
                             "the sibling fills the gap in the same pass")
        XCTAssertEqual(rig.focusController.lastFocusedID, mover.windowID)
        XCTAssertEqual(rig.bordered, [mover.windowID])
        let slot = try XCTUnwrap(rig.engine.intendedRect(
            for: mover.windowID, onWorkspace: destination, screen: rig.screens[1]))
        XCTAssertEqual(rig.warps, [center(slot)])
    }

    func testFollowWhoseFirstLayoutFailsStillLandsTheCursorOnTheDestination() {
        let source = rig.visible(on: 0)
        let mover = StuckWindow(id: 11, live: CGRect(x: 100, y: 100, width: 600, height: 400))
        rig.add(11, to: source, window: mover)
        rig.add(12, to: source)
        rig.tile(source)
        rig.focused = mover
        rig.ignoresWrites = [mover.windowID]
        let destination = rig.hidden(on: 1)

        rig.orchestrator.moveToWorkspace(destination, follow: true)

        XCTAssertEqual(rig.visible(on: 1), destination)
        XCTAssertEqual(rig.workspaceManager.workspaceFor(mover.windowID), destination)
        XCTAssertTrue(rig.treeIDs(destination).isEmpty, "no slot to aim at")
        XCTAssertEqual(rig.warps, [center(rig.rect(1))], "not the live frame on screen 0")
        XCTAssertEqual(rig.focusController.lastFocusedID, mover.windowID)
    }

    func testFollowToAWorkspaceShowingOnTheOtherScreenFocusesItWithoutASwitch() {
        let (mover, _, source) = seedSource()
        let destination = rig.visible(on: 1)
        let tenant = rig.add(21, to: destination)
        rig.tile(destination)

        rig.orchestrator.moveToWorkspace(destination, follow: true)

        XCTAssertEqual(rig.workspaceManager.workspaceFor(mover.windowID), destination)
        XCTAssertEqual(rig.visible(on: 0), source)
        XCTAssertEqual(rig.visible(on: 1), destination)
        XCTAssertTrue(rig.announced.isEmpty, "already showing, as with the silent move")
        XCTAssertEqual(rig.treeIDs(destination), [mover.windowID, tenant.windowID])
        XCTAssertEqual(rig.focusController.lastFocusedID, mover.windowID)
        XCTAssertEqual(rig.bordered, [mover.windowID])
        XCTAssertEqual(rig.warps.count, 1)
        XCTAssertTrue(rig.rect(1).contains(rig.warps.first ?? .zero))
    }

    func testARefusedFollowDoesNotSwitch() {
        let (mover, _, source) = seedSource()
        let destination = rig.hidden(on: 0)
        // one tile per workspace, and the destination already holds one
        rig.engine.maxSplitsPerMonitor = ["Follow 0": 0]
        rig.add(31, to: destination)

        rig.orchestrator.moveToWorkspace(destination, follow: true)

        XCTAssertEqual(rig.workspaceManager.workspaceFor(mover.windowID), source)
        XCTAssertEqual(rig.visible(on: 0), source)
        XCTAssertTrue(rig.announced.isEmpty)
        XCTAssertTrue(rig.bordered.isEmpty)
        XCTAssertTrue(rig.warps.isEmpty)
        XCTAssertEqual(rig.focusController.lastFocusedID, 0)
    }

    func testAFloatingWindowFollowsAndStaysFloating() {
        let source = rig.visible(on: 0)
        let mover = rig.add(11, to: source, floating: true)
        rig.add(12, to: source)
        rig.tile(source)
        rig.focused = mover
        let destination = rig.hidden(on: 0)

        rig.orchestrator.moveToWorkspace(destination, follow: true)

        XCTAssertEqual(rig.workspaceManager.workspaceFor(mover.windowID), destination)
        XCTAssertEqual(rig.visible(on: 0), destination)
        XCTAssertTrue(rig.cache.floatingWindowIDs.contains(mover.windowID))
        XCTAssertTrue(rig.treeIDs(destination).isEmpty, "a floater joins no tree")
        XCTAssertEqual(rig.focusController.lastFocusedID, mover.windowID)
        XCTAssertEqual(rig.bordered, [mover.windowID])
    }

    func testAQuickLookPreviewFollowsToTheOtherScreenAsAFloater() {
        let source = rig.visible(on: 0)
        let preview = StuckWindow(id: 11, live: CGRect(x: 600, y: 300, width: 800, height: 500))
        preview.isQuickLookPanel = true
        rig.add(11, to: source, floating: true, window: preview)
        rig.focused = preview
        let destination = rig.hidden(on: 1)

        rig.orchestrator.moveToWorkspace(destination, follow: true)

        XCTAssertEqual(rig.workspaceManager.workspaceFor(preview.windowID), destination)
        XCTAssertEqual(rig.visible(on: 1), destination)
        XCTAssertTrue(rig.cache.floatingWindowIDs.contains(preview.windowID))
        XCTAssertTrue(rig.treeIDs(destination).isEmpty)
        XCTAssertEqual(rig.focusController.lastFocusedID, preview.windowID)
        // carried to the same spot one screen over, middle (3400, 550), while
        // the live frame still reads screen 0
        XCTAssertEqual(rig.warps.count, 1)
        XCTAssertEqual(rig.warps.first?.x ?? 0, 3400, accuracy: 0.01)
        XCTAssertEqual(rig.warps.first?.y ?? 0, 550, accuracy: 0.01)
    }

    func testMoveAndFollowIsHandledLikeAMove() {
        let action = Action.moveToWorkspaceAndFollow(3)
        XCTAssertEqual(ActionDispatcher.discriminator(for: action), "moveToWorkspaceAndFollow")
        XCTAssertEqual(KeybindCategory.from(action), .workspaces)
        XCTAssertTrue(WindowManager.isDroppedMidDisplayTransition(action))
        XCTAssertTrue(WindowManager.cancelsPendingRecovery(action))
    }
}
