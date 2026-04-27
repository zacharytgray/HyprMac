// Coordinates workspace switch / move-window / move-workspace workflows on
// top of `WorkspaceManager` and `TilingEngine`. No new policy lives here —
// the orchestrator just sequences the right calls and supplies the
// focus/cursor/border glue each workflow needs.

import Cocoa

/// Coordinator for workspace-level user actions.
///
/// Delegates the data ownership to the services it composes:
/// `WorkspaceManager` still owns workspace-to-screen mapping and home
/// screens; `TilingEngine` still owns BSP trees. The orchestrator
/// sequences switch, move-window-to-workspace, and move-workspace-to-
/// monitor flows, applies suppression keys (`activation-switch`,
/// `mouse-focus`) for the duration of each action, and routes focus and
/// cursor-warp results through closure handles back into
/// `WindowManager`.
///
/// Threading: main-thread only.
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

    /// Switch to workspace `number` on the cursor's monitor.
    ///
    /// Two paths:
    /// - Already visible (on this or another screen): focus the best
    ///   window on it and warp the cursor; no hide/show needed.
    /// - Not visible: hide the displaced workspace's windows, restore
    ///   floating frames on the incoming workspace, retile, then focus
    ///   the best new window.
    ///
    /// Suppresses `activation-switch` and `mouse-focus` for the duration
    /// (and a tail) of the switch — `best.focus()` queues asynchronous
    /// notifications that would otherwise re-bounce focus.
    func switchWorkspace(_ number: Int) {
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

    /// Move the focused window to workspace `number`.
    ///
    /// Capacity is checked before any mutation: if the target workspace
    /// is currently visible, `canFitWindow` is consulted (so min-size
    /// constraints reject impossible moves); if it is not visible, a
    /// raw tile-count vs. dwindle-depth check rejects when the
    /// workspace is full. Rejections beep and flash a red border;
    /// successful moves animate the surrounding tile and post a
    /// workspace-changed notification.
    ///
    /// Special-cases windows on disabled monitors: they unfloat into
    /// the target as tiled windows on success.
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

    /// Swap the cursor's workspace with the workspace currently on the
    /// adjacent monitor in `direction` (left or right only).
    ///
    /// Sequence:
    /// 1. Hide windows on both the moving workspace and the displaced
    ///    workspace (the one currently on the target monitor).
    /// 2. Restore floating frames on the fallback workspace that takes
    ///    over the source monitor.
    /// 3. Retile every visible space.
    /// 4. Restore floating frames on the moved workspace, now positioned
    ///    on the target monitor.
    ///
    /// Disabled monitors are excluded from the candidate set on both
    /// sides — moves involving them are rejected without effect.
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
