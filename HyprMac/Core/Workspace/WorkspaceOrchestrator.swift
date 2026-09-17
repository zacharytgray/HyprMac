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
    private let revalidation: MinimaRevalidation

    var screenUnderCursor: () -> NSScreen = { NSScreen.main! }
    var currentFocusedWindow: () -> HyprWindow? = { nil }
    var updateFocusBorder: (HyprWindow) -> Void = { _ in }
    var tileAllVisibleSpaces: () -> Void = { }
    /// Every window AX can see right now. A seam because the explicit
    /// revalidation attempt needs the destination's tenants, and a test has
    /// no desktop to read them off.
    var allWindows: () -> [HyprWindow] = { [] }
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
         suppressions: SuppressionRegistry,
         revalidation: MinimaRevalidation) {
        self.revalidation = revalidation
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
        self.allWindows = { [weak accessibility] in accessibility?.getAllWindows() ?? [] }
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
    /// Capacity is checked before any mutation. `admissionOutlook` answers
    /// for visible and hidden destinations alike: it fits, only learned
    /// bounds refuse it, or the refusal is one no attempt can change. A
    /// hidden destination then also gets the raw tile-count vs.
    /// dwindle-depth check. Rejections beep and flash a red border;
    /// successful moves animate the surrounding tile and post a
    /// workspace-changed notification. A refusal that only learned bounds
    /// produced buys one revalidation — run here for a visible destination,
    /// left as a marker for the reveal when the destination is hidden.
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

        // the user asking again replaces whatever the last ask left pending
        revalidation.cancel(focused.windowID, reason: "moved again")

        // check capacity on target workspace before moving a tiled window.
        var decision = MinimaRevalidation.Decision.admit
        if willTile {
            let outlook = tilingEngine.admissionOutlook(focused, onWorkspace: number, screen: targetScreen)
            decision = MinimaRevalidation.decide(outlook, destinationVisible: targetVisible)
            if decision == .refuse {
                hyprLog(.notice, .workspace, "workspace \(number) can't fit \(focused.windowID)"
                        + " on \(targetScreen.localizedName) — rejected move")
                NSSound.beep()
                if let frame = focused.frame {
                    focusBorder.flashError(around: frame, windowID: focused.windowID, window: focused,
                                           message: "Won't fit on workspace \(number)")
                }
                return
            }

            if workspaceManager.screenForWorkspace(number) == nil {
                // count occupancy the way admission does: a closed-but-alive
                // ghost holds no slot, a minimized or Cmd-H'd window still does
                let excluded = ActionDispatcher.admissionExclusions(
                    floatingWindowIDs: stateCache.floatingWindowIDs,
                    hiddenWindowIDs: stateCache.hiddenWindowIDs,
                    reservedHiddenWindowIDs: stateCache.reservedHiddenWindowIDs)
                let tiledCount = workspaceManager.windowIDs(onWorkspace: number)
                    .subtracting(excluded).count
                let maxDepth = tilingEngine.maxDepth(for: targetScreen)
                let maxWindows = RetileAllPlanner.workspaceCapacity(maxDepth: maxDepth)
                if tiledCount >= maxWindows {
                    hyprLog(.notice, .workspace, "workspace \(number) full: incoming=\(focused.windowID)"
                            + " tiled=\(tiledCount) max=\(maxWindows) axis=count source=structural"
                            + " — rejected move")
                    NSSound.beep()
                    if let frame = focused.frame {
                        focusBorder.flashError(around: frame, windowID: focused.windowID, window: focused,
                                               message: "Workspace \(number) is full")
                    }
                    return
                }
            }
        }

        // the destination refused on learned bounds alone. a visible one gets
        // its one attempt right here, and nothing about the source changes
        // until the screen has accepted the layout; a hidden one keeps a
        // marker and is settled on its reveal.
        switch decision {
        case .revalidateHere:
            guard revalidateVisibleDestination(focused, workspace: number, screen: targetScreen,
                                               from: screen) else {
                hyprLog(.notice, .workspace, "moveToWorkspace(\(number)): revalidation refused"
                        + " incoming=\(focused.windowID) — \(focused.windowID) stays on"
                        + " ws\(currentWorkspace.map(String.init) ?? "none")")
                NSSound.beep()
                if let frame = focused.frame {
                    focusBorder.flashError(around: frame, windowID: focused.windowID, window: focused,
                                           message: "Won't fit on workspace \(number)")
                }
                return
            }
        case .parkForReveal:
            revalidation.park(focused.windowID, toWorkspace: number, screen: targetScreen,
                              sourceWorkspace: currentWorkspace, sourceScreen: screen)
        case .admit, .refuse:
            break
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

    /// The one bypassed attempt for a destination that is on screen.
    ///
    /// The window is laid out into the destination alongside its tenants
    /// before anything about the source is touched, so a refusal costs the
    /// user nothing: the rollback puts every incumbent back and the window
    /// back on `sourceScreen`, it keeps its place in the source tree and its
    /// floating flag, and the caller shows the ordinary rejection.
    ///
    /// `sourceScreen` is not decoration. A visible destination is always
    /// another screen, so the window is standing on `sourceScreen` when the
    /// attempt captures it, and a captured original outside the restoration
    /// rect cancels the whole rollback — the incumbents would keep the failed
    /// candidate's frames and the window would be left on a screen it is not
    /// assigned to, which the next poll reads as drift and acts on. The
    /// engine is told to reach both screens.
    ///
    /// - Returns: whether the screen accepted a layout holding `window`.
    private func revalidateVisibleDestination(_ window: HyprWindow, workspace: Int,
                                              screen: NSScreen, from sourceScreen: NSScreen) -> Bool {
        let all = allWindows()
        for w in all where stateCache.floatingWindowIDs.contains(w.windowID) { w.isFloating = true }
        let assigned = workspaceManager.windowIDs(onWorkspace: workspace)
        var windows = all.filter {
            assigned.contains($0.windowID) && $0.windowID != window.windowID && !$0.isFloating
        }
        // the live element if AX still knows it, so the attempt writes to the
        // same window the retile will
        let incoming = all.first { $0.windowID == window.windowID } ?? window
        let wasFloating = incoming.isFloating
        // the move is what makes it tiled; the flag goes back if this fails
        incoming.isFloating = false
        windows.append(incoming)

        let result = tilingEngine.revalidateAdmission(
            windows, incoming: [window.windowID], onWorkspace: workspace, screen: screen,
            restorationReach: displayManager.cgRect(for: sourceScreen))
        guard result.publishedIDs.contains(window.windowID) else {
            incoming.isFloating = wasFloating
            return false
        }
        return true
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

    // MARK: - batch move (layout restore)

    /// Batch form of `moveToWorkspace` for layout restore. Each window
    /// takes the same path — admission decided the same way, drop from
    /// the source tree, reassign, park or place — under one suppression
    /// window and one final retile, with none of the per-window focus,
    /// warp, beep, or error flash. Windows on disabled monitors are left
    /// alone; a window its destination refuses is skipped and logged.
    ///
    /// - Returns: how many windows actually moved.
    @discardableResult
    func moveWindows(_ moves: [(window: HyprWindow, workspace: Int)]) -> Int {
        guard !moves.isEmpty else { return 0 }
        suppressions.suppress("workspace-transition", for: 1.5)
        suppressions.suppress("activation-switch", for: 0.5)
        suppressions.suppress("mouse-focus", for: 0.15)
        tilingEngine.primeMinimumSizes(moves.map(\.window))

        var moved = 0
        for (window, number) in moves {
            guard let screen = displayManager.screen(for: window) ?? displayManager.screens.first,
                  !workspaceManager.isMonitorDisabled(screen) else { continue }
            let currentWorkspace = workspaceManager.workspaceFor(window.windowID)
            if currentWorkspace == number { continue }
            let isFloating = stateCache.floatingWindowIDs.contains(window.windowID)
            let targetScreen = workspaceManager.homeScreenForWorkspace(number) ?? screen
            let targetVisible = workspaceManager.screenForWorkspace(number) != nil

            if !isFloating {
                // same admission decision as moveToWorkspace, same
                // consequences: a hidden destination full by count or a
                // refusal no attempt can change skips the window; a
                // visible destination that refused on learned bounds alone
                // gets its one attempt now; a hidden one keeps a marker.
                if let reason = capacityRefusal(for: window, movingTo: number, on: targetScreen,
                                                targetVisible: targetVisible) {
                    hyprLog(.notice, .workspace, "moveWindows: \(window.windowID) → ws\(number) skipped: \(reason)")
                    continue
                }
                let outlook = tilingEngine.admissionOutlook(window, onWorkspace: number, screen: targetScreen)
                switch MinimaRevalidation.decide(outlook, destinationVisible: targetVisible) {
                case .refuse:
                    hyprLog(.notice, .workspace, "moveWindows: \(window.windowID) → ws\(number) skipped: won't fit")
                    continue
                case .revalidateHere:
                    guard revalidateVisibleDestination(window, workspace: number, screen: targetScreen,
                                                       from: screen) else {
                        hyprLog(.notice, .workspace, "moveWindows: \(window.windowID) → ws\(number) skipped: revalidation refused")
                        continue
                    }
                case .parkForReveal:
                    revalidation.park(window.windowID, toWorkspace: number, screen: targetScreen,
                                      sourceWorkspace: currentWorkspace, sourceScreen: screen)
                case .admit:
                    break
                }
            }

            if !isFloating, let cw = currentWorkspace {
                tilingEngine.removeWindow(window, fromWorkspace: cw)
            }
            workspaceManager.moveWindow(window.windowID, toWorkspace: number)
            if targetVisible {
                if isFloating { carryFloaterToScreen(window, targetScreen) }
            } else {
                if isFloating { workspaceManager.saveFloatingFrame(window) }
                workspaceManager.hideInCorner(window, on: targetScreen)
            }
            hyprLog(.debug, .workspace, "moveWindows: \(window.windowID) ws\(currentWorkspace.map(String.init) ?? "none") → ws\(number)")
            moved += 1
        }

        if moved > 0 {
            tileAllVisibleSpaces()
            NotificationCenter.default.post(name: .hyprMacWorkspaceChanged, object: nil)
        }
        return moved
    }

    /// The structural full-by-count check `moveToWorkspace` applies to a
    /// hidden destination, as the reason to log, or `nil` when the
    /// workspace has room. Occupancy counts the way admission does: a
    /// closed-but-alive ghost holds no slot, a minimized or Cmd-H'd
    /// window still does.
    private func capacityRefusal(for window: HyprWindow, movingTo number: Int, on targetScreen: NSScreen,
                                 targetVisible: Bool) -> String? {
        guard !targetVisible else { return nil }
        let excluded = ActionDispatcher.admissionExclusions(
            floatingWindowIDs: stateCache.floatingWindowIDs,
            hiddenWindowIDs: stateCache.hiddenWindowIDs,
            reservedHiddenWindowIDs: stateCache.reservedHiddenWindowIDs)
        let tiledCount = workspaceManager.windowIDs(onWorkspace: number).subtracting(excluded).count
        let maxWindows = RetileAllPlanner.workspaceCapacity(maxDepth: tilingEngine.maxDepth(for: targetScreen))
        return tiledCount >= maxWindows ? "workspace full (\(tiledCount)/\(maxWindows))" : nil
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
