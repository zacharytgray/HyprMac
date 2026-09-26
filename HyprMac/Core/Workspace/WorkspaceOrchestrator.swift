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
    var actualFocusedWindow: () -> HyprWindow? = { nil }
    var focusTransferredWindow: (HyprWindow) -> Void = { $0.focusWithoutRaise() }
    var warpToWindow: (HyprWindow) -> Void = { _ in }
    var transferRejected: ((HyprWindow, String) -> Void)?
    var updateFocusBorder: (HyprWindow) -> Void = { _ in }
    var updatePositionCache: () -> Void = { }
    var tileAllVisibleSpaces: () -> Void = { }
    /// Every window AX can see right now. A seam because the explicit
    /// revalidation attempt needs the destination's tenants, and a test has
    /// no desktop to read them off.
    var allWindows: () -> [HyprWindow] = { [] }
    var animatedRetile: (_ prepare: (() -> Void)?, _ completion: (() -> Void)?) -> Void = { _, _ in }
    /// Fired as soon as the destination workspace and its screen are known,
    /// before any AX read or write. The switch HUD hangs off this so it can
    /// paint while the main thread is still busy hiding and retiling — off
    /// `onDidSwitch` the panel could not reach the screen for most of a
    /// second. Same (workspace, screen) pair `onDidSwitch` will report.
    var onWillSwitch: (_ workspace: Int, _ screen: NSScreen) -> Void = { _, _ in }
    /// Fired once the switch has landed, with the windows moved and focus
    /// settled. State that has to reflect the finished switch lives here.
    var onDidSwitch: (_ workspace: Int, _ screen: NSScreen) -> Void = { _, _ in }
    var excludedBundleIDs: () -> Set<String> = { [] }
    var isScratchpadWindow: (CGWindowID) -> Bool = { _ in false }

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
        self.actualFocusedWindow = { [weak accessibility] in
            accessibility?.getActualFocusedStandardWindow()
        }
        self.warpToWindow = { [weak cursorManager] in cursorManager?.warpToCenter(of: $0) }
    }

    // MARK: - switch

    /// Move the actual AX-focused standard window to the next empty workspace
    /// owned by its physical display, switch there, and leave it as the sole
    /// tile. Destination geometry and source parking are verified before any
    /// workspace ownership changes.
    func moveToNextEmptyWorkspace() {
        guard let focused = actualFocusedWindow(),
              let cached = stateCache.cachedWindows[focused.windowID],
              cached.ownerPID == focused.ownerPID,
              CFEqual(cached.element, focused.element),
              !stateCache.hiddenWindowIDs.contains(focused.windowID),
              !isScratchpadWindow(focused.windowID),
              let sourceWorkspace = workspaceManager.workspaceFor(focused.windowID),
              sourceWorkspace != TilingEngine.scratchpadWorkspace,
              workspaceManager.isWorkspaceVisible(sourceWorkspace),
              let initialPhysicalScreen = displayManager.screen(for: focused),
              !workspaceManager.isMonitorDisabled(initialPhysicalScreen),
              focused.frame?.isSubstantiallyVisible(
                on: displayManager.cgRect(for: initialPhysicalScreen), threshold: 0.5) == true,
              let home = workspaceManager.homeScreenForWorkspace(sourceWorkspace),
              workspaceManager.screenID(for: home) == workspaceManager.screenID(for: initialPhysicalScreen),
              !focused.isFullscreen else {
            NSSound.beep()
            return
        }
        // The fresh AX object owns the authoritative element. Preserve the
        // model flags discovery had already assigned to the cached instance.
        focused.isFloating = stateCache.floatingWindowIDs.contains(focused.windowID)

        let sourceIDs = workspaceManager.windowIDs(onWorkspace: sourceWorkspace)
        // A dedicated workspace already containing only the focused window is
        // the desired end state. Repeated Hypr+F is therefore a no-op, even if
        // that sole window is currently floating.
        guard sourceIDs.count > 1 else { return }
        guard FloatingAdmissionPolicy.reason(
            isExcluded: focused.bundleID.map(excludedBundleIDs().contains) ?? false,
            isSizeSettable: focused.isSizeSettable
        ) == nil else {
            rejectTransfer(focused, message: "This window cannot be tiled")
            return
        }
        // a workspace with nothing on screen is empty, same as the menu bar:
        // closed-but-app-alive, minimized, and Cmd-H'd windows keep their
        // assignment but hold no slot here
        let hidden = { self.stateCache.hiddenWindowIDs }
        let destinationOccupants = { (workspace: Int) in
            self.workspaceManager.windowIDs(onWorkspace: workspace).subtracting(hidden())
        }
        guard let destination = workspaceManager.nextEmptyWorkspace(
            after: sourceWorkspace, on: initialPhysicalScreen, ignoring: hidden()
        ) else {
            rejectTransfer(focused, message: "No empty workspace on this display")
            return
        }

        let known = allWindows().reduce(into: [CGWindowID: HyprWindow]()) { $0[$1.windowID] = $1 }
        var sourceWindows: [HyprWindow] = []
        for id in sourceIDs where !stateCache.hiddenWindowIDs.contains(id) {
            guard let window = id == focused.windowID ? focused : (known[id] ?? stateCache.cachedWindows[id]),
                  window.frame != nil else {
                rejectTransfer(focused, message: "Could not verify workspace windows")
                return
            }
            sourceWindows.append(window)
        }

        let initialScreenID = workspaceManager.screenID(for: initialPhysicalScreen)
        let signature = displayManager.refreshedFingerprint()
        guard let physicalScreen = displayManager.screens.first(where: {
            workspaceManager.screenID(for: $0) == initialScreenID
        }), !workspaceManager.isMonitorDisabled(physicalScreen),
        workspaceManager.homeScreenForWorkspace(sourceWorkspace).map({
            workspaceManager.screenID(for: $0) == initialScreenID
        }) == true,
        workspaceManager.workspaceForScreen(physicalScreen) == sourceWorkspace,
        focused.frame?.isSubstantiallyVisible(
            on: displayManager.cgRect(for: physicalScreen), threshold: 0.5) == true else {
            rejectTransfer(focused, message: "Displays changed before the move")
            return
        }
        let wasFloating = stateCache.floatingWindowIDs.contains(focused.windowID)
        suppressions.suppress("workspace-transition", for: 1.5)
        suppressions.suppress("activation-switch", for: 0.5)
        suppressions.suppress("mouse-focus", for: 0.15)
        focused.isFloating = false
        let preparedResult = tilingEngine.prepareSoleWindowTransfer(
            focused, sourceWindows: sourceWindows, fromWorkspace: sourceWorkspace,
            toWorkspace: destination, screen: physicalScreen,
            restorationReach: displayManager.cgRect(for: physicalScreen))
        let prepared: TilingEngine.PreparedSoleWindowTransfer
        switch preparedResult {
        case .refusedRestored:
            focused.isFloating = wasFloating
            rejectTransfer(focused, message: "Could not apply the workspace layout")
            return
        case .degraded:
            focused.isFloating = wasFloating
            rejectTransfer(focused, message: "Could not safely restore the window")
            return
        case .prepared(let value):
            prepared = value
        }

        guard signature == displayManager.refreshedFingerprint() else {
            tilingEngine.markWorkspaceGeometryUnverified(
                sourceWorkspace, screen: physicalScreen, windowIDs: sourceIDs)
            focused.isFloating = wasFloating
            rejectTransfer(focused, message: "Displays changed during the move")
            return
        }
        guard destinationOccupants(destination).isEmpty,
              workspaceManager.homeScreenForWorkspace(destination).map({
                  workspaceManager.screenID(for: $0) == workspaceManager.screenID(for: physicalScreen)
              }) == true else {
            if case .degraded = tilingEngine.restorePreparedSoleWindowTransfer(prepared) {
                tilingEngine.markWorkspaceGeometryUnverified(
                    sourceWorkspace, screen: physicalScreen, windowIDs: sourceIDs)
            }
            focused.isFloating = wasFloating
            rejectTransfer(focused, message: "Displays changed during the move")
            return
        }

        let park = workspaceManager.hidePosition()
        let parked = sourceWindows.filter { $0.windowID != focused.windowID }
        if case .degraded = tilingEngine.parkPreparedSourceWindows(
            prepared, excluding: focused.windowID, at: park,
            displayFrames: displayManager.screens.map { displayManager.cgFullRect(for: $0) }) {
            let restoration = tilingEngine.restorePreparedSoleWindowTransfer(
                prepared)
            focused.isFloating = wasFloating
            let message: String
            switch restoration {
            case .restored: message = "Could not hide the current workspace"
            case .degraded:
                tilingEngine.markWorkspaceGeometryUnverified(
                    sourceWorkspace, screen: physicalScreen, windowIDs: sourceIDs)
                message = "Could not safely restore the workspace"
            }
            rejectTransfer(focused, message: message)
            return
        }

        guard signature == displayManager.refreshedFingerprint() else {
            tilingEngine.markWorkspaceGeometryUnverified(
                sourceWorkspace, screen: physicalScreen, windowIDs: sourceIDs)
            focused.isFloating = wasFloating
            rejectTransfer(focused, message: "Displays changed during the move")
            return
        }
        guard workspaceManager.workspaceFor(focused.windowID) == sourceWorkspace,
              workspaceManager.windowIDs(onWorkspace: sourceWorkspace) == sourceIDs,
              destinationOccupants(destination).isEmpty,
              workspaceManager.homeScreenForWorkspace(destination).map({
                  workspaceManager.screenID(for: $0) == initialScreenID
              }) == true,
              tilingEngine.commitPreparedSoleWindowTransfer(prepared) else {
            if case .degraded = tilingEngine.restorePreparedSoleWindowTransfer(prepared) {
                tilingEngine.markWorkspaceGeometryUnverified(
                    sourceWorkspace, screen: physicalScreen, windowIDs: sourceIDs)
            }
            focused.isFloating = wasFloating
            rejectTransfer(focused, message: "The workspace move was superseded")
            return
        }

        revalidation.cancel(focused.windowID, reason: "full workspace move")
        for window in parked where stateCache.floatingWindowIDs.contains(window.windowID) {
            if let original = tilingEngine.capturedFrame(for: window.windowID, in: prepared) {
                workspaceManager.setSavedFloatingFrame(original, for: window.windowID)
            }
        }
        tilingEngine.removeWindowMembershipOnly(focused, fromWorkspace: sourceWorkspace)
        stateCache.floatingWindowIDs.remove(focused.windowID)
        workspaceManager.clearSavedFloatingFrame(for: focused.windowID)
        if wasFloating, let original = tilingEngine.capturedFrame(for: focused.windowID, in: prepared) {
            stateCache.originalFrames[focused.windowID] = original
        }
        focused.isFloating = false
        workspaceManager.moveWindow(focused.windowID, toWorkspace: destination)
        _ = workspaceManager.switchWorkspace(destination, cursorScreen: physicalScreen)

        // earliest point the switch is certain here — every guard above can
        // still reject the move, and a rejected move must not flash the HUD.
        onWillSwitch(destination, physicalScreen)

        focusTransferredWindow(focused)
        warpToWindow(focused)
        focusController.recordFocus(focused.windowID, reason: "moveToNextEmptyWorkspace")
        stateCache.cachedWindows[focused.windowID] = focused
        updatePositionCache()
        updateFocusBorder(focused)
        NotificationCenter.default.post(name: .hyprMacWorkspaceChanged, object: nil)
        onDidSwitch(destination, physicalScreen)
    }

    private func rejectTransfer(_ window: HyprWindow, message: String) {
        if let transferRejected {
            transferRejected(window, message)
            return
        }
        NSSound.beep()
        if let frame = window.frame {
            focusBorder.flashError(around: frame, windowID: window.windowID,
                                   window: window, message: message)
        }
    }

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
    func switchWorkspace(_ number: Int, preferredWindowID: CGWindowID? = nil) {
        // hold polls off for the duration of the transition. Tahoe AX
        // writes lag, so a poll mid-transition reads stale frames and
        // drift detection can falsely reassign windows.
        suppressions.suppress("workspace-transition", for: 1.5)
        suppressions.suppress("activation-switch", for: 0.5)
        suppressions.suppress("mouse-focus", for: 0.15)

        let currentScreen = screenUnderCursor()

        // announce the switch before the AX sweep below. homeScreenForWorkspace
        // is a pure function of the workspace and the live screen layout, so
        // the destination screen is already settled here, and it is the same
        // screen every onDidSwitch below reports: the home screen when there
        // is one, the cursor's screen otherwise (bad workspace number, or no
        // enabled screens at all).
        //
        // this fires on the already-visible path too. pressing Hypr+3 while 3
        // is up is a no-op for windows but still flashes the HUD, the way it
        // always has — the flash is the answer to "which workspace am I on".
        onWillSwitch(number, workspaceManager.homeScreenForWorkspace(number) ?? currentScreen)

        let allWindows = accessibility.getAllWindows()
        let result = workspaceManager.switchWorkspace(number, cursorScreen: currentScreen)

        if result.alreadyVisible {
            // workspace is showing on result.screen — just focus it
            let visibleWindows = allWindows.filter { result.toShow.contains($0.windowID) }
            if let best = visibleWindows.first(where: { $0.windowID == preferredWindowID })
                ?? visibleWindows.first(where: { !stateCache.floatingWindowIDs.contains($0.windowID) })
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
            NotificationCenter.default.post(name: .hyprMacWorkspaceChanged, object: nil)
            onDidSwitch(number, result.screen)
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
        let preferred = newWorkspaceWindows.first { $0.windowID == preferredWindowID }
        let tiled = newWorkspaceWindows.first { !stateCache.floatingWindowIDs.contains($0.windowID) }
        if let best = preferred ?? tiled ?? newWorkspaceWindows.first {
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
        onDidSwitch(number, result.screen)
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

        // when coming from disabled monitor, unfloat so it enters tiling on
        // target. a quick look preview stays floating wherever it goes.
        let willTile = (onDisabledMonitor || !isFloating) && !focused.isQuickLookPanel

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
        if onDisabledMonitor && isFloating && !focused.isQuickLookPanel {
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
    /// attempt captures it. Without the reach the rollback leaves a newcomer
    /// from outside the restoration rect where the candidate put it — on a
    /// screen it is not assigned to, which the next poll reads as drift and
    /// acts on. The engine is told to reach both screens.
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

    /// What `moveWindows` did with each window it was asked to move. A
    /// window already on its destination appears in neither map.
    struct BatchMoveResult {
        enum Refusal: Equatable {
            /// the window stands on a disabled monitor; those are left alone
            case sourceMonitorDisabled
            /// the destination has no enabled home monitor
            case destinationMonitorDisabled
            /// workspace 0 belongs to the scratchpad; a batch never touches it
            case scratchpad
            /// the destination would end the batch over its tile count
            case full(tiled: Int, capacity: Int)
            /// the destination's projected tree has no slot for the arrivals
            case wontFit
            /// the destination is on screen and refused the verified layout
            case sizingRefused
        }

        /// window → the workspace it now belongs to
        var moved: [CGWindowID: Int] = [:]
        var refused: [CGWindowID: Refusal] = [:]

        var isComplete: Bool { refused.isEmpty }
    }

    private struct PlannedMove {
        let window: HyprWindow
        let source: Int?
        let destination: Int
        let tiled: Bool
        let sourceScreen: NSScreen
        let targetScreen: NSScreen
        let targetVisible: Bool
        var id: CGWindowID { window.windowID }
    }

    /// Batch form of `moveToWorkspace` for layout restore.
    ///
    /// Every destination is judged on the membership it will have once the
    /// whole batch lands — occupants, minus the windows leaving it, plus
    /// the ones arriving — so two full workspaces can trade windows.
    /// Occupancy counts the way admission does (a closed-but-alive ghost
    /// holds no slot, a minimized or Cmd-H'd window still does), and the
    /// fit uses the same outlook `moveToWorkspace` does: a refusal no
    /// attempt can change refuses, a visible destination refused on
    /// learned bounds alone gets its one attempt, a hidden one keeps a
    /// marker.
    ///
    /// Refusal is per destination: a workspace takes all of its arrivals
    /// or none. Which arrival to drop from an over-full workspace would be
    /// an arbitrary pick, and one stuck workspace should not hold back
    /// unrelated ones. A refused group keeps its windows where they are,
    /// which can overfill a workspace they were due to leave, so the check
    /// runs until nothing new is refused.
    ///
    /// Visible destinations are laid out and verified before any
    /// assignment changes. A refusal there refuses that group and the rest
    /// is settled again; a destination already laid out for a plan that
    /// has since shrunk is laid out again for what is left. Nothing is
    /// reassigned until every visible destination has accepted, so no
    /// window ends up half-moved or in two trees.
    ///
    /// Floaters never enter a tree and never count toward capacity; they
    /// move unless their own window is off limits. Windows on disabled
    /// monitors stay put. One suppression window, one final retile, no
    /// per-window focus, warp, beep, or flash.
    @discardableResult
    func moveWindows(_ moves: [(window: HyprWindow, workspace: Int)]) -> BatchMoveResult {
        var result = BatchMoveResult()
        guard !moves.isEmpty else { return result }
        suppressions.suppress("workspace-transition", for: 1.5)
        suppressions.suppress("activation-switch", for: 0.5)
        suppressions.suppress("mouse-focus", for: 0.15)
        tilingEngine.primeMinimumSizes(moves.map(\.window))

        var plans: [PlannedMove] = []
        var seen: Set<CGWindowID> = []
        for (window, number) in moves where seen.insert(window.windowID).inserted {
            let id = window.windowID
            let source = workspaceManager.workspaceFor(id)
            if source == number { continue }
            if number == TilingEngine.scratchpadWorkspace || source == TilingEngine.scratchpadWorkspace
                || isScratchpadWindow(id) {
                result.refused[id] = .scratchpad
                continue
            }
            // a parked window stands on no screen, which is not a disabled one
            let physical = displayManager.screen(for: window)
            if let physical, workspaceManager.isMonitorDisabled(physical) {
                result.refused[id] = .sourceMonitorDisabled
                continue
            }
            guard let targetScreen = workspaceManager.homeScreenForWorkspace(number),
                  !workspaceManager.isMonitorDisabled(targetScreen) else {
                result.refused[id] = .destinationMonitorDisabled
                continue
            }
            plans.append(PlannedMove(
                window: window, source: source, destination: number,
                tiled: !stateCache.floatingWindowIDs.contains(id),
                sourceScreen: physical ?? source.flatMap(workspaceManager.homeScreenForWorkspace) ?? targetScreen,
                targetScreen: targetScreen,
                targetVisible: workspaceManager.screenForWorkspace(number) != nil))
        }

        // the windows a retile would lay out, plus the batch's own
        var known: [CGWindowID: HyprWindow] = [:]
        for window in allWindows() {
            if stateCache.floatingWindowIDs.contains(window.windowID) { window.isFloating = true }
            known[window.windowID] = window
        }
        for plan in plans { known[plan.id] = plan.window }

        var refusedGroups: [Int: BatchMoveResult.Refusal] = [:]
        // visible destinations this batch has republished, with what they now hold
        var laidOut: [Int: (screen: NSScreen, ids: Set<CGWindowID>)] = [:]
        // arrivals some layout pulled onto a visible screen
        var attempted: Set<CGWindowID> = []
        var accepted: [PlannedMove] = []
        var outlooks: [Int: TilingEngine.AdmissionOutlook] = [:]
        while true {
            (accepted, outlooks) = settleBatch(plans, refusing: &refusedGroups, known: known)
            guard let failed = layOutVisibleDestinations(accepted, outlooks: outlooks, known: known,
                                                         laidOut: &laidOut, attempted: &attempted) else { break }
            refusedGroups[failed] = .sizingRefused
        }

        for plan in accepted {
            revalidation.cancel(plan.id, reason: "moved again")
            if plan.tiled, let source = plan.source {
                // membership only: the one retile below lays the source out
                tilingEngine.removeWindowMembershipOnly(plan.window, fromWorkspace: source)
            }
            workspaceManager.moveWindow(plan.id, toWorkspace: plan.destination)
            if plan.targetVisible {
                // tiled arrivals already hold their verified slot
                if !plan.tiled { carryFloaterToScreen(plan.window, plan.targetScreen) }
            } else {
                if !plan.tiled { workspaceManager.saveFloatingFrame(plan.window) }
                workspaceManager.hideInCorner(plan.window, on: plan.targetScreen)
                if plan.tiled, case .revalidatable = outlooks[plan.destination] {
                    revalidation.park(plan.id, toWorkspace: plan.destination, screen: plan.targetScreen,
                                      sourceWorkspace: plan.source, sourceScreen: plan.sourceScreen)
                }
            }
            hyprLog(.debug, .workspace, "moveWindows: \(plan.id) ws\(plan.source.map(String.init) ?? "none") → ws\(plan.destination)")
            result.moved[plan.id] = plan.destination
        }

        for plan in plans where result.moved[plan.id] == nil {
            guard let reason = refusedGroups[plan.destination] else { continue }
            result.refused[plan.id] = reason
            // a refused layout's rollback may not have put it back in the corner
            if attempted.contains(plan.id), let source = plan.source,
               !workspaceManager.isWorkspaceVisible(source) {
                workspaceManager.hideInCorner(plan.window, on: plan.sourceScreen)
            }
        }
        for (id, reason) in result.refused.sorted(by: { $0.key < $1.key }) {
            hyprLog(.notice, .workspace, "moveWindows: \(id) skipped: \(reason)")
        }

        if !result.moved.isEmpty || !laidOut.isEmpty {
            tileAllVisibleSpaces()
        }
        if !result.moved.isEmpty {
            NotificationCenter.default.post(name: .hyprMacWorkspaceChanged, object: nil)
        }
        return result
    }

    /// Refuse destination groups until every remaining destination fits
    /// its projected membership. Returns the moves still standing and the
    /// outlook of each destination they tile into.
    private func settleBatch(_ plans: [PlannedMove],
                             refusing refused: inout [Int: BatchMoveResult.Refusal],
                             known: [CGWindowID: HyprWindow])
        -> ([PlannedMove], [Int: TilingEngine.AdmissionOutlook]) {
        while true {
            let accepted = plans.filter { !$0.tiled || refused[$0.destination] == nil }
            var outlooks: [Int: TilingEngine.AdmissionOutlook] = [:]
            var changed = false
            for workspace in Set(accepted.filter(\.tiled).map(\.destination)).sorted() {
                let screen = accepted.first { $0.destination == workspace }!.targetScreen
                let ids = projectedTiledIDs(workspace, accepted)
                let capacity = RetileAllPlanner.workspaceCapacity(maxDepth: tilingEngine.maxDepth(for: screen))
                if ids.count > capacity {
                    refused[workspace] = .full(tiled: ids.count, capacity: capacity)
                    changed = true
                    continue
                }
                let arriving = Set(accepted.filter { $0.tiled && $0.destination == workspace }.map(\.id))
                let outlook = tilingEngine.projectedAdmissionOutlook(
                    ids.sorted().compactMap { known[$0] }, incoming: arriving,
                    onWorkspace: workspace, screen: screen)
                if case .refused = outlook {
                    refused[workspace] = .wontFit
                    changed = true
                    continue
                }
                outlooks[workspace] = outlook
            }
            if !changed { return (accepted, outlooks) }
        }
    }

    /// What `workspace` tiles once `accepted` lands, counted the way
    /// admission counts: a closed-but-alive ghost holds no slot, a
    /// minimized or Cmd-H'd window still does.
    private func projectedTiledIDs(_ workspace: Int, _ accepted: [PlannedMove]) -> Set<CGWindowID> {
        let excluded = ActionDispatcher.admissionExclusions(
            floatingWindowIDs: stateCache.floatingWindowIDs,
            hiddenWindowIDs: stateCache.hiddenWindowIDs,
            reservedHiddenWindowIDs: stateCache.reservedHiddenWindowIDs)
        let leaving = Set(accepted.filter { $0.source == workspace }.map(\.id))
        let arriving = Set(accepted.filter { $0.tiled && $0.destination == workspace }.map(\.id))
        return workspaceManager.windowIDs(onWorkspace: workspace)
            .subtracting(excluded).subtracting(leaving).union(arriving)
    }

    /// Lay every visible destination out for its projected membership
    /// before any assignment changes. Also lays out again any destination
    /// an earlier round republished whose plan has since changed, which is
    /// how a refused group's arrivals leave a screen they were tried on.
    ///
    /// - Returns: the first destination that refused its arrivals, or nil
    ///   when every one accepted.
    private func layOutVisibleDestinations(_ accepted: [PlannedMove],
                                           outlooks: [Int: TilingEngine.AdmissionOutlook],
                                           known: [CGWindowID: HyprWindow],
                                           laidOut: inout [Int: (screen: NSScreen, ids: Set<CGWindowID>)],
                                           attempted: inout Set<CGWindowID>) -> Int? {
        var screens: [Int: NSScreen] = laidOut.mapValues(\.screen)
        for plan in accepted where plan.tiled && plan.targetVisible {
            screens[plan.destination] = plan.targetScreen
        }
        for (workspace, screen) in screens.sorted(by: { $0.key < $1.key }) {
            let ids = projectedTiledIDs(workspace, accepted)
            if laidOut[workspace]?.ids == ids { continue }
            let arrivals = accepted.filter { $0.tiled && $0.destination == workspace }
            let arriving = Set(arrivals.map(\.id))
            let windows = ids.sorted().compactMap { known[$0] }
            // the rollback has to reach back to wherever the arrivals stand
            let reach = arrivals.map { displayManager.cgRect(for: $0.sourceScreen) }.reduce(nil) {
                (union: CGRect?, rect: CGRect) in union.map { $0.union(rect) } ?? rect
            }
            attempted.formUnion(arriving)
            let layout: TilingEngine.AdmissionResult
            if case .revalidatable = outlooks[workspace] {
                layout = tilingEngine.revalidateAdmission(windows, incoming: arriving, onWorkspace: workspace,
                                                          screen: screen, restorationReach: reach)
            } else {
                layout = tilingEngine.tileWindows(windows, onWorkspace: workspace, screen: screen,
                                                  alsoRestoringWithin: reach)
            }
            if layout.published && arriving.isSubset(of: layout.publishedIDs) {
                laidOut[workspace] = (screen, ids)
                continue
            }
            if arriving.isEmpty {
                // putting a destination back refused. an earlier round's
                // arrival would stay in this tree while it stays assigned
                // elsewhere, so drop it by membership; the final retile
                // lays out what is left
                hyprLog(.notice, .workspace, "moveWindows: ws\(workspace) relayout refused"
                        + " \(layout.failure.map { "\($0)" } ?? "")")
                let strays = tilingEngine.existingTree(forWorkspace: workspace, screen: screen)?
                    .allWindows.filter { !ids.contains($0.windowID) } ?? []
                for window in strays {
                    tilingEngine.removeWindowMembershipOnly(window, fromWorkspace: workspace)
                }
                laidOut[workspace] = (screen, ids)
                continue
            }
            hyprLog(.notice, .workspace, "moveWindows: ws\(workspace) refused its arrivals"
                    + " [\(arriving.sorted().map(String.init).joined(separator: ", "))]"
                    + " \(layout.failure.map { "\($0)" } ?? "no slot")")
            // the refused candidate may have been published in part, or a
            // parked arrival left where the candidate put it while the rest
            // were rolled back. record what was tried so the next round lays
            // the destination out again without these arrivals
            laidOut[workspace] = (screen, ids)
            return workspace
        }
        return nil
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
