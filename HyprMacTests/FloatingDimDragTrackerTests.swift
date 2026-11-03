import XCTest
@testable import HyprMac

final class FloatingDimDragTrackerTests: XCTestCase {
    private var carves: [CGRect] = []
    private var cleared = 0
    private var clock: TimeInterval = 100
    private var size: CGSize?
    private var position: CGPoint?
    private var liveFrame: CGRect?
    private let start = CGRect(x: 100, y: 100, width: 400, height: 300)

    private func armed() -> FloatingDimDragTracker {
        let tracker = FloatingDimDragTracker(
            now: { [unowned self] in self.clock },
            setCarve: { [unowned self] _, rect in self.carves.append(rect) },
            clearCarve: { [unowned self] in self.cleared += 1 })
        size = start.size
        position = start.origin
        tracker.arm(id: 7,
                    probe: .init(size: { [unowned self] in self.size },
                                 position: { [unowned self] in self.position },
                                 frame: { [unowned self] in self.liveFrame }),
                    startFrame: start, downPointCG: CGPoint(x: 150, y: 110))
        return tracker
    }

    func testContentDragNeverMovesTheCarve() {
        let tracker = armed()
        tracker.update(cursorCG: CGPoint(x: 400, y: 400))
        position = CGPoint(x: 102, y: 101) // ax noise, under the guard
        tracker.update(cursorCG: CGPoint(x: 500, y: 500))
        XCTAssertTrue(carves.isEmpty)
    }

    func testConfirmedMoveTracksOffTheMouseDownPair() {
        let tracker = armed()
        position = CGPoint(x: 110, y: 100) // lags the cursor, must not be used
        tracker.update(cursorCG: CGPoint(x: 350, y: 310))
        let expected = start.offsetBy(dx: 200, dy: 200).insetBy(dx: -2, dy: -2)
        XCTAssertEqual(carves, [expected])
    }

    func testStaysConfirmedWithoutAnotherPositionRead() {
        let tracker = armed()
        position = CGPoint(x: 110, y: 100)
        tracker.update(cursorCG: CGPoint(x: 160, y: 110))
        position = nil
        tracker.update(cursorCG: CGPoint(x: 170, y: 110))
        XCTAssertEqual(carves.count, 2)
    }

    func testEdgeResizeFollowsTheLiveFrame() {
        let tracker = armed()
        size = CGSize(width: 450, height: 300)
        liveFrame = CGRect(x: 50, y: 100, width: 450, height: 300)
        tracker.update(cursorCG: CGPoint(x: 100, y: 110))
        XCTAssertEqual(carves, [liveFrame!.insetBy(dx: -2, dy: -2)])
    }

    func testSizeProbeIsThrottled() {
        let tracker = armed()
        tracker.update(cursorCG: .zero)
        // inside 0.1 s the new size goes unread, and the window has not moved
        clock += 0.05
        size = CGSize(width: 450, height: 300)
        tracker.update(cursorCG: .zero)
        XCTAssertTrue(carves.isEmpty)
        clock += 0.06
        liveFrame = start
        tracker.update(cursorCG: .zero)
        XCTAssertEqual(carves.count, 1)
    }

    func testResizeFallsBackToTheStartFrame() {
        let tracker = armed()
        size = CGSize(width: 450, height: 300)
        liveFrame = nil
        tracker.update(cursorCG: .zero)
        XCTAssertEqual(carves, [start.insetBy(dx: -2, dy: -2)])
    }

    func testDisarmKeepsTheOverrideAndFinishClearsIt() {
        let tracker = armed()
        tracker.disarm()
        XCTAssertFalse(tracker.isArmed)
        XCTAssertEqual(cleared, 0)
        position = CGPoint(x: 200, y: 200)
        tracker.update(cursorCG: .zero)
        XCTAssertTrue(carves.isEmpty)
        tracker.finish()
        XCTAssertEqual(cleared, 1)
    }
}
