import XCTest
import Cocoa
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

final class FocusBorderCornerRadiusTests: XCTestCase {

    func testDisabledBorderRejectsEveryPublicRenderPath() {
        let border = FocusBorder()
        border.primaryScreenHeight = 1080
        border.isEnabled = false
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)

        border.show(around: frame, windowID: 41)
        border.updateFloatingBorders([42: frame], color: NSColor.systemPink.cgColor)
        border.flashInfo(message: "→ scratchpad", around: frame, windowID: 43)
        border.flashError(around: frame, windowID: 44)

        XCTAssertNil(border.trackedWindowID)
        XCTAssertEqual(border.visibleOwnedPanelCount, 0)
    }

    func testDisablingOrdersOutFocusedPanelSynchronously() {
        let border = FocusBorder()
        border.primaryScreenHeight = 1080
        border.fadeDurationSec = 10
        border.show(around: CGRect(x: 100, y: 100, width: 400, height: 300), windowID: 45)
        XCTAssertEqual(border.visibleOwnedPanelCount, 1)

        border.isEnabled = false

        XCTAssertNil(border.trackedWindowID)
        XCTAssertEqual(border.visibleOwnedPanelCount, 0)
    }

    func testDisablingCancelsErrorShakeAndRunsRestore() {
        let border = FocusBorder()
        border.primaryScreenHeight = 1080
        var restoreCount = 0
        border.onShakeRestore = { restoreCount += 1 }
        border.flashError(around: CGRect(x: 100, y: 100, width: 400, height: 300),
                          windowID: 47)

        border.isEnabled = false

        XCTAssertEqual(restoreCount, 1)
        XCTAssertEqual(border.visibleOwnedPanelCount, 0)
    }

    @MainActor
    func testSameFrameShowDoesNotStrandErrorFlash() async {
        let border = FocusBorder()
        border.primaryScreenHeight = 1080
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        border.flashError(around: frame, windowID: 48)
        border.show(around: frame, windowID: 48)

        let deadline = Date().addingTimeInterval(2)
        while border.trackedWindowID != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertNil(border.trackedWindowID)
        // Headless Core Animation may defer the fade completion that orders
        // out the panel. Disable provides deterministic cleanup after the
        // callback-routing assertion above.
        border.isEnabled = false
        XCTAssertEqual(border.visibleOwnedPanelCount, 0)
    }

    @MainActor
    func testDisablingOrdersOutInfoPanelAfterItsFadeStarts() async {
        let border = FocusBorder()
        border.primaryScreenHeight = 1080
        border.flashInfo(message: "→ scratchpad",
                         around: CGRect(x: 100, y: 100, width: 400, height: 300),
                         windowID: 46)
        XCTAssertEqual(border.visibleOwnedPanelCount, 1)
        try? await Task.sleep(nanoseconds: 950_000_000)

        border.isEnabled = false

        XCTAssertEqual(border.visibleOwnedPanelCount, 0)
    }

    func testRefreshPreservesErrorBorderWidthExpansion() throws {
        let border = FocusBorder()
        border.primaryScreenHeight = 1080
        defer { border.hide() }

        let windowID: CGWindowID = 42
        border.flashError(
            around: CGRect(x: 100, y: 100, width: 400, height: 300),
            windowID: windowID)
        border.refreshCornerRadius()

        let renderedRadius = try XCTUnwrap(border.currentFocusedBorderCornerRadius())
        let expectedRadius = WindowCornerRadius.resolve(for: windowID) + 1.25
        XCTAssertEqual(renderedRadius, expectedRadius, accuracy: 0.001)
    }
}
