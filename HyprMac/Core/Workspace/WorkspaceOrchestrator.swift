import Cocoa

// coordinates workspace switch / move / move-to-monitor workflows.
//
// per plan §3.3, the orchestrator delegates to WorkspaceManager (which still
// owns workspace-to-screen mapping) and TilingEngine (which still owns BSP
// trees). it does not own:
//   - workspaceManager.monitorWorkspace / workspaceHomeScreen (still on WM).
//   - any tree mutation beyond what TilingEngine.removeWindow / canFitWindow /
//     maxDepth expose.
//   - focus / cursor / border policy — those go through the injected closures
//     and the per-subsystem references, no new policy lives here.
//
// the orchestrator holds direct references to long-lived dependencies and
// closure handles for WM-side helpers (animatedRetile, tileAllVisibleSpaces,
// currentFocusedWindow, screenUnderCursor, updateFocusBorder) that can't be
// expressed as standalone services without a wider refactor. these are
// utility callbacks for action workflows, not reaction callbacks the way
// Q2 warned against — Phase 4's ActionDispatcher will route into this
// orchestrator on top, not unwire it.
final class WorkspaceOrchestrator {

    private let workspaceManager: WorkspaceManager
    private let tilingEngine: TilingEngine
    private let accessibility: AccessibilityManager
    private let displayManager: DisplayManager
    private let cursorManager: CursorManager
    private let stateCache: WindowStateCache
    private let focusController: FocusStateController
    private let focusBorder: FocusBorder
    private let dimmingOverlay: DimmingOverlay
    private let suppressions: SuppressionRegistry

    var screenUnderCursor: () -> NSScreen = { NSScreen.main! }
    var currentFocusedWindow: () -> HyprWindow? = { nil }
    var updateFocusBorder: (HyprWindow) -> Void = { _ in }
    var tileAllVisibleSpaces: () -> Void = { }
    var animatedRetile: (_ prepare: (() -> Void)?, _ completion: (() -> Void)?) -> Void = { _, _ in }

    init(workspaceManager: WorkspaceManager,
         tilingEngine: TilingEngine,
         accessibility: AccessibilityManager,
         displayManager: DisplayManager,
         cursorManager: CursorManager,
         stateCache: WindowStateCache,
         focusController: FocusStateController,
         focusBorder: FocusBorder,
         dimmingOverlay: DimmingOverlay,
         suppressions: SuppressionRegistry) {
        self.workspaceManager = workspaceManager
        self.tilingEngine = tilingEngine
        self.accessibility = accessibility
        self.displayManager = displayManager
        self.cursorManager = cursorManager
        self.stateCache = stateCache
        self.focusController = focusController
        self.focusBorder = focusBorder
        self.dimmingOverlay = dimmingOverlay
        self.suppressions = suppressions
    }

    // MARK: - switch

    func switchWorkspace(_ number: Int) {
        // suppress FFM and activation-triggered switches during and after this switch.
        // must outlive the synchronous scope because best.focus() queues async notifications.
        suppressions.suppress("activation-switch", for: 0.5)
        suppressions.suppress("mouse-focus", for: 0.3)

        let currentScreen = screenUnderCursor()

        let allWindows = accessibility.getAllWindows()
        let result = workspaceManager.switchWorkspace(number, cursorScreen: currentScreen)

        if result.alreadyVisible {
            // workspace is showing on result.screen — just focus it
            let visibleWindows = allWindows.filter { result.toShow.contains($0.windowID) }
            if let best = visibleWindows.first(where: { !stateCache.floatingWindowIDs.contains($0.windowID) })
                ?? visibleWindows.first {
                best.focus()
                cursorManager.warpToCenter(of: best)
                focusController.recordFocus(best.windowID, reason: "switchWorkspace-already-visible")
                updateFocusBorder(best)
            } else {
                let rect = displayManager.cgRect(for: result.screen)
                CGWarpMouseCursorPosition(CGPoint(x: rect.midX, y: rect.midY))
                focusBorder.hide(); dimmingOverlay.hideAll()
            }
            return
        }

        // batch: hide old + restore floating new in one tight pass
        for wid in result.toHide {
            if let w = allWindows.first(where: { $0.windowID == wid }) ?? stateCache.cachedWindows[wid] {
                if stateCache.floatingWindowIDs.contains(wid) { workspaceManager.saveFloatingFrame(w) }
                workspaceManager.hideInCorner(w, on: result.screen)
            }
        }
        for wid in result.toShow where stateCache.floatingWindowIDs.contains(wid) {
            if let w = allWindows.first(where: { $0.windowID == wid }) ?? stateCache.cachedWindows[wid] {
                workspaceManager.restoreFloatingFrame(w)
            }
        }

        // retile immediately — no delay between hide and show
        tileAllVisibleSpaces()

        // focus best tiled window on the new workspace; if none, fall back to
        // any floating window before giving up. only warp+hide if truly empty.
        let newWorkspaceWindows = allWindows.filter { result.toShow.contains($0.windowID) }
        let tiled = newWorkspaceWindows.first { !stateCache.floatingWindowIDs.contains($0.windowID) }
        if let best = tiled ?? newWorkspaceWindows.first {
            best.focus()
            cursorManager.warpToCenter(of: best)
            focusController.recordFocus(best.windowID, reason: "switchWorkspace-after-show")
            updateFocusBorder(best)
        } else {
            let rect = displayManager.cgRect(for: result.screen)
            CGWarpMouseCursorPosition(CGPoint(x: rect.midX, y: rect.midY))
            focusBorder.hide(); dimmingOverlay.hideAll()
        }

        NotificationCenter.default.post(name: .hyprMacWorkspaceChanged, object: nil)
    }

    // MARK: - move focused window to workspace

    func moveToWorkspace(_ number: Int) {
        guard let focused = currentFocusedWindow() else { return }
        tilingEngine.primeMinimumSizes([focused])
        guard let screen = displayManager.screen(for: focused) ?? displayManager.screens.first else { return }

        // window on a disabled monitor — send it to the target workspace as a tiled window
        let onDisabledMonitor = workspaceManager.isMonitorDisabled(screen)

        let currentWorkspace = onDisabledMonitor ? nil : Optional(workspaceManager.workspaceForScreen(screen))

        if let cw = currentWorkspace, number == cw {
            hyprLog(.debug, .workspace, "window already on workspace \(number)")
            return
        }

        let isFloating = stateCache.floatingWindowIDs.contains(focused.windowID)

        // when coming from disabled monitor, unfloat so it enters tiling on target
        let willTile = onDisabledMonitor || !isFloating

        // check capacity on target workspace before moving a tiled window
        if willTile {
            let targetScreen = workspaceManager.screenForWorkspace(number)
                ?? workspaceManager.homeScreenForWorkspace(number)
                ?? screen

            if let visibleScreen = workspaceManager.screenForWorkspace(number) {
                if !tilingEngine.canFitWindow(focused, onWorkspace: number, screen: visibleScreen) {
                    hyprLog(.debug, .workspace, "workspace \(number) can't fit '\(focused.title ?? "?")' on \(visibleScreen.localizedName) — rejected move")
                    NSSound.beep()
                    if let frame = focused.frame {
                        focusBorder.flashError(around: frame, windowID: focused.windowID, window: focused)
                    }
                    return
                }
            } else {
                // exclude hidden windows (minimized/closed but app still running) from count
                let wids = workspaceManager.windowIDs(onWorkspace: number).subtracting(stateCache.hiddenWindowIDs)
                let tiledCount = wids.filter { !stateCache.floatingWindowIDs.contains($0) }.count
                let maxDepth = tilingEngine.maxDepth(for: targetScreen)
                let maxWindows = 1 << maxDepth // 2^maxDepth — smart insert backtracks to fill all slots
                if tiledCount >= maxWindows {
                    hyprLog(.debug, .workspace, "workspace \(number) full (\(tiledCount) tiled, max \(maxWindows)) — rejected move")
                    NSSound.beep()
                    if let frame = focused.frame {
                        focusBorder.flashError(around: frame, windowID: focused.windowID, window: focused)
                    }
                    return
                }
            }
        }

        // unfloat if coming from disabled monitor
        if onDisabledMonitor && isFloating {
            stateCache.floatingWindowIDs.remove(focused.windowID)
            focused.isFloating = false
            hyprLog(.debug, .workspace, "unfloating '\(focused.title ?? "?")' from disabled monitor → workspace \(number)")
        }

        // animate remaining windows filling the gap
        animatedRetile({ [self] in
            // remove from current workspace's tiling tree
            if !isFloating, let cw = currentWorkspace {
                tilingEngine.removeWindow(focused, fromWorkspace: cw)
            }

            // reassign globally
            workspaceManager.moveWindow(focused.windowID, toWorkspace: number)

            // hide the window — target workspace may not be visible
            if isFloating && !onDisabledMonitor {
                workspaceManager.saveFloatingFrame(focused)
            }
            workspaceManager.hideInCorner(focused, on: screen)
        }, {
            NotificationCenter.default.post(name: .hyprMacWorkspaceChanged, object: nil)
        })
    }

    // MARK: - move workspace to adjacent monitor

    func moveCurrentWorkspaceToMonitor(_ direction: Direction) {
        let currentScreen = screenUnderCursor()

        // can't move workspaces from/to disabled monitors
        if workspaceManager.isMonitorDisabled(currentScreen) {
            hyprLog(.debug, .workspace, "moveWorkspaceToMonitor: current monitor is disabled")
            return
        }

        // find adjacent enabled monitor in the given direction
        let screens = displayManager.screens
            .filter { !workspaceManager.isMonitorDisabled($0) }
            .sorted { $0.frame.origin.x < $1.frame.origin.x }
        guard let currentIdx = screens.firstIndex(of: currentScreen) else { return }

        let targetIdx: Int
        switch direction {
        case .left:  targetIdx = currentIdx - 1
        case .right: targetIdx = currentIdx + 1
        default:
            hyprLog(.debug, .workspace, "moveWorkspaceToMonitor: only left/right supported")
            return
        }

        guard targetIdx >= 0 && targetIdx < screens.count else {
            hyprLog(.debug, .workspace, "moveWorkspaceToMonitor: no monitor in that direction")
            return
        }

        let targetScreen = screens[targetIdx]
        let monitorCount = screens.count

        guard let result = workspaceManager.moveWorkspace(
            from: currentScreen, to: targetScreen, monitorCount: monitorCount
        ) else { return }

        let allWindows = accessibility.getAllWindows()

        // hide windows that need to move — they'll be retiled to correct positions
        // moved workspace windows: currently on source screen, moving to target
        let movedWindows = workspaceManager.windowIDs(onWorkspace: result.movedWs)
        for wid in movedWindows {
            if let w = allWindows.first(where: { $0.windowID == wid }) ?? stateCache.cachedWindows[wid] {
                if stateCache.floatingWindowIDs.contains(wid) { workspaceManager.saveFloatingFrame(w) }
                workspaceManager.hideInCorner(w, on: targetScreen)
            }
        }

        // target's old workspace windows: need to be hidden (displaced, no longer visible)
        let displacedWindows = workspaceManager.windowIDs(onWorkspace: result.targetOldWs)
        if !workspaceManager.isWorkspaceVisible(result.targetOldWs) {
            for wid in displacedWindows {
                if let w = allWindows.first(where: { $0.windowID == wid }) ?? stateCache.cachedWindows[wid] {
                    if stateCache.floatingWindowIDs.contains(wid) { workspaceManager.saveFloatingFrame(w) }
                    workspaceManager.hideInCorner(w, on: targetScreen)
                }
            }
        }

        // fallback workspace windows: need to appear on source screen
        let fallbackWindows = workspaceManager.windowIDs(onWorkspace: result.fallbackWs)
        for wid in fallbackWindows where stateCache.floatingWindowIDs.contains(wid) {
            if let w = allWindows.first(where: { $0.windowID == wid }) ?? stateCache.cachedWindows[wid] {
                workspaceManager.restoreFloatingFrame(w)
            }
        }

        tileAllVisibleSpaces()

        // restore floating windows on moved workspace (now on target screen)
        for wid in movedWindows where stateCache.floatingWindowIDs.contains(wid) {
            if let w = allWindows.first(where: { $0.windowID == wid }) ?? stateCache.cachedWindows[wid] {
                workspaceManager.restoreFloatingFrame(w)
            }
        }

        NotificationCenter.default.post(name: .hyprMacWorkspaceChanged, object: nil)
    }
}
