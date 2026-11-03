// Which workspace each window goes on: classify, distribute, and keep hidden
// workspaces parked. Callers run classify, then distribute, then tile. Classify
// and distribute share one array, because `isFloating` is set on its objects.

import Cocoa

final class WindowPlacement {
    private let config: UserConfig
    private let accessibility: AccessibilityManager
    private let displayManager: DisplayManager
    private let workspaceManager: WorkspaceManager
    private let tilingEngine: TilingEngine
    private let stateCache: WindowStateCache
    private let floatingController: FloatingWindowController
    private let scratchpad: ScratchpadController
    private let actionDispatcher: ActionDispatcher
    private let workspaceOrchestrator: WorkspaceOrchestrator

    init(config: UserConfig,
         accessibility: AccessibilityManager,
         displayManager: DisplayManager,
         workspaceManager: WorkspaceManager,
         tilingEngine: TilingEngine,
         stateCache: WindowStateCache,
         floatingController: FloatingWindowController,
         scratchpad: ScratchpadController,
         actionDispatcher: ActionDispatcher,
         workspaceOrchestrator: WorkspaceOrchestrator) {
        self.config = config
        self.accessibility = accessibility
        self.displayManager = displayManager
        self.workspaceManager = workspaceManager
        self.tilingEngine = tilingEngine
        self.stateCache = stateCache
        self.floatingController = floatingController
        self.scratchpad = scratchpad
        self.actionDispatcher = actionDispatcher
        self.workspaceOrchestrator = workspaceOrchestrator
    }

    /// Classification half of the snapshot: capture original frames,
    /// register ownership, auto-float excluded apps and disabled-monitor
    /// windows, and assign unassigned windows to their physical screen's
    /// active workspace. Idempotent — already-known windows keep their
    /// state and workspace assignment.
    func classifyAndAssign(_ allWindows: [HyprWindow]) {
        tilingEngine.primeMinimumSizes(allWindows)
        for w in allWindows {
            if let frame = w.frame, stateCache.originalFrames[w.windowID] == nil {
                // only save if the frame is actually visible on some screen.
                // after a restart, windows may still be at the previous session's hide corner.
                let onScreen = displayManager.screens.contains { screen in
                    frame.isSubstantiallyVisible(on: displayManager.cgRect(for: screen))
                }
                if onScreen {
                    stateCache.originalFrames[w.windowID] = frame
                }
            }
            stateCache.cachedWindows[w.windowID] = w
            stateCache.knownWindowIDs.insert(w.windowID)
            stateCache.windowOwners[w.windowID] = w.ownerPID

            // auto-float excluded apps and explicitly fixed-size windows
            if let reason = floatingController.autoFloatReason(
                w, excludedBundleIDs: Set(config.excludedBundleIDs)
            ), !stateCache.floatingWindowIDs.contains(w.windowID) {
                stateCache.setFloating(true, window: w)
                hyprLog(.debug, .lifecycle, "auto-float \(reason.rawValue): '\(w.title ?? "?")'")
            }

            // auto-float windows on disabled monitors — don't assign workspace
            if let screen = displayManager.screen(for: w), workspaceManager.isMonitorDisabled(screen) {
                if !stateCache.floatingWindowIDs.contains(w.windowID) {
                    stateCache.setFloating(true, window: w)
                    hyprLog(.debug, .lifecycle, "auto-float on disabled monitor: '\(w.title ?? "?")'")
                }
                continue
            }

            assignToScreenWorkspace(w)
        }
    }

    /// Spread every tiling-eligible window across workspaces so no single
    /// workspace is forced past its dwindle depth.
    ///
    /// Workspaces fill in numeric order, with each workspace's capacity
    /// derived from its statically anchored monitor. Anything that does not
    /// fit even in the tenth workspace is auto-floated. Called from every
    /// `start()` (including resume from pause), Retile All and a Max Splits
    /// change, through `snapshotAndTile`.
    func distributeWindowsAcrossWorkspaces(_ allWindows: [HyprWindow]) {
        hyprLog(.notice, .lifecycle, "distributeWindowsAcrossWorkspaces ENTER — full redistribute about to run (this rewrites workspace assignments)")
        // the homes' order, so a stacked desk fills the primary first here too
        let screens = workspaceManager.enabledScreensLeftToRight()
        guard !screens.isEmpty else { return }

        let allWids = Set(allWindows.map { $0.windowID })

        // full redistribution: un-float everything except excluded apps and
        // non-standard windows (dialogs, sheets, floating panels).
        let excluded = Set(config.excludedBundleIDs)
        let keepFloating = Set(allWindows.filter {
            RetileAllPlanner.shouldRemainFloating(
                isAutoFloat: floatingController.shouldAutoFloat($0, excludedBundleIDs: excluded),
                isOnDisabledMonitor: displayManager.screen(for: $0).map(workspaceManager.isMonitorDisabled) == true
            )
        }.map { $0.windowID })
        for wid in stateCache.floatingWindowIDs where !keepFloating.contains(wid) && allWids.contains(wid) {
            // scratchpad members survive Retile All — unfloating them would
            // dissolve the layer and drag parked windows into the trees
            if scratchpad.contains(wid) { continue }
            stateCache.floatingWindowIDs.remove(wid)
            if let w = allWindows.first(where: { $0.windowID == wid }) {
                w.isFloating = false
            }
        }

        // Include every tracked regular workspace, including parked windows
        // that AX omits, and globally sort with newly discovered windows.
        let excludedWids = stateCache.floatingWindowIDs
            .union(stateCache.hiddenWindowIDs)
            .union(scratchpad.members)
        let tilingWids = RetileAllPlanner.eligibleWindowIDs(
            workspaceAssignments: workspaceManager.regularWorkspaceWindowIDs(),
            discoveredWindowIDs: allWids,
            excludedWindowIDs: excludedWids
        )

        // floaters first: the tiled pass below can return early
        placePinnedFloaters(allWindows)

        guard !tilingWids.isEmpty else { return }

        let plan = startupPlacement(windowIDs: tilingWids, windows: allWindows, screens: screens)
        for workspace in plan.assignments.keys.sorted() {
            for windowID in plan.assignments[workspace] ?? [] {
                workspaceManager.assignWindow(windowID, toWorkspace: workspace)
            }
        }

        // any remaining (all workspaces full) — auto-float
        for wid in plan.overflow {
            stateCache.floatingWindowIDs.insert(wid)
            if let w = allWindows.first(where: { $0.windowID == wid }) {
                w.isFloating = true
                if let original = stateCache.originalFrames[wid] {
                    w.placeFloating(original, reason: "all workspaces full, original frame",
                                    displayManager: displayManager)
                }
                hyprLog(.debug, .lifecycle, "all workspaces full — auto-floating '\(w.title ?? "?")'")
            }
        }

        // hide windows on non-visible workspaces
        for wid in tilingWids where !stateCache.floatingWindowIDs.contains(wid) {
            guard let assignedWs = workspaceManager.workspaceFor(wid),
                  !workspaceManager.isWorkspaceVisible(assignedWs) else { continue }
            if let w = allWindows.first(where: { $0.windowID == wid }) {
                let screen = workspaceManager.homeScreenForWorkspace(assignedWs) ?? screens[0]
                workspaceManager.hideInCorner(w, on: screen)
            }
        }

        hyprLog(.debug, .lifecycle, "distributed \(tilingWids.count) windows across \(plan.assignments.count) slot(s), \(screens.count) monitor(s)")
    }

    /// Retile All's half of window rules for floaters: a pinned app's
    /// floating window (Never tile, fixed size) goes to its pin too. Hidden
    /// windows keep their workspace, scratchpad members stay in the layer,
    /// and a floater on a disabled monitor stays there.
    private func placePinnedFloaters(_ allWindows: [HyprWindow]) {
        guard !config.windowRules.isEmpty else { return }
        let byID = Dictionary(allWindows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = stateCache.floatingWindowIDs.filter { id in
            guard let window = byID[id], !stateCache.hiddenWindowIDs.contains(id),
                  !scratchpad.contains(id) else { return false }
            return displayManager.screen(for: window).map(workspaceManager.isMonitorDisabled) != true
        }
        let moves = RetileAllPlanner.pinnedFloaterMoves(
            floatingWindowIDs: Array(candidates),
            workspaceFor: workspaceManager.workspaceFor,
            pinnedWorkspaceFor: { [self] id in byID[id].flatMap(actionDispatcher.pinnedWorkspace(for:)) }
        )
        for move in moves {
            guard let window = byID[move.windowID] else { continue }
            workspaceManager.moveWindow(move.windowID, toWorkspace: move.to)
            workspaceOrchestrator.placePinnedFloater(window, onWorkspace: move.to, fromWorkspace: move.from)
        }
    }

    /// Assign `window` to the active workspace on its physical screen, but
    /// only if it has no existing assignment. Used during snapshot so an
    /// already-placed window is not bounced off its current workspace.
    private func assignToScreenWorkspace(_ window: HyprWindow) {
        guard workspaceManager.workspaceFor(window.windowID) == nil else { return }
        if let screen = displayManager.screen(for: window) ?? displayManager.screens.first {
            let ws = workspaceManager.workspaceForScreen(screen)
            workspaceManager.assignWindow(window.windowID, toWorkspace: ws)
        }
    }

    /// Re-park every window assigned to a hidden workspace at the current
    /// global hide position. After a monitor connect/disconnect the
    /// rightmost screen — and with it the park corner — can move; windows
    /// left at the old corner would sit fully visible mid-screen (or on a
    /// dead coordinate) while their workspace is still hidden.
    func reparkHiddenWorkspaceWindows(_ allWindows: [HyprWindow]) {
        for w in allWindows {
            guard let ws = workspaceManager.workspaceFor(w.windowID),
                  !workspaceManager.isWorkspaceVisible(ws),
                  let screen = workspaceManager.homeScreenForWorkspace(ws) ?? displayManager.screens.first
            else { continue }
            workspaceManager.hideInCorner(w, on: screen)
        }
    }

    /// Park self-repair: a hidden-workspace window the OS (or its own app)
    /// moved back on-screen would otherwise sit visible forever — nothing
    /// re-parks in steady state and drift deliberately ignores hidden-ws
    /// windows. Runs after applyChanges so a just-reassigned returned
    /// window (recycled-id reopen) is already on its visible workspace and
    /// exempt. Re-parking is idempotent, so a stale AX read of a window
    /// that is really parked just re-asserts the park.
    func repairParkedWindows(_ allWindows: [HyprWindow]) {
        for w in allWindows {
            guard let ws = workspaceManager.workspaceFor(w.windowID),
                  !workspaceManager.isWorkspaceVisible(ws),
                  let frame = w.frame
            else { continue }
            let substantiallyVisible = displayManager.screens.contains { screen in
                frame.isSubstantiallyVisible(on: displayManager.cgRect(for: screen))
            }
            guard substantiallyVisible,
                  let screen = workspaceManager.homeScreenForWorkspace(ws) ?? displayManager.screens.first
            else { continue }
            hyprLog(.notice, .lifecycle, "park repair: '\(w.title ?? "?")' (\(w.windowID)) on hidden ws\(ws) reads visible — re-parking")
            workspaceManager.hideInCorner(w, on: screen)
        }
    }

    private func startupPlacement(windowIDs: [CGWindowID], windows: [HyprWindow], screens: [NSScreen]) -> RetileAllPlan {
        let byID = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let frames = Dictionary(uniqueKeysWithValues: windows.compactMap { window in
            window.frame.map { (window.windowID, $0) }
        })
        let focusedID = accessibility.getFocusedWindow()?.windowID
        let order = { (ids: [CGWindowID]) in
            RetileAllPlanner.startupWindowOrder(windowIDs: ids, framesByID: frames, focusedWindowID: focusedID)
        }
        // pinned apps' windows go to their rule's workspace, whichever display
        // they sit on, and claim it before the screen batches fill it. a
        // parked window AX omits is looked up in the cache, when the cache has it
        let pinned = RetileAllPlanner.pinnedStartupBatches(
            windowIDs: windowIDs,
            pinnedWorkspaceFor: { [self] id in
                (byID[id] ?? stateCache.cachedWindows[id]).flatMap(actionDispatcher.pinnedWorkspace(for:))
            },
            order: order
        )
        let screenBatches = screens.map { screen in
            let localIDs = pinned.unpinned.filter { id in
                let assignedHome = workspaceManager.workspaceFor(id).flatMap(workspaceManager.homeScreenForWorkspace)
                let home = assignedHome ?? byID[id].flatMap(displayManager.screen(for:)) ?? screens[0]
                return home == screen
            }
            return RetileAllBatch(
                preferredWorkspace: workspaceManager.workspaceForScreen(screen),
                windowIDs: order(localIDs)
            )
        }
        let batches = pinned.batches + screenBatches
        let reserved = Dictionary(uniqueKeysWithValues: Constants.workspaceRange.map { workspace in
            (workspace, workspaceManager.windowIDs(onWorkspace: workspace)
                .intersection(stateCache.reservedHiddenWindowIDs)
                .subtracting(stateCache.floatingWindowIDs))
        })
        return RetileAllPlanner.admitStartupBatches(
            batches,
            workspaceCount: workspaceManager.workspaceCount,
            reservedAssignments: reserved
        ) { [self] workspace in
            guard let home = workspaceManager.homeScreenForWorkspace(workspace),
                  screens.contains(home) else { return 0 }
            return RetileAllPlanner.workspaceCapacity(maxDepth: tilingEngine.maxDepth(for: home))
        }
    }
}
