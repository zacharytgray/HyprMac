import Cocoa
import Combine

class WindowManager {
    let accessibility = AccessibilityManager()
    let hotkeyManager = HotkeyManager()
    let spaceManager = SpaceManager()
    let displayManager = DisplayManager()
    let cursorManager = CursorManager()
    let appLauncher = AppLauncherManager()
    let config: UserConfig
    let animator = WindowAnimator()
    let focusBorder = FocusBorder()
    let dimmingOverlay = DimmingOverlay()
    let mouseTracker = MouseTrackingManager()
    let dragManager = DragManager()
    let keybindOverlay = KeybindOverlayController()

    private(set) var workspaceManager: WorkspaceManager!
    private(set) var tilingEngine: TilingEngine!

    // window-keyed state cache. owns all seven lifecycle/classification dicts:
    // knownWindowIDs, floatingWindowIDs, originalFrames, windowOwners, hiddenWindowIDs,
    // tiledPositions, cachedWindows.
    let stateCache = WindowStateCache()

    // canonical focus state. owns lastFocusedID; passes through borderTrackedID
    // from FocusBorder. constructed in init() since it depends on focusBorder.
    let focusController: FocusStateController

    // window discovery (poll-cycle diff). owns its half of cache mutations
    // and surfaces the rest as a WindowChanges struct that this class applies.
    private var discovery: WindowDiscoveryService!

    // floating-window lifecycle: float/tile toggle, cycle-focus, raise-behind, auto-float predicate.
    private(set) var floatingController: FloatingWindowController!

    // drag-result application — DragManager classifies, this handler applies.
    private var dragSwapHandler: DragSwapHandler!

    // Action → service routing. dispatch(_:) replaces the handleAction switch.
    private var actionDispatcher: ActionDispatcher!

    // workspace switch / move / move-to-monitor workflows.
    // delegates to workspaceManager + tilingEngine; no new policy lives there.
    private var workspaceOrchestrator: WorkspaceOrchestrator!

    // periodic discovery timer + coalesced notification-driven polls.
    // constructed in init() so the closure can capture self weakly.
    private var pollingScheduler: PollingScheduler!

    // mouse tracking
    private var mouseMoveMonitor: Any?
    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?
    private var mouseDragMonitor: Any?
    private var mouseButtonDown = false
    private var mouseDraggedSinceDown = false
    private var mouseDownTiledFrames: [CGWindowID: CGRect] = [:]
    private var mouseDownFloatingWindowID: CGWindowID = 0

    // window whose focus border was hidden when a drag started — re-shown on mouseUp.
    // we hide rather than try to follow, because we'd need 60Hz AX polling per window
    // and that's prohibitively expensive.
    private var preDragFocusedID: CGWindowID = 0

    // date-gated suppression flags. owned here, shared with subsystems via closures.
    // keys in use: "activation-switch" (gates appDidActivate workspace switch),
    // "mouse-focus" (will migrate from MouseTrackingManager in a follow-up commit).
    let suppressions = SuppressionRegistry()

    // live config reload
    private var configObservers: Set<AnyCancellable> = []
    private var isRunning = false

    init(config: UserConfig) {
        self.config = config
        self.focusController = FocusStateController(focusBorder: focusBorder)
        self.workspaceManager = WorkspaceManager(displayManager: displayManager)
        self.tilingEngine = TilingEngine(displayManager: displayManager)
        self.discovery = WindowDiscoveryService(
            stateCache: stateCache,
            accessibility: accessibility,
            displayManager: displayManager,
            workspaceManager: workspaceManager
        )
        self.floatingController = FloatingWindowController(
            stateCache: stateCache,
            suppressions: suppressions,
            workspaceManager: workspaceManager,
            tilingEngine: tilingEngine,
            displayManager: displayManager,
            accessibility: accessibility,
            cursorManager: cursorManager,
            focusController: focusController,
            focusBorder: focusBorder,
            dimmingOverlay: dimmingOverlay
        )
        self.workspaceOrchestrator = WorkspaceOrchestrator(
            workspaceManager: workspaceManager,
            tilingEngine: tilingEngine,
            accessibility: accessibility,
            displayManager: displayManager,
            cursorManager: cursorManager,
            stateCache: stateCache,
            focusController: focusController,
            focusBorder: focusBorder,
            dimmingOverlay: dimmingOverlay,
            suppressions: suppressions
        )
        self.workspaceOrchestrator.screenUnderCursor = { [weak self] in self?.screenUnderCursor() ?? NSScreen.main! }
        self.workspaceOrchestrator.currentFocusedWindow = { [weak self] in self?.currentFocusedWindow() }
        self.workspaceOrchestrator.updateFocusBorder = { [weak self] w in self?.updateFocusBorder(for: w) }
        self.workspaceOrchestrator.tileAllVisibleSpaces = { [weak self] in self?.tileAllVisibleSpaces() }
        self.workspaceOrchestrator.animatedRetile = { [weak self] prepare, completion in
            self?.animatedRetile(prepare: prepare, completion: completion)
        }
        self.pollingScheduler = PollingScheduler { [weak self] in
            self?.pollWindowChanges()
        }
        // hold polling off while a cross-monitor drag-swap is in flight (Phase 4 step 5).
        // DragSwapHandler.applySwap registers the "cross-swap-in-flight" key for ~800ms;
        // both the 1Hz timer and notification-driven schedule() calls drop until it expires.
        pollingScheduler.isSuppressed = { [weak self] in
            self?.suppressions.isSuppressed("cross-swap-in-flight") ?? false
        }

        hotkeyManager.onAction = { [weak self] action in
            self?.suppressions.suppress("mouse-focus", for: 0.3)
            self?.handleAction(action)
        }

        hotkeyManager.onHyprKeyDown = { [weak self] in
            self?.ensureFocus()
        }
        hotkeyManager.onHyprKeyUp = { [weak self] in
            self?.reassertFocusBorderAfterHyprRelease()
        }

        // wire up mouse tracker dependencies
        mouseTracker.isFocusFollowsMouseEnabled = { [weak self] in self?.config.focusFollowsMouse ?? false }
        mouseTracker.isMouseButtonDown = { [weak self] in self?.mouseButtonDown ?? false }
        mouseTracker.isAnimating = { [weak self] in self?.animator.isAnimating ?? false }
        mouseTracker.primaryScreenHeight = { [weak self] in self?.displayManager.primaryScreenHeight ?? 0 }
        mouseTracker.screenAt = { [weak self] pt in self?.displayManager.screen(at: pt) }
        mouseTracker.floatingWindowIDs = { [weak self] in self?.stateCache.floatingWindowIDs ?? [] }
        mouseTracker.isWindowVisible = { [weak self] wid in self?.workspaceManager.isWindowVisible(wid) ?? false }
        mouseTracker.cachedWindow = { [weak self] wid in self?.stateCache.cachedWindows[wid] }
        mouseTracker.tiledPositions = { [weak self] in self?.stateCache.tiledPositions ?? [:] }
        mouseTracker.onFocusForFFM = { [weak self] w in self?.focusForFFM(w) }
        mouseTracker.onUpdateFocusBorder = { [weak self] w in self?.updateFocusBorder(for: w) }
        mouseTracker.isMouseFocusSuppressed = { [weak self] in self?.suppressions.isSuppressed("mouse-focus") ?? false }
        mouseTracker.lastFocusedID = { [weak self] in self?.focusController.lastFocusedID ?? 0 }
        mouseTracker.recordFocus = { [weak self] id, reason in self?.focusController.recordFocus(id, reason: reason) }
        mouseTracker.onHideFocusBorder = { [weak self] in
            self?.focusBorder.hide()
            self?.dimmingOverlay.hideAll()
        }

        // wire up floating controller — closure handles for WM-side helpers.
        floatingController.animatedRetile = { [weak self] prepare in
            self?.animatedRetile(prepare: prepare)
        }
        floatingController.updateFocusBorder = { [weak self] w in self?.updateFocusBorder(for: w) }
        floatingController.updatePositionCache = { [weak self] in self?.updatePositionCache() }
        floatingController.isMenuTracking = { [weak self] in self?.mouseTracker.menuTracking ?? false }

        // drag-result handler
        self.dragSwapHandler = DragSwapHandler(
            stateCache: stateCache,
            dragManager: dragManager,
            accessibility: accessibility,
            displayManager: displayManager,
            workspaceManager: workspaceManager,
            tilingEngine: tilingEngine,
            animator: animator,
            config: config,
            suppressions: suppressions
        )
        dragSwapHandler.updatePositionCache = { [weak self] windows in self?.updatePositionCache(windows: windows) }
        dragSwapHandler.tileAllVisibleSpaces = { [weak self] windows in self?.tileAllVisibleSpaces(windows: windows) }

        // action dispatcher — owns the per-Action routing previously in handleAction.
        self.actionDispatcher = ActionDispatcher(
            stateCache: stateCache,
            accessibility: accessibility,
            displayManager: displayManager,
            cursorManager: cursorManager,
            workspaceManager: workspaceManager,
            tilingEngine: tilingEngine,
            animator: animator,
            focusController: focusController,
            focusBorder: focusBorder,
            keybindOverlay: keybindOverlay,
            appLauncher: appLauncher,
            workspaceOrchestrator: workspaceOrchestrator,
            floatingController: floatingController,
            config: config
        )
        actionDispatcher.currentFocusedWindow = { [weak self] in self?.currentFocusedWindow() }
        actionDispatcher.updateFocusBorder = { [weak self] w in self?.updateFocusBorder(for: w) }
        actionDispatcher.updatePositionCache = { [weak self] in self?.updatePositionCache() }
        actionDispatcher.screenUnderCursor = { [weak self] in self?.screenUnderCursor() ?? NSScreen.main! }
        actionDispatcher.applyForgottenIDCleanup = { [weak self] id in self?.applyForgottenIDExternalCleanup(id) }
        actionDispatcher.animatedRetile = { [weak self] windows in self?.animatedRetile(windows: windows) }
        actionDispatcher.refocusUnderCursor = { [weak self] in self?.mouseTracker.refocusUnderCursor() }
        actionDispatcher.isMenuTracking = { [weak self] in self?.mouseTracker.menuTracking ?? false }
        // DragSwapHandler shares the dispatcher's swap-rejection flash so cross-monitor and
        // direction swaps both surface the same red-border + beep feedback.
        dragSwapHandler.rejectSwap = { [weak self] window, reason in self?.actionDispatcher.rejectSwap(window, reason: reason) }

        tilingEngine.onAutoFloat = { [weak self] window in
            guard let self = self else { return }
            window.isFloating = true
            self.stateCache.floatingWindowIDs.insert(window.windowID)
            if let original = self.stateCache.originalFrames[window.windowID] {
                window.setFrame(original)
            }
            hyprLog(.debug, .lifecycle, "auto-floated '\(window.title ?? "?")' — screen full")
        }

        // react to enabled toggling (including mid-flight config rewrites from iCloud sync)
        config.$enabled
            .dropFirst() // skip initial value — start() handles that
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self = self else { return }
                if enabled && !self.isRunning {
                    hyprLog(.debug, .lifecycle, "config re-enabled, starting")
                    self.start()
                } else if !enabled && self.isRunning {
                    hyprLog(.debug, .lifecycle, "config disabled, stopping")
                    self.stop()
                }
            }.store(in: &configObservers)

        config.$hyprKey
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] key in
                KeyRemapper.applyHyprKey(key)
                self?.hotkeyManager.updateHyprKey(key)
            }.store(in: &configObservers)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        tilingEngine.gapSize = config.gapSize
        tilingEngine.outerPadding = config.outerPadding
        tilingEngine.maxSplitsPerMonitor = config.maxSplitsPerMonitor
        focusBorder.primaryScreenHeight = displayManager.primaryScreenHeight
        workspaceManager.disabledMonitors = config.disabledMonitors
        hotkeyManager.updateHyprKey(config.hyprKey)
        hotkeyManager.updateKeybinds(config.keybinds)
        hotkeyManager.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.isRunning else { return }
            self.spaceManager.setup()
            self.workspaceManager.initializeMonitors()
            self.snapshotAndTile()
            // start polling only after the initial tile so pollWindowChanges can't
            // race against snapshotAndTile, claim all windows as new, and trigger
            // an animation that blocks the correct initial distribution
            self.pollingScheduler.start()
        }

        startMouseTracking()

        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(self, selector: #selector(appDidActivate(_:)),
                         name: NSWorkspace.didActivateApplicationNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(appDidLaunch(_:)),
                         name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(appDidTerminate(_:)),
                         name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(appVisibilityChanged(_:)),
                         name: NSWorkspace.didHideApplicationNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(appVisibilityChanged(_:)),
                         name: NSWorkspace.didUnhideApplicationNotification, object: nil)

        // suppress FFM while any app's menu bar is active
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(menuTrackingBegan),
            name: NSNotification.Name("com.apple.HIToolbox.beginMenuTrackingNotification"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(menuTrackingEnded),
            name: NSNotification.Name("com.apple.HIToolbox.endMenuTrackingNotification"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self, selector: #selector(retileAllRequested),
            name: .hyprMacRetileAll, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        // reload keybinds when config changes (no retile, just update hotkey table)
        config.$keybinds.sink { [weak self] newBinds in
            guard let self = self else { return }
            self.hotkeyManager.updateKeybinds(newBinds)
            hyprLog(.debug, .lifecycle, "keybinds reloaded (\(newBinds.count) binds)")
        }.store(in: &configObservers)

        config.$gapSize
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newGap in
                guard let self = self else { return }
                self.tilingEngine.gapSize = newGap
                self.animatedRetile()
            }.store(in: &configObservers)

        config.$outerPadding
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newPadding in
                guard let self = self else { return }
                self.tilingEngine.outerPadding = newPadding
                self.animatedRetile()
            }.store(in: &configObservers)

        config.$maxSplitsPerMonitor
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newSplits in
                guard let self = self else { return }
                self.tilingEngine.maxSplitsPerMonitor = newSplits
                self.snapshotAndTile()
                hyprLog(.debug, .lifecycle, "max splits updated: \(newSplits)")
            }.store(in: &configObservers)

        config.$disabledMonitors
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newDisabled in
                guard let self = self else { return }
                self.workspaceManager.disabledMonitors = newDisabled
                // unfloat windows on newly-disabled monitors from their tiling trees
                self.handleDisabledMonitorChange()
                hyprLog(.debug, .lifecycle, "disabled monitors updated: \(newDisabled)")
            }.store(in: &configObservers)

        config.$dimInactiveWindows
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self = self else { return }
                if !enabled {
                    self.dimmingOverlay.enabled = false
                    self.dimmingOverlay.hideAll()
                } else {
                    self.refreshDimming()
                }
            }.store(in: &configObservers)

        config.$dimIntensity
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refreshDimming()
            }.store(in: &configObservers)

        config.$showFocusBorder
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.updatePositionCache()
                } else {
                    self.focusBorder.hide()
                    self.focusBorder.hideFloatingBorders()
                    self.dimmingOverlay.hideAll()
                }
            }.store(in: &configObservers)

        config.$floatingBorderColorHex
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updatePositionCache()
            }.store(in: &configObservers)

        hyprLog(.debug, .lifecycle, "started")
    }

    func stop() {
        restoreAllWindows()
        isRunning = false
        pollingScheduler.stop()
        stopMouseTracking()
        hotkeyManager.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        focusBorder.hide()
        focusBorder.hideFloatingBorders()
        dimmingOverlay.hideAll()
        hyprLog(.debug, .lifecycle, "stopped")
    }

    // bring all hidden workspace windows back on-screen so they're not stranded
    // in corners after quit or disable
    private func restoreAllWindows() {
        let allWindows = accessibility.getAllWindows()
        let mainScreen = displayManager.screens.first
        let screenRect = mainScreen.map { displayManager.cgRect(for: $0) }
            ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // unhide windows on invisible workspaces
        for (wid, ws) in workspaceManager.allWindowWorkspaces() {
            guard !workspaceManager.isWorkspaceVisible(ws) else { continue }
            guard let window = allWindows.first(where: { $0.windowID == wid }) else { continue }

            if let original = stateCache.originalFrames[wid] {
                window.setFrame(original)
                hyprLog(.debug, .lifecycle, "restored '\(window.title ?? "?")' to original frame")
            } else {
                // cascade onto main screen
                let x = screenRect.origin.x + 50
                let y = screenRect.origin.y + 50
                let w = min(screenRect.width * 0.6, 1200)
                let h = min(screenRect.height * 0.6, 800)
                window.setFrame(CGRect(x: x, y: y, width: w, height: h))
                hyprLog(.debug, .lifecycle, "restored '\(window.title ?? "?")' to main screen")
            }
        }

        hyprLog(.debug, .lifecycle, "all windows restored to visible positions")
    }

    @objc private func menuTrackingBegan(_ note: Notification) {
        mouseTracker.menuTrackingBegan()
    }

    @objc private func menuTrackingEnded(_ note: Notification) {
        mouseTracker.menuTrackingEnded()
    }

    func restart() {
        stop()
        start()
    }

    // MARK: - mouse tracking

    private func startMouseTracking() {
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.mouseTracker.handleMouseMove()
        }
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self else { return }
            self.mouseButtonDown = true
            self.mouseDraggedSinceDown = false
            self.captureMouseDownFrames()
            // sync our focus tracker with the click — without this, manual clicks
            // leave focusController.lastFocusedID stale and currentFocusedWindow() routes
            // commands to whatever was previously hovered, not what the user clicked
            self.syncFocusTrackerToCursor()
        }
        // when the user drags a floating window, its frame changes 60Hz but our
        // border only repositions on poll (1Hz) — so it lags behind ugly. hide
        // the border for the duration of the drag and restore it on mouseUp.
        mouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            guard let self = self else { return }
            self.mouseDraggedSinceDown = true
            if self.mouseDownFloatingWindowID != 0 {
                self.focusBorder.hideFloatingBorder(for: self.mouseDownFloatingWindowID)
            }
            guard self.preDragFocusedID == 0 else { return }
            guard let tid = self.focusBorder.trackedWindowID else { return }
            // only hide for floating windows — tiled windows can't be free-dragged
            guard self.stateCache.floatingWindowIDs.contains(tid) else { return }
            self.preDragFocusedID = tid
            self.focusBorder.hide(); self.dimmingOverlay.hideAll()
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            let shouldDetectDrag = self?.mouseDraggedSinceDown ?? false
            let startFrames = self?.mouseDownTiledFrames ?? [:]
            let draggedFloatingID = self?.mouseDownFloatingWindowID ?? 0
            self?.mouseButtonDown = false
            self?.mouseDraggedSinceDown = false
            self?.mouseDownTiledFrames.removeAll()
            self?.mouseDownFloatingWindowID = 0
            if shouldDetectDrag {
                self?.handleMouseUp(startFrames: startFrames)
            }
            if draggedFloatingID != 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                    self?.updatePositionCache()
                }
            }
            // restore the focus border on whatever floating window we hid it for,
            // after a brief settle delay so we read its final position
            if let id = self?.preDragFocusedID, id != 0 {
                self?.preDragFocusedID = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    guard let self = self, let w = self.stateCache.cachedWindows[id] else { return }
                    self.updateFocusBorder(for: w)
                    self.refreshFloatingBorders()
                }
            }
        }
    }

    private func stopMouseTracking() {
        if let m = mouseMoveMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseDownMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseDragMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m) }
        mouseMoveMonitor = nil
        mouseDownMonitor = nil
        mouseDragMonitor = nil
        mouseUpMonitor = nil
        mouseDownTiledFrames.removeAll()
        mouseDownFloatingWindowID = 0
    }

    private func focusForFFM(_ window: HyprWindow) {
        suppressions.suppress("activation-switch", for: 0.5)
        window.focusWithoutRaise()
        updateFocusBorder(for: window)
    }

    private func updateFocusBorder(for window: HyprWindow) {
        guard config.showFocusBorder else {
            focusBorder.hide()
            focusBorder.hideFloatingBorders()
            dimmingOverlay.hideAll()
            return
        }
        guard let frame = window.frame else {
            focusBorder.hide()
            dimmingOverlay.hideAll()
            return
        }
        focusBorder.accentCGColor = stateCache.floatingWindowIDs.contains(window.windowID)
            ? config.resolvedFloatingBorderColor.cgColor
            : config.resolvedFocusBorderColor.cgColor
        focusBorder.show(around: frame, windowID: window.windowID)
        if stateCache.floatingWindowIDs.contains(window.windowID) {
            refreshFloatingBorders(windows: accessibility.getAllWindows())
        } else {
            refreshFloatingBorders()
        }
        refreshDimming(focusedID: window.windowID)
    }

    private func reassertFocusBorderAfterHyprRelease() {
        guard config.showFocusBorder else { return }
        refreshFloatingBorders(windows: accessibility.getAllWindows())

        guard let tid = focusBorder.trackedWindowID,
              stateCache.floatingWindowIDs.contains(tid) else { return }

        func reassert() {
            let windows = accessibility.getAllWindows()
            if let window = windows.first(where: { $0.windowID == tid }) ?? stateCache.cachedWindows[tid] {
                window.isFloating = true
                stateCache.cachedWindows[tid] = window
                updateFocusBorder(for: window)
                refreshFloatingBorders(windows: windows)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            reassert()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            reassert()
        }
    }

    // recompute the dim mask from current tiled positions. called on focus
    // change and after any tile update so the shape stays accurate when
    // windows move, resize, or a workspace switch changes what's visible.
    private func refreshDimming(focusedID: CGWindowID? = nil) {
        dimmingOverlay.enabled = config.dimInactiveWindows
        dimmingOverlay.setIntensity(CGFloat(config.dimIntensity))
        dimmingOverlay.primaryScreenHeight = displayManager.primaryScreenHeight
        let fid = focusedID ?? focusBorder.trackedWindowID ?? focusController.lastFocusedID
        dimmingOverlay.update(
            focusedID: fid,
            tiledRects: currentTiledRects(),
            floatingRects: floatingFrames(from: Array(stateCache.cachedWindows.values), expandedBy: 8),
            screens: displayManager.screens
        )
    }

    // re-read tile frames from live AX before dim/border computations.
    // stateCache.tiledPositions only refreshes on poll/retile (1Hz timer +
    // activation/launch notifications). between those events a window can
    // resize or move — app self-resize, AX min-size kick-in, manual drag,
    // pass-2 layout responding to a constraint — and the cache stays stale.
    // without this re-read, refreshDimming triggered by FFM/click during the
    // gap computes the cutout against the old rect, leaving the new rect
    // partly bright and partly covered by stale dim ("half-dim" artifact).
    // cost is one AX query per visible tile, bounded by the visible-window
    // count, only paid on focus change / retile / poll completion.
    private func currentTiledRects() -> [CGWindowID: CGRect] {
        var rects: [CGWindowID: CGRect] = [:]
        for id in stateCache.tiledPositions.keys {
            if let w = stateCache.cachedWindows[id], let live = w.frame ?? w.cachedFrame {
                rects[id] = live
            } else if let fallback = stateCache.tiledPositions[id] {
                rects[id] = fallback
            }
        }
        return rects
    }

    // recapture focus on bare hypr keydown — the visible border is the source
    // of truth for intent, as long as that window belongs to the cursor's
    // current workspace. fallbacks are only for stale/missing border state.
    private func ensureFocus() {
        suppressions.suppress("mouse-focus", for: 0.3)

        let screen = screenUnderCursor()
        let workspace = workspaceManager.workspaceForScreen(screen)
        let wsWindows = workspaceManager.windowIDs(onWorkspace: workspace)

        if let tid = focusBorder.trackedWindowID,
           isSelectableInCurrentContext(tid, workspaceWindows: wsWindows),
           let w = stateCache.cachedWindows[tid] {
            w.focusWithoutRaise()
            focusController.recordFocus(tid, reason: "ensureFocus-trackedID")
            updateFocusBorder(for: w)
            return
        }

        if focusController.lastFocusedID != 0,
           isSelectableInCurrentContext(focusController.lastFocusedID, workspaceWindows: wsWindows),
           let w = stateCache.cachedWindows[focusController.lastFocusedID] {
            w.focusWithoutRaise()
            updateFocusBorder(for: w)
            return
        }

        // convert mouse to CG coords
        let mouseNS = NSEvent.mouseLocation
        let cgY = displayManager.primaryScreenHeight - mouseNS.y
        let cgPoint = CGPoint(x: mouseNS.x, y: cgY)

        // floating windows are visually above tiled windows
        for wid in stateCache.floatingWindowIDs where wsWindows.contains(wid) {
            guard let w = stateCache.cachedWindows[wid], let frame = w.frame else { continue }
            if frame.contains(cgPoint) {
                w.focusWithoutRaise()
                focusController.recordFocus(wid, reason: "ensureFocus-floating")
                updateFocusBorder(for: w)
                return
            }
        }

        // tiled window under cursor
        for (wid, rect) in stateCache.tiledPositions {
            if wsWindows.contains(wid), rect.contains(cgPoint),
               let w = stateCache.cachedWindows[wid] {
                w.focusWithoutRaise()
                focusController.recordFocus(wid, reason: "ensureFocus-tiled")
                updateFocusBorder(for: w)
                return
            }
        }

        // whatever AX says is focused, if it is on this workspace
        if let focused = accessibility.getFocusedWindow(),
           isSelectableInCurrentContext(focused.windowID, workspaceWindows: wsWindows) {
            focusController.recordFocus(focused.windowID, reason: "ensureFocus-ax")
            updateFocusBorder(for: focused)
            return
        }

        // deterministic fallback: nearest tiled window center on this workspace
        let fallback = stateCache.tiledPositions
            .filter { wsWindows.contains($0.key) }
            .min { lhs, rhs in
                let lhsCenter = CGPoint(x: lhs.value.midX, y: lhs.value.midY)
                let rhsCenter = CGPoint(x: rhs.value.midX, y: rhs.value.midY)
                return distanceSquared(lhsCenter, cgPoint) < distanceSquared(rhsCenter, cgPoint)
            }
        if let (wid, _) = fallback, let w = stateCache.cachedWindows[wid] {
            w.focusWithoutRaise()
            focusController.recordFocus(wid, reason: "ensureFocus-fallback")
            updateFocusBorder(for: w)
        }
    }

    private func handleMouseUp(startFrames: [CGWindowID: CGRect]) {
        dragSwapHandler.handleMouseUp(startFrames: startFrames)
    }

    // MARK: - action dispatch

    private func handleAction(_ action: Action) {
        actionDispatcher.dispatch(action)
    }

    // cursor-based screen lookup. shared with WorkspaceOrchestrator and ActionDispatcher
    // via closure handles. focused-window-based detection is unreliable post-switch
    // (focused window can still belong to the previous screen).
    private func screenUnderCursor() -> NSScreen {
        let mouseNS = NSEvent.mouseLocation
        let cgY = displayManager.primaryScreenHeight - mouseNS.y
        return displayManager.screen(at: CGPoint(x: mouseNS.x, y: cgY))
            ?? displayManager.screens.first
            ?? NSScreen.main!
    }

    // MARK: - floating

    // public accessors for menu bar indicator
    var hasVisibleFloatingWindows: Bool {
        stateCache.floatingWindowIDs.contains { workspaceManager.isWindowVisible($0) }
    }

    func occupiedWorkspaces() -> Set<Int> {
        var result = Set<Int>()
        for ws in 1...9 {
            // exclude hidden windows (minimized/closed but app still running)
            let live = workspaceManager.windowIDs(onWorkspace: ws).subtracting(stateCache.hiddenWindowIDs)
            if !live.isEmpty {
                result.insert(ws)
            }
        }
        return result
    }

    func activeWorkspaces() -> [Int] {
        displayManager.screens
            .filter { !workspaceManager.isMonitorDisabled($0) }
            .map { workspaceManager.workspaceForScreen($0) }
    }

    // MARK: - disabled monitor handling

    // called when disabledMonitors config changes at runtime
    private func handleDisabledMonitorChange() {
        let allWindows = accessibility.getAllWindows()

        // windows on newly-disabled monitors: remove from workspace + auto-float
        for screen in displayManager.screens where workspaceManager.isMonitorDisabled(screen) {
            for w in allWindows {
                guard let wScreen = displayManager.screen(for: w),
                      wScreen == screen else { continue }
                if let ws = workspaceManager.workspaceFor(w.windowID) {
                    tilingEngine.removeWindow(w, fromWorkspace: ws)
                    workspaceManager.removeWindow(w.windowID)
                }
                if !stateCache.floatingWindowIDs.contains(w.windowID) {
                    stateCache.floatingWindowIDs.insert(w.windowID)
                    w.isFloating = true
                    hyprLog(.debug, .lifecycle, "disabled monitor change: floated '\(w.title ?? "?")'")
                }
            }
        }

        // windows on re-enabled monitors: unfloat and let snapshotAndTile pick them up
        for screen in displayManager.screens where !workspaceManager.isMonitorDisabled(screen) {
            for w in allWindows {
                guard let wScreen = displayManager.screen(for: w),
                      wScreen == screen else { continue }
                // only unfloat if it was auto-floated (no workspace assignment = was on disabled monitor)
                if stateCache.floatingWindowIDs.contains(w.windowID) && workspaceManager.workspaceFor(w.windowID) == nil {
                    stateCache.floatingWindowIDs.remove(w.windowID)
                    w.isFloating = false
                    hyprLog(.debug, .lifecycle, "re-enabled monitor: unfloated '\(w.title ?? "?")'")
                }
            }
        }

        workspaceManager.initializeMonitors()
        snapshotAndTile()
    }

    // MARK: - tiling

    func snapshotAndTile() {
        let allWindows = accessibility.getAllWindows()
        tilingEngine.primeMinimumSizes(allWindows)
        for w in allWindows {
            if let frame = w.frame, stateCache.originalFrames[w.windowID] == nil {
                // only save if the frame is actually visible on some screen.
                // after a restart, windows may still be at the previous session's hide corner.
                let onScreen = displayManager.screens.contains { screen in
                    isFrameVisible(frame, on: displayManager.cgRect(for: screen))
                }
                if onScreen {
                    stateCache.originalFrames[w.windowID] = frame
                }
            }
            stateCache.knownWindowIDs.insert(w.windowID)
            stateCache.windowOwners[w.windowID] = w.ownerPID

            // auto-float excluded apps
            if floatingController.shouldAutoFloat(w, excludedBundleIDs: Set(config.excludedBundleIDs))
                && !stateCache.floatingWindowIDs.contains(w.windowID) {
                stateCache.floatingWindowIDs.insert(w.windowID)
                w.isFloating = true
                hyprLog(.debug, .lifecycle, "auto-float excluded app: '\(w.title ?? "?")'")
            }

            // auto-float windows on disabled monitors — don't assign workspace
            if let screen = displayManager.screen(for: w), workspaceManager.isMonitorDisabled(screen) {
                if !stateCache.floatingWindowIDs.contains(w.windowID) {
                    stateCache.floatingWindowIDs.insert(w.windowID)
                    w.isFloating = true
                    hyprLog(.debug, .lifecycle, "auto-float on disabled monitor: '\(w.title ?? "?")'")
                }
                continue
            }

            assignToScreenWorkspace(w)
        }
        distributeWindowsAcrossWorkspaces()
        tileAllVisibleSpaces()
    }

    func tileAllVisibleSpaces(windows: [HyprWindow]? = nil) {
        guard !animator.isAnimating else { return }
        let allWindows = windows ?? accessibility.getAllWindows()
        tilingEngine.primeMinimumSizes(allWindows)

        for w in allWindows {
            if stateCache.floatingWindowIDs.contains(w.windowID) {
                w.isFloating = true
            }
        }

        // for each enabled monitor, tile the windows that belong to its active workspace
        for screen in displayManager.screens {
            if workspaceManager.isMonitorDisabled(screen) { continue }
            let workspace = workspaceManager.workspaceForScreen(screen)
            let widsOnWorkspace = workspaceManager.windowIDs(onWorkspace: workspace)

            var workspaceWindows: [HyprWindow] = []
            for window in allWindows {
                if widsOnWorkspace.contains(window.windowID) {
                    workspaceWindows.append(window)
                }
            }

            hyprLog(.debug, .lifecycle, "retile: workspace=\(workspace) screen=\(workspaceManager.screenID(for: screen)), \(workspaceWindows.count) windows")
            tilingEngine.tileWindows(workspaceWindows, onWorkspace: workspace, screen: screen)
        }

        updatePositionCache(windows: allWindows)
    }

    // animated retile — captures before-frames, runs prepare(), computes new layout,
    // then animates existing windows sliding from old → new positions.
    // only animates the surrounding windows — no fade/scale on the window that triggered the change.
    private func animatedRetile(
        windows: [HyprWindow]? = nil,
        prepare: (() -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard config.animateWindows, !animator.isAnimating else {
            prepare?()
            tileAllVisibleSpaces(windows: windows)
            completion?()
            return
        }

        let allWindows = windows ?? accessibility.getAllWindows()
        tilingEngine.primeMinimumSizes(allWindows)

        // capture before-frames for visible tiled windows
        var beforeFrames: [CGWindowID: CGRect] = [:]
        for w in allWindows {
            guard workspaceManager.isWindowVisible(w.windowID),
                  !stateCache.floatingWindowIDs.contains(w.windowID),
                  let f = w.frame else { continue }
            beforeFrames[w.windowID] = f
        }

        // run state changes (e.g. remove from tree, toggle float)
        prepare?()

        // re-fetch after prepare() — window list may have changed (add/remove/float toggle).
        // only re-fetch if prepare actually ran; otherwise reuse existing list.
        let refreshedWindows = prepare != nil ? accessibility.getAllWindows() : allWindows
        tilingEngine.primeMinimumSizes(refreshedWindows)

        // compute new layout for each screen without applying
        var newLayouts: [(HyprWindow, CGRect)] = []

        // mark floating flags on refreshed window objects
        for w in refreshedWindows {
            if stateCache.floatingWindowIDs.contains(w.windowID) { w.isFloating = true }
        }
        for screen in displayManager.screens {
            if workspaceManager.isMonitorDisabled(screen) { continue }
            let workspace = workspaceManager.workspaceForScreen(screen)
            let widsOnWorkspace = workspaceManager.windowIDs(onWorkspace: workspace)

            var workspaceWindows: [HyprWindow] = []
            for window in refreshedWindows {
                if widsOnWorkspace.contains(window.windowID) {
                    workspaceWindows.append(window)
                }
            }

            let layouts = tilingEngine.prepareTileLayout(workspaceWindows, onWorkspace: workspace, screen: screen)
            newLayouts.append(contentsOf: layouts)
        }

        // build slide transitions for windows that moved
        var transitions: [WindowAnimator.FrameTransition] = []
        for (w, toRect) in newLayouts {
            if let fromRect = beforeFrames[w.windowID], fromRect != toRect {
                transitions.append(.init(window: w, from: fromRect, to: toRect))
            }
        }

        guard !transitions.isEmpty else {
            tileAllVisibleSpaces(windows: refreshedWindows)
            completion?()
            return
        }

        animator.animate(transitions, duration: config.animationDuration) { [weak self] in
            guard let self else { return }
            // apply final layout with two-pass min-size resolution
            for screen in self.displayManager.screens {
                if self.workspaceManager.isMonitorDisabled(screen) { continue }
                let workspace = self.workspaceManager.workspaceForScreen(screen)
                self.tilingEngine.applyComputedLayout(onWorkspace: workspace, screen: screen)
            }
            self.updatePositionCache()
            completion?()
        }
    }

    // distribute tiling windows across workspaces, spilling into next workspace when full.
    // each workspace is tied to one screen. fills visible workspaces first (left-to-right),
    // then spillover workspaces cycle through screens.
    private func distributeWindowsAcrossWorkspaces() {
        let screens = displayManager.screens.filter { !workspaceManager.isMonitorDisabled($0) }
            .sorted { $0.frame.origin.x < $1.frame.origin.x }
        guard !screens.isEmpty else { return }

        let allWindows = accessibility.getAllWindows()
        let focusedID = accessibility.getFocusedWindow()?.windowID
        let allWids = Set(allWindows.map { $0.windowID })

        // full redistribution: un-float everything except excluded apps and
        // non-standard windows (dialogs, sheets, floating panels).
        let excluded = Set(config.excludedBundleIDs)
        let keepFloating = Set(allWindows.filter { floatingController.shouldAutoFloat($0, excludedBundleIDs: excluded) }.map { $0.windowID })
        for wid in stateCache.floatingWindowIDs where !keepFloating.contains(wid) && allWids.contains(wid) {
            stateCache.floatingWindowIDs.remove(wid)
            if let w = allWindows.first(where: { $0.windowID == wid }) {
                w.isFloating = false
            }
        }

        // gather all tiling window IDs (from visible workspaces + unassigned)
        var tilingWids: [CGWindowID] = []
        for screen in screens {
            let ws = workspaceManager.workspaceForScreen(screen)
            for wid in workspaceManager.windowIDs(onWorkspace: ws) where !stateCache.floatingWindowIDs.contains(wid) {
                tilingWids.append(wid)
            }
        }
        for w in allWindows where !stateCache.floatingWindowIDs.contains(w.windowID) {
            if !tilingWids.contains(w.windowID) {
                tilingWids.append(w.windowID)
            }
        }

        guard !tilingWids.isEmpty else { return }

        // focused window first so it lands on the first visible workspace
        if let fid = focusedID, let idx = tilingWids.firstIndex(of: fid), idx != 0 {
            tilingWids.swapAt(0, idx)
        }

        // build ordered (workspace, screen) slots.
        // visible workspaces first (left-to-right), then spillover cycling screens.
        var slots: [(ws: Int, screen: NSScreen)] = []
        var usedWs = Set<Int>()

        for screen in screens {
            let ws = workspaceManager.workspaceForScreen(screen)
            slots.append((ws, screen))
            usedWs.insert(ws)
        }

        var spillScreenIdx = 0
        for ws in 1...workspaceManager.workspaceCount where !usedWs.contains(ws) {
            let screen = screens[spillScreenIdx % screens.count]
            slots.append((ws, screen))
            workspaceManager.setHomeScreen(for: ws, screenID: workspaceManager.screenID(for: screen))
            spillScreenIdx += 1
        }

        // fill slots in order — each slot = one workspace on one screen
        var widIdx = 0
        var slotsUsed = 0
        for slot in slots {
            guard widIdx < tilingWids.count else { break }
            let cap = tilingEngine.maxDepth(for: slot.screen) + 1 // dwindle depth, no backtracking on distribute
            for _ in 0..<cap where widIdx < tilingWids.count {
                workspaceManager.assignWindow(tilingWids[widIdx], toWorkspace: slot.ws)
                widIdx += 1
            }
            slotsUsed += 1
        }

        // any remaining (all 9 workspaces full) — auto-float
        while widIdx < tilingWids.count {
            let wid = tilingWids[widIdx]
            stateCache.floatingWindowIDs.insert(wid)
            if let w = allWindows.first(where: { $0.windowID == wid }) {
                w.isFloating = true
                if let original = stateCache.originalFrames[wid] { w.setFrame(original) }
                hyprLog(.debug, .lifecycle, "all workspaces full — auto-floating '\(w.title ?? "?")'")
            }
            widIdx += 1
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

        hyprLog(.debug, .lifecycle, "distributed \(tilingWids.count) windows across \(slotsUsed) slot(s), \(screens.count) monitor(s)")
    }

    // find a window by ID — checks live list first, falls back to cache
    private func findWindow(_ wid: CGWindowID, in allWindows: [HyprWindow]) -> HyprWindow? {
        allWindows.first { $0.windowID == wid } ?? stateCache.cachedWindows[wid]
    }

    // assign window to the active workspace on its physical screen (for startup/snapshot)
    private func assignToScreenWorkspace(_ window: HyprWindow) {
        guard workspaceManager.workspaceFor(window.windowID) == nil else { return }
        if let screen = displayManager.screen(for: window) ?? displayManager.screens.first {
            let ws = workspaceManager.workspaceForScreen(screen)
            workspaceManager.assignWindow(window.windowID, toWorkspace: ws)
        }
    }

    // returns the window the user actually intends to control. AX's notion of
    // "focused window" can lag or flat-out diverge from reality for multi-window
    // apps (Finder, Teams) — focusWithoutRaise (used by FFM and Hypr+Arrow) does
    // not reliably update kAXFocusedWindowAttribute. our own focusController.lastFocusedID
    // tracker is updated on every focus action *and* on manual clicks, so it
    // stays in sync with what the user actually pointed at last.
    private func currentFocusedWindow() -> HyprWindow? {
        let workspace = workspaceManager.workspaceForScreen(screenUnderCursor())
        let wsWindows = workspaceManager.windowIDs(onWorkspace: workspace)

        if let tid = focusBorder.trackedWindowID,
           isSelectableInCurrentContext(tid, workspaceWindows: wsWindows),
           let w = stateCache.cachedWindows[tid] {
            return w
        }

        if focusController.lastFocusedID != 0,
           isSelectableInCurrentContext(focusController.lastFocusedID, workspaceWindows: wsWindows),
           let w = stateCache.cachedWindows[focusController.lastFocusedID] {
            return w
        }

        if let focused = accessibility.getFocusedWindow(),
           isSelectableInCurrentContext(focused.windowID, workspaceWindows: wsWindows) {
            return focused
        }

        return nil
    }

    private func isSelectableInCurrentContext(_ windowID: CGWindowID, workspaceWindows: Set<CGWindowID>) -> Bool {
        if workspaceWindows.contains(windowID) { return true }
        return stateCache.floatingWindowIDs.contains(windowID) && workspaceManager.isWindowVisible(windowID)
    }

    // hit-test the cursor against tiled and floating windows, update tracker.
    // called from leftMouseDown so a manual click immediately wins over any
    // stale FFM tracker state.
    private func captureMouseDownFrames() {
        mouseDownTiledFrames.removeAll()
        mouseDownFloatingWindowID = 0

        let mouseNS = NSEvent.mouseLocation
        let cgY = displayManager.primaryScreenHeight - mouseNS.y
        let cgPoint = CGPoint(x: mouseNS.x, y: cgY)

        for w in accessibility.getAllWindows() {
            guard workspaceManager.isWindowVisible(w.windowID),
                  let frame = w.frame else { continue }
            if stateCache.floatingWindowIDs.contains(w.windowID) {
                if mouseDownFloatingWindowID == 0, frame.contains(cgPoint) {
                    mouseDownFloatingWindowID = w.windowID
                }
                continue
            }
            mouseDownTiledFrames[w.windowID] = frame
        }
    }

    private func syncFocusTrackerToCursor() {
        let mouseNS = NSEvent.mouseLocation
        let cgY = displayManager.primaryScreenHeight - mouseNS.y
        let cgPoint = CGPoint(x: mouseNS.x, y: cgY)

        // floating windows take precedence (drawn on top)
        for wid in stateCache.floatingWindowIDs {
            guard workspaceManager.isWindowVisible(wid),
                  let w = stateCache.cachedWindows[wid], let frame = w.frame else { continue }
            if frame.contains(cgPoint) {
                focusController.recordFocus(wid, reason: "syncTracker-floating")
                return
            }
        }
        for (wid, rect) in stateCache.tiledPositions where rect.contains(cgPoint) {
            focusController.recordFocus(wid, reason: "syncTracker-tiled")
            return
        }
    }

    // central per-window cleanup — prune every dict that keys on windowID.
    // safe to call on already-forgotten IDs (idempotent).
    private func forgetWindow(_ id: CGWindowID) {
        stateCache.forget(id)
        applyForgottenIDExternalCleanup(id)
    }

    // run the engine/workspace/focus cleanup half of forgetting an id. used
    // both by forgetWindow (one-shot) and by the discovery apply-loop, where
    // the service has already cleared cache state for a batch of ids.
    private func applyForgottenIDExternalCleanup(_ id: CGWindowID) {
        tilingEngine.forgetMinimumSize(windowID: id)
        workspaceManager.removeWindow(id)
        if focusController.lastFocusedID == id {
            focusController.recordFocus(0, reason: "forgetWindow")
        }
        if focusBorder.trackedWindowID == id {
            focusBorder.hide(); dimmingOverlay.hideAll()
        }
        focusBorder.hideFloatingBorder(for: id)
    }

    // forget every window we knew about for a given pid. handles the case where
    // an app terminates while some of its windows are hidden/minimized — those
    // ids would otherwise leak in hiddenWindowIDs/windowOwners/etc forever.
    private func forgetApp(_ pid: pid_t) {
        let ids = discovery.forgetApp(pid)
        for id in ids { applyForgottenIDExternalCleanup(id) }
    }


    // check if at least 25% of the frame is visible on the given screen rect
    private func isFrameVisible(_ frame: CGRect, on screenRect: CGRect) -> Bool {
        let overlap = frame.intersection(screenRect)
        guard !overlap.isNull else { return false }
        let overlapArea = overlap.width * overlap.height
        let frameArea = frame.width * frame.height
        guard frameArea > 0 else { return false }
        return overlapArea / frameArea > 0.25
    }

    private func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }

    private func floatingFrames(from source: [HyprWindow], expandedBy padding: CGFloat = 0) -> [CGWindowID: CGRect] {
        var frames: [CGWindowID: CGRect] = [:]
        for w in source {
            guard stateCache.floatingWindowIDs.contains(w.windowID),
                  workspaceManager.isWindowVisible(w.windowID),
                  let frame = w.frame ?? w.cachedFrame else { continue }
            frames[w.windowID] = padding == 0 ? frame : frame.insetBy(dx: -padding, dy: -padding)
        }
        return frames
    }

    private func updatePositionCache(windows: [HyprWindow]? = nil) {
        let allWindows = windows ?? accessibility.getAllWindows()
        tilingEngine.primeMinimumSizes(allWindows)
        stateCache.tiledPositions.removeAll()
        stateCache.cachedWindows.removeAll()
        for w in allWindows {
            guard workspaceManager.isWindowVisible(w.windowID) else { continue }
            stateCache.cachedWindows[w.windowID] = w
            guard let frame = w.cachedFrame ?? w.frame else { continue }
            if stateCache.floatingWindowIDs.contains(w.windowID) {
                continue
            } else {
                stateCache.tiledPositions[w.windowID] = frame
            }
        }
        refreshFloatingBorders(windows: allWindows)
        updateMenuBarState()

        // keep focus border tracking window position (retile, resize, etc.)
        if let tid = focusBorder.trackedWindowID, let w = stateCache.cachedWindows[tid], let frame = w.frame {
            focusBorder.updatePosition(frame)
            refreshFloatingBorders(windows: allWindows)
        }
        refreshDimming()
    }

    private func refreshFloatingBorders(windows: [HyprWindow]? = nil) {
        if config.showFocusBorder {
            let source = windows ?? Array(stateCache.cachedWindows.values)
            let frames = floatingFrames(from: source)
            focusBorder.updateFloatingBorders(
                frames,
                color: config.resolvedFloatingBorderColor.cgColor
            )
            refreshBorderOcclusion(floaterFrames: frames)
        } else {
            focusBorder.hideFloatingBorders()
        }
    }

    // compute per-border occluders (rects of higher-z tracked windows that
    // overlap the bordered window) and push them into FocusBorder so the
    // border layer is masked to the bordered window's visible region.
    // z-order via CGWindowListCopyWindowInfo (front-to-back).
    private func refreshBorderOcclusion(floaterFrames: [CGWindowID: CGRect]) {
        guard config.showFocusBorder else { return }
        guard let info = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID) as? [[String: Any]] else { return }

        var zIndex: [CGWindowID: Int] = [:]
        for (i, dict) in info.enumerated() {
            guard let num = dict[kCGWindowNumber as String] as? Int else { continue }
            zIndex[CGWindowID(num)] = i
        }

        var trackedRects: [CGWindowID: CGRect] = [:]
        // live tile frames — same staleness rationale as refreshDimming
        for (id, rect) in currentTiledRects() { trackedRects[id] = rect }
        for (id, rect) in floaterFrames { trackedRects[id] = rect }

        let focusedID = focusBorder.trackedWindowID ?? 0
        var focusedOccluders: [CGRect] = []
        if focusedID != 0,
           let focusedRect = trackedRects[focusedID],
           let focusedZ = zIndex[focusedID] {
            for (id, rect) in trackedRects where id != focusedID {
                guard let z = zIndex[id], z < focusedZ else { continue }
                if rect.intersects(focusedRect) { focusedOccluders.append(rect) }
            }
        }

        var floaterOccluders: [CGWindowID: [CGRect]] = [:]
        for (fid, frect) in floaterFrames {
            guard let fz = zIndex[fid] else { continue }
            var list: [CGRect] = []
            for (id, rect) in trackedRects where id != fid {
                guard let z = zIndex[id], z < fz else { continue }
                if rect.intersects(frect) { list.append(rect) }
            }
            if !list.isEmpty { floaterOccluders[fid] = list }
        }

        focusBorder.applyOcclusion(
            focusedOccluders: focusedOccluders,
            floaterOccluders: floaterOccluders)
    }

    private func updateMenuBarState() {
        let active = Set(activeWorkspaces())
        let occupied = occupiedWorkspaces()
        let floatingWs = workspacesWithFloatingWindows()
        let maxWs = max(active.max() ?? 1, occupied.max() ?? 1)

        // dots: ● active, ◆ active+floating, ○ occupied, ◇ occupied+floating, · empty
        var parts: [String] = []
        for i in 1...maxWs {
            let hasFloat = floatingWs.contains(i)
            if active.contains(i) {
                parts.append(hasFloat ? "◆" : "●")
            } else if occupied.contains(i) {
                parts.append(hasFloat ? "◇" : "○")
            } else {
                parts.append("·")
            }
        }
        let text = parts.joined(separator: " ")

        DispatchQueue.main.async {
            let state = MenuBarState.shared
            state.labelText = text
            state.occupiedWorkspaces = occupied
            state.floatingWorkspaces = floatingWs
            state.hasData = true
        }
    }

    private func workspacesWithFloatingWindows() -> Set<Int> {
        var result = Set<Int>()
        // only count live (non-hidden) floating windows
        let liveFloating = stateCache.floatingWindowIDs.subtracting(stateCache.hiddenWindowIDs)
        for ws in 1...9 {
            let wsWindows = workspaceManager.windowIDs(onWorkspace: ws)
            if !wsWindows.isDisjoint(with: liveFloating) {
                result.insert(ws)
            }
        }
        return result
    }

    // MARK: - poll

    // run a discovery diff and hand the result to the dispatcher's apply-loop.
    // mouse-button-down + animation-in-flight guards stay here because they're
    // about whether to poll AT ALL; the apply-loop itself runs unconditionally
    // once it's invoked.
    private func pollWindowChanges() {
        guard !animator.isAnimating else { return }
        guard !mouseButtonDown else { return }

        let allWindows = accessibility.getAllWindows()
        tilingEngine.primeMinimumSizes(allWindows)
        let runningPIDs = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })

        let changes = discovery.computeChanges(
            snapshot: allWindows,
            runningPIDs: runningPIDs,
            excludedBundleIDs: Set(config.excludedBundleIDs),
            focusedWindowID: focusController.lastFocusedID,
            animationInProgress: false
        )
        actionDispatcher.applyChanges(changes, allWindows: allWindows)
    }

    // MARK: - observers

    @objc private func appDidActivate(_ notification: Notification) {
        // suppress FFM while dock popups (downloads, stacks) are open
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            mouseTracker.dockIsActive = (app.bundleIdentifier == "com.apple.dock")
        }

        // dock-click workspace switch — only when NOT suppressed by FFM/switch/raise
        if !suppressions.isSuppressed("activation-switch") {
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                let pid = app.processIdentifier
                let visibleWorkspaces = Set(workspaceManager.monitorWorkspace.values)

                // only consider windows still tracked (not hidden/closed)
                let appWindows = stateCache.windowOwners
                    .filter { $0.value == pid && stateCache.knownWindowIDs.contains($0.key) && !stateCache.hiddenWindowIDs.contains($0.key) }

                let appWorkspaces = appWindows.compactMap { (wid, _) in workspaceManager.workspaceFor(wid) }
                let hasVisibleWindow = appWorkspaces.contains { visibleWorkspaces.contains($0) }

                if !hasVisibleWindow {
                    if let targetWS = appWorkspaces.filter({ !visibleWorkspaces.contains($0) }).min() {
                        workspaceOrchestrator.switchWorkspace(targetWS)
                        return
                    }
                }
            }
        }

        pollingScheduler.schedule()

        // re-raise floating windows after any app activation (e.g. user clicked a tiled window).
        // must always run — even when activation switch is suppressed — so floaters stay on top.
        if !stateCache.floatingWindowIDs.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.floatingController.raiseBehind()
            }
        }
    }


    @objc private func appDidLaunch(_ notification: Notification) {
        pollingScheduler.schedule(after: 0.5)
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        // proactively prune state for the dead pid — without this, hidden/minimized
        // windows owned by the app would leak in windowOwners/hiddenWindowIDs/etc
        // (they're not in knownWindowIDs anymore so the gone-detect path skips them).
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            forgetApp(app.processIdentifier)
        }
        pollingScheduler.schedule()
    }

    @objc private func appVisibilityChanged(_ notification: Notification) {
        pollingScheduler.schedule(after: 0.3)
    }

    @objc private func screenParametersChanged() {
        hyprLog(.debug, .lifecycle, "screen parameters changed — reinitializing workspaces")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.focusBorder.primaryScreenHeight = self.displayManager.primaryScreenHeight
            // ordering: DisplayManager.refresh runs automatically via the same
            // notification; WorkspaceManager.initializeMonitors must run before
            // TilingEngine.handleDisplayChange so the home-screen lookup is
            // current. see plan §4.2.
            self.workspaceManager.initializeMonitors()
            self.tilingEngine.handleDisplayChange(
                currentScreens: self.displayManager.screens,
                homeScreenForWorkspace: { [weak self] ws in
                    self?.workspaceManager.homeScreenForWorkspace(ws)
                }
            )
            self.snapshotAndTile()
        }
    }

    @objc private func retileAllRequested() {
        hyprLog(.debug, .lifecycle, "retile all spaces requested")
        snapshotAndTile()
    }
}
