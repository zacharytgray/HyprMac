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
        suppressions.suppress("mouse-focus", for: 0.15)

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

        hyprLog(.notice, .workspace, "moveToWorkspace(\(number)): '\(focused.title ?? "?")' (\(focused.windowID)) floating=\(isFloating) currentWs=\(currentWorkspace.map(String.init) ?? "nil") srcScreen=\(screen.localizedName)")

        // when coming from disabled monitor, unfloat so it enters tiling on target
        let willTile = onDisabledMonitor || !isFloating

        // target screen is the workspace's static home — same answer
        // whether the workspace is currently visible or hidden.
        let targetScreen = workspaceManager.homeScreenForWorkspace(number) ?? screen
        let targetVisible = workspaceManager.screenForWorkspace(number) != nil

        // check capacity on target workspace before moving a tiled window.
        if willTile {
            if !tilingEngine.canFitWindow(focused, onWorkspace: number, screen: targetScreen) {
                hyprLog(.debug, .workspace, "workspace \(number) can't fit '\(focused.title ?? "?")' on \(targetScreen.localizedName) — rejected move")
                NSSound.beep()
                if let frame = focused.frame {
                    focusBorder.flashError(around: frame, windowID: focused.windowID, window: focused,
                                           message: "Won't fit on workspace \(number)")
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
                        focusBorder.flashError(around: frame, windowID: focused.windowID, window: focused,
                                               message: "Workspace \(number) is full")
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

            if targetVisible {
                // target workspace is on screen — no park. tiled windows
                // get their frame from the retile that follows; floaters
                // are carried to the target screen directly. parking here
                // used to strand floaters in the hide corner: nothing
                // restores a floating frame until the next workspace
                // switch, and the switch's hide pass would re-save the
                // park position as the "real" frame.
                hyprLog(.notice, .workspace, "moveToWorkspace(\(number)): target visible — placing '\(focused.title ?? "?")' (\(focused.windowID)) on \(targetScreen.localizedName) tiled=\(willTile)")
                if !willTile {
                    carryFloaterToScreen(focused, targetScreen)
                }
            } else {
                // target hidden — park at the global hide corner until the
                // workspace is shown. park on the workspace's static home
                // monitor, not the source screen (AeroSpace pattern: a
                // window assigned to ws N belongs physically near ws N's
                // monitor so the next show is a single-screen transition).
                if isFloating && !onDisabledMonitor {
                    workspaceManager.saveFloatingFrame(focused)
                }
                hyprLog(.notice, .workspace, "moveToWorkspace(\(number)): parking '\(focused.title ?? "?")' (\(focused.windowID)) homeScreen=\(targetScreen.localizedName) at \(workspaceManager.hidePosition())")
                workspaceManager.hideInCorner(focused, on: targetScreen)
            }
        }, { [self] in
            if targetVisible {
                // destination is on screen — focus follows the window,
                // matching switchWorkspace's focus+warp behavior.
                focused.focusWithoutRaise()
                cursorManager.warpToCenter(of: focused)
                focusController.recordFocus(focused.windowID, reason: "moveToWorkspace-follow")
                updateFocusBorder(focused)
            } else {
                // window vanished into a hidden workspace — re-anchor focus
                // on whatever remains on the source workspace instead of
                // leaving the border tracking a parked window.
                refocusAfterMove(on: screen, excluding: focused.windowID)
            }
            NotificationCenter.default.post(name: .hyprMacWorkspaceChanged, object: nil)
        })
    }

    /// Place a floating window onto `screen`, preserving its size and its
    /// relative position. No-op when the floater is already substantially
    /// visible on the target screen.
    private func carryFloaterToScreen(_ window: HyprWindow, _ screen: NSScreen) {
        guard let frame = window.frame else { return }
        let targetRect = displayManager.cgRect(for: screen)
        if frame.isSubstantiallyVisible(on: targetRect, threshold: 0.5) { return }

        let sourceScreen = displayManager.screen(for: window) ?? screen
        let sourceRect = displayManager.cgRect(for: sourceScreen)
        let relX = sourceRect.width > 0 ? (frame.midX - sourceRect.minX) / sourceRect.width : 0.5
        let relY = sourceRect.height > 0 ? (frame.midY - sourceRect.minY) / sourceRect.height : 0.5
        let size = CGSize(width: min(frame.width, targetRect.width),
                          height: min(frame.height, targetRect.height))
        var origin = CGPoint(x: targetRect.minX + relX * targetRect.width - size.width / 2,
                             y: targetRect.minY + relY * targetRect.height - size.height / 2)
        origin.x = max(targetRect.minX, min(origin.x, targetRect.maxX - size.width))
        origin.y = max(targetRect.minY, min(origin.y, targetRect.maxY - size.height))
        window.setFrame(CGRect(origin: origin, size: size))
    }

    /// Focus the best remaining window on `screen`'s active workspace
    /// after `movedID` left it. Prefers tiled windows; hides the chrome
    /// when the workspace emptied out.
    private func refocusAfterMove(on screen: NSScreen, excluding movedID: CGWindowID) {
        guard !workspaceManager.isMonitorDisabled(screen) else { return }
        let ws = workspaceManager.workspaceForScreen(screen)
        let remaining = workspaceManager.windowIDs(onWorkspace: ws)
            .subtracting(stateCache.hiddenWindowIDs)
            .subtracting([movedID])
            .filter { stateCache.cachedWindows[$0] != nil }
            .sorted()
        let pick = remaining.first { !stateCache.floatingWindowIDs.contains($0) } ?? remaining.first
        guard let wid = pick, let w = stateCache.cachedWindows[wid] else {
            focusBorder.hide(); dimmingOverlay.hideAll()
            return
        }
        w.focusWithoutRaise()
        focusController.recordFocus(wid, reason: "moveToWorkspace-refocus")
        updateFocusBorder(w)
    }

    // MARK: - move window to adjacent monitor

    /// Move the focused window to the monitor adjacent in `direction`,
    /// landing on whatever workspace is visible there. Delegates to
    /// `moveToWorkspace` so capacity checks, floater handling, and focus
    /// follow all behave identically to `Hypr+Shift+N`.
    ///
    /// Replaces the old workspace-to-monitor move, which static
    /// anchoring turned into a permanent no-op.
    func moveWindowToMonitor(_ direction: Direction) {
        guard direction == .left || direction == .right else {
            NSSound.beep()
            return
        }
        guard let focused = currentFocusedWindow(),
              let screen = displayManager.screen(for: focused) ?? displayManager.screens.first else {
            NSSound.beep()
            return
        }

        let enabled = displayManager.screens.filter { !workspaceManager.isMonitorDisabled($0) }
        let candidates = enabled.filter {
            direction == .left
                ? $0.frame.maxX <= screen.frame.minX + 1
                : $0.frame.minX >= screen.frame.maxX - 1
        }
        // nearest screen in the requested direction
        let target = direction == .left
            ? candidates.max(by: { $0.frame.origin.x < $1.frame.origin.x })
            : candidates.min(by: { $0.frame.origin.x < $1.frame.origin.x })
        guard let target else {
            hyprLog(.debug, .workspace, "moveWindowToMonitor(\(direction.rawValue)): no monitor in that direction")
            NSSound.beep()
            if let frame = focused.frame {
                focusBorder.flashError(around: frame, windowID: focused.windowID, window: focused,
                                       message: "No monitor to the \(direction.rawValue)")
            }
            return
        }

        moveToWorkspace(workspaceManager.workspaceForScreen(target))
    }
}
