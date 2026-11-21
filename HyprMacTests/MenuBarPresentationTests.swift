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

    func testTheUpdateRowIsAPlainCheckUntilAnUpdateIsPending() {
        XCTAssertEqual(MenuBarPresentation.updateRow(for: nil, currentVersion: "0.25.1"),
                       .init(title: "Check for updates…", icon: "arrow.down.circle",
                             version: "v0.25.1", highlighted: false))
    }

    // a pending update takes over the row and shows the version it brings
    func testTheUpdateRowNamesThePendingUpdate() {
        XCTAssertEqual(MenuBarPresentation.updateRow(for: .available(version: "0.26.0"), currentVersion: "0.25.1"),
                       .init(title: "Update available", icon: "arrow.down.circle.fill",
                             version: "v0.26.0", highlighted: true))
        XCTAssertEqual(MenuBarPresentation.updateRow(for: .ready(version: "0.26.0"), currentVersion: "0.25.1"),
                       .init(title: "Restart to update", icon: "arrow.clockwise.circle.fill",
                             version: "v0.26.0", highlighted: true))
    }

    func testTheMenuBarDotSaysWhatIsPending() {
        XCTAssertEqual(MenuBarPresentation.updateHelp(for: .available(version: "0.26.0")),
                       "HyprMac 0.26.0 is available")
        XCTAssertEqual(MenuBarPresentation.updateHelp(for: .ready(version: "0.26.0")),
                       "HyprMac 0.26.0 is ready to install")
        XCTAssertEqual(UpdateNotice.ready(version: "0.26.0").version, "0.26.0")
    }

    // the menu bar draws label text at its own size, so the mark is a
    // glyph that is small at any size
    func testTheMenuBarDotIsABullet() {
        XCTAssertEqual(MenuBarUpdateDot.glyph, "•")
    }

    func testCurrentStyleShowsOnlyTheWorkspaceOnScreen() {
        let monitors = [monitor(0, "Studio Display", workspace: 3)]
        XCTAssertEqual(MenuBarPresentation.indicatorText(
            style: .currentWorkspace, glyphs: "· · ■ □",
            monitors: monitors, names: [:]), "3")
        XCTAssertEqual(MenuBarPresentation.indicatorText(
            style: .allWorkspaces, glyphs: "· · ■ □",
            monitors: monitors, names: [:]), "· · ■ □")
    }

    func testCurrentStyleUsesTheSetNameAndEveryMonitorLeftToRight() {
        let monitors = [
            monitor(0, "Built-in Display", workspace: 10),
            monitor(1, "Studio Display", workspace: 2)
        ]
        XCTAssertEqual(MenuBarPresentation.currentWorkspaceLabel(monitors, names: [:]), "10 2")
        XCTAssertEqual(MenuBarPresentation.currentWorkspaceLabel(
            monitors, names: ["2": "W", "10": "  "]), "10 W")
        XCTAssertEqual(MenuBarPresentation.currentWorkspaceLabel([], names: [:]), "")
    }

    func testTheIndicatorStyleRawValuesAreStable() {
        XCTAssertEqual(MenuBarIndicatorStyle.allWorkspaces.rawValue, "allWorkspaces")
        XCTAssertEqual(MenuBarIndicatorStyle.currentWorkspace.rawValue, "currentWorkspace")
        XCTAssertEqual(UserConfig.menuBarIndicatorStyleKey, "menuBarIndicatorStyle")
    }

    private func monitor(_ id: Int, _ name: String, workspace: Int,
                         portrait: Bool = false) -> MenuBarMonitorSnapshot {
        MenuBarMonitorSnapshot(id: id, name: name, currentWorkspace: workspace,
                               isPortrait: portrait)
    }
}
