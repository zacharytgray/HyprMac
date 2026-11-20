import XCTest
@testable import HyprMac

final class MenuBarPresentationTests: XCTestCase {
    func testWorkspaceGlyphsPreserveActiveOccupiedAndFloatingSemantics() {
        XCTAssertEqual(MenuBarPresentation.workspaceGlyphs(
            active: [1, 4], occupied: [1, 2, 3, 4], floating: [2, 4]),
                       "■ ○ □ ●")
    }

    // circles mark floating windows; the diamonds are gone everywhere
    func testFloatingGlyphsAreCirclesNotDiamonds() {
        XCTAssertEqual(HyprGlyph.workspaceShown, "■")
        XCTAssertEqual(HyprGlyph.workspaceShownFloating, "●")
        XCTAssertEqual(HyprGlyph.workspaceWaiting, "□")
        XCTAssertEqual(HyprGlyph.workspaceWaitingFloating, "○")
        XCTAssertEqual(HyprGlyph.workspaceEmpty, "·")
        XCTAssertEqual(HyprGlyph.floatingMarker, "○")

        let all = MenuBarPresentation.workspaceGlyphs(
            active: [1, 2], occupied: [1, 2, 3, 4], floating: [2, 4])
        XCTAssertEqual(all, "■ ● □ ○")
        XCTAssertFalse(all.contains("◆"))
        XCTAssertFalse(all.contains("◇"))
    }

    func testWorkspaceGlyphsKeepEmptySlotsThroughLastRelevantWorkspace() {
        XCTAssertEqual(MenuBarPresentation.workspaceGlyphs(
            active: [2], occupied: [4], floating: []), "· ■ · □")
        XCTAssertEqual(MenuBarPresentation.workspaceGlyphs(
            active: [], occupied: [], floating: []), "·")
    }

    func testWorkspaceGlyphsRepresentBothActiveMonitors() {
        XCTAssertEqual(MenuBarPresentation.workspaceGlyphs(
            active: [2, 5], occupied: [], floating: [5]), "· ■ · · ●")
    }

    func testTooltipNamesEachMonitorAndCurrentWorkspace() {
        XCTAssertEqual(MenuBarPresentation.monitorSummary([
            monitor(0, "Studio Display", workspace: 7),
            monitor(1, "Built-in Display", workspace: 2)
        ], names: [:]), "Studio Display: Workspace 7\nBuilt-in Display: Workspace 2")
        XCTAssertEqual(MenuBarPresentation.monitorSummary([
            monitor(0, "Studio Display", workspace: 7),
            monitor(1, "Built-in Display", workspace: 2)
        ], names: ["7": "web"]), "Studio Display: web\nBuilt-in Display: Workspace 2")
    }

    func testWorkspaceStateHidesWhilePausedOrIndicatorDisabled() {
        let monitors = [monitor(0, "Studio Display", workspace: 3)]

        XCTAssertTrue(MenuBarPresentation.showsWorkspaceState(
            enabled: true, indicatorEnabled: true, hasData: true,
            monitors: monitors, scratchpadCount: 0))
        XCTAssertFalse(MenuBarPresentation.showsWorkspaceState(
            enabled: false, indicatorEnabled: true, hasData: true,
            monitors: monitors, scratchpadCount: 0))
        XCTAssertFalse(MenuBarPresentation.showsWorkspaceState(
            enabled: true, indicatorEnabled: false, hasData: true,
            monitors: monitors, scratchpadCount: 0))
        XCTAssertFalse(MenuBarPresentation.showsWorkspaceState(
            enabled: true, indicatorEnabled: true, hasData: false,
            monitors: monitors, scratchpadCount: 0))
        XCTAssertFalse(MenuBarPresentation.showsWorkspaceState(
            enabled: true, indicatorEnabled: true, hasData: true,
            monitors: [], scratchpadCount: 0))
        XCTAssertTrue(MenuBarPresentation.showsWorkspaceState(
            enabled: true, indicatorEnabled: true, hasData: true,
            monitors: [], scratchpadCount: 2))
    }

    func testCompactIndicatorUsesGlyphDataWithoutManagerEnabledState() {
        XCTAssertTrue(MenuBarPresentation.showsIndicator(
            indicatorEnabled: true, hasData: true,
            labelText: "■ · ○", scratchpadCount: 0))
        XCTAssertFalse(MenuBarPresentation.showsIndicator(
            indicatorEnabled: false, hasData: true,
            labelText: "■", scratchpadCount: 0))
        XCTAssertFalse(MenuBarPresentation.showsIndicator(
            indicatorEnabled: true, hasData: false,
            labelText: "■", scratchpadCount: 0))
    }

    func testMonitorSnapshotCarriesActionableWorkspaceBadgeState() {
        let badges = [
            MenuBarWorkspaceBadge(id: 1, isActive: true, isOccupied: true, hasFloatingWindows: false),
            MenuBarWorkspaceBadge(id: 4, isActive: false, isOccupied: true, hasFloatingWindows: true)
        ]
        let snapshot = MenuBarMonitorSnapshot(id: 0, name: "Studio", currentWorkspace: 1,
                                              isPortrait: false, workspaces: badges)
        XCTAssertEqual(snapshot.workspaces, badges)
    }

    func testWorkspaceBadgesWrapAfterFiveItems() {
        let badges = Constants.workspaceRange.map {
            MenuBarWorkspaceBadge(id: $0, isActive: false, isOccupied: false,
                                  hasFloatingWindows: false)
        }

        XCTAssertEqual(MenuBarPresentation.workspaceBadgeRows(badges).map { $0.map(\.id) }, [
            [1, 2, 3, 4, 5],
            [6, 7, 8, 9, 10]
        ])
    }

    private func monitor(_ id: Int, _ name: String, workspace: Int,
                         portrait: Bool = false) -> MenuBarMonitorSnapshot {
        MenuBarMonitorSnapshot(id: id, name: name, currentWorkspace: workspace,
                               isPortrait: portrait)
    }
}
