import XCTest
@testable import HyprMac

// native tabs: the pairing rules, discovery's holds and the engine's leaf
// handover, each on its own. NativeTabRegressionTests runs them together
// through a held key.

final class TabSwitchTests: XCTestCase {

    private let app: pid_t = 7000
    private let slot = CGRect(x: 800, y: 8, width: 792, height: 488)

    // MARK: - pairing rules

    private func leaver(_ id: CGWindowID, pid: pid_t? = nil, at frame: CGRect) -> TabSwitchPairing.Leaver {
        TabSwitchPairing.Leaver(windowID: id, pid: pid ?? app, frames: [frame])
    }

    private func arrival(_ id: CGWindowID, pid: pid_t? = nil, at frame: CGRect?) -> TabSwitchPairing.Arrival {
        TabSwitchPairing.Arrival(windowID: id, pid: pid ?? app, frame: frame)
    }

    func testAWindowOfTheSameAppInTheFramePairs() {
        let pairs = TabSwitchPairing.pairs(leavers: [leaver(1, at: slot)], arrivals: [arrival(2, at: slot)])
        XCTAssertEqual(pairs, [1: 2])
    }

    func testAnotherAppsWindowInTheFrameDoesNotPair() {
        let pairs = TabSwitchPairing.pairs(leavers: [leaver(1, at: slot)],
                                           arrivals: [arrival(2, pid: 7001, at: slot)])
        XCTAssertTrue(pairs.isEmpty)
    }

    func testAWindowElsewhereDoesNotPair() {
        let pairs = TabSwitchPairing.pairs(leavers: [leaver(1, at: slot)],
                                           arrivals: [arrival(2, at: slot.offsetBy(dx: 40, dy: 0))])
        XCTAssertTrue(pairs.isEmpty)
    }

    func testTheTabBarsHeightIsWithinTheSlot() {
        var taller = slot
        taller.size.height += 28
        XCTAssertTrue(TabSwitchPairing.sharesSlot(taller, with: slot))
        taller.size.height += 28
        XCTAssertFalse(TabSwitchPairing.sharesSlot(taller, with: slot))
    }

    func testAnUnsizedWindowStandsNowhere() {
        XCTAssertFalse(TabSwitchPairing.sharesSlot(CGRect(origin: slot.origin, size: .zero), with: slot))
        XCTAssertFalse(TabSwitchPairing.sharesSlot(nil, with: slot))
    }

    func testTwoCandidatesOnEitherSidePairWithNothing() {
        XCTAssertTrue(TabSwitchPairing.pairs(leavers: [leaver(1, at: slot)],
                                             arrivals: [arrival(2, at: slot), arrival(3, at: slot)]).isEmpty)
        XCTAssertTrue(TabSwitchPairing.pairs(leavers: [leaver(1, at: slot), leaver(4, at: slot)],
                                             arrivals: [arrival(2, at: slot)]).isEmpty)
    }

    func testTwoGroupsSwitchingAtOncePairByFrame() {
        let other = slot.offsetBy(dx: -796, dy: 0)
        let pairs = TabSwitchPairing.pairs(leavers: [leaver(1, at: slot), leaver(3, at: other)],
                                           arrivals: [arrival(4, at: other), arrival(2, at: slot)])
        XCTAssertEqual(pairs, [1: 2, 3: 4])
    }

    // MARK: - the window server's hint

    private func info(_ id: Int, pid: pid_t, onScreen: Bool, size: CGSize = CGSize(width: 800, height: 600),
                      layer: Int = 0) -> [String: Any] {
        var out: [String: Any] = [
            kCGWindowNumber as String: id, kCGWindowOwnerPID as String: Int(pid),
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: CGRect(origin: .zero, size: size).dictionaryRepresentation,
        ]
        if onScreen { out[kCGWindowIsOnscreen as String] = true }
        return out
    }

    func testABackgroundTabIsOrderedOutBesideAnother() {
        let list = [info(1, pid: app, onScreen: false), info(2, pid: app, onScreen: false),
                    info(3, pid: app, onScreen: true)]
        XCTAssertTrue(WindowStacking.isOrderedOut(1, besideAnotherOf: app, in: list))
    }

    func testAClosedWindowIsNotOrderedOut() {
        // destroyed: the window server no longer lists it
        let list = [info(2, pid: app, onScreen: false), info(3, pid: app, onScreen: true)]
        XCTAssertFalse(WindowStacking.isOrderedOut(1, besideAnotherOf: app, in: list))
    }

    func testAnAppsOnlyOffScreenWindowIsNoTab() {
        // a window its app keeps after a close, with nothing else off screen:
        // on-screen windows, another app's, tiny helpers and panels don't count
        let list = [info(1, pid: app, onScreen: false), info(3, pid: app, onScreen: true),
                    info(4, pid: 7001, onScreen: false),
                    info(5, pid: app, onScreen: false, size: CGSize(width: 1, height: 1)),
                    info(6, pid: app, onScreen: false, layer: 25)]
        XCTAssertFalse(WindowStacking.isOrderedOut(1, besideAnotherOf: app, in: list))
    }

    // MARK: - discovery

    private final class Scene {
        let cache = WindowStateCache()
        let accessibility = StubAccessibility()
        let service: WindowDiscoveryService
        var clock = Date(timeIntervalSince1970: 2_000_000)
        var onScreen: [StackedWindow] = []
        var orderedOut: Set<CGWindowID> = []

        init() {
            let display = DisplayManager()
            service = WindowDiscoveryService(stateCache: cache, accessibility: accessibility,
                                             displayManager: display,
                                             workspaceManager: WorkspaceManager(displayManager: display),
                                             bundleIDForPID: { _ in "com.apple.Terminal" },
                                             isWindowSizeSettable: { _ in true })
            accessibility.stateAnswer = .absent
            service.now = { [unowned self] in self.clock }
            service.onScreenWindows = { [unowned self] in self.onScreen }
            service.isOrderedOutBesideAnother = { [unowned self] id, _ in self.orderedOut.contains(id) }
        }

        func poll(_ windows: [HyprWindow], unreadable: Set<CGWindowID> = []) -> WindowChanges {
            service.computeChanges(snapshot: windows, runningPIDs: [7000], excludedBundleIDs: [],
                                   focusedWindowID: 0, unreadableWindowIDs: unreadable)
        }
    }

    private func window(_ id: CGWindowID, at frame: CGRect) -> HyprWindow {
        let w = makeWindow(id: id, pid: app)
        w.cachedFrame = frame
        return w
    }

    func testASwitchInOnePollIsNeitherGoneNorNew() {
        let scene = Scene()
        _ = scene.poll([window(1, at: slot)])

        let changes = scene.poll([window(2, at: slot)])

        XCTAssertEqual(changes.tabSwitches.map(\.hiddenID), [1])
        XCTAssertEqual(changes.tabSwitches.map(\.shown.windowID), [2])
        XCTAssertTrue(changes.goneIDs.isEmpty)
        XCTAssertTrue(changes.newWindows.isEmpty)
        XCTAssertFalse(changes.needsRetile, "the shown tab stands in the tile already")
        XCTAssertEqual(scene.cache.knownWindowIDs, [2])
        XCTAssertEqual(scene.cache.hiddenWindowIDs, [1])
        XCTAssertFalse(scene.cache.reservedHiddenWindowIDs.contains(1), "the ghost holds no slot")
    }

    func testTheWayBackPairsAGhost() {
        let scene = Scene()
        _ = scene.poll([window(1, at: slot)])
        _ = scene.poll([window(2, at: slot)])

        let changes = scene.poll([window(1, at: slot)])

        XCTAssertEqual(changes.tabSwitches.map(\.hiddenID), [2])
        XCTAssertTrue(changes.returned.isEmpty)
        XCTAssertEqual(scene.cache.knownWindowIDs, [1])
    }

    func testAShownTabOffTheFrameAsksForARetile() {
        let scene = Scene()
        _ = scene.poll([window(1, at: slot)])
        var taller = slot
        taller.size.height += 28

        let changes = scene.poll([window(2, at: taller)])

        XCTAssertEqual(changes.tabSwitches.count, 1)
        XCTAssertTrue(changes.needsRetile)
    }

    func testTheShownTabTakesTheFloatingState() {
        let scene = Scene()
        let first = window(1, at: slot)
        _ = scene.poll([first])
        scene.cache.setFloating(true, window: first)

        let shown = window(2, at: slot)
        _ = scene.poll([shown])

        XCTAssertTrue(scene.cache.floatingWindowIDs.contains(2))
        XCTAssertTrue(shown.isFloating)
    }

    func testAMinimizedWindowIsNoTab() {
        let scene = Scene()
        _ = scene.poll([window(1, at: slot)])
        scene.accessibility.stateAnswer = .minimized

        let changes = scene.poll([window(2, at: slot)])

        XCTAssertTrue(changes.tabSwitches.isEmpty)
        XCTAssertEqual(changes.goneIDs, [1])
        XCTAssertEqual(changes.newWindows.map(\.windowID), [2])
    }

    func testAnUnreadWindowInTheFrameHoldsTheTabUntilItReads() {
        let scene = Scene()
        _ = scene.poll([window(1, at: slot)])
        scene.accessibility.stateAnswer = nil
        scene.onScreen = [StackedWindow(windowID: 2, ownerPID: app, bounds: slot)]

        let busy = scene.poll([], unreadable: [2])
        XCTAssertTrue(busy.goneIDs.isEmpty)
        XCTAssertEqual(scene.service.heldWindowIDs, [1])
        XCTAssertNotNil(scene.service.secondsUntilARetryIsDue, "the window it waits on gets a quick look")

        scene.clock.addTimeInterval(2)
        let read = scene.poll([window(2, at: slot)])
        XCTAssertEqual(read.tabSwitches.map(\.hiddenID), [1])
        XCTAssertTrue(scene.service.heldWindowIDs.isEmpty)
    }

    func testAWindowThatNeverReadsEndsTheHold() {
        let scene = Scene()
        _ = scene.poll([window(1, at: slot)])
        scene.onScreen = [StackedWindow(windowID: 2, ownerPID: app, bounds: slot)]

        XCTAssertTrue(scene.poll([], unreadable: [2]).goneIDs.isEmpty)
        scene.clock.addTimeInterval(WindowDiscoveryService.listedHoldSpan + 0.1)
        XCTAssertEqual(scene.poll([], unreadable: [2]).goneIDs, [1])
    }

    func testAnotherWindowInTheFrameStartsTheHoldAgain() {
        // a held key on a busy app: a different tab every poll, none read
        let scene = Scene()
        _ = scene.poll([window(1, at: slot)])
        for next in CGWindowID(2)...5 {
            scene.onScreen = [StackedWindow(windowID: next, ownerPID: app, bounds: slot)]
            XCTAssertTrue(scene.poll([], unreadable: [next]).goneIDs.isEmpty, "tab \(next)")
            scene.clock.addTimeInterval(3)
        }
    }

    func testAnOrderedOutTabWaitsHalfASecondForTheShownOne() {
        let scene = Scene()
        _ = scene.poll([window(1, at: slot)])
        scene.orderedOut = [1]

        XCTAssertTrue(scene.poll([]).goneIDs.isEmpty)
        XCTAssertNotNil(scene.service.secondsUntilAHoldEnds)
        scene.clock.addTimeInterval(0.3)
        XCTAssertEqual(scene.poll([window(2, at: slot)]).tabSwitches.map(\.hiddenID), [1])
    }

    func testAnOrderedOutWindowNothingReplacesIsGoneAfterTheWait() {
        let scene = Scene()
        _ = scene.poll([window(1, at: slot)])
        scene.orderedOut = [1]

        XCTAssertTrue(scene.poll([]).goneIDs.isEmpty)
        scene.clock.addTimeInterval(0.6)
        XCTAssertEqual(scene.poll([]).goneIDs, [1])
    }

    func testAClosedWindowIsGoneInTheSamePoll() {
        let scene = Scene()
        _ = scene.poll([window(1, at: slot)])

        XCTAssertEqual(scene.poll([]).goneIDs, [1])
    }

    func testAnUnsizedNewTabWaitsForItsSize() {
        // Cmd-T: the new tab is listed at 0×0 first
        let scene = Scene()
        _ = scene.poll([window(1, at: slot)])

        let unsized = scene.poll([window(2, at: CGRect(origin: slot.origin, size: .zero))])
        XCTAssertTrue(unsized.newWindows.isEmpty)
        XCTAssertTrue(unsized.goneIDs.isEmpty)

        scene.clock.addTimeInterval(0.3)
        let sized = scene.poll([window(2, at: slot)])
        XCTAssertEqual(sized.tabSwitches.map(\.hiddenID), [1])
    }

    func testAnUnsizedWindowThatStaysSoIsAdmittedAfterTheWait() {
        let scene = Scene()
        _ = scene.poll([window(1, at: slot)])
        let unsized = window(2, at: CGRect(origin: slot.origin, size: .zero))

        _ = scene.poll([unsized])
        scene.clock.addTimeInterval(1.1)
        let changes = scene.poll([unsized])

        XCTAssertEqual(changes.goneIDs, [1])
        XCTAssertEqual(changes.newWindows.map(\.windowID), [2])
    }

    func testTheAdmitOnlyPassLeavesAShownTabToTheFullPoll() {
        let scene = Scene()
        _ = scene.poll([window(1, at: slot)])

        let admitted = scene.service.computeAdmissions(
            snapshot: [window(2, at: slot), window(3, at: slot.offsetBy(dx: -796, dy: 0))],
            excludedBundleIDs: [])

        XCTAssertEqual(admitted.newWindows.map(\.windowID), [3])
    }

    // MARK: - the engine

    func testHandingOverALeafKeepsTheTreeAndTheMaximize() throws {
        let screen = TabSwitchTestScreen()
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { [screen] }),
                                  frameSizingIOFactory: acceptingFrameSizingIOFactory())
        let windows = [1, 2, 3].map { makeWindow(id: $0) }
        engine.tileWindows(windows, onWorkspace: 1, screen: screen)
        engine.resizeInDirection(windows[0], direction: .right, onWorkspace: 1, screen: screen)
        let before = engine.intendedTileRects()
        XCTAssertEqual(engine.maximize(windows[1], onWorkspace: 1, screen: screen), .maximized)

        XCTAssertTrue(engine.handOverLeaf(from: 2, to: makeWindow(id: 9)))

        XCTAssertEqual(Set(engine.windowIDs(inTreeForWorkspace: 1, screen: screen)), [1, 3, 9])
        XCTAssertEqual(engine.maximizedWindowID(onWorkspace: 1, screen: screen), 9)
        XCTAssertTrue(engine.endMaximize(onWorkspace: 1, screen: screen))
        let after = engine.intendedTileRects()
        XCTAssertEqual(after[9], before[2])
        XCTAssertEqual(after[1], before[1])
        XCTAssertEqual(after[3], before[3])
    }

    func testNoLeafIsHandedToAWindowAlreadyTiled() {
        let screen = TabSwitchTestScreen()
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { [screen] }),
                                  frameSizingIOFactory: acceptingFrameSizingIOFactory())
        let windows = [1, 2].map { makeWindow(id: $0) }
        engine.tileWindows(windows, onWorkspace: 1, screen: screen)

        XCTAssertFalse(engine.handOverLeaf(from: 1, to: windows[1]))
        XCTAssertFalse(engine.handOverLeaf(from: 7, to: makeWindow(id: 9)))
        XCTAssertEqual(Set(engine.windowIDs(inTreeForWorkspace: 1, screen: screen)), [1, 2])
    }
}

private final class TabSwitchTestScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 1600, height: 1000) }
    override var visibleFrame: NSRect { frame }
}
