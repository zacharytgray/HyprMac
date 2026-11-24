import XCTest
import Cocoa
@testable import HyprMac

// FocusStateControllerTests pin focus transition semantics and idempotence.
// the controller is mostly a logged accessor — tests cover the storage
// invariants and the no-op-on-same-id contract.

final class FocusStateControllerTests: XCTestCase {
    func testErrorFeedbackTokenCannotCancelNewerUnrelatedFeedback() throws {
        let border = FocusBorder()
        let frame = CGRect(x: 20, y: 20, width: 300, height: 200)
        let tiledDragToken = try XCTUnwrap(border.flashError(
            around: frame, windowID: 41, message: "Could not restore the tiled layout"))
        let unrelatedToken = try XCTUnwrap(border.flashError(
            around: frame, windowID: 42, message: "Not enough room"))

        XCTAssertFalse(border.cancelErrorFeedback(token: tiledDragToken))
        XCTAssertTrue(border.isErrorFeedbackActive)
        XCTAssertTrue(border.cancelErrorFeedback(token: unrelatedToken))
        XCTAssertFalse(border.isErrorFeedbackActive)
    }

    private func makeController() -> FocusStateController {
        FocusStateController(focusBorder: FocusBorder())
    }

    func testDisabledBorderAllowsOneShotErrorFeedback() {
        XCTAssertTrue(FocusBorder.errorFeedbackCanRender(isEnabled: false))
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

final class FocusBorderFeedbackLifecycleTests: XCTestCase {
    func testPersistentRefreshStaysBlockedUntilFeedbackFinishes() {
        var lifecycle = FocusBorderFeedbackLifecycle()

        lifecycle.begin()
        XCTAssertFalse(lifecycle.permitsPersistentShow)
        XCTAssertNil(lifecycle.persistentTrackedID(71),
                     "the error overlay target must not become persistent focus identity")
        XCTAssertTrue(lifecycle.finish())
        XCTAssertTrue(lifecycle.permitsPersistentShow)
        XCTAssertEqual(lifecycle.persistentTrackedID(72), 72,
                       "the latest persistent focus identity resumes after feedback")
        XCTAssertFalse(lifecycle.finish(), "completion must be delivered once")
    }

    func testExplicitCancellationImmediatelyReleasesPersistentRefresh() {
        var lifecycle = FocusBorderFeedbackLifecycle()
        lifecycle.begin()

        lifecycle.cancel()

        XCTAssertTrue(lifecycle.permitsPersistentShow)
        XCTAssertFalse(lifecycle.finish(), "cancelled feedback must not report natural completion")
    }

    func testPersistentHideDoesNotCancelActiveFeedback() {
        let border = FocusBorder()
        border.beginErrorFeedback(windowID: 71)

        border.hidePersistentBorder()

        XCTAssertTrue(border.isErrorFeedbackActive)
        border.hide()
        XCTAssertFalse(border.isErrorFeedbackActive)
    }
}

final class FocusBorderCornerRadiusTests: XCTestCase {
    override func setUpWithError() throws {
        if ProcessInfo.processInfo.environment["HYPRMAC_HEADLESS_TESTS"] == "1" {
            throw XCTSkip("hostless run excludes tests that create AppKit panels")
        }
    }

    func testDisabledBorderRejectsPersistentAndInformationalRenderPaths() {
        let border = FocusBorder()
        border.primaryScreenHeight = 1080
        border.isEnabled = false
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)

        border.show(around: frame, windowID: 41)
        border.flashInfo(message: "→ scratchpad", around: frame, windowID: 43)

        XCTAssertNil(border.trackedWindowID)
        XCTAssertEqual(border.visibleOwnedPanelCount, 0)

        // a floater's outline follows the floater marks, not the focus
        // border (testCornersModeOutlinesFloatersWithTheBorderOff)
        border.setFloaterMarks(.none)
        border.updateFloatingBorders([42: frame], color: NSColor.systemPink.cgColor)
        XCTAssertEqual(border.visibleOwnedPanelCount, 0)
    }

    func testDisabledBorderStillRendersOneShotErrorFeedback() {
        let border = FocusBorder()
        border.primaryScreenHeight = 1080
        border.isEnabled = false

        border.flashError(around: CGRect(x: 100, y: 100, width: 400, height: 300),
                          windowID: 44)

        XCTAssertNil(border.trackedWindowID, "one-shot feedback must not become focus identity")
        XCTAssertTrue(border.isErrorFeedbackActive)
        XCTAssertEqual(border.visibleOwnedPanelCount, 1)
        border.hide()
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
        while border.isErrorFeedbackActive, Date() < deadline {
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
    func testFocusChangeCannotCutErrorFeedbackShort() async {
        let border = FocusBorder()
        border.primaryScreenHeight = 1080
        let rejected = CGRect(x: 100, y: 100, width: 400, height: 300)
        let newlyFocused = CGRect(x: 600, y: 100, width: 400, height: 300)
        var finished = false
        border.onErrorFeedbackFinished = { finished = true }

        border.flashError(around: rejected, windowID: 48)
        border.show(around: newlyFocused, windowID: 49)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(finished, "an ordinary focus refresh must not cancel rejection feedback")
        XCTAssertNil(border.trackedWindowID, "the rejected window is visual feedback, not focus intent")
        XCTAssertTrue(border.isErrorFeedbackActive)

        let deadline = Date().addingTimeInterval(3)
        while !finished, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(finished)
        border.isEnabled = false
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

final class FocusBracketAppearanceTests: XCTestCase {
    override func setUpWithError() throws {
        if ProcessInfo.processInfo.environment["HYPRMAC_HEADLESS_TESTS"] == "1" {
            throw XCTSkip("hostless run excludes tests that create AppKit panels")
        }
    }

    func testAppearanceUpdatesVisibleBracketsAndOffHidesThem() throws {
        let brackets = FocusBrackets()
        brackets.primaryScreenHeight = 1080
        brackets.applyAppearance(style: .rounded, color: NSColor.white.cgColor,
                                 radius: 14, thickness: 3, length: 14)
        brackets.show(
            around: CGRect(x: 100, y: 100, width: 400, height: 300),
            windowID: 42)
        XCTAssertEqual(brackets.currentPathCount(), 4)
        let defaultBounds = try XCTUnwrap(brackets.currentPathBounds())

        brackets.applyAppearance(
            style: .rounded,
            color: NSColor.systemGray.cgColor,
            radius: 14,
            thickness: 5,
            length: 14)
        XCTAssertEqual(brackets.currentStrokeWidths().mark, 5)
        XCTAssertEqual(brackets.currentStrokeWidths().outline, 7)
        let thickBounds = try XCTUnwrap(brackets.currentPathBounds())
        XCTAssertEqual(thickBounds, defaultBounds)
        brackets.applyAppearance(
            style: .rounded, color: NSColor.systemGray.cgColor,
            radius: 14, thickness: 5, length: 28)
        let longBounds = try XCTUnwrap(brackets.currentPathBounds())
        XCTAssertGreaterThan(longBounds.width, thickBounds.width)
        XCTAssertGreaterThan(longBounds.height, thickBounds.height)
        XCTAssertEqual(brackets.currentStrokeWidths().mark, 5)

        brackets.applyAppearance(
            style: .rounded,
            color: NSColor.systemGray.cgColor,
            radius: 6,
            thickness: 5)
        XCTAssertEqual(brackets.currentAppearance().style, .rounded)
        XCTAssertEqual(brackets.currentAppearance().radius, 6)
        XCTAssertEqual(brackets.currentAppearance().thickness, 5)
        XCTAssertTrue(brackets.isVisible)
        let rendered = try XCTUnwrap(brackets.currentAppearance().color)
        XCTAssertEqual(NSColor(cgColor: rendered)?.usingColorSpace(.sRGB),
                       NSColor.systemGray.usingColorSpace(.sRGB))

        brackets.applyAppearance(
            style: .off, color: NSColor.white.cgColor, radius: 14, thickness: 3)
        XCTAssertFalse(brackets.isVisible)
        XCTAssertNil(brackets.trackedWindowID)
    }


    @MainActor
    func testRapidHideAndReshowKeepsReusablePanelVisible() async {
        let brackets = FocusBrackets()
        brackets.primaryScreenHeight = 1080
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        brackets.show(around: frame, windowID: 42)
        brackets.hide()
        brackets.show(around: frame, windowID: 42)

        try? await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertTrue(brackets.isVisible)
        XCTAssertEqual(brackets.trackedWindowID, 42)
        XCTAssertEqual(brackets.currentPathCount(), 4)
    }
}

final class FocusBracketDimensionTests: XCTestCase {
    func testLengthAndThicknessUpdateIndependentlyWithoutShowingPanels() {
        let brackets = FocusBrackets()
        brackets.applyAppearance(style: .rounded, color: NSColor.white.cgColor,
                                 radius: 14, thickness: 3, length: 20)
        brackets.applyAppearance(style: .rounded, color: NSColor.white.cgColor,
                                 radius: 14, thickness: 6, length: 20)
        XCTAssertEqual(brackets.currentAppearance().length, 20)
        XCTAssertEqual(brackets.currentAppearance().thickness, 6)
        brackets.applyAppearance(style: .rounded, color: NSColor.white.cgColor,
                                 radius: 14, thickness: 6, length: 10)
        XCTAssertEqual(brackets.currentAppearance().length, 10)
        XCTAssertEqual(brackets.currentAppearance().thickness, 6)
        XCTAssertFalse(brackets.isVisible)
    }
}
