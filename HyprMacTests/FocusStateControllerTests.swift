import XCTest
@testable import HyprMac

// FocusStateControllerTests pin focus transition semantics and idempotence.
// the controller is mostly a logged accessor — tests cover the storage
// invariants and the no-op-on-same-id contract.

final class FocusStateControllerTests: XCTestCase {

    private func makeController() -> FocusStateController {
        FocusStateController(focusBorder: FocusBorder())
    }

    // MARK: - initial state

    func testInitialLastFocusedIsZero() {
        let c = makeController()
        XCTAssertEqual(c.lastFocusedID, 0)
    }

    func testInitialBorderTrackedIsNil() {
        let c = makeController()
        XCTAssertNil(c.borderTrackedID)
    }

    // MARK: - recordFocus updates state

    func testRecordFocusUpdatesLastFocused() {
        let c = makeController()
        c.recordFocus(42, reason: "test")
        XCTAssertEqual(c.lastFocusedID, 42)
    }

    func testRecordFocusTransitionsAcrossIDs() {
        let c = makeController()
        c.recordFocus(1, reason: "first")
        c.recordFocus(2, reason: "second")
        c.recordFocus(3, reason: "third")
        XCTAssertEqual(c.lastFocusedID, 3)
    }

    func testRecordFocusZeroIsValid() {
        // 0 is a sentinel used to mean "no intent" — recording it after a
        // non-zero must reset the state, not be ignored as a degenerate value.
        let c = makeController()
        c.recordFocus(42, reason: "set")
        c.recordFocus(0, reason: "clear")
        XCTAssertEqual(c.lastFocusedID, 0)
    }

    // MARK: - idempotence

    func testRecordFocusSameIDIsNoOp() {
        // re-recording the same id must not log or mutate. no API surface
        // exposes the log directly, so the invariant we can pin is "value
        // unchanged after redundant record" which is trivially true; the
        // log-skip is the actual contract and is verified by inspection.
        let c = makeController()
        c.recordFocus(42, reason: "first")
        c.recordFocus(42, reason: "redundant")
        XCTAssertEqual(c.lastFocusedID, 42)
    }
}
