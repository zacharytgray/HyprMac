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
        // hold polls off for the duration of the transition. Tahoe AX
        // writes lag, so a poll mid-transition reads stale frames and
        // drift detection can falsely reassign windows.
        suppressions.suppress("workspace-transition", for: 1.5)
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
        // hold polls off for the duration of the transition. Tahoe AX
        // writes lag, so a poll mid-transition reads the moved window
        // at its OLD pre-hide tile rect and drift detection
        // erroneously reassigns it back to its source workspace.
        suppressions.suppress("workspace-transition", for: 1.5)
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

        // check capacity on target workspace before moving a tiled window.
        // target screen is the workspace's static home — same answer
        // whether the workspace is currently visible or hidden.
        if willTile {
            let targetScreen = workspaceManager.homeScreenForWorkspace(number) ?? screen

            if !tilingEngine.canFitWindow(focused, onWorkspace: number, screen: targetScreen) {
                hyprLog(.debug, .workspace, "workspace \(number) can't fit '\(focused.title ?? "?")' on \(targetScreen.localizedName) — rejected move")
                NSSound.beep()
                if let frame = focused.frame {
                    focusBorder.flashError(around: frame, windowID: focused.windowID, window: focused)
                }
                return
            }

            if workspaceManager.screenForWorkspace(number) == nil {
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

            // hide the window — target workspace may not be visible.
            // park on the workspace's static home monitor, not the source
            // screen. AeroSpace pattern: a window assigned to ws N belongs
            // physically near ws N's monitor so the next show is a no-op
            // hide-corner→tile transition on a single screen.
            if isFloating && !onDisabledMonitor {
                workspaceManager.saveFloatingFrame(focused)
            }
            let parkScreen = workspaceManager.homeScreenForWorkspace(number) ?? screen
            workspaceManager.hideInCorner(focused, on: parkScreen)
        }, {
            NotificationCenter.default.post(name: .hyprMacWorkspaceChanged, object: nil)
        })
    }

    // MARK: - move workspace to adjacent monitor

    /// No-op under static workspace anchoring. Workspaces are pinned to
    /// monitors by `(N - 1) % enabledMonitorCount` and cannot move.
    /// Beeps so the user gets immediate feedback that the keybind fired
    /// but the action is rejected.
    func moveCurrentWorkspaceToMonitor(_ direction: Direction) {
        hyprLog(.debug, .workspace, "moveWorkspaceToMonitor: rejected (workspaces are statically anchored)")
        NSSound.beep()
    }
}
