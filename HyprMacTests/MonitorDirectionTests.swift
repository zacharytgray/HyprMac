import XCTest
@testable import HyprMac

// pins which monitor Hypr+Ctrl+arrow sends a window to. the pick is a pure
// function over NSScreen.frame rectangles (AppKit coordinates, y grows
// upward), so no display is needed.

final class MonitorDirectionTests: XCTestCase {

    private let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    private func pick(_ direction: Direction, among frames: [CGRect], from source: CGRect? = nil) -> Int? {
        WorkspaceOrchestrator.nearestScreenIndex(from: source ?? main, direction: direction, among: frames)
    }

    // MARK: - stacked displays

    func testUpFindsTheMonitorAboveAndDownTheOneBelow() {
        let above = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let below = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        let frames = [main, above, below]
        XCTAssertEqual(pick(.up, among: frames), 1)
        XCTAssertEqual(pick(.down, among: frames), 2)
        XCTAssertNil(pick(.left, among: frames))
        XCTAssertNil(pick(.right, among: frames))
    }

    // a laptop under an external display: the small screen is centred, and
    // macOS may leave a point of rounding between the two edges
    func testUpToleratesOffsetAndRoundingBetweenStackedScreens() {
        let laptop = CGRect(x: 240, y: -900, width: 1440, height: 900)
        let external = CGRect(x: 0, y: 0.5, width: 1920, height: 1080)
        XCTAssertEqual(pick(.up, among: [laptop, external], from: laptop), 1)
        XCTAssertEqual(pick(.down, among: [laptop, external], from: external), 0)
    }

    func testNearestMonitorWinsWhenTwoAreStackedAbove() {
        let near = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let far = CGRect(x: 0, y: 2160, width: 1920, height: 1080)
        XCTAssertEqual(pick(.up, among: [far, main, near]), 2)
    }

    // two monitors side by side above a wide one: the one the source
    // mostly sits under wins, not the leftmost
    func testTieAboveGoesToTheMonitorWithMostHorizontalOverlap() {
        let wide = CGRect(x: 0, y: 0, width: 3840, height: 1080)
        let topLeft = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let topRight = CGRect(x: 1920, y: 1080, width: 1920, height: 1080)
        let source = CGRect(x: 1500, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(pick(.up, among: [wide, topLeft, topRight], from: source), 2)
    }

    func testNoMonitorInThatDirectionIsNil() {
        XCTAssertNil(pick(.up, among: [main]))
        XCTAssertNil(pick(.down, among: [main]))
        XCTAssertNil(pick(.up, among: []))
    }

    // MARK: - side-by-side displays, unchanged behaviour

    func testLeftAndRightStillPickTheAdjacentMonitor() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let farRight = CGRect(x: 3840, y: 0, width: 1920, height: 1080)
        let frames = [farRight, left, main, right]
        XCTAssertEqual(pick(.left, among: frames), 1)
        XCTAssertEqual(pick(.right, among: frames), 3)
        XCTAssertNil(pick(.up, among: frames))
    }

    // a monitor that overlaps the source on the axis is beside it, not
    // past it: a stacked arrangement must not answer a left/right request
    func testOverlappingMonitorIsNotPastTheEdge() {
        let above = CGRect(x: 200, y: 1080, width: 1920, height: 1080)
        XCTAssertNil(pick(.right, among: [main, above]))
        XCTAssertNil(pick(.left, among: [main, above]))
    }

    func testFlashMessageNamesTheDirection() {
        XCTAssertEqual(WorkspaceOrchestrator.monitorDirectionLabel(.up), "above")
        XCTAssertEqual(WorkspaceOrchestrator.monitorDirectionLabel(.down), "below")
        XCTAssertEqual(WorkspaceOrchestrator.monitorDirectionLabel(.left), "to the left")
        XCTAssertEqual(WorkspaceOrchestrator.monitorDirectionLabel(.right), "to the right")
    }
}
