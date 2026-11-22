import XCTest
@testable import HyprMac

final class AccessibilityDragHelperPlacementTests: XCTestCase {
    private typealias Placement = AccessibilityDragHelperPlacement
    private let panel = CGSize(width: Placement.panelWidth, height: 64)
    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
    private let gap = Placement.gap
    /// x of the panel that puts its icon in the list's column
    private func aligned(_ settingsX: CGFloat) -> CGFloat {
        settingsX + Placement.listIconCenterX - Placement.padding - Placement.iconSize / 2
    }

    func testPanelIconLinesUpWithTheListIcons() {
        let settings = CGRect(x: 400, y: 300, width: 740, height: 600)
        let origin = Placement.panelOrigin(settings: settings, panel: panel, visible: visible)
        XCTAssertEqual(origin, CGPoint(x: aligned(400), y: 300 - gap - 64))
    }

    // no room below: the panel rides inside the window's bottom edge
    func testPanelMovesInsideTheWindowWithNoRoomBelow() {
        let settings = CGRect(x: 400, y: 40, width: 740, height: 600)
        let origin = Placement.panelOrigin(settings: settings, panel: panel, visible: visible)
        XCTAssertEqual(origin.y, 40 + gap)
    }

    // near the right edge the text may run off the screen; the icon stays
    // in the list's column
    func testIconKeepsItsColumnWhenThePanelOverhangsTheRightEdge() {
        let settings = CGRect(x: 1100, y: 300, width: 740, height: 600)
        let origin = Placement.panelOrigin(settings: settings, panel: panel, visible: visible)
        XCTAssertGreaterThan(origin.x + panel.width, visible.maxX)
        XCTAssertEqual(origin.x, aligned(1100))
    }

    // the window that pressed Grant waits beside System Settings, tops level
    func testWaitingWindowGoesRightOfSystemSettings() {
        let settings = CGRect(x: 100, y: 200, width: 740, height: 700)
        let origin = Placement.besideOrigin(
            settings: settings, window: CGSize(width: 520, height: 530), visible: visible)
        XCTAssertEqual(origin, CGPoint(x: 840 + gap, y: 900 - 530))
    }

    func testWaitingWindowGoesLeftWhenTheRightIsFull() {
        let settings = CGRect(x: 700, y: 200, width: 740, height: 700)
        let origin = Placement.besideOrigin(
            settings: settings, window: CGSize(width: 520, height: 530), visible: visible)
        XCTAssertEqual(origin, CGPoint(x: 700 - gap - 520, y: 900 - 530))
    }

    func testWaitingWindowStaysPutWhenNeitherSideFits() {
        let settings = CGRect(x: 400, y: 200, width: 740, height: 700)
        XCTAssertNil(Placement.besideOrigin(
            settings: settings, window: CGSize(width: 520, height: 530), visible: visible))
    }

    func testIconNeverLeavesTheScreen() {
        let leftEdge = Placement.panelOrigin(
            settings: CGRect(x: -500, y: -200, width: 740, height: 600), panel: panel, visible: visible)
        XCTAssertEqual(leftEdge, CGPoint(x: gap, y: gap))

        let rightEdge = Placement.panelOrigin(
            settings: CGRect(x: 1400, y: 300, width: 740, height: 600), panel: panel, visible: visible)
        XCTAssertEqual(rightEdge.x, 1512 - Placement.padding - Placement.iconSize - gap)
    }
}
