import XCTest
@testable import HyprMac

// injected window lists only. none of this proves what macOS does with
// z-order or key focus; that needs the live test on the laptop.

private let frontPID: pid_t = 100
private let otherPID: pid_t = 200
private let ownPID: pid_t = 999

private func win(_ id: CGWindowID, pid: pid_t = frontPID, layer: Int = 0,
                 _ rect: CGRect, alpha: CGFloat = 1) -> StackedWindow {
    StackedWindow(windowID: id, ownerPID: pid, layer: layer, bounds: rect, alpha: alpha)
}

final class WindowStackingTests: XCTestCase {
    func testDecodesWindowServerAndSwiftNumbers() {
        let raw: [[String: Any]] = [
            [kCGWindowNumber as String: NSNumber(value: 7), kCGWindowOwnerPID as String: NSNumber(value: 42),
             kCGWindowLayer as String: NSNumber(value: 101), kCGWindowAlpha as String: NSNumber(value: 0.5),
             kCGWindowBounds as String: CGRect(x: 1, y: 2, width: 30, height: 40).dictionaryRepresentation],
            [kCGWindowNumber as String: CGWindowID(8)],
            [kCGWindowOwnerPID as String: 3],
        ]

        let decoded = WindowStacking.decode(raw)

        XCTAssertEqual(decoded, [
            StackedWindow(windowID: 7, ownerPID: 42, layer: 101,
                          bounds: CGRect(x: 1, y: 2, width: 30, height: 40), alpha: 0.5),
            StackedWindow(windowID: 8, ownerPID: 0, layer: 0, bounds: nil, alpha: 1),
        ])
    }

    func testLayerConstantsMatchTheWindowServer() {
        XCTAssertEqual(WindowStacking.popUpMenuLayer, 101)
        XCTAssertEqual(WindowStacking.statusLayer, 25)
        XCTAssertEqual(WindowStacking.mainMenuLayer, 24)
        XCTAssertEqual(WindowStacking.dockLayer, 20)
    }

    func testOnlyTheFrontmostAppsMenuLevelWindowCountsAsAnOpenPopup() {
        let tile = win(1, CGRect(x: 0, y: 0, width: 800, height: 800))
        let menu = win(2, layer: 101, CGRect(x: 10, y: 30, width: 200, height: 300))
        let status = win(3, layer: 25, CGRect(x: 900, y: 0, width: 30, height: 24))
        let panel = win(4, layer: 3, CGRect(x: 400, y: 400, width: 200, height: 200))
        let banner = win(5, pid: otherPID, layer: 101, CGRect(x: 1200, y: 40, width: 300, height: 80))
        let hidden = win(6, layer: 101, CGRect(x: 10, y: 30, width: 200, height: 300), alpha: 0)
        let ours = win(7, pid: ownPID, layer: 101, CGRect(x: 0, y: 0, width: 300, height: 300))

        func popup(_ windows: [StackedWindow], front: pid_t? = frontPID) -> CGWindowID? {
            WindowStacking.openPopup(in: windows, frontmostPID: front, ownPID: ownPID)?.windowID
        }

        XCTAssertEqual(popup([menu, tile]), 2)
        XCTAssertNil(popup([status, panel, tile]), "status items and floating panels stay open for good")
        XCTAssertNil(popup([banner, tile]), "another app's banner must not freeze focus")
        XCTAssertNil(popup([hidden, tile]))
        XCTAssertNil(popup([ours, tile], front: ownPID))
        XCTAssertNil(popup([menu, tile], front: nil))
    }

    func testHitTestStopsAtTheFrontAppsRaisedWindows() {
        let menu = win(2, layer: 101, CGRect(x: 0, y: 0, width: 300, height: 300))
        let panel = win(4, layer: 3, CGRect(x: 0, y: 0, width: 300, height: 300))
        let floater = win(10, pid: otherPID, CGRect(x: 0, y: 0, width: 400, height: 400))
        let tile = win(11, CGRect(x: 0, y: 0, width: 800, height: 800))
        let point = CGPoint(x: 100, y: 100)

        XCTAssertEqual(WindowStacking.hitTest(point, in: [menu, floater, tile],
                                              frontmostPID: frontPID, ownPID: ownPID), .blocked(menu))
        XCTAssertEqual(WindowStacking.hitTest(point, in: [panel, tile],
                                              frontmostPID: frontPID, ownPID: ownPID), .blocked(panel))
        XCTAssertEqual(WindowStacking.hitTest(CGPoint(x: 500, y: 500), in: [menu, floater, tile],
                                              frontmostPID: frontPID, ownPID: ownPID), .window(11))
    }

    func testHitTestStillLooksThroughOtherAppsOverlaysAndOurOwnPanels() {
        let overlay = win(2, pid: otherPID, layer: 101, CGRect(x: 0, y: 0, width: 2000, height: 2000))
        let border = win(3, pid: ownPID, layer: 3, CGRect(x: 0, y: 0, width: 2000, height: 2000))
        let dock = win(4, pid: otherPID, layer: 20, CGRect(x: 0, y: 0, width: 2000, height: 2000))
        let tile = win(11, CGRect(x: 0, y: 0, width: 800, height: 800))

        XCTAssertEqual(WindowStacking.hitTest(CGPoint(x: 100, y: 100), in: [overlay, border, dock, tile],
                                              frontmostPID: frontPID, ownPID: ownPID), .window(11))
    }

    func testFloatersAboveATargetMustOverlapAndBeInFront() {
        let covering = win(10, pid: otherPID, CGRect(x: 100, y: 100, width: 300, height: 300))
        let target = win(11, CGRect(x: 0, y: 0, width: 800, height: 800))
        let beside = win(12, pid: otherPID, CGRect(x: 804, y: 0, width: 300, height: 300))
        let behind = win(13, pid: otherPID, CGRect(x: 200, y: 200, width: 300, height: 300))
        let pinned = win(14, pid: otherPID, layer: 3, CGRect(x: 100, y: 100, width: 300, height: 300))

        let above = WindowStacking.floaters(above: 11, among: [10, 12, 13, 14],
                                            in: [pinned, covering, beside, target, behind])

        XCTAssertEqual(above.map(\.windowID), [10],
                       "a floater beside the tile, behind it, or pinned above every window is not at risk")
    }

    func testExposedPointAvoidsTheCoveringFloater() throws {
        let tile = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let floater = CGRect(x: 200, y: 150, width: 600, height: 500)

        let point = try XCTUnwrap(WindowStacking.exposedPoint(of: tile, coveredBy: [floater]))

        XCTAssertTrue(tile.contains(point))
        XCTAssertFalse(floater.contains(point))
        XCTAssertNil(WindowStacking.exposedPoint(of: tile, coveredBy: [tile.insetBy(dx: -10, dy: -10)]))
        XCTAssertEqual(WindowStacking.exposedPoint(of: tile, coveredBy: []), CGPoint(x: 500, y: 400))
    }

    func testFloatersBelowATileAreTheOnesAClickBuried() {
        let tile = win(11, CGRect(x: 0, y: 0, width: 800, height: 800))
        let buried = win(10, pid: otherPID, CGRect(x: 100, y: 100, width: 300, height: 300))
        let above = win(12, pid: otherPID, CGRect(x: 200, y: 200, width: 300, height: 300))
        let beside = win(13, pid: otherPID, CGRect(x: 804, y: 0, width: 300, height: 300))
        let hidden = win(14, pid: otherPID, CGRect(x: 100, y: 100, width: 300, height: 300), alpha: 0)

        let below = WindowStacking.floaters(below: 11, among: [10, 12, 13, 14],
                                            in: [above, tile, beside, buried, hidden])

        XCTAssertEqual(below.map(\.windowID), [10])
    }

    // two tiles side by side; the floater straddles the gap between them
    private let tileA = CGRect(x: 0, y: 0, width: 400, height: 400)
    private let tileB = CGRect(x: 408, y: 0, width: 400, height: 400)
    private let straddler = CGRect(x: 300, y: 100, width: 200, height: 200)

    func testAFloaterInFrontOfEveryTileHasNoOccluders() {
        let windows = [win(10, pid: otherPID, straddler), win(1, tileA), win(2, tileB)]

        let occluders = WindowStacking.occluders(ofFloaters: [10: straddler],
                                                 covers: [1: tileA, 2: tileB], in: windows)

        XCTAssertEqual(occluders, [:])
    }

    func testAFloaterATileBuriedIsOccludedByThatTile() {
        let inside = CGRect(x: 100, y: 100, width: 200, height: 200)
        let windows = [win(1, tileA), win(10, pid: otherPID, inside), win(2, tileB)]

        let occluders = WindowStacking.occluders(ofFloaters: [10: inside],
                                                 covers: [1: tileA, 2: tileB], in: windows)

        XCTAssertEqual(occluders, [10: [tileA]])
    }

    func testAFloaterHalfBuriedAcrossTwoTilesIsOccludedOnlyByTheClickedOne() {
        // the user clicked tile A; B is still behind the floater
        let windows = [win(1, tileA), win(10, pid: otherPID, straddler), win(2, tileB)]

        let occluders = WindowStacking.occluders(ofFloaters: [10: straddler],
                                                 covers: [1: tileA, 2: tileB], in: windows)

        XCTAssertEqual(occluders, [10: [tileA]])
    }

    func testBothTilesClickedOccludeTheFloaterFrontToBack() {
        let windows = [win(2, tileB), win(1, tileA), win(10, pid: otherPID, straddler)]

        let occluders = WindowStacking.occluders(ofFloaters: [10: straddler],
                                                 covers: [1: tileA, 2: tileB], in: windows)

        XCTAssertEqual(occluders, [10: [tileB, tileA]])
    }

    func testAFloaterTheListDoesNotShowKeepsItsWholeCutout() {
        let windows = [win(1, tileA), win(2, tileB)]

        let occluders = WindowStacking.occluders(ofFloaters: [10: straddler],
                                                 covers: [1: tileA, 2: tileB], in: windows)

        XCTAssertEqual(occluders, [:])
    }
}

// the dim path math, without panels, so it runs headless
final class FloaterCutoutPathTests: XCTestCase {
    private let tileA = NSRect(x: 0, y: 0, width: 400, height: 400)
    private let tileB = NSRect(x: 408, y: 0, width: 400, height: 400)
    private let straddler = NSRect(x: 300, y: 100, width: 200, height: 200)
    private let overA = CGPoint(x: 350, y: 200)
    private let overB = CGPoint(x: 450, y: 200)

    private func path(_ tile: NSRect, _ holes: [DimmingOverlay.FloaterHole]) -> CGPath {
        DimmingOverlay.dimPath(tile, radius: 10, focused: nil, floaters: holes, holeRadius: 10)
    }

    func testAFloaterInFrontCutsBothTiles() {
        let hole = DimmingOverlay.FloaterHole(rect: straddler)

        XCTAssertFalse(path(tileA, [hole]).contains(overA))
        XCTAssertFalse(path(tileB, [hole]).contains(overB))
        XCTAssertTrue(path(tileA, [hole]).contains(CGPoint(x: 100, y: 200)), "the rest of A stays dim")
    }

    func testAFullyBuriedFloaterCutsNothing() {
        let inside = NSRect(x: 100, y: 100, width: 200, height: 200)
        let hole = DimmingOverlay.FloaterHole(rect: inside, occluders: [tileA])

        XCTAssertNil(hole.path(radius: 10))
        XCTAssertTrue(path(tileA, [hole]).contains(CGPoint(x: 200, y: 200)))
    }

    func testAHalfBuriedFloaterCutsOnlyTheTileItIsInFrontOf() {
        // A was clicked and now covers the floater's left half
        let hole = DimmingOverlay.FloaterHole(rect: straddler, occluders: [tileA])

        XCTAssertTrue(path(tileA, [hole]).contains(overA), "no bright hole left on the clicked tile")
        XCTAssertFalse(path(tileB, [hole]).contains(overB), "the floater still shows over B")
    }

    func testBothTilesClickedLeaveNoHoleAnywhere() {
        let hole = DimmingOverlay.FloaterHole(rect: straddler, occluders: [tileA, tileB])

        XCTAssertTrue(path(tileA, [hole]).contains(overA))
        XCTAssertTrue(path(tileB, [hole]).contains(overB))
    }

    func testTheFocusedTileIsStillCarvedOut() {
        let dimmed = DimmingOverlay.dimPath(tileA, radius: 10, focused: NSRect(x: 350, y: 0, width: 50, height: 400),
                                            floaters: [], holeRadius: 10)

        XCTAssertFalse(dimmed.contains(CGPoint(x: 375, y: 200)))
        XCTAssertTrue(dimmed.contains(CGPoint(x: 100, y: 200)))
    }
}

final class RaiseBehindThrottleTests: XCTestCase {
    private let pair = RaiseBehindThrottle.Pair(floater: 12, tile: 11)

    func testAnIneffectiveRaiseBlocksThePairUntilTheCooldownEnds() {
        var throttle = RaiseBehindThrottle()
        XCTAssertEqual(throttle.decide(pair, now: 0), .raise)
        throttle.noteIneffective(pair, now: 0.05)

        guard case .coolingDown(reason: "ineffective", _) = throttle.decide(pair, now: 5) else {
            return XCTFail("expected the pair to cool down")
        }
        XCTAssertEqual(throttle.decide(pair, now: 0.05 + throttle.ineffectiveCooldown + 0.01), .raise)
    }

    func testARaiseRightAfterOurRestoreIsTreatedAsALoop() {
        var throttle = RaiseBehindThrottle()
        XCTAssertEqual(throttle.decide(pair, now: 0), .raise)
        throttle.noteRestore([pair], now: 0.1)

        XCTAssertEqual(throttle.decide(pair, now: 0.3),
                       .cooldownStarted(reason: "loop", duration: throttle.loopCooldown))
    }

    func testARestoreLongAgoIsNotALoop() {
        var throttle = RaiseBehindThrottle()
        XCTAssertEqual(throttle.decide(pair, now: 0), .raise)
        throttle.noteRestore([pair], now: 0.1)

        XCTAssertEqual(throttle.decide(pair, now: 0.1 + throttle.echoWindow + 0.01), .raise)
    }

    func testABurstOfRaisesCoolsDownAndOtherPairsStayFree() {
        var throttle = RaiseBehindThrottle()
        for step in 0..<throttle.burstLimit {
            XCTAssertEqual(throttle.decide(pair, now: Double(step) * 0.5), .raise)
        }

        XCTAssertEqual(throttle.decide(pair, now: 2.1),
                       .cooldownStarted(reason: "burst", duration: throttle.burstCooldown))
        XCTAssertEqual(throttle.decide(RaiseBehindThrottle.Pair(floater: 12, tile: 13), now: 2.1), .raise)
    }
}

final class TiledFocusRouterTests: XCTestCase {
    private var router: TiledFocusRouter!
    private var windows: [StackedWindow] = []
    private var floaters: Set<CGWindowID> = [10]
    private var front: pid_t? = otherPID
    private var keys: [pid_t: CGWindowID] = [:]
    private var lastFocused: CGWindowID = 11
    private var generation: UInt64 = 1
    private var popup: StackedWindow?
    private var calls: [String] = []
    private var scheduled: [(TimeInterval, () -> Void)] = []

    private let target = makeWindow(id: 11, pid: frontPID)
    private let tileRect = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let floaterRect = CGRect(x: 200, y: 150, width: 600, height: 500)

    override func setUp() {
        super.setUp()
        windows = [win(10, pid: otherPID, floaterRect), win(11, tileRect)]
        router = TiledFocusRouter()
        router.windowList = { [unowned self] in self.windows }
        router.visibleFloaterIDs = { [unowned self] in self.floaters }
        router.isTiled = { $0 == 11 }
        router.frontmostPID = { [unowned self] in self.front }
        router.keyWindowID = { [unowned self] pid in self.keys[pid] }
        router.postWindowFocus = { [unowned self] pid, wid, gained in
            self.calls.append("event \(wid) \(gained ? "gained" : "lost")")
        }
        router.makeFrontAndKey = { [unowned self] w in self.calls.append("front+key \(w.windowID)"); return "ok" }
        router.usualFocus = { [unowned self] w, fallback in self.calls.append("usual \(w.windowID) \(fallback.rawValue)") }
        router.lastFocusedID = { [unowned self] in self.lastFocused }
        router.focusGeneration = { [unowned self] in self.generation }
        router.openPopup = { [unowned self] in self.popup }
        router.schedule = { [unowned self] delay, body in self.scheduled.append((delay, body)) }
    }

    private func runScheduled() {
        while !scheduled.isEmpty { scheduled.removeFirst().1() }
    }

    func testAnUncoveredTileTakesTheUsualPathRightAway() {
        floaters = []

        let route = router.focus(target, reason: "ffm", fallback: .activateAndClick)

        XCTAssertEqual(route.path, .usual)
        XCTAssertEqual(calls, ["usual 11 activate+click"])
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testAFloaterBehindTheTileDoesNotChangeThePath() {
        windows.reverse()

        router.focus(target, reason: "ffm", fallback: .activateAndClick)

        XCTAssertEqual(calls, ["usual 11 activate+click"])
    }

    func testACoveredTileIsFocusedWithoutActivateOrClickAndChecked() {
        let route = router.focus(target, reason: "ffm", fallback: .activateAndClick)

        XCTAssertEqual(route.path, .noRaise)
        XCTAssertEqual(calls, ["front+key 11"])
        XCTAssertEqual(scheduled.map(\.0), [TiledFocusRouter.verifyDelay])

        // the app came forward and the tile is key; the floater stayed above
        front = frontPID
        keys[frontPID] = 11
        runScheduled()

        XCTAssertEqual(calls, ["front+key 11"], "no fallback when focus landed")
    }

    func testAMissedFocusFallsBackToTheCallersUsualPath() {
        router.focus(target, reason: "ffm", fallback: .activateAndClick)
        runScheduled()

        XCTAssertEqual(calls, ["front+key 11", "usual 11 activate+click"])
    }

    func testTheAppFrontButAnotherWindowKeyIsAMiss() {
        router.focus(target, reason: "focusInDirection", fallback: .activate)
        front = frontPID
        keys[frontPID] = 77
        runScheduled()

        XCTAssertEqual(calls.last, "usual 11 activate")
    }

    func testANewerFocusCancelsTheFallback() {
        router.focus(target, reason: "ffm", fallback: .activateAndClick)
        lastFocused = 12
        generation += 1
        runScheduled()

        XCTAssertEqual(calls, ["front+key 11"])
    }

    func testAnOpenPopupCancelsTheFallback() {
        router.focus(target, reason: "ffm", fallback: .activateAndClick)
        popup = win(99, layer: 101, CGRect(x: 0, y: 0, width: 100, height: 100))
        runScheduled()

        XCTAssertEqual(calls, ["front+key 11"])
    }

    func testMenuTrackingCancelsTheFallback() {
        router.isMenuTracking = { true }
        router.focus(target, reason: "ffm", fallback: .activateAndClick)
        runScheduled()

        XCTAssertEqual(calls, ["front+key 11"])
    }

    func testAnAppSwitchMeanwhileCancelsTheFallback() {
        router.focus(target, reason: "ffm", fallback: .activateAndClick)
        // the user pressed Cmd-Tab to a third app before the check
        front = 300
        runScheduled()

        XCTAssertEqual(calls, ["front+key 11"])
    }

    func testWithinTheFrontAppKeyIsHandedOverFirst() {
        front = frontPID
        keys[frontPID] = 12

        router.focus(target, reason: "ffm", fallback: .activateAndClick)
        XCTAssertEqual(calls, ["event 12 lost"])
        XCTAssertEqual(scheduled.map(\.0), [TiledFocusRouter.keyHandoffDelay])

        scheduled.removeFirst().1()
        XCTAssertEqual(calls, ["event 12 lost", "event 11 gained", "front+key 11"])
    }

    func testAnAlreadyKeyTileGetsNoEvents() {
        front = frontPID
        keys[frontPID] = 11

        let route = router.focus(target, reason: "ensureFocus", fallback: .activate)

        XCTAssertEqual(route.path, .alreadyFocused)
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testTheWarpPointIsOnTheUncoveredPartOfTheTile() throws {
        let route = router.focus(target, reason: "focusInDirection", fallback: .activate)

        let point = try XCTUnwrap(route.warpPoint)
        XCTAssertTrue(tileRect.contains(point))
        XCTAssertFalse(floaterRect.contains(point))
    }

    // MARK: - result for the click re-raise

    func testTheResultSaysTheTileIsKeyUnderTheFloater() {
        var results: [Bool] = []
        router.focus(target, reason: "click-reraise", fallback: .activate) { results.append($0) }
        front = frontPID
        keys[frontPID] = 11
        runScheduled()

        XCTAssertEqual(results, [true])
    }

    func testAnAlreadyKeyTileReportsSuccessAtOnce() {
        front = frontPID
        keys[frontPID] = 11
        var results: [Bool] = []

        router.focus(target, reason: "click-reraise", fallback: .activate) { results.append($0) }

        XCTAssertEqual(results, [true])
    }

    func testAMissReportsFailure() {
        var results: [Bool] = []
        router.focus(target, reason: "click-reraise", fallback: .activate) { results.append($0) }
        runScheduled()

        XCTAssertEqual(results, [false])
    }

    func testLandingAboveTheFloaterIsNotSuccess() {
        var results: [Bool] = []
        router.focus(target, reason: "click-reraise", fallback: .activate) { results.append($0) }
        front = frontPID
        keys[frontPID] = 11
        // the tile came up over the floater after all
        windows.reverse()
        runScheduled()

        XCTAssertEqual(results, [false])
    }

    func testTheUsualPathReportsFailure() {
        floaters = []
        var results: [Bool] = []

        router.focus(target, reason: "click-reraise", fallback: .activate) { results.append($0) }

        XCTAssertEqual(results, [false])
    }

    func testASupersededFocusReportsNothing() {
        var results: [Bool] = []
        router.focus(target, reason: "click-reraise", fallback: .activate) { results.append($0) }
        lastFocused = 12
        generation += 1
        runScheduled()

        XCTAssertEqual(results, [])
    }
}

final class MouseTrackingPopupTests: XCTestCase {
    private var windows: [StackedWindow] = []
    private var focused: [CGWindowID] = []
    private var last: CGWindowID = 11

    private let tiled = makeWindow(id: 11, pid: frontPID)
    private let floating = makeWindow(id: 12, pid: otherPID)
    private let otherTile = makeWindow(id: 13, pid: otherPID)

    private func makeTracker(cursor: CGPoint) -> MouseTrackingManager {
        let tracker = MouseTrackingManager()
        tracker.isFocusFollowsMouseEnabled = { true }
        tracker.primaryScreenHeight = { 1000 }
        // NS y is bottom-left; cursor is given in CG coordinates
        tracker.mouseLocationNS = { CGPoint(x: cursor.x, y: 1000 - cursor.y) }
        tracker.hoverThrottleInterval = { 0 }
        tracker.readWindowList = { [unowned self] in self.windows }
        tracker.frontmostPID = { frontPID }
        tracker.ownPID = ownPID
        tracker.floatingWindowIDs = { [12] }
        tracker.isWindowVisible = { $0 == 12 }
        tracker.cachedWindow = { [unowned self] in
            [11: self.tiled, 12: self.floating, 13: self.otherTile][$0]
        }
        tracker.tiledPositions = {
            [11: CGRect(x: 0, y: 0, width: 800, height: 1000),
             13: CGRect(x: 808, y: 0, width: 800, height: 1000)]
        }
        tracker.lastFocusedID = { [unowned self] in self.last }
        tracker.recordFocus = { [unowned self] id, _ in self.last = id }
        tracker.onFocusForFFM = { [unowned self] in self.focused.append($0.windowID) }
        return tracker
    }

    func testAMenuOverAFloaterDoesNotHandTheFloaterFocus() {
        // chrome (front) has a bookmark folder open that hangs over a floater
        windows = [
            win(90, layer: 101, CGRect(x: 100, y: 100, width: 250, height: 500)),
            win(12, pid: otherPID, CGRect(x: 150, y: 300, width: 400, height: 400)),
            win(11, CGRect(x: 0, y: 0, width: 800, height: 1000)),
            win(13, pid: otherPID, CGRect(x: 808, y: 0, width: 800, height: 1000)),
        ]
        let tracker = makeTracker(cursor: CGPoint(x: 200, y: 400))

        tracker.handleMouseMove()

        XCTAssertEqual(focused, [])
        XCTAssertEqual(last, 11)
    }

    func testAnOpenMenuPausesHoverFocusEverywhereUntilItCloses() {
        windows = [
            win(90, layer: 101, CGRect(x: 100, y: 100, width: 250, height: 500)),
            win(11, CGRect(x: 0, y: 0, width: 800, height: 1000)),
            win(13, pid: otherPID, CGRect(x: 808, y: 0, width: 800, height: 1000)),
        ]
        var time: CFAbsoluteTime = 100
        let tracker = makeTracker(cursor: CGPoint(x: 1200, y: 500))
        tracker.now = { time }

        tracker.handleMouseMove()
        XCTAssertEqual(focused, [], "the pointer wandered off the menu; it must stay open")

        windows.removeFirst()
        time += 1
        tracker.handleMouseMove()
        XCTAssertEqual(focused, [13])
    }

    func testAMenuLevelWindowThatNeverClosesStopsPausingHover() {
        windows = [
            win(90, layer: 101, CGRect(x: 100, y: 100, width: 250, height: 500)),
            win(11, CGRect(x: 0, y: 0, width: 800, height: 1000)),
            win(13, pid: otherPID, CGRect(x: 808, y: 0, width: 800, height: 1000)),
        ]
        var time: CFAbsoluteTime = 100
        let tracker = makeTracker(cursor: CGPoint(x: 1200, y: 500))
        tracker.now = { time }

        tracker.handleMouseMove()
        time += MouseTrackingManager.popupPauseLimit - 1
        tracker.handleMouseMove()
        XCTAssertEqual(focused, [])

        time += 2
        tracker.handleMouseMove()
        XCTAssertEqual(focused, [13])
    }

    func testEveryPopupGuardIgnoresAMenuLevelWindowThatNeverCloses() {
        windows = [
            win(90, layer: 101, CGRect(x: 100, y: 100, width: 250, height: 500)),
            win(11, CGRect(x: 0, y: 0, width: 800, height: 1000)),
        ]
        var time: CFAbsoluteTime = 100
        let tracker = makeTracker(cursor: CGPoint(x: 1200, y: 500))
        tracker.now = { time }

        XCTAssertEqual(tracker.openPopup(maxAge: 0)?.windowID, 90)
        time += MouseTrackingManager.popupPauseLimit + 1
        XCTAssertNil(tracker.openPopup(maxAge: 0))
        XCTAssertNil(tracker.livePopup(in: windows, frontmostPID: frontPID))

        // a new menu opened in front of it still counts
        windows.insert(win(91, layer: 101, CGRect(x: 300, y: 100, width: 250, height: 500)), at: 0)
        XCTAssertEqual(tracker.openPopup(maxAge: 0)?.windowID, 91)
    }

    func testAPressDropsTheCachedList() {
        windows = [win(11, CGRect(x: 0, y: 0, width: 800, height: 1000)),
                   win(13, pid: otherPID, CGRect(x: 808, y: 0, width: 800, height: 1000))]
        let time: CFAbsoluteTime = 100
        let tracker = makeTracker(cursor: CGPoint(x: 1200, y: 500))
        tracker.now = { time }
        _ = tracker.stackedWindows()

        windows.insert(win(90, layer: 101, CGRect(x: 100, y: 100, width: 250, height: 500)), at: 0)
        XCTAssertNil(tracker.openPopup(), "still inside the cache age")
        tracker.invalidateWindowListCache()
        XCTAssertEqual(tracker.openPopup()?.windowID, 90)
    }

    func testRefocusUnderCursorLeavesAnOpenMenuAlone() {
        windows = [
            win(90, layer: 101, CGRect(x: 100, y: 100, width: 250, height: 500)),
            win(11, CGRect(x: 0, y: 0, width: 800, height: 1000)),
            win(13, pid: otherPID, CGRect(x: 808, y: 0, width: 800, height: 1000)),
        ]
        let tracker = makeTracker(cursor: CGPoint(x: 1200, y: 500))

        tracker.refocusUnderCursor()

        XCTAssertEqual(focused, [])
        XCTAssertEqual(last, 11)
    }

    func testWithoutAPopupHoverStillFocusesTheWindowUnderTheCursor() {
        windows = [
            win(12, pid: otherPID, CGRect(x: 150, y: 300, width: 400, height: 400)),
            win(11, CGRect(x: 0, y: 0, width: 800, height: 1000)),
        ]
        var time: CFAbsoluteTime = 100
        var cursor = CGPoint(x: 200, y: 400)
        let tracker = makeTracker(cursor: cursor)
        tracker.now = { time }
        tracker.mouseLocationNS = { CGPoint(x: cursor.x, y: 1000 - cursor.y) }

        tracker.handleMouseMove()
        cursor = CGPoint(x: 700, y: 900)
        time += 0.01
        tracker.handleMouseMove()

        XCTAssertEqual(focused, [12, 11])
    }
}
