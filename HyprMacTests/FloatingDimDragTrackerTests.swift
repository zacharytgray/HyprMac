import XCTest
@testable import HyprMac

final class FloatingDimDragTrackerTests: XCTestCase {
    private var carves: [CGRect] = []
    private var cleared = 0
    private var clock: TimeInterval = 100
    private var listFrame: CGRect?
    private var reads = 0
    private let start = CGRect(x: 100, y: 100, width: 400, height: 300)

    private func armed(startFrame: CGRect? = nil) -> FloatingDimDragTracker {
        let tracker = FloatingDimDragTracker(
            now: { [unowned self] in self.clock },
            setCarve: { [unowned self] _, rect in self.carves.append(rect) },
            clearCarve: { [unowned self] in self.cleared += 1 })
        listFrame = start
        tracker.arm(id: 7,
                    readFrame: { [unowned self] in
                        self.reads += 1
                        return self.listFrame
                    },
                    startFrame: startFrame ?? start, downPointCG: CGPoint(x: 150, y: 110))
        reads = 0
        return tracker
    }

    func testContentDragNeverMovesTheCarve() {
        let tracker = armed()
        tracker.update(cursorCG: CGPoint(x: 400, y: 400))
        listFrame = start.offsetBy(dx: 2, dy: 1) // noise, under the guard
        tracker.update(cursorCG: CGPoint(x: 500, y: 500))
        XCTAssertTrue(carves.isEmpty)
    }

    func testAStartFrameOffTheWindowListDoesNotConfirm() {
        // the anchor came from AX, which can still hold the last drag's origin
        let tracker = armed(startFrame: start.offsetBy(dx: -80, dy: 0))
        tracker.update(cursorCG: CGPoint(x: 400, y: 400))
        XCTAssertTrue(carves.isEmpty)
    }

    func testFirstMoveConfirmsWithoutWaiting() {
        let tracker = armed()
        listFrame = start.offsetBy(dx: 4, dy: 0)
        tracker.update(cursorCG: CGPoint(x: 154, y: 110))
        XCTAssertEqual(carves, [start.offsetBy(dx: 4, dy: 0).insetBy(dx: -2, dy: -2)])
    }

    func testEveryEventChecksUntilConfirmed() {
        let tracker = armed()
        tracker.update(cursorCG: .zero)
        tracker.update(cursorCG: .zero)
        XCTAssertEqual(reads, 2)
    }

    func testConfirmedMoveTracksOffTheMouseDownPair() {
        let tracker = armed()
        listFrame = start.offsetBy(dx: 10, dy: 0) // behind the cursor, must not be used
        tracker.update(cursorCG: CGPoint(x: 350, y: 310))
        let expected = start.offsetBy(dx: 200, dy: 200).insetBy(dx: -2, dy: -2)
        XCTAssertEqual(carves, [expected])
    }

    func testStaysConfirmedWithoutAnotherRead() {
        let tracker = armed()
        listFrame = start.offsetBy(dx: 10, dy: 0)
        tracker.update(cursorCG: CGPoint(x: 160, y: 110))
        listFrame = nil
        tracker.update(cursorCG: CGPoint(x: 170, y: 110))
        XCTAssertEqual(carves.count, 2)
        XCTAssertEqual(reads, 1)
    }

    func testEdgeResizeFollowsTheLiveFrame() {
        let tracker = armed()
        listFrame = CGRect(x: 50, y: 100, width: 450, height: 300)
        tracker.update(cursorCG: CGPoint(x: 100, y: 110))
        XCTAssertEqual(carves, [listFrame!.insetBy(dx: -2, dy: -2)])
    }

    func testSizeCheckIsThrottledOnceConfirmed() {
        let tracker = armed()
        listFrame = start.offsetBy(dx: 10, dy: 0)
        tracker.update(cursorCG: CGPoint(x: 160, y: 110))
        // inside 0.1 s the new size goes unread: still delta math
        clock += 0.05
        listFrame = CGRect(x: 110, y: 100, width: 450, height: 300)
        tracker.update(cursorCG: CGPoint(x: 170, y: 110))
        XCTAssertEqual(carves.last, start.offsetBy(dx: 20, dy: 0).insetBy(dx: -2, dy: -2))
        clock += 0.06
        tracker.update(cursorCG: CGPoint(x: 180, y: 110))
        XCTAssertEqual(carves.last, listFrame!.insetBy(dx: -2, dy: -2))
    }

    func testResizeFallsBackToTheStartFrame() {
        var answers: [CGRect?] = [CGRect(x: 100, y: 100, width: 450, height: 300), nil]
        let tracker = FloatingDimDragTracker(
            now: { [unowned self] in self.clock },
            setCarve: { [unowned self] _, rect in self.carves.append(rect) },
            clearCarve: {})
        var armedYet = false
        tracker.arm(id: 7,
                    readFrame: {
                        defer { armedYet = true }
                        return armedYet ? answers.removeFirst() : self.start
                    },
                    startFrame: start, downPointCG: .zero)
        tracker.update(cursorCG: .zero)
        XCTAssertEqual(carves, [start.insetBy(dx: -2, dy: -2)])
    }

    func testAMissingListAtPressFallsBackToTheStartFrame() {
        let tracker = FloatingDimDragTracker(
            now: { [unowned self] in self.clock },
            setCarve: { [unowned self] _, rect in self.carves.append(rect) },
            clearCarve: {})
        var answers: [CGRect?] = [nil, start.offsetBy(dx: 10, dy: 0)]
        tracker.arm(id: 7, readFrame: { answers.removeFirst() },
                    startFrame: start, downPointCG: .zero)
        tracker.update(cursorCG: CGPoint(x: 10, y: 0))
        XCTAssertEqual(carves, [start.offsetBy(dx: 10, dy: 0).insetBy(dx: -2, dy: -2)])
    }

    func testDisarmKeepsTheOverrideAndFinishClearsIt() {
        let tracker = armed()
        tracker.disarm()
        XCTAssertFalse(tracker.isArmed)
        XCTAssertEqual(cleared, 0)
        listFrame = start.offsetBy(dx: 100, dy: 100)
        tracker.update(cursorCG: .zero)
        XCTAssertTrue(carves.isEmpty)
        tracker.finish()
        XCTAssertEqual(cleared, 1)
    }
}
