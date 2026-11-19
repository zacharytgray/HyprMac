import XCTest
@testable import HyprMac

// DiscoveryFollowUpTests pin the bounded re-poll after a window create and
// the on-screen evidence a focus event uses to ask for discovery.

final class DiscoveryFollowUpTests: XCTestCase {

    private let pid: pid_t = 1159

    private func win(_ id: CGWindowID, pid: pid_t = 1159, layer: Int = 0,
                     size: CGFloat = 400, alpha: CGFloat = 1) -> StackedWindow {
        StackedWindow(windowID: id, ownerPID: pid, layer: layer,
                      bounds: CGRect(x: 0, y: 0, width: size, height: size), alpha: alpha)
    }

    func testUnknownOnScreenKeepsOnlyLargeVisibleLayerZeroWindowsDiscoveryDoesNotKnow() {
        let windows = [
            win(1), win(2), win(3, layer: 3), win(4, size: 20), win(5, alpha: 0),
            win(6, pid: 99), win(7), win(8, pid: 2),
        ]
        let unknown = DiscoveryFollowUp.unknownOnScreen(windows, known: [1], hidden: [7], ownPID: 2)
        XCTAssertEqual(unknown, [1159: [2], 99: [6]])
    }

    func testAWindowTheWalkReadAndFilteredOutIsNotUnknown() {
        // Helium's dropdown: AX lists it, the filter drops it by subrole
        let windows = [win(1), win(105605), win(105606)]
        let unknown = DiscoveryFollowUp.unknownOnScreen(windows, known: [1], hidden: [],
                                                        filtered: [105605], ownPID: 2)
        XCTAssertEqual(unknown, [1159: [105606]])
    }

    func testACreateForAFilteredPopupCostsTheBlindRetryOnly() {
        var f = DiscoveryFollowUp()
        let unknown = DiscoveryFollowUp.unknownOnScreen([win(105605)], known: [], hidden: [],
                                                        filtered: [105605], ownPID: 2)
        XCTAssertEqual(retries(&f, unknown: unknown[pid] ?? [], from: 0), 1)
    }

    func testAPollThatAdmitsTheAppsWindowEndsTheWatch() {
        var f = DiscoveryFollowUp()
        f.watch(pid: pid, reason: "windowCreated", blindRetry: true, now: 0)
        let out = f.afterPoll(admitted: [pid: [4628]], unknown: [:], now: 0.2)
        XCTAssertEqual(out, [.admitted(pid: pid, windowIDs: [4628], afterMS: 200, retries: 0, reason: "windowCreated")])
        XCTAssertTrue(f.watches.isEmpty)
    }

    func testMissedWindowRetriesOnTheBackoffThenGivesUp() {
        // the incident: AX never lists the window the window server shows
        var f = DiscoveryFollowUp()
        f.watch(pid: pid, reason: "windowCreated", blindRetry: true, now: 0)
        var delays: [TimeInterval] = []
        var t = 0.2
        for _ in 0..<3 {
            let out = f.afterPoll(admitted: [:], unknown: [pid: [4628]], now: t)
            guard case let .retry(_, after, _, unknown, _) = out.first else { return XCTFail("\(out)") }
            XCTAssertEqual(unknown, [4628])
            delays.append(after)
            t += after
        }
        XCTAssertEqual(delays, [0.3, 0.6, 1.2])
        let last = f.afterPoll(admitted: [:], unknown: [pid: [4628]], now: t)
        XCTAssertEqual(last, [.gaveUp(pid: pid, retries: 3, unknown: [4628], afterMS: 2300, reason: "windowCreated")])
        XCTAssertTrue(f.watches.isEmpty)
    }

    /// Runs a create watch to its end against `unknown` and returns how
    /// many polls it asked for after the first.
    private func retries(_ f: inout DiscoveryFollowUp, unknown: [CGWindowID], from start: TimeInterval) -> Int {
        f.watch(pid: pid, reason: "windowCreated", blindRetry: true, now: start)
        var t = start + 0.2
        var count = 0
        while true {
            let out = f.afterPoll(admitted: [:], unknown: unknown.isEmpty ? [:] : [pid: unknown], now: t)
            guard case let .retry(_, after, _, _, _) = out.first else { return count }
            count += 1
            t += after
        }
    }

    func testAWindowAWatchGaveUpOnIsNoEvidenceForTheNextCreate() {
        // Safari: two layer-0 windows AX never lists, and a create per popover
        var f = DiscoveryFollowUp()
        XCTAssertEqual(retries(&f, unknown: [104038, 104075], from: 0), 3)
        XCTAssertEqual(f.givenUp, [104038, 104075])
        // the next create gets its blind retry and nothing more
        XCTAssertEqual(retries(&f, unknown: [104038, 104075], from: 10), 1)
        XCTAssertTrue(f.watches.isEmpty)
    }

    func testANewUnknownWindowBesideAGivenUpOneGetsTheWholeBudget() {
        var f = DiscoveryFollowUp()
        _ = retries(&f, unknown: [104038], from: 0)
        f.watch(pid: pid, reason: "windowCreated", blindRetry: true, now: 10)
        let out = f.afterPoll(admitted: [:], unknown: [pid: [104038, 105000]], now: 10.2)
        XCTAssertEqual(out, [.retry(pid: pid, after: 0.3, attempt: 1, unknown: [105000], reason: "windowCreated")])
        f.forget(pid: pid)
        XCTAssertEqual(retries(&f, unknown: [104038, 105000], from: 20), 3)
    }

    func testAGivenUpWindowThatLeftTheScreenCountsAgainWhenItComesBack() {
        var f = DiscoveryFollowUp()
        _ = retries(&f, unknown: [104038], from: 0)
        _ = f.afterPoll(admitted: [:], unknown: [:], now: 10)
        XCTAssertTrue(f.givenUp.isEmpty)
        XCTAssertEqual(retries(&f, unknown: [104038], from: 20), 3)
    }

    func testRetryThatFindsTheWindowStops() {
        var f = DiscoveryFollowUp()
        f.watch(pid: pid, reason: "windowCreated", blindRetry: true, now: 0)
        _ = f.afterPoll(admitted: [:], unknown: [pid: [4628]], now: 0.2)
        let out = f.afterPoll(admitted: [pid: [4628]], unknown: [:], now: 0.5)
        XCTAssertEqual(out, [.admitted(pid: pid, windowIDs: [4628], afterMS: 500, retries: 1, reason: "windowCreated")])
    }

    func testCreateGetsOneBlindRetryThenSettlesWithNothingOnScreen() {
        // Dia sends its create after the focus poll already admitted the
        // window: nothing is left to find, so one extra look and done
        var f = DiscoveryFollowUp()
        f.watch(pid: pid, reason: "windowCreated", blindRetry: true, now: 0)
        let first = f.afterPoll(admitted: [:], unknown: [:], now: 0.2)
        XCTAssertEqual(first, [.retry(pid: pid, after: 0.3, attempt: 1, unknown: [], reason: "windowCreated")])
        let second = f.afterPoll(admitted: [:], unknown: [:], now: 0.5)
        XCTAssertEqual(second, [.settled(pid: pid, retries: 1, reason: "windowCreated")])
    }

    func testFocusWatchHasNoBlindRetry() {
        var f = DiscoveryFollowUp()
        f.watch(pid: pid, reason: "axMain", blindRetry: false, now: 0)
        XCTAssertEqual(f.afterPoll(admitted: [:], unknown: [:], now: 0.2),
                       [.settled(pid: pid, retries: 0, reason: "axMain")])
    }

    func testPollRightAfterTheEventIsNotItsFirstLook() {
        // a poll already pending ran ms after the create; the trailing poll
        // is the real first look and the budget is untouched
        var f = DiscoveryFollowUp()
        f.watch(pid: pid, reason: "windowCreated", blindRetry: true, now: 0)
        XCTAssertEqual(f.afterPoll(admitted: [:], unknown: [pid: [4628]], now: 0.01), [])
        XCTAssertEqual(f.watches[pid]?.retries, 0)
    }

    func testASecondCreateDoesNotExtendTheBudget() {
        var f = DiscoveryFollowUp()
        f.watch(pid: pid, reason: "windowCreated", blindRetry: true, now: 0)
        _ = f.afterPoll(admitted: [:], unknown: [pid: [1]], now: 0.2)
        f.watch(pid: pid, reason: "windowCreated", blindRetry: true, now: 0.3)
        XCTAssertEqual(f.watches[pid]?.retries, 1)
        XCTAssertEqual(f.watches[pid]?.since, 0)
    }

    func testFocusAsksOncePerUnseenWindow() {
        var f = DiscoveryFollowUp()
        XCTAssertEqual(f.unpolled([4628], now: 0), [4628])
        XCTAssertEqual(f.unpolled([4628], now: 0.01), [], "a poll is already asked for")
        _ = f.afterPoll(admitted: [:], unknown: [pid: [4628]], now: 0.2)
        XCTAssertEqual(f.unpolled([4628], now: 0.5), [], "a poll walked past it; a rejected window costs one poll")
        XCTAssertEqual(f.unpolled([4630], now: 0.5), [4630])
    }

    func testWindowThatLeavesTheScreenIsAskedForAgainWhenItComesBack() {
        var f = DiscoveryFollowUp()
        _ = f.unpolled([4628], now: 0)
        _ = f.afterPoll(admitted: [:], unknown: [pid: [4628]], now: 0.2)
        _ = f.afterPoll(admitted: [:], unknown: [:], now: 0.4)
        XCTAssertEqual(f.unpolled([4628], now: 0.6), [4628])
    }

    func testOnScreenTimeCountsFromTheFirstSighting() {
        var f = DiscoveryFollowUp()
        _ = f.afterPoll(admitted: [:], unknown: [pid: [4628]], now: 1)
        XCTAssertEqual(f.onScreenMS(4628, now: 5.65), 4650)
        XCTAssertNil(f.onScreenMS(9, now: 5.65))
        _ = f.afterPoll(admitted: [pid: [4628]], unknown: [:], now: 6)
        XCTAssertNil(f.onScreenMS(4628, now: 6), "admitted windows drop their mark")
    }

    func testEventsAreRememberedForTheReconcileLine() {
        var f = DiscoveryFollowUp()
        f.noteEvent("windowCreated", pid: pid, now: 1)
        f.noteEvent("focusedWindowChanged", pid: pid, now: 2)
        XCTAssertEqual(f.lastEvent[pid]?.kind, "focusedWindowChanged")
        XCTAssertEqual(f.lastCreate[pid], 1)
        f.forget(pid: pid)
        XCTAssertNil(f.lastEvent[pid])
        XCTAssertNil(f.lastCreate[pid])
    }
}

// StalePressCheckTests pin when a press with no button held counts as a
// missed mouse-up.

final class StalePressCheckTests: XCTestCase {

    func testNeedsTwoChecksAQuarterSecondApart() {
        var c = StalePressCheck()
        XCTAssertFalse(c.isStale(pressHeld: true, physicalDown: false, now: 0), "the release may be queued")
        XCTAssertFalse(c.isStale(pressHeld: true, physicalDown: false, now: 0.1))
        XCTAssertTrue(c.isStale(pressHeld: true, physicalDown: false, now: 0.3))
    }

    func testHeldButtonIsNeverStale() {
        var c = StalePressCheck()
        XCTAssertFalse(c.isStale(pressHeld: true, physicalDown: true, now: 0))
        XCTAssertFalse(c.isStale(pressHeld: true, physicalDown: true, now: 5))
    }

    func testReleaseInBetweenStartsOver() {
        var c = StalePressCheck()
        _ = c.isStale(pressHeld: true, physicalDown: false, now: 0)
        XCTAssertFalse(c.isStale(pressHeld: false, physicalDown: false, now: 0.1))
        XCTAssertFalse(c.isStale(pressHeld: true, physicalDown: false, now: 0.3))
    }

    func testNewPressStartsOver() {
        var c = StalePressCheck()
        _ = c.isStale(pressHeld: true, physicalDown: false, now: 0)
        c.reset()
        XCTAssertFalse(c.isStale(pressHeld: true, physicalDown: false, now: 0.3))
    }
}
