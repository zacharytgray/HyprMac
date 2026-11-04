import XCTest
@testable import HyprMac

final class HoverResponseRateTests: XCTestCase {
    func testPresetsHaveStableLabelsAndRates() {
        XCTAssertEqual(HoverResponseRate.allCases.map(\.rawValue), [240, 120, 60])
        XCTAssertEqual(HoverResponseRate.allCases.map(\.displayName),
                       ["High (240 Hz)", "Medium (120 Hz)", "Low (60 Hz)"])
    }

    func testCustomSavedRateIsDisplayedWithoutRemapping() {
        XCTAssertEqual(HoverResponseRate.displayName(for: 90), "Custom (90 Hz)")
        XCTAssertEqual(HoverResponseRate.displayName(for: 20),
                       "Custom (20 Hz; effective 30 Hz)")
    }

    func testThrottleUsesInjectedClockAndCurrentInterval() {
        let tracker = makeEligibleTracker()
        var time: CFAbsoluteTime = 100
        var requestedHz = 120
        var resolves = 0
        tracker.now = { time }
        tracker.hoverThrottleInterval = {
            1.0 / Double(HoverResponseRate.effectiveHz(for: requestedHz))
        }
        tracker.resolveTopmostWindowID = { _ in resolves += 1; return 999 }

        tracker.handleMouseMove()
        time += 0.005
        tracker.handleMouseMove()
        XCTAssertEqual(resolves, 1)

        requestedHz = 240
        tracker.handleMouseMove()
        XCTAssertEqual(resolves, 2, "a changed rate applies to the next mouse event")
    }

    func testEachRateSetsMinimumSpacingBetweenResolveAttempts() {
        for savedHz in [60, 120, 240, 20] {
            let tracker = makeEligibleTracker()
            var time: CFAbsoluteTime = 100
            var resolves = 0
            let interval = 1.0 / Double(HoverResponseRate.effectiveHz(for: savedHz))
            tracker.now = { time }
            tracker.hoverThrottleInterval = { interval }
            tracker.resolveTopmostWindowID = { _ in resolves += 1; return 999 }

            tracker.handleMouseMove()
            time += interval * 0.9
            tracker.handleMouseMove()
            XCTAssertEqual(resolves, 1, "\(savedHz) Hz admitted work before its interval")

            time += interval * 0.1 + 0.000_001
            tracker.handleMouseMove()
            XCTAssertEqual(resolves, 2, "\(savedHz) Hz did not admit the next eligible event")
        }
    }

    func testStalePressIsClearedAndHoverCarriesOn() {
        let tracker = makeEligibleTracker()
        var pressDown = true
        var cleared = 0
        var resolves = 0
        tracker.isMouseButtonDown = { pressDown }
        tracker.isPhysicalButtonDown = { false }
        tracker.onStalePress = { pressDown = false; cleared += 1 }
        tracker.resolveTopmostWindowID = { _ in resolves += 1; return 999 }

        tracker.handleMouseMove()

        XCTAssertEqual(cleared, 1)
        XCTAssertEqual(resolves, 1)
    }

    func testHeldButtonStillBlocksHover() {
        let tracker = makeEligibleTracker()
        var cleared = 0
        var resolves = 0
        tracker.isMouseButtonDown = { true }
        tracker.isPhysicalButtonDown = { true }
        tracker.onStalePress = { cleared += 1 }
        tracker.resolveTopmostWindowID = { _ in resolves += 1; return 999 }

        tracker.handleMouseMove()

        XCTAssertEqual(cleared, 0)
        XCTAssertEqual(resolves, 0)
        XCTAssertEqual(tracker.blockedReason, "mouse button down")
    }

    func testBlockedReasonClearsOnceHoverIsAllowedAgain() {
        let tracker = makeEligibleTracker()
        tracker.now = { 100 }
        tracker.hoverThrottleInterval = { 0 }
        tracker.resolveTopmostWindowID = { _ in nil }
        tracker.dockIsActive = true

        tracker.handleMouseMove()
        XCTAssertEqual(tracker.blockedReason, "dock active")

        tracker.dockIsActive = false
        tracker.handleMouseMove()
        XCTAssertNil(tracker.blockedReason)
    }

    func testDisabledFocusFollowsMouseDoesNoResolveWork() {
        let tracker = makeEligibleTracker()
        var resolves = 0
        tracker.isFocusFollowsMouseEnabled = { false }
        tracker.resolveTopmostWindowID = { _ in resolves += 1; return nil }

        tracker.handleMouseMove()

        XCTAssertEqual(resolves, 0)
    }

    private func makeEligibleTracker() -> MouseTrackingManager {
        let tracker = MouseTrackingManager()
        tracker.isFocusFollowsMouseEnabled = { true }
        tracker.primaryScreenHeight = { 1000 }
        tracker.mouseLocationNS = { CGPoint(x: 100, y: 900) }
        return tracker
    }
}
