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
}
