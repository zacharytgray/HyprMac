import Cocoa
import XCTest
@testable import HyprMac

// injected window lists only. whether the panel looks right, and whether
// the hand-off lands, needs the live check.

private let tilePID: pid_t = 100
private let floaterPID: pid_t = 200
private let ownPID: pid_t = 999
private let floating = WindowStacking.floatingLayer

private func win(_ id: CGWindowID, pid: pid_t = tilePID, layer: Int = 0,
                 _ rect: CGRect, alpha: CGFloat = 1) -> StackedWindow {
    StackedWindow(windowID: id, ownerPID: pid, layer: layer, bounds: rect, alpha: alpha)
}

final class FloaterStandInPlanTests: XCTestCase {
    private let tileA = CGRect(x: 0, y: 0, width: 400, height: 400)
    private let tileB = CGRect(x: 408, y: 0, width: 400, height: 400)
    private let straddler = CGRect(x: 300, y: 100, width: 200, height: 200)
    private let insideA = CGRect(x: 100, y: 100, width: 200, height: 200)

    // MARK: mode

    func testTheSwitchOffMeansNoStandInWhateverThePermission() {
        XCTAssertEqual(FloaterStandInMode.resolve(on: false, captureGranted: true), .off)
        XCTAssertEqual(FloaterStandInMode.resolve(on: false, captureGranted: false), .off)
    }

    func testScreenRecordingPicksTheLook() {
        XCTAssertEqual(FloaterStandInMode.resolve(on: true, captureGranted: true), .live)
        XCTAssertEqual(FloaterStandInMode.resolve(on: true, captureGranted: false), .card)
        XCTAssertEqual(FloaterStandInMode.resolve(on: true, captureGranted: true, forcesCard: true), .card)
    }

    func testTheSwitchIsOffByDefault() {
        XCTAssertFalse(UserConfigDefaults.keepFloatingWindowsInFront)
    }

    func testTheDebugCardKnobReadsItsKey() {
        let defaults = UserDefaults(suiteName: "FloaterStandInPlanTests")!
        defer { defaults.removePersistentDomain(forName: "FloaterStandInPlanTests") }
        XCTAssertFalse(FloaterStandInMode.debugForcesCard(defaults))
        defaults.set("card", forKey: FloaterStandInMode.debugLookKey)
        #if DEBUG
        XCTAssertTrue(FloaterStandInMode.debugForcesCard(defaults))
        #else
        XCTAssertFalse(FloaterStandInMode.debugForcesCard(defaults))
        #endif
    }

    // MARK: covered

    func testAFloaterInFrontOfTheTilesGetsNoPanel() {
        let stack = [win(10, pid: floaterPID, straddler), win(1, tileA), win(2, tileB)]
        XCTAssertEqual(FloaterStandInPlan.covered(floaters: [10: straddler], tiles: [1: tileA, 2: tileB],
                                                  in: stack), [])
    }

    func testAFloaterATileIsStackedAboveGetsAPanel() {
        let stack = [win(1, tileA), win(10, pid: floaterPID, straddler), win(2, tileB)]
        XCTAssertEqual(FloaterStandInPlan.covered(floaters: [10: straddler], tiles: [1: tileA, 2: tileB],
                                                  in: stack), [10])
    }

    func testATileAboveThatOnlyTouchesTheEdgeIsNoCover() {
        // the floater's left edge sits 2 pt into the tile: under the overlap floor
        let touching = CGRect(x: 398, y: 100, width: 200, height: 200)
        let stack = [win(1, tileA), win(10, pid: floaterPID, touching)]
        XCTAssertEqual(FloaterStandInPlan.covered(floaters: [10: touching], tiles: [1: tileA], in: stack), [])
    }

    func testAFloaterAtTheFloatingLevelGetsNoPanel() {
        let stack = [win(10, pid: floaterPID, layer: floating, insideA), win(1, tileA)]
        XCTAssertEqual(FloaterStandInPlan.covered(floaters: [10: insideA], tiles: [1: tileA], in: stack), [])
    }

    func testAFloaterTheListDoesNotShowGetsNoPanel() {
        // minimized, hidden or parked off the list
        XCTAssertEqual(FloaterStandInPlan.covered(floaters: [10: insideA], tiles: [1: tileA],
                                                  in: [win(1, tileA)]), [])
    }

    func testAFloaterUnderAnotherFloaterGetsNoPanel() {
        let stack = [win(11, pid: floaterPID, insideA), win(10, pid: floaterPID, insideA), win(1, tileA)]
        XCTAssertEqual(FloaterStandInPlan.covered(floaters: [10: insideA, 11: insideA], tiles: [1: tileA],
                                                  in: stack), [])
    }

    func testOnlyTheCoveredOfTwoFloatersGetsAPanel() {
        let onB = CGRect(x: 500, y: 100, width: 200, height: 200)
        let stack = [win(11, pid: floaterPID, onB), win(1, tileA), win(10, pid: floaterPID, insideA), win(2, tileB)]
        XCTAssertEqual(FloaterStandInPlan.covered(floaters: [10: insideA, 11: onB], tiles: [1: tileA, 2: tileB],
                                                  in: stack), [10])
    }

    // MARK: at risk

    func testEveryFloaterATileOverlapsKeepsItsPictureWhateverTheOrder() {
        let clear = CGRect(x: 900, y: 0, width: 100, height: 100)
        let stack = [win(10, pid: floaterPID, straddler), win(12, pid: floaterPID, clear),
                     win(1, tileA), win(11, pid: floaterPID, insideA)]
        XCTAssertEqual(FloaterStandInPlan.atRisk(floaters: [10: straddler, 11: insideA, 12: clear],
                                                 tiles: [1: tileA], in: stack), [10, 11])
    }

    func testAHiddenFloaterKeepsNoPicture() {
        let stack = [win(1, tileA), win(10, pid: floaterPID, insideA, alpha: 0)]
        XCTAssertEqual(FloaterStandInPlan.atRisk(floaters: [10: insideA], tiles: [1: tileA], in: stack), [])
        XCTAssertEqual(FloaterStandInPlan.atRisk(floaters: [10: insideA], tiles: [1: tileA],
                                                 in: [win(1, tileA)]), [])
    }

    // MARK: press prediction

    func testAPressOnATileOverlappingAFloaterPredictsTheCover() {
        let stack = [win(10, pid: floaterPID, straddler), win(1, tileA), win(2, tileB)]
        let press = FloaterStandInPlan.coveredByPress(
            at: CGPoint(x: 50, y: 50), in: stack, floaters: [10: straddler],
            tiles: [1: tileA, 2: tileB], frontmostPID: floaterPID, ownPID: ownPID)
        XCTAssertEqual(press?.tile, 1)
        XCTAssertEqual(press?.floaters, [10])
    }

    func testAPressOnTheFloaterItselfPredictsNothing() {
        let stack = [win(10, pid: floaterPID, straddler), win(1, tileA)]
        XCTAssertNil(FloaterStandInPlan.coveredByPress(
            at: CGPoint(x: 350, y: 150), in: stack, floaters: [10: straddler],
            tiles: [1: tileA], frontmostPID: floaterPID, ownPID: ownPID))
    }

    func testAPressOnATileAwayFromTheFloaterPredictsNothing() {
        let stack = [win(10, pid: floaterPID, insideA), win(1, tileA), win(2, tileB)]
        XCTAssertNil(FloaterStandInPlan.coveredByPress(
            at: CGPoint(x: 600, y: 50), in: stack, floaters: [10: insideA],
            tiles: [1: tileA, 2: tileB], frontmostPID: tilePID, ownPID: ownPID))
    }

    func testAPressOnAnUnmanagedWindowPredictsNothing() {
        let stack = [win(10, pid: floaterPID, insideA), win(50, CGRect(x: 0, y: 0, width: 80, height: 80)),
                     win(1, tileA)]
        XCTAssertNil(FloaterStandInPlan.coveredByPress(
            at: CGPoint(x: 20, y: 20), in: stack, floaters: [10: insideA],
            tiles: [1: tileA], frontmostPID: tilePID, ownPID: ownPID))
    }

    func testAPressThroughOurOwnPanelReachesTheTile() {
        // a stand-in elsewhere on screen is ours and skipped by the hit test
        let ours = win(70, pid: ownPID, layer: floating, CGRect(x: 0, y: 0, width: 100, height: 100))
        let stack = [ours, win(10, pid: floaterPID, straddler), win(1, tileA)]
        XCTAssertEqual(FloaterStandInPlan.coveredByPress(
            at: CGPoint(x: 50, y: 50), in: stack, floaters: [10: straddler],
            tiles: [1: tileA], frontmostPID: tilePID, ownPID: ownPID)?.floaters, [10])
    }

    func testAFloatingLevelFloaterIsBuriedOnlyByAnotherAppsTile() {
        let panel = win(10, pid: floaterPID, layer: floating, insideA)
        let otherApp = FloaterStandInPlan.coveredByPress(
            at: CGPoint(x: 20, y: 20), in: [panel, win(1, tileA)], floaters: [10: insideA],
            tiles: [1: tileA], frontmostPID: floaterPID, ownPID: ownPID)
        XCTAssertEqual(otherApp?.floaters, [10], "its app deactivates and drops it to layer 0")

        let sameApp = FloaterStandInPlan.coveredByPress(
            at: CGPoint(x: 20, y: 20), in: [panel, win(1, pid: floaterPID, tileA)], floaters: [10: insideA],
            tiles: [1: tileA], frontmostPID: floaterPID, ownPID: ownPID)
        XCTAssertNil(sameApp, "its own app stays active, so it stays at the floating level")
    }

    func testAPressPredictsEveryFloaterThePressedTileOverlaps() {
        let second = CGRect(x: 50, y: 250, width: 100, height: 100)
        let stack = [win(10, pid: floaterPID, insideA), win(11, pid: floaterPID, second),
                     win(1, tileA), win(2, tileB)]
        XCTAssertEqual(FloaterStandInPlan.coveredByPress(
            at: CGPoint(x: 350, y: 380), in: stack, floaters: [10: insideA, 11: second],
            tiles: [1: tileA, 2: tileB], frontmostPID: tilePID, ownPID: ownPID)?.floaters, [10, 11])
    }

    // MARK: two floaters over one tile (Zach's Calendar behind Orca)

    private let tile = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let back = CGRect(x: 100, y: 100, width: 700, height: 500)
    private let front = CGRect(x: 450, y: 350, width: 700, height: 450)

    func testCase1BothRealTheBackOutlineStopsAtTheFrontFloater() {
        let stack = [win(11, pid: floaterPID, front), win(10, pid: floaterPID, back), win(1, tile)]
        let cuts = FloaterStandInPlan.chromeCuts(floaters: [10: back, 11: front], tiles: [1: tile],
                                                 standIns: [], in: stack)
        XCTAssertEqual(cuts[10], [ChromeCut(rect: front, rounded: true)])
        XCTAssertNil(cuts[11], "nothing is above the front one")
    }

    func testCase2ACoveredBackFloaterIsCutByTheRealOneInFront() {
        // the front floater was raised over the tile; the back one stands in
        let stack = [win(11, pid: floaterPID, front), win(1, tile), win(10, pid: floaterPID, back)]
        let covered = FloaterStandInPlan.covered(floaters: [10: back, 11: front], tiles: [1: tile], in: stack)
        XCTAssertEqual(covered, [10], "no stand-in over the real one on top")
        let cuts = FloaterStandInPlan.chromeCuts(floaters: [10: back, 11: front], tiles: [1: tile],
                                                 standIns: covered, in: stack)
        XCTAssertEqual(cuts[10], [ChromeCut(rect: front, rounded: true)],
                       "the picture and outline leave the front floater out, the tile not")
        XCTAssertNil(cuts[11])
    }

    func testCase3BothCoveredStackInTheirRealOrder() {
        let stack = [win(1, tile), win(11, pid: floaterPID, front), win(10, pid: floaterPID, back)]
        XCTAssertEqual(FloaterStandInPlan.floaterOrder([10, 11], in: stack), [11, 10])
        let cuts = FloaterStandInPlan.chromeCuts(floaters: [10: back, 11: front], tiles: [1: tile],
                                                 standIns: [10, 11], in: stack)
        XCTAssertEqual(cuts[10], [ChromeCut(rect: front, rounded: true)])
        XCTAssertNil(cuts[11], "the front picture and outline draw whole, over the tile too")
    }

    func testCase4AFloaterChangingPlaceCutsAndIsCutUntilItLands() {
        // the back one was pressed; the list still has the old order
        let stack = [win(11, pid: floaterPID, front), win(10, pid: floaterPID, back), win(1, tile)]
        let cuts = FloaterStandInPlan.chromeCuts(floaters: [10: back, 11: front], tiles: [1: tile],
                                                 standIns: [], unsettled: [10], in: stack)
        XCTAssertEqual(cuts[10], [ChromeCut(rect: front, rounded: true)])
        XCTAssertEqual(cuts[11], [ChromeCut(rect: back, rounded: true)], "neither order draws meanwhile")
        XCTAssertFalse(FloaterStandInPlan.isAboveOverlappingFloaters(10, floaters: [10: back, 11: front], in: stack))

        // the raise landed
        let landed = [win(10, pid: floaterPID, back), win(11, pid: floaterPID, front), win(1, tile)]
        XCTAssertTrue(FloaterStandInPlan.isAboveOverlappingFloaters(10, floaters: [10: back, 11: front], in: landed))
        let after = FloaterStandInPlan.chromeCuts(floaters: [10: back, 11: front], tiles: [1: tile],
                                                  standIns: [], in: landed)
        XCTAssertNil(after[10])
        XCTAssertEqual(after[11], [ChromeCut(rect: back, rounded: true)])
    }

    func testAStandInIsNeverCutForAFloaterChangingPlace() {
        // both stand in: a mutual cut would leave a hole showing the tile
        let stack = [win(1, tile), win(11, pid: floaterPID, front), win(10, pid: floaterPID, back)]
        let cuts = FloaterStandInPlan.chromeCuts(floaters: [10: back, 11: front], tiles: [1: tile],
                                                 standIns: [10, 11], unsettled: [10], in: stack)
        XCTAssertNil(cuts[11])
    }

    func testAGlowThatOnlyTouchesAWindowInFrontIsCutToo() {
        let beside = CGRect(x: 802, y: 100, width: 300, height: 300)
        let stack = [win(11, pid: floaterPID, beside), win(10, pid: floaterPID, back)]
        XCTAssertNil(FloaterStandInPlan.chromeCuts(floaters: [10: back, 11: beside], tiles: [:],
                                                   standIns: [], in: stack)[10])
        XCTAssertEqual(FloaterStandInPlan.chromeCuts(floaters: [10: back, 11: beside], tiles: [:],
                                                     standIns: [], reach: 4, in: stack)[10]?.count, 1)
    }

    func testARoundedCutLeavesTheFrontWindowsCornersToTheBackFloater() {
        let cut = ChromeCut(rect: front, rounded: true)
        // just inside the front frame's corner, outside its rounded shape
        let corner = CGPoint(x: front.minX + 1, y: front.minY + 1)
        XCTAssertFalse(FloaterStandInPlan.isCut(corner, by: [cut], cornerRadius: 10))
        XCTAssertTrue(FloaterStandInPlan.isCut(corner, by: [ChromeCut(rect: front, rounded: false)], cornerRadius: 10))
        XCTAssertTrue(FloaterStandInPlan.isCut(CGPoint(x: front.midX, y: front.midY), by: [cut], cornerRadius: 10))
    }

    func testTheCutMaskIsClearInsideARoundedCutAndOpaqueAtItsCorner() throws {
        let image = try XCTUnwrap(ChromeCutMask.image(
            size: CGSize(width: 100, height: 100), topLeftCG: CGPoint(x: 0, y: 0),
            cuts: [ChromeCut(rect: CGRect(x: 50, y: 50, width: 50, height: 50), rounded: true)],
            cornerRadius: 12, scale: 1))
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = CFDataGetBytePtr(data)!
        func alpha(_ x: Int, _ yFromTop: Int) -> UInt8 { bytes[yFromTop * image.bytesPerRow + x * 4 + 3] }
        XCTAssertEqual(alpha(10, 10), 255, "outside the cut the chrome draws")
        XCTAssertEqual(alpha(75, 75), 0, "inside the cut it doesn't")
        XCTAssertEqual(alpha(51, 51), 255, "the cut's rounded corner leaves the chrome")
    }

    // MARK: ghosts (Zach's Teams window, 0.29.0)

    // the floater as HyprMac parked it for a hidden workspace: on screen, in
    // the hide corner, full size
    private let parked = CGRect(x: 1919, y: 1079, width: 744, height: 414)
    private let lastSeen = CGRect(x: 223, y: 238, width: 744, height: 414)
    private let slot = CGRect(x: 8, y: 33, width: 1904, height: 954)

    private func reveal(_ windows: [StackedWindow], hidden: Set<CGWindowID> = [],
                        floating: Set<CGWindowID> = [8905]) -> (show: Set<CGWindowID>, drop: [CGWindowID: StandInBlock]) {
        FloaterStandInPlan.revealPictures(kept: [8905: lastSeen], revealed: [8905, 1], floating: floating,
                                          hidden: hidden, excluded: [], tileSlots: [slot], in: windows)
    }

    func testATeamsStyleClosedFloaterGetsNoStandInOnAnyPath() {
        // closed while its workspace was away: the app keeps the window and
        // its id but orders it out. HyprMac still lists it as a floater
        let stack = [win(1, slot)]
        XCTAssertEqual(FloaterStandInPlan.standInBlock(8905, floating: [8905], hidden: [], excluded: [], in: stack),
                       .offScreen, "pre-raise and refresh take their floaters through this")
        let back = reveal(stack)
        XCTAssertEqual(back.show, [], "the return shows nothing")
        XCTAssertEqual(back.drop, [8905: .offScreen], "and drops the kept picture for good")
        let zone = StandInPressTap.Zone(tileID: 1, tileFrame: slot, panels: [8905: 4242])
        XCTAssertEqual(StandInPressTap.livePanels(zone, in: stack), [:], "a stale tap zone raises nothing")
    }

    func testAParkedLiveFloaterKeepsItsPictureForTheReturn() {
        let stack = [win(8905, pid: floaterPID, parked), win(1, slot)]
        XCTAssertNil(FloaterStandInPlan.standInBlock(8905, floating: [8905], hidden: [], excluded: [], in: stack),
                     "parked in the hide corner is still on screen")
        XCTAssertEqual(reveal(stack).show, [8905])
        let zone = StandInPressTap.Zone(tileID: 1, tileFrame: slot, panels: [8905: 4242])
        XCTAssertEqual(StandInPressTap.livePanels(zone, in: stack), [8905: 4242])
    }

    func testARevealShowsNothingNoTileWillCover() {
        let stack = [win(8905, pid: floaterPID, parked)]
        let back = FloaterStandInPlan.revealPictures(kept: [8905: lastSeen], revealed: [8905], floating: [8905],
                                                     hidden: [], excluded: [], tileSlots: [], in: stack)
        XCTAssertEqual(back.show, [])
        XCTAssertEqual(back.drop, [:], "still a live floater: its picture stays kept")
    }

    func testMinimizedAppHiddenAndDestroyedFloatersGetNoStandIn() {
        let stack = [win(1, slot)]
        // minimized: ordered out, discovery not caught up yet
        XCTAssertEqual(reveal(stack).drop, [8905: .offScreen])
        // app hidden (Cmd-H) once discovery knows: HyprMac's hidden set
        XCTAssertEqual(reveal(stack, hidden: [8905]).drop, [8905: .hidden])
        XCTAssertEqual(FloaterStandInPlan.standInBlock(8905, floating: [8905], hidden: [8905], excluded: [],
                                                       in: [win(8905, pid: floaterPID, lastSeen)]), .hidden,
                       "HyprMac's own word wins even while the list still shows it")
        // destroyed and forgotten: no longer a floater
        XCTAssertEqual(reveal(stack, floating: []).drop, [8905: .notFloating])
        // a transparent or zero-size leftover is not on screen either
        XCTAssertEqual(FloaterStandInPlan.standInBlock(8905, floating: [8905], hidden: [], excluded: [],
                                                       in: [win(8905, pid: floaterPID, lastSeen, alpha: 0)]),
                       .offScreen)
    }

    func testScratchpadMembersAndPopUpsAreExcluded() {
        XCTAssertEqual(FloaterStandInPlan.standInBlock(8905, floating: [8905], hidden: [], excluded: [8905],
                                                       in: [win(8905, pid: floaterPID, lastSeen)]), .excluded)
    }
}
