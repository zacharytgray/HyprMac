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
        return zip(actions, tokens).compactMap { c.admit($0, token: $1, sameMonitor: sameMonitor)?.action }
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

    func testCycleEndsTheSwitchRun() {
        let actions: [Action] = [.switchWorkspace(3), .cycleWorkspace(1), .switchWorkspace(4)]
        XCTAssertEqual(ran(actions), actions)
    }

    func testSwitchThatAlreadyRanIsNotAffected() {
        let c = SwitchCoalescer()
        let first = c.enqueue(.switchWorkspace(3))
        XCTAssertNotNil(c.admit(.switchWorkspace(3), token: first, sameMonitor: sameMonitor))
        let second = c.enqueue(.switchWorkspace(4))
        XCTAssertNotNil(c.admit(.switchWorkspace(4), token: second, sameMonitor: sameMonitor))
    }

    // MARK: - cycleWorkspace

    func testQueuedCyclesRunOnceWithSummedDelta() {
        let c = SwitchCoalescer()
        let tokens = (0..<4).map { _ in c.enqueue(.cycleWorkspace(1)) }
        let results = tokens.map { c.admit(.cycleWorkspace(1), token: $0, sameMonitor: sameMonitor) }
        XCTAssertEqual(results.dropLast().compactMap { $0 }.count, 0)
        XCTAssertEqual(results.last??.action, .cycleWorkspace(4))
        XCTAssertEqual(results.last??.merged, 4)
    }

    func testSignChangeEndsTheCycleRun() {
        XCTAssertEqual(ran([.cycleWorkspace(1), .cycleWorkspace(1), .cycleWorkspace(-1),
                            .cycleWorkspace(-1), .cycleWorkspace(1)]),
                       [.cycleWorkspace(2), .cycleWorkspace(-2), .cycleWorkspace(1)])
    }

    func testSwitchEndsTheCycleRun() {
        XCTAssertEqual(ran([.cycleWorkspace(1), .switchWorkspace(3), .cycleWorkspace(1)]),
                       [.cycleWorkspace(1), .switchWorkspace(3), .cycleWorkspace(1)])
    }

    func testOtherActionEndsTheCycleRun() {
        XCTAssertEqual(ran([.cycleWorkspace(1), .cycleWorkspace(1), .toggleFloating,
                            .cycleWorkspace(1)]),
                       [.cycleWorkspace(2), .toggleFloating, .cycleWorkspace(1)])
    }

    func testHandWrittenBigDeltaIsNeverMerged() {
        let actions: [Action] = [.cycleWorkspace(.max), .cycleWorkspace(.max)]
        XCTAssertEqual(ran(actions), actions)
        XCTAssertEqual(ActionDispatcher.cycleTarget(from: 1, delta: .min, occupied: [2, 5], total: 10), 2)
    }

    func testCycleThatAlreadyRanIsNotMerged() {
        let c = SwitchCoalescer()
        let first = c.enqueue(.cycleWorkspace(1))
        XCTAssertEqual(c.admit(.cycleWorkspace(1), token: first, sameMonitor: sameMonitor)?.action,
                       .cycleWorkspace(1))
        let second = c.enqueue(.cycleWorkspace(1))
        XCTAssertEqual(c.admit(.cycleWorkspace(1), token: second, sameMonitor: sameMonitor)?.action,
                       .cycleWorkspace(1))
    }

    // MARK: - cycleTarget: a summed delta lands where single steps would

    private func stepped(from start: Int, _ deltas: [Int], occupied: Set<Int>) -> Int? {
        var current = start
        for d in deltas {
            guard let next = ActionDispatcher.cycleTarget(from: current, delta: d, occupied: occupied, total: 10)
            else { return nil }
            current = next
        }
        return current
    }

    func testSummedDeltaMatchesSingleStepsWithWrapAround() {
        let occupied: Set<Int> = [2, 5, 9]
        for start in 1...10 {
            for k in 1...7 {
                XCTAssertEqual(ActionDispatcher.cycleTarget(from: start, delta: k, occupied: occupied, total: 10),
                               stepped(from: start, Array(repeating: 1, count: k), occupied: occupied),
                               "start \(start) +\(k)")
                XCTAssertEqual(ActionDispatcher.cycleTarget(from: start, delta: -k, occupied: occupied, total: 10),
                               stepped(from: start, Array(repeating: -1, count: k), occupied: occupied),
                               "start \(start) -\(k)")
            }
        }
    }

    func testCycleWrapsPastTheLastWorkspace() {
        XCTAssertEqual(ActionDispatcher.cycleTarget(from: 9, delta: 2, occupied: [2, 5, 9], total: 10), 5)
        XCTAssertEqual(ActionDispatcher.cycleTarget(from: 2, delta: -1, occupied: [2, 5, 9], total: 10), 9)
    }

    func testCycleFromEmptyWorkspaceLandsOnNextOccupied() {
        XCTAssertEqual(ActionDispatcher.cycleTarget(from: 4, delta: 1, occupied: [2, 6], total: 10), 6)
        XCTAssertEqual(ActionDispatcher.cycleTarget(from: 4, delta: -1, occupied: [2, 6], total: 10), 2)
    }

    func testCycleWithNothingOccupiedOrZeroDeltaDoesNothing() {
        XCTAssertNil(ActionDispatcher.cycleTarget(from: 1, delta: 1, occupied: [], total: 10))
        XCTAssertNil(ActionDispatcher.cycleTarget(from: 1, delta: 0, occupied: [3], total: 10))
    }
}
