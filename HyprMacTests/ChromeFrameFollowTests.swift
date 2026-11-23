import XCTest
@testable import HyprMac

// the chrome follows a window that moved or resized without HyprMac asking:
// one follow per run loop turn, and one full refresh once the moves stop
final class ChromeFrameFollowTests: XCTestCase {
    private var scheduled: [(delay: TimeInterval, body: () -> Void)] = []
    private var follows: [[CGWindowID]] = []
    // what follow reports as not moved yet in the window list
    private var notYet: Set<CGWindowID> = []
    private var settles = 0

    private func make(tracked: Set<CGWindowID>) -> ChromeFrameFollow {
        let follow = ChromeFrameFollow(
            isTracked: { tracked.contains($0) },
            follow: { [unowned self] ids in
                self.follows.append(ids)
                return ids.filter { self.notYet.contains($0) }
            },
            settle: { [unowned self] in self.settles += 1 },
            schedule: { [unowned self] delay, body in self.scheduled.append((delay, body)) })
        return follow
    }

    private func run(delay: TimeInterval) {
        let due = scheduled.filter { $0.delay == delay }
        scheduled.removeAll { $0.delay == delay }
        for item in due { item.body() }
    }

    func testAWindowWithNoChromeIsIgnored() {
        let follow = make(tracked: [7])
        follow.noteFrameChange(9)
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testMovesInOneTurnFollowOnceEachWindowOnce() {
        let follow = make(tracked: [7, 8])
        follow.noteFrameChange(7)
        follow.noteFrameChange(8)
        follow.noteFrameChange(7)
        run(delay: 0)
        XCTAssertEqual(follows, [[7, 8]])
        follow.noteFrameChange(8)
        run(delay: 0)
        XCTAssertEqual(follows, [[7, 8], [8]])
    }

    // an app posts the move before the window server has the new frame, so a
    // window the list still shows at the old spot is read again next frame
    func testAWindowTheListHasNotMovedYetIsReadAgainNextFrame() {
        let follow = make(tracked: [7, 8])
        notYet = [7]
        follow.noteFrameChange(7)
        follow.noteFrameChange(8)
        run(delay: 0)
        run(delay: ChromeFrameFollow.retryDelay)
        notYet = []
        run(delay: ChromeFrameFollow.retryDelay)
        XCTAssertEqual(follows, [[7, 8], [7], [7]])
        XCTAssertTrue(scheduled.allSatisfy { $0.delay != ChromeFrameFollow.retryDelay })
    }

    func testTheRereadsStopAfterTheBudget() {
        let follow = make(tracked: [7])
        notYet = [7]
        follow.noteFrameChange(7)
        run(delay: 0)
        for _ in 0..<(ChromeFrameFollow.maxRereads + 3) { run(delay: ChromeFrameFollow.retryDelay) }
        XCTAssertEqual(follows.count, 1 + ChromeFrameFollow.maxRereads)
    }

    func testTheFullRefreshWaitsForTheLastMove() {
        let follow = make(tracked: [7])
        follow.noteFrameChange(7)
        follow.noteFrameChange(7)
        run(delay: ChromeFrameFollow.settleDelay)
        XCTAssertEqual(settles, 1, "only the last move's refresh runs")
    }
}
