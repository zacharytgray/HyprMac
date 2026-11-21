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
            indicator: MenuBarIndicator(text: "■ · ○")))
        XCTAssertFalse(MenuBarPresentation.showsIndicator(
            indicatorEnabled: false, hasData: true,
            indicator: MenuBarIndicator(text: "■")))
        XCTAssertFalse(MenuBarPresentation.showsIndicator(
            indicatorEnabled: true, hasData: false,
            indicator: MenuBarIndicator(text: "■")))
        XCTAssertFalse(MenuBarPresentation.showsIndicator(
            indicatorEnabled: true, hasData: true,
            indicator: MenuBarIndicator()))
        XCTAssertTrue(MenuBarPresentation.showsIndicator(
            indicatorEnabled: true, hasData: true,
            indicator: MenuBarIndicator(showsFullscreenIcon: true)))
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

    /// Two monitors showing 2 and 5; focus on 5, which is fullscreen;
    /// three windows in the scratchpad.
    private func menuBarState() -> MenuBarState {
        let state = MenuBarState()
        state.workspaceGlyphs = "· ■ · · ●"
        state.isFullscreen = true
        state.focusedWorkspace = 5
        state.isFocusedFullscreen = true
        state.monitors = [monitor(0, "Built-in Display", workspace: 2),
                          monitor(1, "Studio Display", workspace: 5)]
        state.scratchpadCount = 3
        state.scratchpadVisible = true
        state.hasData = true
        return state
    }

    func testAllStyleKeepsTheGlyphsTrayAndUpdateDot() {
        let state = menuBarState()
        state.isFullscreen = false
        XCTAssertEqual(MenuBarIndicatorStyle.allWorkspaces.indicator(for: state, names: [:]),
                       MenuBarIndicator(text: "· ■ · · ●", scratchpadCount: 3,
                                        scratchpadVisible: true, showsUpdateDot: true))
        // a fullscreen window anywhere swaps the glyphs for the icon
        state.isFullscreen = true
        XCTAssertEqual(MenuBarIndicatorStyle.allWorkspaces.indicator(for: state, names: [:]),
                       MenuBarIndicator(showsFullscreenIcon: true, scratchpadCount: 3,
                                        scratchpadVisible: true, showsUpdateDot: true))
    }

    func testCurrentStyleShowsOnlyTheFocusedWorkspaceBesideTheFullscreenIcon() {
        let state = menuBarState()
        XCTAssertEqual(MenuBarIndicatorStyle.currentWorkspace.indicator(for: state, names: [:]),
                       MenuBarIndicator(showsFullscreenIcon: true, text: "5", showsUpdateDot: false))
        // fullscreen on the other monitor leaves no icon
        state.isFocusedFullscreen = false
        XCTAssertEqual(MenuBarIndicatorStyle.currentWorkspace.indicator(for: state, names: [:]),
                       MenuBarIndicator(text: "5", showsUpdateDot: false))
    }

    func testCurrentStyleShowsTheSetNameElseTheNumber() {
        let state = menuBarState()
        func text(_ names: [String: String]) -> String {
            MenuBarIndicatorStyle.currentWorkspace.indicator(for: state, names: names).text
        }
        XCTAssertEqual(text(["5": "W", "2": "Q"]), "W")
        XCTAssertEqual(text(["5": "  "]), "5")
        state.focusedWorkspace = 10
        XCTAssertEqual(text([:]), "10")
        state.focusedWorkspace = nil
        XCTAssertEqual(text(["5": "W"]), "")
        XCTAssertFalse(MenuBarPresentation.showsIndicator(
            indicatorEnabled: true, hasData: true,
            indicator: MenuBarIndicator(text: text([:]), showsUpdateDot: false)))
    }

    // the raw values are config.json values
    func testTheIndicatorStyleRawValuesAreStable() {
        XCTAssertEqual(MenuBarIndicatorStyle.allWorkspaces.rawValue, "allWorkspaces")
        XCTAssertEqual(MenuBarIndicatorStyle.currentWorkspace.rawValue, "currentWorkspace")
        XCTAssertEqual(UserConfigDefaults.menuBarIndicatorStyle, .allWorkspaces)
    }

    private func monitor(_ id: Int, _ name: String, workspace: Int,
                         portrait: Bool = false) -> MenuBarMonitorSnapshot {
        MenuBarMonitorSnapshot(id: id, name: name, currentWorkspace: workspace,
                               isPortrait: portrait)
    }
}
