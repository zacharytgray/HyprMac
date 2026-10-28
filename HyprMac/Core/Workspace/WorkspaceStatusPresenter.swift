// Read-only views of workspace state: the menu bar, the overview, the status
// export and the state dump. Nothing here changes a window or an assignment.

import Cocoa

final class WorkspaceStatusPresenter {
    private let config: UserConfig
    private let accessibility: AccessibilityManager
    private let displayManager: DisplayManager
    private let workspaceManager: WorkspaceManager
    private let tilingEngine: TilingEngine
    private let stateCache: WindowStateCache
    private let scratchpad: ScratchpadController
    private let focusController: FocusStateController

    init(config: UserConfig,
         accessibility: AccessibilityManager,
         displayManager: DisplayManager,
         workspaceManager: WorkspaceManager,
         tilingEngine: TilingEngine,
         stateCache: WindowStateCache,
         scratchpad: ScratchpadController,
         focusController: FocusStateController) {
        self.config = config
        self.accessibility = accessibility
        self.displayManager = displayManager
        self.workspaceManager = workspaceManager
        self.tilingEngine = tilingEngine
        self.stateCache = stateCache
        self.scratchpad = scratchpad
        self.focusController = focusController
    }

    /// Regular workspaces that hold at least one live, non-hidden window.
    /// Hidden windows (minimized or closed apps still running) are excluded
    /// so the menu bar grid does not show ghost occupancy.
    func occupiedWorkspaces() -> Set<Int> {
        var result = Set<Int>()
        for ws in Constants.workspaceRange {
            // exclude hidden windows (minimized/closed but app still running)
            let live = workspaceManager.windowIDs(onWorkspace: ws).subtracting(stateCache.hiddenWindowIDs)
            if !live.isEmpty {
                result.insert(ws)
            }
        }
        return result
    }

    /// Workspace currently visible on each enabled screen, in screen order.
    /// Disabled monitors are omitted entirely.
    func activeWorkspaces() -> [Int] {
        displayManager.screens
            .filter { !workspaceManager.isMonitorDisabled($0) }
            .map { workspaceManager.workspaceForScreen($0) }
    }

    /// Workspaces that hold at least one live floating window.
    private func workspacesWithFloatingWindows() -> Set<Int> {
        var result = Set<Int>()
        let liveFloating = stateCache.floatingWindowIDs.subtracting(stateCache.hiddenWindowIDs)
        for workspace in Constants.workspaceRange {
            if !workspaceManager.windowIDs(onWorkspace: workspace).isDisjoint(with: liveFloating) {
                result.insert(workspace)
            }
        }
        return result
    }

    /// Publish workspace glyphs and monitor snapshots for the menu.
    func updateMenuBarState() {
        let active = Set(activeWorkspaces())
        let occupied = occupiedWorkspaces()
        let floating = workspacesWithFloatingWindows()
        let labelText = MenuBarPresentation.workspaceGlyphs(
            active: active, occupied: occupied, floating: floating)
        let enabledScreens = workspaceManager.enabledScreensLeftToRight()
        let monitors = enabledScreens.enumerated().map {
            index, screen in
                let anchored = workspaceManager.workspacesAnchoredTo(screen)
                return MenuBarMonitorSnapshot(
                    id: index,
                    name: screen.localizedName,
                    currentWorkspace: workspaceManager.workspaceForScreen(screen),
                    isPortrait: screen.frame.height > screen.frame.width,
                    workspaces: anchored.map { workspace in
                        MenuBarWorkspaceBadge(
                            id: workspace,
                            isActive: active.contains(workspace),
                            isOccupied: occupied.contains(workspace),
                            hasFloatingWindows: floating.contains(workspace))
                    })
            }
        let scratchpadCount = scratchpad.members.count
        let scratchpadVisible = scratchpad.isVisible

        DispatchQueue.main.async {
            let state = MenuBarState.shared
            state.labelText = labelText
            state.monitors = monitors
            state.scratchpadCount = scratchpadCount
            state.scratchpadVisible = scratchpadVisible
            state.hasData = true
        }
    }

    /// Read-only. `windows` is a snapshot the caller already walked, so a
    /// refresh from a poll or a retile doesn't walk AX a second time.
    func workspaceOverviewSnapshots(windows: [HyprWindow]? = nil) -> (workspaces: [WorkspaceSnapshot], scratchpad: [WorkspaceWindowSnapshot]) {
        let active = Set(activeWorkspaces())
        let currentWindows = Dictionary((windows ?? accessibility.getAllWindows()).map { ($0.windowID, $0) },
                                        uniquingKeysWith: { first, _ in first })
        let currentWindowIDs = Set(currentWindows.keys)
        let knownOrCachedWindowIDs = stateCache.knownWindowIDs.union(stateCache.cachedWindows.keys)
        let hiddenWindowIDs = stateCache.hiddenWindowIDs
        let reservedHidden = stateCache.reservedHiddenWindowIDs
        let intendedFrames = tilingEngine.intendedTileRects()

        func snapshot(_ id: CGWindowID, screenFrame: CGRect) -> WorkspaceWindowSnapshot {
            let window = currentWindows[id] ?? stateCache.cachedWindows[id]
            let owner = window?.ownerPID ?? stateCache.windowOwners[id]
            let app = owner.flatMap { NSRunningApplication(processIdentifier: $0) }
            let bundleID = window?.bundleID ?? app?.bundleIdentifier
            let appName = app?.localizedName ?? bundleID ?? "Unknown app"
            let isFloating = stateCache.floatingWindowIDs.contains(id)
            let frame = isFloating
                ? (workspaceManager.savedFloatingFrame(for: id) ?? window?.cachedFrame ?? stateCache.originalFrames[id])
                : (intendedFrames[id] ?? stateCache.tiledPositions[id] ?? window?.cachedFrame ?? stateCache.originalFrames[id])
            return WorkspaceWindowSnapshot(
                id: id,
                title: window?.title ?? appName,
                bundleID: bundleID,
                appName: appName,
                normalizedFrame: WorkspaceOverviewPresentation.normalized(frame, in: screenFrame),
                isFloating: isFloating)
        }

        let workspaces = Constants.workspaceRange.compactMap { workspace -> WorkspaceSnapshot? in
            guard let screen = workspaceManager.homeScreenForWorkspace(workspace) else { return nil }
            let screenFrame = displayManager.cgRect(for: screen)
            let visibleIDs = WorkspaceOverviewPresentation.displayedWindowIDs(
                assigned: workspaceManager.windowIDs(onWorkspace: workspace),
                current: currentWindowIDs,
                knownOrCached: knownOrCachedWindowIDs,
                hidden: hiddenWindowIDs,
                reservedHidden: reservedHidden)
            let windows = visibleIDs.map {
                snapshot($0, screenFrame: screenFrame)
            }
            return WorkspaceSnapshot(
                id: workspace,
                monitorID: workspaceManager.screenID(for: screen),
                monitorName: screen.localizedName,
                isActive: active.contains(workspace),
                windows: windows)
        }
        let scratchFrame = displayManager.screens.first.map { displayManager.cgRect(for: $0) } ?? .zero
        let scratchIDs = WorkspaceOverviewPresentation.displayedWindowIDs(
            assigned: scratchpad.members,
            current: currentWindowIDs,
            knownOrCached: knownOrCachedWindowIDs,
            hidden: hiddenWindowIDs,
            reservedHidden: reservedHidden)
        let scratchWindows = scratchIDs.map { snapshot($0, screenFrame: scratchFrame) }
        return (workspaces, scratchWindows)
    }

    /// Read-only, no AX walk: workspace state plus app names from the owners.
    func statusSnapshot() -> StatusSnapshot {
        let assigned = workspaceManager.regularWorkspaceWindowIDs()
        let members = scratchpad.members
        let hidden = stateCache.hiddenWindowIDs
        var apps: [CGWindowID: StatusSnapshot.Input.App] = [:]
        for id in assigned.values.reduce(members, { $0.union($1) }).subtracting(hidden) {
            let window = stateCache.cachedWindows[id]
            let app = (stateCache.windowOwners[id] ?? window?.ownerPID)
                .flatMap { NSRunningApplication(processIdentifier: $0) }
            let bundleID = window?.bundleID ?? app?.bundleIdentifier
            apps[id] = .init(name: app?.localizedName ?? bundleID ?? "Unknown app", bundleID: bundleID)
        }
        let screens = workspaceManager.enabledScreensLeftToRight()
        return StatusSnapshot.build(.init(
            screens: screens.map { .init(name: $0.localizedName, visibleWorkspace: workspaceManager.workspaceForScreen($0)) },
            homeScreens: Dictionary(uniqueKeysWithValues: Constants.workspaceRange.compactMap { ws in
                workspaceManager.homeScreenForWorkspace(ws).map { (ws, $0.localizedName) }
            }),
            assigned: assigned,
            scratchpad: members,
            scratchpadVisible: scratchpad.isVisible,
            hidden: hidden,
            floating: stateCache.floatingWindowIDs,
            focusedWindowID: focusController.lastFocusedID,
            cursorScreen: screens.isEmpty ? nil : displayManager.screenUnderCursor().localizedName,
            apps: apps,
            names: config.workspaceNames))
    }

    /// Log a snapshot of workspace, cache and tree state at `.notice`
    /// so it survives in `log show` as well as the debug log file.
    ///
    /// Fired once after the initial tile and on every `SIGUSR1`
    /// (`kill -USR1 $(pgrep -x 'HyprMac Debug')`). Ids only — no window
    /// titles ever enter these lines.
    func dumpState(reason: String) {
        let enabled = workspaceManager.enabledScreensLeftToRight()
        var homes: [Int: String] = [:]
        var trees: [Int: [CGWindowID]] = [:]
        var visible: Set<Int> = []
        for ws in Constants.workspaceRange {
            if workspaceManager.isWorkspaceVisible(ws) { visible.insert(ws) }
            guard let home = workspaceManager.homeScreenForWorkspace(ws) else { continue }
            homes[ws] = home.localizedName
            trees[ws] = tilingEngine.windowIDs(inTreeForWorkspace: ws, screen: home)
        }

        let dump = StateDumpFormatter(
            screens: enabled.map {
                .init(name: $0.localizedName, visibleWorkspace: workspaceManager.workspaceForScreen($0))
            },
            homeScreenNames: homes,
            visibleWorkspaces: visible,
            assignments: workspaceManager.allWindowWorkspaces(),
            hidden: stateCache.hiddenWindowIDs,
            reserved: stateCache.reservedHiddenWindowIDs,
            floating: stateCache.floatingWindowIDs,
            trees: trees,
            scratchpad: scratchpad.members,
            knownCount: stateCache.knownWindowIDs.count,
            minima: tilingEngine.knownMinimumSizes,
            fixedSizes: tilingEngine.knownFixedSizeApps,
            pendingRecovery: tilingEngine.pendingRecoveryWindowIDs,
            unverifiedGeometry: tilingEngine.unverifiedGeometryWindowIDs
        )

        hyprLog(.notice, .lifecycle, "state dump (\(reason))")
        for line in dump.lines() {
            hyprLog(.notice, .lifecycle, line)
        }
    }
}
