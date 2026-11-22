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

    func testFullIndicatorUsesGlyphDataWithoutManagerEnabledState() {
        XCTAssertTrue(MenuBarPresentation.showsIndicator(
            hasData: true, labelText: "■ · ○", scratchpadCount: 0))
        XCTAssertTrue(MenuBarPresentation.showsIndicator(
            hasData: true, labelText: "", scratchpadCount: 1))
        XCTAssertFalse(MenuBarPresentation.showsIndicator(
            hasData: false, labelText: "■", scratchpadCount: 0))
    }

    func testCompactSymbolCoversWorkspaceOneAndTen() {
        XCTAssertEqual(MenuBarPresentation.compactSymbolName(
            workspace: 1, floating: false, maximized: false), "1.square")
        XCTAssertEqual(MenuBarPresentation.compactSymbolName(
            workspace: 10, floating: false, maximized: false), "10.square")
    }

    // every badge is one 20x20 template image so the item never changes width
    func testCompactImageIsOneFixedSizeTemplate() {
        for symbol in ["3.square", "3.circle", "10.square.fill", "10.circle.fill"] {
            let image = MenuBarPresentation.compactImage(symbol: symbol)
            XCTAssertEqual(image?.size, NSSize(width: 20, height: 20), symbol)
            XCTAssertEqual(image?.isTemplate, true, symbol)
        }
        XCTAssertNil(MenuBarPresentation.compactImage(symbol: "not.a.real.symbol"))
    }

    func testSwitchedToWinsWhileShowing() {
        XCTAssertEqual(focusedScreen(focused: 20, cursor: 1, switchedTo: 4), 0)
    }

    func testSwitchedToNoLongerShowingIsIgnored() {
        XCTAssertEqual(focusedScreen(focused: 20, cursor: 0, switchedTo: 7), 1)
        XCTAssertNil(focusedScreen(focused: 0, cursor: nil, visible: [], switchedTo: 3))
    }

    func testNoSwitchedToKeepsTheFocusRule() {
        XCTAssertEqual(focusedScreen(focused: 20, cursor: 0, switchedTo: nil), 1)
        XCTAssertEqual(focusedScreen(focused: 0, cursor: 1, switchedTo: nil), 1)
    }

    // the live log: monitor A switched to empty 3, focus still on a window on 2
    func testEmptySwitchBeatsFocusOnOtherMonitor() {
        XCTAssertEqual(focusedScreen(focused: 20, cursor: 1, visible: [3, 2], switchedTo: 3), 0)
        XCTAssertEqual(focusedScreen(focused: 20, cursor: 0, visible: [3, 2], switchedTo: nil), 1)
    }

    // a set name replaces the badge; the fullscreen icon sits beside it
    func testCompactShowsTheSetNameElseTheNumberedBadge() {
        let plain = MenuBarCompactBadge(workspace: 3, floating: true, maximized: false)
        let maximized = MenuBarCompactBadge(workspace: 3, floating: false, maximized: true)
        XCTAssertEqual(MenuBarPresentation.compactLabel(plain, names: ["3": "R", "1": "W"]),
                       .name("R", fullscreen: false))
        XCTAssertEqual(MenuBarPresentation.compactLabel(maximized, names: ["3": "R"]),
                       .name("R", fullscreen: true))
        XCTAssertEqual(MenuBarPresentation.compactLabel(plain, names: ["1": "W"]), .symbol("3.circle"))
        XCTAssertEqual(MenuBarPresentation.compactLabel(maximized, names: ["3": "  "]),
                       .symbol("3.square.fill"))
    }

    func testCompactSymbolShowsFloatingAndMaximizedStates() {
        XCTAssertEqual(MenuBarPresentation.compactSymbolName(
            workspace: 3, floating: false, maximized: false), "3.square")
        XCTAssertEqual(MenuBarPresentation.compactSymbolName(
            workspace: 3, floating: true, maximized: false), "3.circle")
        XCTAssertEqual(MenuBarPresentation.compactSymbolName(
            workspace: 3, floating: false, maximized: true), "3.square.fill")
        XCTAssertEqual(MenuBarPresentation.compactSymbolName(
            workspace: 3, floating: true, maximized: true), "3.circle.fill")
    }

    // two screens: the left shows 4 (windows 11, 12), the right shows 2
    // (window 20). 7 is hidden and holds 70.
    private func focusedScreen(focused: CGWindowID, cursor: Int?,
                               visible: [Int] = [4, 2], switchedTo: Int? = nil) -> Int? {
        StatusSnapshot.focusedScreenIndex(
            visibleWorkspaces: visible,
            assigned: [4: [11, 12], 2: [20], 7: [70]],
            hidden: [],
            focusedWindowID: focused,
            cursorScreenIndex: cursor,
            switchedTo: switchedTo)
    }

    func testFocusedWindowOnAShowingWorkspaceWins() {
        XCTAssertEqual(focusedScreen(focused: 20, cursor: 0), 1)
        XCTAssertEqual(focusedScreen(focused: 12, cursor: 1), 0)
    }

    func testFocusedWindowOnAHiddenWorkspaceFallsBackToTheCursorScreen() {
        XCTAssertEqual(focusedScreen(focused: 70, cursor: 1), 1)
    }

    func testNoFocusedWindowUsesTheCursorScreen() {
        XCTAssertEqual(focusedScreen(focused: 0, cursor: 1), 1)
        XCTAssertEqual(focusedScreen(focused: 999, cursor: 0), 0)
    }

    func testNoCursorScreenUsesTheFirst() {
        XCTAssertEqual(focusedScreen(focused: 0, cursor: nil), 0)
        XCTAssertEqual(focusedScreen(focused: 0, cursor: 5), 0)
        XCTAssertNil(focusedScreen(focused: 0, cursor: nil, visible: []))
    }

    // a hidden window still assigned to a showing workspace is not focus
    func testHiddenFocusedWindowIsNotFocus() {
        let index = StatusSnapshot.focusedScreenIndex(
            visibleWorkspaces: [4, 2], assigned: [4: [11], 2: [20]], hidden: [11],
            focusedWindowID: 11, cursorScreenIndex: 1)
        XCTAssertEqual(index, 1)
    }

    // index based: two monitors of one model with the same name stay apart
    func testSameNamedScreensAreToldApartByIndex() {
        let input = StatusSnapshot.Input(
            screens: [.init(name: "DELL", visibleWorkspace: 4), .init(name: "DELL", visibleWorkspace: 2)],
            homeScreens: [:], assigned: [4: [11], 2: [20]], scratchpad: [], scratchpadVisible: false,
            hidden: [], floating: [], focusedWindowID: 20, cursorScreen: "DELL", apps: [:], names: [:])
        XCTAssertEqual(StatusSnapshot.build(input).focusedWorkspace, 2)
        XCTAssertEqual(focusedScreen(focused: 0, cursor: 1), 1)
    }

    func testCompactSymbolForTheChosenWorkspace() {
        let floating: Set<Int> = [2]
        let maximized: Set<Int> = [4]
        let symbols = [4, 2].map {
            MenuBarPresentation.compactSymbolName(workspace: $0, floating: floating.contains($0),
                                                  maximized: maximized.contains($0))
        }
        XCTAssertEqual(symbols, ["4.square.fill", "2.circle"])
        XCTAssertEqual(focusedScreen(focused: 20, cursor: 0).map { symbols[$0] }, "2.circle")
        XCTAssertEqual(focusedScreen(focused: 0, cursor: 0).map { symbols[$0] }, "4.square.fill")
    }

    // a burst of moves schedules one check; the next move after it schedules another
    func testCursorScreenWatchSchedulesOneCheckPerBurst() {
        var watch = CursorScreenWatch()
        XCTAssertEqual(CursorScreenWatch.delay, 0.25)
        XCTAssertTrue(watch.noteMove())
        XCTAssertFalse(watch.noteMove())
        XCTAssertFalse(watch.noteMove())
        XCTAssertTrue(watch.checkScheduled)
        _ = watch.check(screen: 1)
        XCTAssertFalse(watch.checkScheduled)
        XCTAssertTrue(watch.noteMove())
    }

    func testCursorScreenWatchReportsOnlyAChange() {
        var watch = CursorScreenWatch()
        XCTAssertTrue(watch.check(screen: 1))
        XCTAssertFalse(watch.check(screen: 1))
        XCTAssertTrue(watch.check(screen: 2))
        XCTAssertFalse(watch.check(screen: 2))
        XCTAssertTrue(watch.check(screen: 1))
    }

    func testMenuBarStyleMigratesFromOldToggles() {
        XCTAssertEqual(MenuBarStyle.migrated(showIcon: false, showIndicator: true), .hidden)
        XCTAssertEqual(MenuBarStyle.migrated(showIcon: true, showIndicator: false), .compact)
        XCTAssertEqual(MenuBarStyle.migrated(showIcon: true, showIndicator: true), .full)
    }

    func testMenuBarStyleMigrationIgnoresIndicatorWhenIconIsOff() {
        XCTAssertEqual(MenuBarStyle.migrated(showIcon: false, showIndicator: false), .hidden)
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

    private func monitor(_ id: Int, _ name: String, workspace: Int,
                         portrait: Bool = false) -> MenuBarMonitorSnapshot {
        MenuBarMonitorSnapshot(id: id, name: name, currentWorkspace: workspace,
                               isPortrait: portrait)
    }
}
