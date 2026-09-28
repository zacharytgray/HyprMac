import Cocoa
import XCTest
@testable import HyprMac

// Same-screen drift: a tiled window whose app put it back where it wanted.
// The interesting part is the bound, not the reaction — one re-apply per
// window per episode, and a stop rather than a write-for-write fight.

final class TiledDriftMonitorTests: XCTestCase {

    private var monitor: TiledDriftMonitor!
    private var screen: NSScreen!
    private var clock: Date!

    override func setUp() {
        super.setUp()
        screen = DriftTestScreen()
        clock = Date(timeIntervalSince1970: 1_000)
        monitor = TiledDriftMonitor()
        monitor.now = { [unowned self] in self.clock }
    }

    private let tile = CGRect(x: 8, y: 41, width: 744, height: 841)
    private let fullScreen = CGRect(x: 0, y: 0, width: 1512, height: 900)

    private func reading(_ id: CGWindowID, at actual: CGRect,
                         workspace: Int = 1) -> TiledDriftReading {
        TiledDriftReading(windowID: id, workspace: workspace, screen: screen,
                          actual: actual, intended: tile)
    }

    // MARK: - noticing

    func testOneDriftedPollAsksForNothing() {
        XCTAssertTrue(monitor.note([reading(32913, at: fullScreen)]).isEmpty,
                      "one sample could be an animation in flight")
    }

    func testTwoStablePollsOfTheSameDriftedFrameAskForOneReapply() {
        _ = monitor.note([reading(32913, at: fullScreen)])

        let decisions = monitor.note([reading(32913, at: fullScreen)])

        XCTAssertEqual(decisions, [.reapply(workspace: 1, screen: screen, windowID: 32913)])
    }

    func testAWindowStillMovingIsNeverReapplied() {
        _ = monitor.note([reading(32913, at: fullScreen)])
        let moving = monitor.note([reading(32913, at: fullScreen.insetBy(dx: 40, dy: 40))])

        XCTAssertTrue(moving.isEmpty, "the frame changed between polls")
    }

    func testDriftBelowTheTolerancesIsIgnored() {
        let nudged = CGRect(x: tile.minX + 1, y: tile.minY - 1,
                            width: tile.width + 20, height: tile.height - 20)
        for _ in 0..<4 {
            XCTAssertTrue(monitor.note([reading(32913, at: nudged)]).isEmpty)
        }
    }

    func testDriftIsIgnoredWhileSomethingElseOwnsTheGeometry() {
        monitor.isSuspended = { true }

        _ = monitor.note([reading(32913, at: fullScreen)])
        let duringDrag = monitor.note([reading(32913, at: fullScreen)])

        XCTAssertTrue(duringDrag.isEmpty)

        // and nothing was banked: it still takes two polls of its own
        monitor.isSuspended = { false }
        XCTAssertTrue(monitor.note([reading(32913, at: fullScreen)]).isEmpty)
        XCTAssertEqual(monitor.note([reading(32913, at: fullScreen)]).count, 1)
    }

    // MARK: - the bound

    func testOneDriftedPollAfterTheReapplyIsNotEnoughToStop() {
        _ = monitor.note([reading(32913, at: fullScreen)])
        _ = monitor.note([reading(32913, at: fullScreen)])
        clock = clock.addingTimeInterval(1)

        XCTAssertTrue(monitor.note([reading(32913, at: fullScreen)]).isEmpty,
                      "one sample could be the layout still landing")
    }

    func testAWindowStillMovingAfterTheReapplyIsNotAbandoned() {
        _ = monitor.note([reading(32913, at: fullScreen)])
        _ = monitor.note([reading(32913, at: fullScreen)])
        clock = clock.addingTimeInterval(1)

        _ = monitor.note([reading(32913, at: fullScreen)])
        let moving = monitor.note([reading(32913, at: fullScreen.insetBy(dx: 40, dy: 40))])

        XCTAssertTrue(moving.isEmpty, "the frame changed between polls")
    }

    func testAnAppThatTakesItsFrameBackStopsTheEpisode() {
        _ = monitor.note([reading(32913, at: fullScreen)])
        _ = monitor.note([reading(32913, at: fullScreen)])
        clock = clock.addingTimeInterval(1)
        _ = monitor.note([reading(32913, at: fullScreen)])

        let again = monitor.note([reading(32913, at: fullScreen)])

        XCTAssertEqual(again, [.abandon(workspace: 1, screen: screen, windowID: 32913)])
        XCTAssertTrue(monitor.note([reading(32913, at: fullScreen)]).isEmpty,
                      "no second re-apply and no second abandon")
        XCTAssertTrue(monitor.note([reading(32913, at: fullScreen)]).isEmpty)
    }

    func testALayoutThatHeldForAWhileEarnsAFreshEpisode() {
        _ = monitor.note([reading(32913, at: fullScreen)])
        _ = monitor.note([reading(32913, at: fullScreen)])
        clock = clock.addingTimeInterval(30)

        XCTAssertTrue(monitor.note([reading(32913, at: fullScreen)]).isEmpty)
        XCTAssertEqual(monitor.note([reading(32913, at: fullScreen)]),
                       [.reapply(workspace: 1, screen: screen, windowID: 32913)])
    }

    func testAWindowBackOnItsTileEndsTheEpisode() {
        _ = monitor.note([reading(32913, at: fullScreen)])
        _ = monitor.note([reading(32913, at: fullScreen)])

        // the re-apply was accepted and stuck
        XCTAssertTrue(monitor.note([reading(32913, at: tile)]).isEmpty)

        // much later it drifts again, and gets a full episode of its own
        XCTAssertTrue(monitor.note([reading(32913, at: fullScreen)]).isEmpty)
        XCTAssertEqual(monitor.note([reading(32913, at: fullScreen)]),
                       [.reapply(workspace: 1, screen: screen, windowID: 32913)])
    }

    func testOneWorkspaceGetsOneReapplyHoweverManyOfItsWindowsDrifted() {
        let both = [reading(32913, at: fullScreen), reading(32914, at: fullScreen)]
        _ = monitor.note(both)

        let decisions = monitor.note(both)

        XCTAssertEqual(decisions, [.reapply(workspace: 1, screen: screen, windowID: 32913)],
                       "the re-apply lays out the whole workspace")
    }

    func testTwoWorkspacesAreJudgedSeparately() {
        let readings = [reading(32913, at: fullScreen),
                        reading(32915, at: fullScreen, workspace: 2)]
        _ = monitor.note(readings)

        XCTAssertEqual(monitor.note(readings).count, 2)
    }

    func testAWindowThatLeavesTheReadingsIsForgotten() {
        _ = monitor.note([reading(32913, at: fullScreen)])

        // floated, hidden, or its key went unverified
        _ = monitor.note([])

        XCTAssertTrue(monitor.note([reading(32913, at: fullScreen)]).isEmpty,
                      "its half-finished episode went with it")
    }
}

private final class DriftTestScreen: SyntheticScreen {
    override func isEqual(_ object: Any?) -> Bool {
        guard let screen = object as? NSScreen else { return false }
        return self === screen
    }
    override var hash: Int { ObjectIdentifier(self).hashValue }
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 1512, height: 900) }
    override var visibleFrame: NSRect { frame }
}
