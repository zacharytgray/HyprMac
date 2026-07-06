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
    // production. DisplayManager anchors CG top-left conversion to the
    // PRIMARY screen (NSScreen.screens.first, the one at NS origin) —
    // NOT NSScreen.main, which is wherever the key window happens to be
    // and broke these tests on multi-monitor rigs.
    private func makeOverlay() -> DimmingOverlay {
        let overlay = DimmingOverlay()
        overlay.enabled = true
        overlay.intensity = 0.25
        overlay.primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080
        return overlay
    }

    // helper: a CG-coords (top-left origin) rect near the primary
    // screen's top-left. CG (0,0) is the primary's top-left corner, so
    // small positive coords always land on the primary regardless of
    // how external monitors are arranged.
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

    // MARK: - drag override

    // setDragOverride re-stamps the affected tile's PATH (carve appears)
    // without disturbing any opacity target. A floater dragged over a
    // dimmed tile must punch a hole into that tile's dim path live.
    func testDragOverrideRestampsPathWithoutChangingTargets() {
        let overlay = makeOverlay()
        let tileA: CGWindowID = 1, tileB: CGWindowID = 2
        // two big side-by-side tiles, A focused (bright), B dimmed.
        let tiles: [CGWindowID: CGRect] = [
            tileA: cgRectOnPrimary(x: 0, y: 0, w: 400, h: 400),
            tileB: cgRectOnPrimary(x: 400, y: 0, w: 400, h: 400),
        ]
        overlay.update(focusedID: tileA, tiledRects: tiles, floatingRects: [:], screens: screens)
        let targetsBefore = overlay.currentStates()
        let bPathBefore = overlay.currentPathBounds()[tileB]
        XCTAssertNotNil(bPathBefore)

        // drag a floater into the middle of tile B — the carve shrinks B's
        // dim path (union bbox unchanged, but path is re-stamped: assert the
        // override landed and no opacity target moved).
        let floater = CGRect(x: 500, y: 100, width: 100, height: 100)
        overlay.setDragOverride(id: 99, rect: floater)

        XCTAssertEqual(overlay.currentDragOverride()?.id, 99)
        XCTAssertEqual(overlay.currentDragOverride()?.rect, floater)
        let targetsAfter = overlay.currentStates()
        XCTAssertEqual(targetsBefore[tileA]?.target, targetsAfter[tileA]?.target, "focused target unchanged")
        XCTAssertEqual(targetsBefore[tileB]?.target, targetsAfter[tileB]?.target, "dimmed target unchanged")
        // B's dim path now has a hole → it degrades to axis-aligned strips,
        // so it's no longer the single rounded rect. bounding box still the
        // tile, but the presence of the override proves the re-stamp ran.
        XCTAssertNotNil(overlay.currentPathBounds()[tileB])
    }

    // a full update() carrying STALE floatingRects must not stomp the live
    // override rect — the merge inside update() keeps the drag rect.
    func testFullUpdateHonorsOverrideMergeSemantics() {
        let overlay = makeOverlay()
        let tileA: CGWindowID = 1, tileB: CGWindowID = 2
        let tiles: [CGWindowID: CGRect] = [
            tileA: cgRectOnPrimary(x: 0, y: 0, w: 400, h: 400),
            tileB: cgRectOnPrimary(x: 400, y: 0, w: 400, h: 400),
        ]
        let floaterID: CGWindowID = 99
        let stale = CGRect(x: 420, y: 20, width: 100, height: 100)  // poll's old rect
        overlay.update(focusedID: tileA, tiledRects: tiles,
                       floatingRects: [floaterID: stale], screens: screens)

        // live drag moved the floater further right
        let live = CGRect(x: 600, y: 200, width: 100, height: 100)
        overlay.setDragOverride(id: floaterID, rect: live)
        XCTAssertEqual(overlay.currentDragOverride()?.rect, live)

        // a 1Hz poll fires mid-drag with the STALE floater rect — the
        // override must survive and the carve honor `live`, not `stale`.
        overlay.update(focusedID: tileA, tiledRects: tiles,
                       floatingRects: [floaterID: stale], screens: screens)
        XCTAssertEqual(overlay.currentDragOverride()?.rect, live, "override survives a full update")

        // B's dim path must carve out `live` (mapped to local NS coords),
        // proving the merged rect — not the stale input — drove the geometry.
        let liveLocalY = overlay.primaryScreenHeight - live.origin.y - live.height
        let liveLocal = NSRect(x: live.origin.x, y: liveLocalY, width: live.width, height: live.height)
        let bPath = overlay.currentPath(for: tileB)
        XCTAssertNotNil(bPath)
        XCTAssertFalse(bPath!.contains(CGPoint(x: liveLocal.midX, y: liveLocal.midY), using: .winding),
                       "B's dim path must NOT cover the live floater center (it's carved out)")

        // clearing drops the override; a subsequent update paints from caches.
        overlay.clearDragOverride()
        XCTAssertNil(overlay.currentDragOverride())
    }

    // MARK: - panel level

    func testPanelLevelAppliesAndFlipsOnReusedPanels() {
        let overlay = makeOverlay()
        let a: CGWindowID = 1
        let floatingMinus1 = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)

        // scrim mode: .normal
        overlay.panelLevel = .normal
        overlay.update(
            focusedID: a,
            tiledRects: [a: cgRectOnPrimary(x: 100, y: 100)],
            floatingRects: [:],
            screens: screens
        )
        let scrimLevels = overlay.currentPanelLevels()
        XCTAssertFalse(scrimLevels.isEmpty)
        for (_, level) in scrimLevels {
            XCTAssertEqual(level, .normal, "scrim mode should put every panel at .normal")
        }

        // flip back to floating-1 — same reused panels must pick it up
        overlay.panelLevel = floatingMinus1
        overlay.update(
            focusedID: a,
            tiledRects: [a: cgRectOnPrimary(x: 100, y: 100)],
            floatingRects: [:],
            screens: screens
        )
        let normalLevels = overlay.currentPanelLevels()
        XCTAssertEqual(normalLevels.keys.sorted(), scrimLevels.keys.sorted(),
                       "same panels reused across the mode switch")
        for (_, level) in normalLevels {
            XCTAssertEqual(level, floatingMinus1, "normal mode should put every panel at floating-1")
        }
    }
}
