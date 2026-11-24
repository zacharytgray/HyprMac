import XCTest
@testable import HyprMac

// lesson 2 on the practice windows: a task counts when its key ran and the
// windows show it; the practice session moves to an empty workspace and back
final class MoveAroundLessonTests: XCTestCase {
    private final class FakeHost: PracticeHost {
        var current = 1
        var empty: Int? = 3
        var switches: [Int] = []
        func currentWorkspace() -> Int? { current }
        func emptyWorkspace() -> Int? { empty }
        func switchToWorkspace(_ number: Int) {
            switches.append(number)
            current = number
        }
    }

    private var clock = Date(timeIntervalSince1970: 1000)
    private var practice: PracticeSession!
    private var model: MoveAroundLessonModel!

    override func setUp() {
        practice = PracticeSession(host: nil)
        model = MoveAroundLessonModel(practice: practice, window: 1.5) { [unowned self] in self.clock }
        practice.apply(["focused": 1, "order": [1, 2, 3]])
        model.start()
    }

    override func tearDown() {
        model.stop()
    }

    private func report(focused: Int, order: [Int] = [1, 2, 3]) {
        practice.apply(["focused": focused, "order": order])
    }

    func testFocusAwayBackAndSwap() {
        model.noteFocusKey()
        report(focused: 2)
        XCTAssertTrue(model.focusedAway)
        XCTAssertFalse(model.focusedBack)

        model.noteFocusKey()
        report(focused: 1)
        XCTAssertTrue(model.focusedBack)

        model.noteSwapKey()
        report(focused: 1, order: [2, 1, 3])
        XCTAssertTrue(model.swapped)
        XCTAssertTrue(model.isDone)
    }

    func testFocusFromTheMouseAloneDoesNotCount() {
        report(focused: 2)
        XCTAssertFalse(model.focusedAway)
    }

    func testAStaleKeyDoesNotCount() {
        model.noteFocusKey()
        clock.addTimeInterval(2)
        report(focused: 2)
        XCTAssertFalse(model.focusedAway)
    }

    func testFocusBackMeansTheFirstWindowAgain() {
        model.noteFocusKey()
        report(focused: 2)
        model.noteFocusKey()
        report(focused: 3)
        XCTAssertFalse(model.focusedBack)
        model.noteFocusKey()
        report(focused: 1)
        XCTAssertTrue(model.focusedBack)
    }

    func testWithoutTheHelperTheKeysAloneCount() {
        let alone = MoveAroundLessonModel(practice: PracticeSession(host: nil))
        alone.noteFocusKey()
        alone.noteFocusKey()
        alone.noteSwapKey()
        XCTAssertTrue(alone.isDone)
    }

    func testPracticeMovesToAnEmptyWorkspaceAndBack() {
        let host = FakeHost()
        let session = PracticeSession(host: host)
        session.begin()
        XCTAssertEqual(host.switches, [3])
        session.end()
        XCTAssertEqual(host.switches, [3, 1])
    }

    private final class FakeHelper: PracticeHelperProcess {
        var processIdentifier: pid_t { 4242 }
        var terminated = 0
        func terminate() -> Bool { terminated += 1; return true }
    }

    // the open call can hand the helper back after the tutorial ended
    func testAHelperThatOpensAfterTheEndIsQuit() {
        let session = PracticeSession(host: FakeHost())
        session.begin()
        let launch = session.launch
        session.end()
        let late = FakeHelper()
        session.adoptHelper(late, launch: launch)
        XCTAssertEqual(late.terminated, 1)
    }

    // or after the session ended and began again: that one isn't ours either
    func testAHelperFromAnEarlierBeginIsQuit() {
        let session = PracticeSession(host: FakeHost())
        session.begin()
        let first = session.launch
        session.end()
        session.begin()
        let stale = FakeHelper()
        session.adoptHelper(stale, launch: first)
        XCTAssertEqual(stale.terminated, 1)
        let current = FakeHelper()
        session.adoptHelper(current, launch: session.launch)
        XCTAssertEqual(current.terminated, 0)
        session.end()
        XCTAssertEqual(current.terminated, 1, "end quits the helper it kept")
    }

    func testPracticeStaysPutWithNoEmptyWorkspace() {
        let host = FakeHost()
        host.empty = nil
        let session = PracticeSession(host: host)
        session.begin()
        session.end()
        XCTAssertEqual(host.switches, [])
    }
}
