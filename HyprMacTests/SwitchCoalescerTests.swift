import XCTest
@testable import HyprMac

// SwitchCoalescerTests pin which queued hotkey actions still run once main
// gets to them. monitors: 1-5 on one screen, 6-9 on another.

final class SwitchCoalescerTests: XCTestCase {

    private func sameMonitor(_ a: Int, _ b: Int) -> Bool { (a <= 5) == (b <= 5) }

    /// Queues every action first (main busy), then runs them in order.
    private func ran(_ actions: [Action]) -> [Action] {
        let c = SwitchCoalescer()
        let tokens = actions.map { c.enqueue($0) }
        return zip(actions, tokens).filter { c.shouldRun($0, token: $1, sameMonitor: sameMonitor) }.map(\.0)
    }

    func testLaterSwitchOnSameMonitorReplacesEarlier() {
        XCTAssertEqual(ran([.switchWorkspace(3), .switchWorkspace(4), .switchWorkspace(2)]),
                       [.switchWorkspace(2)])
    }

    func testSwitchesOnDifferentMonitorsBothRun() {
        XCTAssertEqual(ran([.switchWorkspace(3), .switchWorkspace(7)]),
                       [.switchWorkspace(3), .switchWorkspace(7)])
    }

    func testOnlyTheMonitorWithALaterSwitchGivesWay() {
        XCTAssertEqual(ran([.switchWorkspace(3), .switchWorkspace(7), .switchWorkspace(4)]),
                       [.switchWorkspace(7), .switchWorkspace(4)])
    }

    func testOtherActionEndsTheRun() {
        let actions: [Action] = [.switchWorkspace(3), .cycleWorkspace(1), .switchWorkspace(4)]
        XCTAssertEqual(ran(actions), actions)
    }

    func testSwitchThatAlreadyRanIsNotAffected() {
        let c = SwitchCoalescer()
        let first = c.enqueue(.switchWorkspace(3))
        XCTAssertTrue(c.shouldRun(.switchWorkspace(3), token: first, sameMonitor: sameMonitor))
        let second = c.enqueue(.switchWorkspace(4))
        XCTAssertTrue(c.shouldRun(.switchWorkspace(4), token: second, sameMonitor: sameMonitor))
    }
}
