import Cocoa
import XCTest
@testable import HyprMac

// issue #19, claim 2: an ordinary Hypr+Shift+N onto a workspace that is on
// screen on another display. the move reassigns the window and drops it from
// the source tree first; the retile that follows is where the destination's
// candidate fails, the way ghostty settled 1366x1136 against a 1394 target
// after a 2x -> 1x hop. the window's captured original is still on the
// source screen, outside the destination's restoration rect.

/// DELL-shaped primary on the left, a built-in-shaped screen on the right.
/// the scale factor is not modelled; the engine only sees points.
private final class HopScreen: NSScreen {
    private let bounds: NSRect
    private let menuBar: CGFloat
    private let name: String

    init(x: CGFloat, width: CGFloat, height: CGFloat, menuBar: CGFloat, name: String) {
        bounds = NSRect(x: x, y: 0, width: width, height: height)
        self.menuBar = menuBar
        self.name = name
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var frame: NSRect { bounds }
    override var visibleFrame: NSRect {
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height - menuBar)
    }
    override var localizedName: String { name }
}

/// Frame i/o across two screens. A window whose position write lands it on
/// another screen settles `hopShortfall` points short on every size write
/// in that same batch, like a terminal re-quantizing to the new backing
/// scale after the resize already went out. Its next batch lands. A
/// window with a `heightCap` never grows past it, whatever the ask.
private final class HopTrace {
    var frames: [CGWindowID: CGRect] = [:]
    var screens: [CGRect] = []
    var hopShortfall: [CGWindowID: CGFloat] = [:]
    var heightCap: [CGWindowID: CGFloat] = [:]
    var failNextSizeWriteID: CGWindowID?
    private var hopped: Set<CGWindowID> = []
    private var now: TimeInterval = 0

    private func screenIndex(of point: CGPoint) -> Int? {
        screens.firstIndex { $0.contains(point) }
    }

    func io(_ generation: @escaping () -> UInt64) -> FrameSizingIO {
        var io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { [self] id, size, _ in
                if failNextSizeWriteID == id {
                    failNextSizeWriteID = nil
                    return .cannotComplete
                }
                var height = size.height - (hopped.contains(id) ? hopShortfall[id] ?? 0 : 0)
                if let cap = heightCap[id] { height = min(height, cap) }
                frames[id]?.size = CGSize(width: size.width, height: height)
                return .success
            },
            writePosition: { [self] id, position, _ in
                if let old = frames[id]?.origin, screenIndex(of: old) != screenIndex(of: position) {
                    hopped.insert(id)
                }
                frames[id]?.origin = position
                return .success
            },
            readPosition: { [self] id, _ in (.success, frames[id]?.origin) },
            readSize: { [self] id, _ in (.success, frames[id]?.size) },
            now: { [self] in now }, sleep: { [self] in now += $0 },
            currentGeneration: generation)
        // a new batch is a new write: the app has settled on its new screen
        io.beginFrameWrite = { [self] id, _, _ in
            hopped.remove(id)
            return .ready(.noop(windowID: id))
        }
        return io
    }
}

private final class HopRig {
    let dell = HopScreen(x: 0, width: 3440, height: 1440, menuBar: 30, name: "DELL U3423WE")
    let builtIn = HopScreen(x: 3440, width: 1512, height: 982, menuBar: 38, name: "Built-in Retina Display")
    let displayManager: DisplayManager
    let workspaceManager: WorkspaceManager
    let engine: TilingEngine
    let trace = HopTrace()
    var windows: [CGWindowID: HyprWindow] = [:]

    init() {
        let screens: [NSScreen] = [dell, builtIn]
        displayManager = DisplayManager(screenSource: { screens })
        workspaceManager = WorkspaceManager(displayManager: displayManager)
        workspaceManager.initializeMonitors()
        let trace = trace
        engine = TilingEngine(displayManager: displayManager,
                              frameSizingIOFactory: { _, generation in trace.io(generation) })
        trace.screens = screens.map { displayManager.cgRect(for: $0) }
    }

    var dellRect: CGRect { displayManager.cgRect(for: dell) }
    var builtInRect: CGRect { displayManager.cgRect(for: builtIn) }

    /// a window standing somewhere on `rect`, assigned to `workspace`
    @discardableResult
    func window(_ id: CGWindowID, on rect: CGRect, workspace: Int) -> HyprWindow {
        let window = makeWindow(id: id)
        trace.frames[id] = CGRect(x: rect.minX + 40, y: rect.minY + 40, width: 600, height: 500)
        windows[id] = window
        workspaceManager.assignWindow(id, toWorkspace: workspace)
        return window
    }

    func assigned(_ workspace: Int) -> [HyprWindow] {
        workspaceManager.windowIDs(onWorkspace: workspace).sorted().compactMap { windows[$0] }
    }

    func treeIDs(_ workspace: Int, _ screen: NSScreen) -> Set<CGWindowID> {
        Set(engine.existingTree(forWorkspace: workspace, screen: screen)?.allWindows.map(\.windowID) ?? [])
    }
}

final class CrossMonitorArrivalEngineTests: XCTestCase {
    private var rig: HopRig!
    private var incumbent: HyprWindow!
    private var mover: HyprWindow!
    private var incumbentOriginal: CGRect!

    override func setUp() {
        rig = HopRig()
        // Dia tiled alone on the DELL's workspace, Ghostty on the built-in
        incumbent = rig.window(115, on: rig.dellRect, workspace: 1)
        XCTAssertTrue(rig.engine.tileWindows([incumbent], onWorkspace: 1, screen: rig.dell).published)
        incumbentOriginal = rig.trace.frames[115]
        mover = rig.window(74, on: rig.builtInRect, workspace: 2)
        // 1394 target, 1136 readback
        rig.trace.hopShortfall[74] = 258
    }

    /// what the retile after an ordinary move asks for: the destination's
    /// tenants plus the mover, with no reach back to the source screen
    private func arrive() -> TilingEngine.AdmissionResult {
        rig.engine.tileWindows([incumbent, mover], onWorkspace: 1, screen: rig.dell)
    }

    func testAnArrivalThatSettlesShortPutsTheIncumbentBackAndLeavesTheMoverOnTheDestination() {
        let result = arrive()

        XCTAssertFalse(result.published)
        XCTAssertEqual(result.strandedIDs, [74], "the mover is stranded for the recovery, not orphaned")
        XCTAssertEqual(result.restoredIDs, [115], "the incumbent's rollback runs and verifies")
        XCTAssertEqual(rig.trace.frames[115], incumbentOriginal,
                       "the incumbent is back on its original, not the failed candidate's half")
        let moverFrame = rig.trace.frames[74]!
        XCTAssertTrue(rig.dellRect.contains(moverFrame),
                      "the mover stays on the screen it was moved to: \(moverFrame)")
        XCTAssertEqual(rig.treeIDs(1, rig.dell), [115])
        XCTAssertTrue(rig.engine.clearUnverifiedGeometry(forWorkspace: 1, screen: rig.dell),
                      "every attempt on the key put its incumbents back")
    }

    func testAWriteFailureBeforeTheMoverIsReachedStillPutsTheIncumbentBack() {
        rig.trace.failNextSizeWriteID = 115
        let moverOriginal = rig.trace.frames[74]

        let result = arrive()

        XCTAssertFalse(result.published)
        XCTAssertEqual(result.strandedIDs, [74])
        XCTAssertEqual(result.restoredIDs, [115])
        XCTAssertEqual(rig.trace.frames[115], incumbentOriginal)
        XCTAssertEqual(rig.trace.frames[74], moverOriginal, "nothing wrote the mover, so nothing moved it")
    }

    func testTheSettleRetryTilesTheMoverOnceItStandsOnTheDestination() throws {
        let first = arrive()
        XCTAssertEqual(first.strandedIDs, [74])

        // what AdmissionRecovery.attempt runs about 250 ms later
        let retry = rig.engine.retryAdmission([incumbent, mover], onWorkspace: 1, screen: rig.dell,
                                              bypassingMinimaBefore: [74: first.generation],
                                              refusingImpossibleArrangements: true)

        XCTAssertTrue(retry.published)
        XCTAssertEqual(rig.treeIDs(1, rig.dell), [115, 74])
        let tiles = try XCTUnwrap(rig.engine.existingTree(forWorkspace: 1, screen: rig.dell))
            .layout(in: rig.dellRect, gap: rig.engine.gapSize, padding: rig.engine.outerPadding)
        for (window, tile) in tiles {
            XCTAssertEqual(rig.trace.frames[window.windowID], tile, "\(window.windowID)")
        }
    }

    func testAMoverThatNeverTakesItsTileEndsOnTheDestinationWithTheIncumbentBack() {
        rig.trace.heightCap[74] = 1136
        let first = arrive()
        let afterFirst = rig.trace.frames[74]!

        let retry = rig.engine.retryAdmission([incumbent, mover], onWorkspace: 1, screen: rig.dell,
                                              bypassingMinimaBefore: [74: first.generation],
                                              refusingImpossibleArrangements: true)

        XCTAssertFalse(retry.published)
        XCTAssertEqual(retry.strandedIDs, [74], "the recovery floats it in place from here")
        XCTAssertEqual(rig.trace.frames[115], incumbentOriginal)
        XCTAssertEqual(rig.trace.frames[74], afterFirst,
                       "the retry's rollback puts the mover back where the first pass left it")
        XCTAssertTrue(rig.dellRect.contains(rig.trace.frames[74]!))
        XCTAssertTrue(rig.engine.clearUnverifiedGeometry(forWorkspace: 1, screen: rig.dell))
    }

    func testWithTheReachTheMoverStillGoesBackToTheScreenItCameFrom() {
        // the layout-first paths (revalidation, batch restore) have not
        // reassigned the window yet, so the rollback must take it home.
        // no hop here: a rollback back across the scale boundary is a hop
        // of its own, and this is only about who the rollback targets
        rig.trace.hopShortfall = [:]
        rig.trace.failNextSizeWriteID = 74
        let moverOriginal = rig.trace.frames[74]

        let result = rig.engine.tileWindows([incumbent, mover], onWorkspace: 1, screen: rig.dell,
                                            alsoRestoringWithin: rig.builtInRect)

        XCTAssertFalse(result.published)
        XCTAssertEqual(result.restoredIDs, [115, 74])
        XCTAssertEqual(rig.trace.frames[115], incumbentOriginal)
        XCTAssertEqual(rig.trace.frames[74], moverOriginal)
    }
}

/// The whole ordinary move: reassignment, the per-screen admission pass the
/// app runs after it, and the bounded recovery, with the recovery's timer in
/// the test's hands.
final class CrossMonitorMoveRecoveryTests: XCTestCase {
    private var rig: HopRig!
    private var recovery: AdmissionRecovery!
    private var scheduled: [() -> Void] = []
    private var floated: [CGWindowID] = []
    private var floating: Set<CGWindowID> = []
    private var incumbentOriginal: CGRect!

    override func setUp() {
        rig = HopRig()
        recovery = AdmissionRecovery()
        wire()
        XCTAssertEqual(rig.workspaceManager.workspaceForScreen(rig.dell), 1)
        XCTAssertEqual(rig.workspaceManager.workspaceForScreen(rig.builtIn), 2)
        rig.window(115, on: rig.dellRect, workspace: 1)
        rig.window(74, on: rig.builtInRect, workspace: 2)
        retileVisible()
        XCTAssertEqual(rig.treeIDs(1, rig.dell), [115])
        XCTAssertEqual(rig.treeIDs(2, rig.builtIn), [74])
        incumbentOriginal = rig.trace.frames[115]
    }

    private func wire() {
        let rig = rig!
        recovery.schedule = { [unowned self] _, body in scheduled.append(body) }
        recovery.workspaceFor = { rig.workspaceManager.workspaceFor($0) }
        recovery.homeScreenForWorkspace = { rig.workspaceManager.homeScreenForWorkspace($0) }
        recovery.isWorkspaceVisible = { rig.workspaceManager.isWorkspaceVisible($0) }
        recovery.isFloating = { [unowned self] in floating.contains($0) }
        recovery.liveWindow = { rig.windows[$0] }
        recovery.isReadable = { rig.trace.frames[$0.windowID] != nil }
        recovery.attempt = { [unowned self] workspace, screen, bypass in
            let result = rig.engine.retryAdmission(tileable(workspace), onWorkspace: workspace,
                                                   screen: screen, bypassingMinimaBefore: bypass,
                                                   refusingImpossibleArrangements: true)
            return AdmissionRecovery.AttemptResult(placed: result.publishedIDs.intersection(bypass.keys),
                                                   failure: result.failure, admission: result)
        }
        recovery.floatInPlace = { [unowned self] window, _ in
            floating.insert(window.windowID)
            window.isFloating = true
            floated.append(window.windowID)
        }
        recovery.clearUnverified = { rig.engine.clearUnverifiedGeometry(forWorkspace: $0, screen: $1) }
        recovery.retileAfterFallback = { [unowned self] workspace, screen in
            let windows = tileable(workspace)
            let result = rig.engine.tileWindows(windows, onWorkspace: workspace, screen: screen)
            return Set(windows.filter { !$0.isFloating && !result.publishedIDs.contains($0.windowID) }
                .map(\.windowID))
        }
    }

    private func tileable(_ workspace: Int) -> [HyprWindow] {
        rig.assigned(workspace).map { window in
            window.isFloating = floating.contains(window.windowID)
            return window
        }
    }

    /// WindowManager.tileAllVisibleSpaces: one admission pass per screen
    private func retileVisible() {
        let pass = AdmissionPass(engine: rig.engine, revalidation: MinimaRevalidation(), recovery: recovery)
        for screen in [rig.dell, rig.builtIn] {
            let workspace = rig.workspaceManager.workspaceForScreen(screen)
            pass.run(tileable(workspace), onWorkspace: workspace, screen: screen)
        }
    }

    /// WorkspaceOrchestrator.moveToWorkspace for a visible destination: the
    /// window leaves its source tree, is reassigned, and the retile follows
    private func moveGhosttyToTheDell() {
        let mover = rig.windows[74]!
        rig.engine.removeWindow(mover, fromWorkspace: 2)
        rig.workspaceManager.moveWindow(74, toWorkspace: 1)
        retileVisible()
    }

    private func fire() {
        let pending = scheduled
        scheduled = []
        for body in pending { body() }
    }

    func testAMoveWhoseFirstLayoutFailsIsTiledOnTheDestinationByTheRetry() {
        rig.trace.hopShortfall[74] = 258

        moveGhosttyToTheDell()

        XCTAssertEqual(rig.workspaceManager.workspaceFor(74), 1)
        XCTAssertEqual(recovery.pendingWindowIDs, [74], "the stranded mover has a recovery scheduled")
        XCTAssertEqual(rig.trace.frames[115], incumbentOriginal)
        XCTAssertTrue(rig.dellRect.contains(rig.trace.frames[74]!))

        fire()

        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertTrue(floated.isEmpty)
        XCTAssertEqual(rig.treeIDs(1, rig.dell), [115, 74], "tiled on the destination")
        XCTAssertTrue(rig.treeIDs(2, rig.builtIn).isEmpty)
    }

    func testAWindowThatDriftedAwayIsANewcomerWhenItIsMovedBack() {
        // dragged by mouse onto the DELL: discovery reads drift, reassigns
        // it, and the retile admits it there
        rig.trace.frames[74] = CGRect(x: rig.dellRect.minX + 700, y: rig.dellRect.minY + 40,
                                      width: 600, height: 500)
        rig.workspaceManager.moveWindow(74, toWorkspace: 1)
        retileVisible()
        XCTAssertEqual(rig.treeIDs(1, rig.dell), [115, 74])
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)

        // Hypr+Shift+2 takes it back, and the built-in refuses it once
        rig.trace.hopShortfall[74] = 258
        let mover = rig.windows[74]!
        rig.engine.removeWindow(mover, fromWorkspace: 1)
        rig.workspaceManager.moveWindow(74, toWorkspace: 2)
        retileVisible()

        XCTAssertEqual(recovery.pendingWindowIDs, [74],
                       "leaving workspace 2 by drift ended its incumbency there, so it is stranded, not orphaned")

        fire()

        XCTAssertEqual(rig.treeIDs(2, rig.builtIn), [74])
    }

    func testAMoveThatKeepsFailingFloatsOnTheDestinationNotTheSource() {
        rig.trace.heightCap[74] = 1136

        moveGhosttyToTheDell()
        fire()

        XCTAssertEqual(floated, [74])
        XCTAssertEqual(rig.workspaceManager.workspaceFor(74), 1)
        XCTAssertTrue(rig.dellRect.contains(rig.trace.frames[74]!),
                      "floating where its workspace is shown, so nothing reads it as drift")
        XCTAssertEqual(rig.treeIDs(1, rig.dell), [115])
        XCTAssertEqual(rig.trace.frames[115], incumbentOriginal,
                       "the fallback retile gives the incumbent its whole screen back")
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertTrue(rig.engine.unverifiedLayouts.isEmpty, "every key is back to verified geometry")
    }
}
