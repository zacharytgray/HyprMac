import Cocoa
import XCTest
@testable import HyprMac

// a resume from Pause keeps the desk: workspace assignments, floats and hand
// choices stay, a window opened while paused goes to the active workspace,
// windows of hidden workspaces go back to the park corner, and nothing is
// reassigned while a full-screen Space hides the desktop. the launch and
// Retile All keep the full redistribute.
//
// the resume here runs the same steps WindowManager runs after start():
// prepareResume, then the ordinary poll (computeChanges, applyChanges), then
// the retile of the visible workspace.
final class ResumeFromPauseTests: XCTestCase {

    func testResumeKeepsEveryWorkspaceAssignment() {
        let h = ResumeHarness()
        let before = h.workspaces.allWindowWorkspaces()
        h.pause()

        let changes = h.resume(walk: h.allWindows)

        XCTAssertEqual(h.workspaces.allWindowWorkspaces(), before)
        XCTAssertTrue(changes.newWindows.isEmpty)
        XCTAssertTrue(changes.goneIDs.isEmpty)
        XCTAssertEqual(h.treeMembers(1), [10, 11])
        XCTAssertEqual(h.treeMembers(2), [20])
        XCTAssertEqual(h.treeMembers(3), [30, 31])
    }

    func testResumeKeepsAManualFloatAndItsFrame() {
        let h = ResumeHarness()
        h.pause()
        // moved while paused, where stop() put it
        let moved = CGRect(x: 300, y: 200, width: 500, height: 400)
        h.window(21).storedFrame = moved

        _ = h.resume(walk: h.allWindows)

        XCTAssertTrue(h.cache.floatingWindowIDs.contains(21))
        XCTAssertTrue(h.window(21).isFloating)
        XCTAssertEqual(h.floating.manualChoice(for: 21), true)
        XCTAssertEqual(h.workspaces.workspaceFor(21), 2)
        XCTAssertEqual(h.workspaces.savedFloatingFrame(for: 21), moved,
                       "its next reveal puts it where it stood")
    }

    func testAWindowOpenedWhilePausedGoesToTheActiveWorkspace() {
        let h = ResumeHarness()
        h.pause()
        let opened = ResumeWindow(id: 40, frame: CGRect(x: 400, y: 300, width: 600, height: 400))

        let changes = h.resume(walk: h.allWindows + [opened])

        XCTAssertEqual(changes.newWindows.map(\.windowID), [40])
        XCTAssertEqual(h.workspaces.workspaceFor(40), 3)
        XCTAssertEqual(h.treeMembers(3), [30, 31, 40])
        XCTAssertEqual(h.workspaces.workspaceFor(10), 1, "the rest stay put")
        XCTAssertEqual(h.workspaces.workspaceFor(20), 2)
    }

    func testAWindowClosedWhilePausedIsDropped() {
        let h = ResumeHarness()
        h.pause()

        let changes = h.resume(walk: h.allWindows.filter { $0.windowID != 31 })

        XCTAssertEqual(changes.goneIDs, [31])
        XCTAssertEqual(h.treeMembers(3), [30])
        XCTAssertEqual(h.workspaces.workspaceFor(30), 3)
    }

    func testResumeParksEveryWindowOfAHiddenWorkspaceAgain() {
        let h = ResumeHarness()
        h.pause()

        _ = h.resume(walk: h.allWindows)

        let corner = h.workspaces.hidePosition()
        for id: CGWindowID in [10, 11, 20, 21] {
            XCTAssertEqual(h.window(id).positionWrites.last, corner, "\(id) parked")
        }
        for id: CGWindowID in [30, 31] {
            XCTAssertTrue(h.window(id).positionWrites.isEmpty, "\(id) is on the visible workspace")
        }
    }

    // the MacBook log: a video in native full screen during the pause and the
    // resume. the walk listed only the video, and the redistribute moved the
    // ws1/ws2 windows onto the visible workspace
    func testResumeBehindAFullScreenSpaceReassignsNothing() {
        let h = ResumeHarness()
        let before = h.workspaces.allWindowWorkspaces()
        h.pause()
        let offSpace: Set<CGWindowID> = [10, 11, 20, 21, 30]
        h.discovery.windowSpaces = { ids in
            SpaceAnswers(offSpace: Dictionary(uniqueKeysWithValues: ids.intersection(offSpace)
                .map { ($0, .behindFullScreen) }), answered: ids)
        }
        let video = h.window(31)
        video.storedFrame = CGRect(x: 0, y: 0, width: 1600, height: 1000)

        let changes = h.resume(walk: [video])

        XCTAssertEqual(h.workspaces.allWindowWorkspaces(), before)
        XCTAssertTrue(changes.goneIDs.isEmpty)
        XCTAssertTrue(h.cache.hiddenWindowIDs.isEmpty)
        XCTAssertEqual(h.discovery.heldWindowIDs, offSpace)
        XCTAssertEqual(h.treeMembers(3), [30, 31], "the off-Space tile keeps its leaf")
        XCTAssertTrue(h.cache.floatingWindowIDs.contains(21))
        for id in offSpace {
            XCTAssertTrue(h.window(id).positionWrites.isEmpty, "\(id) is not in the walk, nothing is written")
        }
    }

    // what the launch and Retile All still do with the same walk: the full
    // redistribute claims the off-Space members and un-floats the manual float
    func testTheFullRedistributeStillRewritesTheDesk() {
        let h = ResumeHarness()
        let before = h.workspaces.allWindowWorkspaces()
        let video = h.window(31)

        h.placement.distributeWindowsAcrossWorkspaces([video, h.window(21)])

        XCTAssertNotEqual(h.workspaces.allWindowWorkspaces(), before)
        XCTAssertFalse(h.cache.floatingWindowIDs.contains(21))
    }
}

/// one screen showing ws3. ws1 holds 10 and 11, ws2 holds 20 and the manual
/// float 21, ws3 holds 30 and 31. all parked but ws3's, as before a pause
private final class ResumeHarness {
    let screen = ResumeTestScreen()
    let workspaces: WorkspaceManager
    let engine: TilingEngine
    let cache = WindowStateCache()
    let floating: FloatingWindowController
    let dispatcher: ActionDispatcher
    let placement: WindowPlacement
    let discovery: WindowDiscoveryService
    private(set) var allWindows: [ResumeWindow] = []
    private let configDir: URL
    static let pid: pid_t = 8600

    init() {
        let screen = self.screen
        let display = DisplayManager(screenSource: { [screen] })
        workspaces = WorkspaceManager(displayManager: display)
        workspaces.initializeMonitors()
        _ = workspaces.switchWorkspace(3, cursorScreen: screen)
        engine = TilingEngine(displayManager: display, frameSizingIOFactory: acceptingFrameSizingIOFactory())
        configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResumeHarness-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let config = UserConfig(store: ConfigStore(
            localConfigURL: configDir.appendingPathComponent("config.json"),
            monitorConfigURL: configDir.appendingPathComponent("monitor-config.json"),
            iCloudRootURL: configDir.appendingPathComponent("cloud", isDirectory: true)))

        let suppressions = SuppressionRegistry()
        let border = FocusBorder()
        let focus = FocusStateController(focusBorder: border)
        let dimming = DimmingOverlay()
        let accessibility = StubAccessibility()
        accessibility.stateAnswer = .absent
        let cursor = CursorManager()
        let orchestrator = WorkspaceOrchestrator(
            workspaceManager: workspaces, tilingEngine: engine,
            accessibility: accessibility, displayManager: display,
            cursorManager: cursor, stateCache: cache,
            focusController: focus, focusBorder: border,
            dimmingOverlay: dimming, suppressions: suppressions,
            revalidation: MinimaRevalidation())
        floating = FloatingWindowController(
            stateCache: cache, suppressions: suppressions,
            workspaceManager: workspaces, tilingEngine: engine,
            displayManager: display, accessibility: accessibility,
            cursorManager: cursor, focusController: focus,
            focusBorder: border, dimmingOverlay: dimming)
        dispatcher = ActionDispatcher(
            stateCache: cache, accessibility: accessibility,
            displayManager: display, cursorManager: cursor,
            workspaceManager: workspaces, tilingEngine: engine,
            focusController: focus, focusBorder: border,
            keybindOverlay: KeybindOverlayController(), appLauncher: AppLauncherManager(),
            workspaceOrchestrator: orchestrator, floatingController: floating,
            config: config)
        placement = WindowPlacement(
            config: config, accessibility: accessibility, displayManager: display,
            workspaceManager: workspaces, tilingEngine: engine, stateCache: cache,
            floatingController: floating,
            scratchpad: ScratchpadController(
                workspaceManager: workspaces, stateCache: cache, accessibility: accessibility,
                displayManager: display, tilingEngine: engine, focusController: focus,
                focusBorder: border, suppressions: suppressions),
            actionDispatcher: dispatcher, workspaceOrchestrator: orchestrator)
        discovery = WindowDiscoveryService(
            stateCache: cache, accessibility: accessibility, displayManager: display,
            workspaceManager: workspaces, bundleIDForPID: { _ in nil },
            isWindowSizeSettable: { _ in true })
        discovery.onScreenWindows = { [] }
        discovery.windowSpaces = { ids in SpaceAnswers(answered: ids) }
        dispatcher.screenUnderCursor = { screen }
        dispatcher.isMenuTracking = { true }
        // as WindowManager wires it: a held member keeps its leaf
        engine.heldWindowIDsSource = { [unowned self] in
            discovery.heldWindowIDs.subtracting(cache.floatingWindowIDs).subtracting(cache.hiddenWindowIDs)
        }

        let tile = CGRect(x: 100, y: 100, width: 600, height: 400)
        for (id, ws) in [(10, 1), (11, 1), (20, 2), (21, 2), (30, 3), (31, 3)] as [(CGWindowID, Int)] {
            let w = ResumeWindow(id: id, frame: tile)
            allWindows.append(w)
            cache.knownWindowIDs.insert(id)
            cache.windowOwners[id] = Self.pid
            cache.cachedWindows[id] = w
            workspaces.assignWindow(id, toWorkspace: ws)
        }
        // hypr+t floated 21 before its workspace was hidden
        cache.setFloating(true, window: window(21))
        floating.noteManualChoice(21, floating: true)
        workspaces.setSavedFloatingFrame(CGRect(x: 250, y: 150, width: 500, height: 400), for: 21)
        engine.tileWindows([window(10), window(11)], onWorkspace: 1, screen: screen)
        engine.tileWindows([window(20)], onWorkspace: 2, screen: screen)
        engine.tileWindows([window(30), window(31)], onWorkspace: 3, screen: screen)
        for w in allWindows where workspaces.workspaceFor(w.windowID) != 3 {
            w.storedFrame.origin = workspaces.hidePosition()
        }
        allWindows.forEach { $0.positionWrites = [] }
    }

    deinit { try? FileManager.default.removeItem(at: configDir) }

    func window(_ id: CGWindowID) -> ResumeWindow {
        allWindows.first { $0.windowID == id }!
    }

    func treeMembers(_ workspace: Int) -> [CGWindowID] {
        engine.windowIDs(inTreeForWorkspace: workspace, screen: screen).sorted()
    }

    /// what stop() leaves: every hidden-workspace window back on screen, the
    /// float at its saved frame
    func pause() {
        for w in allWindows where workspaces.workspaceFor(w.windowID) != 3 {
            w.storedFrame = workspaces.savedFloatingFrame(for: w.windowID)
                ?? CGRect(x: 50, y: 50, width: 600, height: 400)
        }
    }

    /// WindowManager's resume: prepare, one ordinary poll, the retile
    @discardableResult
    func resume(walk: [ResumeWindow]) -> WindowChanges {
        placement.prepareResume(walk)
        let changes = discovery.computeChanges(snapshot: walk, runningPIDs: [Self.pid],
                                               excludedBundleIDs: [], focusedWindowID: 0)
        _ = dispatcher.applyChanges(changes, allWindows: walk, cursorPlacement: .reconcilePoll)
        let visible = walk.filter { workspaces.workspaceFor($0.windowID) == 3 }
        engine.tileWindows(visible, onWorkspace: 3, screen: screen)
        return changes
    }
}

/// reads the frame it was given and records every park write
private final class ResumeWindow: HyprWindow {
    var storedFrame: CGRect
    var positionWrites: [CGPoint] = []
    init(id: CGWindowID, frame: CGRect) {
        storedFrame = frame
        super.init(element: AXUIElementCreateApplication(ResumeHarness.pid), windowID: id,
                   ownerPID: ResumeHarness.pid)
    }
    override func readPosition() -> (AXError, CGPoint?) { (.success, storedFrame.origin) }
    override func readSize() -> (AXError, CGSize?) { (.success, storedFrame.size) }
    override func setPositionOnly(_ point: CGPoint) -> AXError {
        positionWrites.append(point)
        storedFrame.origin = point
        return .success
    }
}

private final class ResumeTestScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 1600, height: 1000) }
    override var visibleFrame: NSRect { frame }
    override var localizedName: String { "resume-test" }
}
