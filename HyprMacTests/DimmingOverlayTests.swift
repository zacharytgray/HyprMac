import XCTest
import AppKit
@testable import HyprMac

// Per-window opacity-target invariants. These don't paint — they drive
// DimmingOverlay through synthetic focus / window-set transitions and
// assert against the targets recorded in `currentStates()`. The model
// opacity changes synchronously inside `animateOpacity` (set right
// before the CABasicAnimation is added), so we can assert on it without
// waiting for the animation clock; `present` is left out of assertions
// because it's tied to render-server timing.

final class DimmingOverlayTests: XCTestCase {

    // helper: make an overlay whose screen-coordinate math lines up with
    // whatever NSScreen.main reports, and whose tile rects we generate
    // below will all land on the primary screen.
    private func makeOverlay() -> DimmingOverlay {
        let overlay = DimmingOverlay()
        overlay.enabled = true
        overlay.intensity = 0.25
        overlay.primaryScreenHeight = NSScreen.main?.frame.height ?? 1080
        return overlay
    }

    // helper: a CG-coords (top-left origin) rect that we know intersects
    // the primary screen. inset 100px so multi-monitor offsets don't push
    // it off the primary.
    private func cgRectOnPrimary(x: CGFloat, y: CGFloat, w: CGFloat = 200, h: CGFloat = 200) -> CGRect {
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private var screens: [NSScreen] { NSScreen.screens }

    // MARK: - enable / disable

    func testEnableFromOffSetsCorrectTargets() {
        let overlay = makeOverlay()
        let a: CGWindowID = 1, b: CGWindowID = 2, c: CGWindowID = 3
        overlay.update(
            focusedID: b,
            tiledRects: [
                a: cgRectOnPrimary(x: 100, y: 100),
                b: cgRectOnPrimary(x: 400, y: 100),
                c: cgRectOnPrimary(x: 700, y: 100),
            ],
            floatingRects: [:],
            screens: screens
        )
        let s = overlay.currentStates()
        XCTAssertEqual(s[a]?.target, 1, "non-focused window should target dim=1")
        XCTAssertEqual(s[b]?.target, 0, "focused window should target dim=0")
        XCTAssertEqual(s[c]?.target, 1, "non-focused window should target dim=1")
    }

    func testFocusTraversalFadesParallel() {
        let overlay = makeOverlay()
        let a: CGWindowID = 1, b: CGWindowID = 2
        let tiles: [CGWindowID: CGRect] = [
            a: cgRectOnPrimary(x: 100, y: 100),
            b: cgRectOnPrimary(x: 400, y: 100),
        ]
        overlay.update(focusedID: a, tiledRects: tiles, floatingRects: [:], screens: screens)
        XCTAssertEqual(overlay.currentStates()[a]?.target, 0)
        XCTAssertEqual(overlay.currentStates()[b]?.target, 1)

        // focus traverses A → B: the window being left fades to dim,
        // the window being entered fades to bright. both targets flip
        // in a single update().
        overlay.update(focusedID: b, tiledRects: tiles, floatingRects: [:], screens: screens)
        XCTAssertEqual(overlay.currentStates()[a]?.target, 1, "A: lost focus → dim=1")
        XCTAssertEqual(overlay.currentStates()[b]?.target, 0, "B: gained focus → dim=0")
    }

    func testIdempotentUpdateDoesNotFlipTargets() {
        let overlay = makeOverlay()
        let a: CGWindowID = 1, b: CGWindowID = 2
        let tiles: [CGWindowID: CGRect] = [
            a: cgRectOnPrimary(x: 100, y: 100),
            b: cgRectOnPrimary(x: 400, y: 100),
        ]
        overlay.update(focusedID: a, tiledRects: tiles, floatingRects: [:], screens: screens)
        let before = overlay.currentStates()
        overlay.update(focusedID: a, tiledRects: tiles, floatingRects: [:], screens: screens)
        overlay.update(focusedID: a, tiledRects: tiles, floatingRects: [:], screens: screens)
        let after = overlay.currentStates()
        // targets are stable across repeat-updates with the same focus.
        // (this also implicitly verifies we don't re-fire a 1→1 fade,
        // which would cause every focus-poll tick to add a redundant
        // CABasicAnimation onto each layer.)
        XCTAssertEqual(before[a]?.target, after[a]?.target)
        XCTAssertEqual(before[b]?.target, after[b]?.target)
    }

    func testHideAllSetsAllTargetsToZero() {
        let overlay = makeOverlay()
        let a: CGWindowID = 1, b: CGWindowID = 2
        let tiles: [CGWindowID: CGRect] = [
            a: cgRectOnPrimary(x: 100, y: 100),
            b: cgRectOnPrimary(x: 400, y: 100),
        ]
        overlay.update(focusedID: a, tiledRects: tiles, floatingRects: [:], screens: screens)
        overlay.hideAll()
        let s = overlay.currentStates()
        XCTAssertEqual(s[a]?.target, 0, "after hideAll, A target should be 0")
        XCTAssertEqual(s[b]?.target, 0, "after hideAll, B target should be 0")
    }

    func testReenableAfterHideRestoresTargets() {
        let overlay = makeOverlay()
        let a: CGWindowID = 1, b: CGWindowID = 2
        let tiles: [CGWindowID: CGRect] = [
            a: cgRectOnPrimary(x: 100, y: 100),
            b: cgRectOnPrimary(x: 400, y: 100),
        ]
        overlay.update(focusedID: a, tiledRects: tiles, floatingRects: [:], screens: screens)
        overlay.hideAll()
        // re-enable with the same focus — non-focused tile must fade
        // back to 1, focused stays at 0.
        overlay.update(focusedID: a, tiledRects: tiles, floatingRects: [:], screens: screens)
        let s = overlay.currentStates()
        XCTAssertEqual(s[a]?.target, 0)
        XCTAssertEqual(s[b]?.target, 1)
    }

    // MARK: - window lifecycle

    func testNewWindowGetsTargetFromFocus() {
        let overlay = makeOverlay()
        let a: CGWindowID = 1
        overlay.update(
            focusedID: a,
            tiledRects: [a: cgRectOnPrimary(x: 100, y: 100)],
            floatingRects: [:],
            screens: screens
        )
        // window B appears while A stays focused — B should target dim=1
        let b: CGWindowID = 2
        overlay.update(
            focusedID: a,
            tiledRects: [
                a: cgRectOnPrimary(x: 100, y: 100),
                b: cgRectOnPrimary(x: 400, y: 100),
            ],
            floatingRects: [:],
            screens: screens
        )
        let s = overlay.currentStates()
        XCTAssertEqual(s[a]?.target, 0)
        XCTAssertEqual(s[b]?.target, 1)
        // a freshly-created layer's model opacity starts at 0; the
        // animateOpacity call moves it to the target. model == target
        // synchronously because animateOpacity sets layer.opacity = target
        // before adding the CABasicAnimation.
        XCTAssertEqual(s[b]?.model, 1, "new non-focused layer ramps from 0 to 1 — model is the target")
    }

    func testWindowLeavingScreenIsDroppedFromState() {
        let overlay = makeOverlay()
        let a: CGWindowID = 1, b: CGWindowID = 2
        overlay.update(
            focusedID: a,
            tiledRects: [
                a: cgRectOnPrimary(x: 100, y: 100),
                b: cgRectOnPrimary(x: 400, y: 100),
            ],
            floatingRects: [:],
            screens: screens
        )
        XCTAssertNotNil(overlay.currentStates()[b])
        // B disappears — gone from currentStates (the layer is still
        // alive for the fade-out window, but its lastTarget entry is
        // cleared the instant we decide to remove it).
        overlay.update(
            focusedID: a,
            tiledRects: [a: cgRectOnPrimary(x: 100, y: 100)],
            floatingRects: [:],
            screens: screens
        )
        XCTAssertNil(overlay.currentStates()[b], "removed window should not appear in current states")
    }

    // MARK: - focused-id changes

    func testFocusToZeroHidesEverything() {
        let overlay = makeOverlay()
        let a: CGWindowID = 1, b: CGWindowID = 2
        let tiles: [CGWindowID: CGRect] = [
            a: cgRectOnPrimary(x: 100, y: 100),
            b: cgRectOnPrimary(x: 400, y: 100),
        ]
        overlay.update(focusedID: a, tiledRects: tiles, floatingRects: [:], screens: screens)
        // focused=0 triggers the same path as disabling.
        overlay.update(focusedID: 0, tiledRects: tiles, floatingRects: [:], screens: screens)
        let s = overlay.currentStates()
        XCTAssertEqual(s[a]?.target, 0)
        XCTAssertEqual(s[b]?.target, 0)
    }

    func testDisabledFlagShortCircuits() {
        let overlay = makeOverlay()
        overlay.enabled = false
        let a: CGWindowID = 1
        overlay.update(
            focusedID: a,
            tiledRects: [a: cgRectOnPrimary(x: 100, y: 100)],
            floatingRects: [:],
            screens: screens
        )
        // with enabled=false, update() never creates layers.
        XCTAssertTrue(overlay.currentStates().isEmpty)
    }
}
