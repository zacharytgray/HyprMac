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
/// The engine only sees points. The backing scale is 1 unless a test sets
/// it, and only the sizing budget reads it.
private final class HopScreen: NSScreen {
    private let bounds: NSRect
    private let menuBar: CGFloat
    private let name: String
    private let scale: CGFloat

    init(x: CGFloat, width: CGFloat, height: CGFloat, menuBar: CGFloat, name: String,
         scale: CGFloat = 1) {
        bounds = NSRect(x: x, y: 0, width: width, height: height)
        self.menuBar = menuBar
        self.name = name
        self.scale = scale
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var frame: NSRect { bounds }
    override var visibleFrame: NSRect {
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height - menuBar)
    }
    override var localizedName: String { name }
    override var backingScaleFactor: CGFloat { scale }
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
    /// seconds every AX call on a window costs once its position write has
    /// hopped it to another screen, until its next batch: the app redrawing
    /// at the new scale while our calls wait. each call stays under the
    /// 0.1 s messaging timeout, so none of them fails on its own.
    var hopCallLatency: [CGWindowID: TimeInterval] = [:]
    /// seconds every read of a window costs, always
    var readLatency: [CGWindowID: TimeInterval] = [:]
    /// windows whose height never holds still between reads, like an app
    /// still animating its resize. their readback never settles.
    var jitter: Set<CGWindowID> = []
    private var jitterReads = 0
    private var hopped: Set<CGWindowID> = []
    private(set) var now: TimeInterval = 0

    private func cost(_ id: CGWindowID) {
        if hopped.contains(id) { now += hopCallLatency[id] ?? 0 }
    }

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
                cost(id)
                var height = size.height - (hopped.contains(id) ? hopShortfall[id] ?? 0 : 0)
                if let cap = heightCap[id] { height = min(height, cap) }
                frames[id]?.size = CGSize(width: size.width, height: height)
                return .success
            },
            writePosition: { [self] id, position, _ in
                if let old = frames[id]?.origin, screenIndex(of: old) != screenIndex(of: position) {
                    hopped.insert(id)
                }
                cost(id)
                frames[id]?.origin = position
                return .success
            },
            readPosition: { [self] id, _ in
                cost(id)
                now += readLatency[id] ?? 0
                return (.success, frames[id]?.origin)
            },
            readSize: { [self] id, _ in
                cost(id)
                now += readLatency[id] ?? 0
                guard jitter.contains(id), var size = frames[id]?.size else {
                    return (.success, frames[id]?.size)
                }
                jitterReads += 1
                size.height += CGFloat(jitterReads % 2)
                return (.success, size)
            },
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
    let dell: HopScreen
    let builtIn: HopScreen
    let displayManager: DisplayManager
    let workspaceManager: WorkspaceManager
    let engine: TilingEngine
    let trace = HopTrace()
    var windows: [CGWindowID: HyprWindow] = [:]

    init(dellScale: CGFloat = 1, builtInScale: CGFloat = 1) {
        dell = HopScreen(x: 0, width: 3440, height: 1440, menuBar: 30, name: "DELL U3423WE",
                         scale: dellScale)
        builtIn = HopScreen(x: 3440, width: 1512, height: 982, menuBar: 38,
                            name: "Built-in Retina Display", scale: builtInScale)
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

    // MARK: - an app that does not answer in time

    func testTheLastRetryKeepsATimedOutArrivalTiledAndUnverified() throws {
        // the mover's readback never settles, so every pass runs out of time
        // with its frames sent and nothing verified
        rig.trace.hopShortfall = [:]
        rig.trace.jitter = [74]
        let first = arrive()
        XCTAssertEqual(first.failure.map(\.isTimeout), true, "\(String(describing: first.failure))")
        XCTAssertEqual(first.strandedIDs, [74])

        let kept = rig.engine.retryAdmission([incumbent, mover], onWorkspace: 1, screen: rig.dell,
                                             bypassingMinimaBefore: [74: first.generation],
                                             refusingImpossibleArrangements: true,
                                             keepingUnverifiedOnTimeout: true)

        XCTAssertEqual(kept.failure.map(\.isTimeout), true, "nothing was verified")
        XCTAssertTrue(kept.strandedIDs.isEmpty, "the mover is in the tree")
        XCTAssertEqual(rig.treeIDs(1, rig.dell), [115, 74])
        let mark = try XCTUnwrap(rig.engine.unverifiedLayouts.first { $0.workspace == 1 })
        XCTAssertTrue(mark.windowIDs.isSuperset(of: [115, 74]))
        XCTAssertFalse(rig.engine.clearUnverifiedGeometry(forWorkspace: 1, screen: rig.dell),
                       "only an accepted layout clears the mark")
        let tiles = try XCTUnwrap(rig.engine.existingTree(forWorkspace: 1, screen: rig.dell))
            .layout(in: rig.dellRect, gap: rig.engine.gapSize, padding: rig.engine.outerPadding)
        for (window, tile) in tiles {
            XCTAssertEqual(rig.trace.frames[window.windowID], tile,
                           "no rollback: \(window.windowID) keeps the frame the tree describes")
        }
    }

    func testAnOrdinaryRetryStillRollsBackATimeout() {
        rig.trace.hopShortfall = [:]
        rig.trace.jitter = [74]
        let first = arrive()

        let retry = rig.engine.retryAdmission([incumbent, mover], onWorkspace: 1, screen: rig.dell,
                                              bypassingMinimaBefore: [74: first.generation],
                                              refusingImpossibleArrangements: true)

        XCTAssertEqual(retry.strandedIDs, [74])
        XCTAssertEqual(rig.treeIDs(1, rig.dell), [115])
        XCTAssertEqual(rig.trace.frames[115], incumbentOriginal)
    }

    func testALastRetryCutOffMidWriteKeepsNothing() {
        // the hop makes every call after the mover's position write slow, so
        // the deadline lands after its second size write went out but before
        // it came back. the mover never got its whole frame, so there is no
        // tile to keep: the tree would place it where nothing sent it
        rig.trace.hopShortfall = [:]
        rig.trace.hopCallLatency[74] = 0.2

        let retry = rig.engine.retryAdmission([incumbent, mover], onWorkspace: 1, screen: rig.dell,
                                              bypassingMinimaBefore: [74: 0],
                                              refusingImpossibleArrangements: true,
                                              keepingUnverifiedOnTimeout: true)

        XCTAssertEqual(retry.failure, .deadlineExceeded)
        XCTAssertEqual(retry.strandedIDs, [74], "left for the recovery to hold")
        XCTAssertEqual(rig.treeIDs(1, rig.dell), [115])
        XCTAssertEqual(rig.trace.frames[115], incumbentOriginal, "the incumbent was rolled back")
    }

    func testALastRetryThatTimesOutBeforeWritingKeepsNothing() {
        // every read of the mover is slow, so even the capture runs out of
        // time. nothing is sent, and a tree must not describe frames nobody
        // sent
        rig.trace.hopShortfall = [:]
        rig.trace.readLatency[74] = 0.2
        let moverOriginal = rig.trace.frames[74]
        let first = arrive()
        XCTAssertEqual(first.failure, .deadlineExceeded)

        let retry = rig.engine.retryAdmission([incumbent, mover], onWorkspace: 1, screen: rig.dell,
                                              bypassingMinimaBefore: [74: first.generation],
                                              refusingImpossibleArrangements: true,
                                              keepingUnverifiedOnTimeout: true)

        XCTAssertEqual(retry.failure, .deadlineExceeded)
        XCTAssertEqual(retry.strandedIDs, [74], "left for the recovery to hold")
        XCTAssertEqual(rig.treeIDs(1, rig.dell), [115])
        XCTAssertEqual(rig.trace.frames[74], moverOriginal)
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
        recovery.attempt = { [unowned self] workspace, screen, bypass, keepOnTimeout in
            let result = rig.engine.retryAdmission(tileable(workspace), onWorkspace: workspace,
                                                   screen: screen, bypassingMinimaBefore: bypass,
                                                   refusingImpossibleArrangements: true,
                                                   keepingUnverifiedOnTimeout: keepOnTimeout)
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

    func testAMoveWhoseLayoutsKeepTimingOutEndsTiledAndUnverifiedNotFloated() {
        rig.trace.jitter = [74]

        moveGhosttyToTheDell()
        XCTAssertEqual(recovery.pendingWindowIDs, [74])

        fire()
        XCTAssertEqual(recovery.phase(of: 74), .awaitingRetry, "a timeout backs off")
        XCTAssertTrue(floated.isEmpty)
        fire()
        fire()

        XCTAssertTrue(floated.isEmpty, "a timeout never floats the window")
        XCTAssertTrue(recovery.pendingWindowIDs.isEmpty)
        XCTAssertTrue(scheduled.isEmpty, "bounded: nothing is armed after the keep")
        XCTAssertEqual(rig.workspaceManager.workspaceFor(74), 1)
        XCTAssertEqual(rig.treeIDs(1, rig.dell), [115, 74], "tiled on the destination")
        XCTAssertTrue(rig.dellRect.contains(rig.trace.frames[74]!))
        XCTAssertTrue(rig.engine.unverifiedLayouts.contains {
            $0.workspace == 1 && $0.windowIDs.contains(74)
        }, "and its key says the geometry is unverified")
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


/// A window that crosses to a screen with a different backing scale. Its
/// app redraws at the new scale while the attempt's calls queue behind it.
/// On the MacBook every Hypr+Shift+N onto the 2x panel missed the 0.36 s
/// budget with nothing read back, and the retry 250 ms later usually tiled.
final class ScaleChangeArrivalTests: XCTestCase {
    /// Safari on the 1x DELL, sent to the built-in's empty workspace. Every
    /// call after the hop costs 95 ms, under the messaging timeout, so only
    /// the attempt's budget can run out.
    private func sendSafariToTheBuiltIn(builtInScale: CGFloat)
        -> (rig: HopRig, result: TilingEngine.AdmissionResult) {
        let rig = HopRig(builtInScale: builtInScale)
        XCTAssertEqual(rig.workspaceManager.workspaceForScreen(rig.builtIn), 2)
        let safari = rig.window(59300, on: rig.dellRect, workspace: 1)
        rig.trace.hopCallLatency[59300] = 0.095
        rig.workspaceManager.moveWindow(59300, toWorkspace: 2)
        let result = rig.engine.tileWindows([safari], onWorkspace: 2, screen: rig.builtIn)
        return (rig, result)
    }

    func testAScaleChangingArrivalGetsTheLongerBudgetAndVerifies() throws {
        let (rig, result) = sendSafariToTheBuiltIn(builtInScale: 2)

        XCTAssertTrue(result.published, "\(String(describing: result.failure))")
        XCTAssertEqual(rig.treeIDs(2, rig.builtIn), [59300])
        let tile = try XCTUnwrap(rig.engine.existingTree(forWorkspace: 2, screen: rig.builtIn))
            .layout(in: rig.builtInRect, gap: rig.engine.gapSize, padding: rig.engine.outerPadding)[0].1
        XCTAssertEqual(rig.trace.frames[59300], tile)
        XCTAssertGreaterThan(rig.trace.now, FrameSizingConfiguration().deadline,
                             "it needed more than the ordinary budget")
        XCTAssertTrue(rig.engine.unverifiedLayouts.isEmpty)
    }

    func testTheSameSlowArrivalWithoutAScaleChangeKeepsTheOrdinaryBudget() {
        let (rig, result) = sendSafariToTheBuiltIn(builtInScale: 1)

        XCTAssertEqual(result.failure, .deadlineExceeded)
        XCTAssertEqual(result.strandedIDs, [59300], "the recovery takes it from here")
        XCTAssertTrue(rig.builtInRect.contains(rig.trace.frames[59300]!),
                      "left on the screen the candidate sent it to")
    }

    /// Hidden windows park in one global corner on the rightmost screen. A
    /// reveal on a screen of another scale moves them across the boundary,
    /// so it gets the longer budget too.
    private func revealFromTheHideCorner(dellScale: CGFloat)
        -> (rig: HopRig, result: TilingEngine.AdmissionResult) {
        let rig = HopRig(dellScale: dellScale, builtInScale: 1)
        let window = rig.window(4100, on: rig.dellRect, workspace: 1)
        let corner = rig.workspaceManager.hidePosition()
        XCTAssertTrue(rig.builtInRect.contains(corner), "the built-in is the rightmost screen")
        rig.trace.frames[4100] = CGRect(origin: corner, size: CGSize(width: 900, height: 700))
        rig.trace.hopCallLatency[4100] = 0.06
        let result = rig.engine.tileWindows([window], onWorkspace: 1, screen: rig.dell)
        return (rig, result)
    }

    func testARevealFromTheHideCornerOntoAnotherScaleGetsTheLongerBudget() {
        let (rig, result) = revealFromTheHideCorner(dellScale: 2)

        XCTAssertTrue(result.published, "\(String(describing: result.failure))")
        XCTAssertEqual(rig.treeIDs(1, rig.dell), [4100])
        XCTAssertGreaterThan(rig.trace.now, FrameSizingConfiguration().deadline)
    }

    func testARevealFromTheHideCornerOnTheSameScaleKeepsTheOrdinaryBudget() {
        let (_, result) = revealFromTheHideCorner(dellScale: 1)

        XCTAssertEqual(result.failure, .deadlineExceeded)
    }

    func testTheBudgetOnlyGrows() {
        let ordinary = FrameSizingConfiguration()
        let extended = ordinary.withScaleChangeBudget
        XCTAssertEqual(extended.deadline, 1.0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(Double(extended.maximumAttempts) * extended.pollInterval,
                                    extended.deadline, "the settle loop can use the time")
        XCTAssertEqual(extended.perCallTimeout, ordinary.perCallTimeout,
                       "one call still fails at the same messaging timeout")

        var generous = ordinary
        generous.deadline = 2
        XCTAssertEqual(generous.withScaleChangeBudget.deadline, 2, accuracy: 0.0001)
    }
}

/// Frame i/o for Zach's three-screen desk. Every write is recorded with the
/// frame it left the window in. A window lying over more than one screen
/// never reads back the same position twice, the way the live readback
/// never settled for a 3424-wide ultrawide window set down on the panel.
private final class DeskTrace {
    let screens: [CGRect]
    var frames: [CGWindowID: CGRect] = [:]
    private(set) var writes: [(label: String, frame: CGRect)] = []
    private(set) var begins = 0
    private var positionReads = 0
    private(set) var now: TimeInterval = 0

    init(screens: [CGRect]) { self.screens = screens }

    /// the screens `frame` covers some area of
    func screensCovered(by frame: CGRect) -> [CGRect] {
        screens.filter { screen in
            let overlap = screen.intersection(frame)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
        }
    }

    func io(_ generation: @escaping () -> UInt64) -> FrameSizingIO {
        var io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { [self] id, size, _ in
                frames[id]?.size = size
                if let frame = frames[id] { writes.append(("size", frame)) }
                return .success
            },
            writePosition: { [self] id, position, _ in
                frames[id]?.origin = position
                if let frame = frames[id] { writes.append(("position", frame)) }
                return .success
            },
            readPosition: { [self] id, _ in
                guard let frame = frames[id] else { return (.invalidUIElement, nil) }
                positionReads += 1
                let wobble: CGFloat = screensCovered(by: frame).count > 1
                    ? CGFloat(positionReads % 2) * 3 : 0
                return (.success, CGPoint(x: frame.minX, y: frame.minY + wobble))
            },
            readSize: { [self] id, _ in
                guard let frame = frames[id] else { return (.invalidUIElement, nil) }
                return (.success, frame.size)
            },
            now: { [self] in now }, sleep: { [self] in now += $0 },
            currentGeneration: generation)
        io.beginFrameWrite = { [self] id, _, _ in
            begins += 1
            return .ready(.noop(windowID: id))
        }
        return io
    }
}

/// Which order a window crossing screens gets its frame in. The 2x panel is
/// primary, the LG portrait to its right, the ultrawide right of that.
final class CrossScreenWriteOrderTests: XCTestCase {
    private var builtIn: HopScreen!
    private var portrait: HopScreen!
    private var ultrawide: HopScreen!
    private var displayManager: DisplayManager!
    private var engine: TilingEngine!
    private var trace: DeskTrace!

    override func setUp() {
        builtIn = HopScreen(x: 0, width: 1512, height: 982, menuBar: 38,
                            name: "Built-in Retina Display", scale: 2)
        portrait = HopScreen(x: 1512, width: 1080, height: 1920, menuBar: 25, name: "LG BL450")
        ultrawide = HopScreen(x: 2592, width: 3440, height: 1440, menuBar: 25, name: "S34C65xT")
        let screens: [NSScreen] = [builtIn, portrait, ultrawide]
        let displayManager = DisplayManager(screenSource: { screens })
        let trace = DeskTrace(screens: screens.map { displayManager.cgFullRect(for: $0) })
        self.displayManager = displayManager
        self.trace = trace
        engine = TilingEngine(displayManager: displayManager,
                              frameSizingIOFactory: { _, generation in trace.io(generation) })
    }

    private func usable(_ screen: NSScreen) -> CGRect { displayManager.cgRect(for: screen) }

    func testAnUltrawideWindowSentToThePanelShrinksBeforeItMovesAndNeverCoversThePortrait() {
        let id: CGWindowID = 77803
        let window = makeWindow(id: id)
        trace.frames[id] = usable(ultrawide).insetBy(dx: 8, dy: 8)

        let result = engine.tileWindows([window], onWorkspace: 1, screen: builtIn)

        XCTAssertTrue(result.published, "\(String(describing: result.failure))")
        XCTAssertEqual(trace.writes.map(\.label), ["size", "position", "size"])
        let portraitRect = displayManager.cgFullRect(for: portrait)
        for write in trace.writes {
            XCTAssertFalse(trace.screensCovered(by: write.frame).contains(portraitRect),
                           "the \(write.label) write left it over the portrait: \(write.frame)")
            XCTAssertEqual(trace.screensCovered(by: write.frame).count, 1,
                           "the \(write.label) write left it across screens: \(write.frame)")
        }
        XCTAssertEqual(trace.begins, 1, "accepted on the first attempt, no rollback")
        XCTAssertLessThan(trace.now, 0.36, "no settle wait on the way")
    }

    func testAPortraitWindowSentToTheUltrawideMovesBeforeItIsSized() {
        let id: CGWindowID = 5100
        let window = makeWindow(id: id)
        trace.frames[id] = usable(portrait).insetBy(dx: 8, dy: 8)

        let result = engine.tileWindows([window], onWorkspace: 3, screen: ultrawide)

        XCTAssertTrue(result.published, "\(String(describing: result.failure))")
        XCTAssertEqual(trace.writes.map(\.label), ["position", "size", "size"],
                       "a 3424-wide target does not fit the 1080-wide portrait")
    }

    func testAnUltrawideWindowSentToThePortraitMovesFirstWhenItIsTooTallForTheSource() {
        let id: CGWindowID = 5200
        let window = makeWindow(id: id)
        trace.frames[id] = CGRect(x: usable(ultrawide).minX + 40, y: usable(ultrawide).minY + 40,
                                  width: 900, height: 700)

        let result = engine.tileWindows([window], onWorkspace: 2, screen: portrait)

        XCTAssertTrue(result.published, "\(String(describing: result.failure))")
        XCTAssertEqual(trace.writes.map(\.label), ["position", "size", "size"],
                       "a portrait-height target does not fit the ultrawide")
    }

    func testAParkedRevealStillMovesFirstEvenWhenItsSizeWouldFitTheCornerScreen() {
        let id: CGWindowID = 5300
        let window = makeWindow(id: id)
        let corner = WorkspaceManager(displayManager: displayManager).hidePosition()
        XCTAssertTrue(usable(ultrawide).contains(corner), "the ultrawide is the rightmost screen")
        trace.frames[id] = CGRect(origin: corner, size: CGSize(width: 1400, height: 800))

        let result = engine.tileWindows([window], onWorkspace: 1, screen: builtIn)

        XCTAssertTrue(result.published, "\(String(describing: result.failure))")
        XCTAssertEqual(trace.writes.map(\.label), ["position", "size", "size"])
    }
}
