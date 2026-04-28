// Central orchestrator. Wires every subsystem together, owns the long-lived
// references, and routes hotkey actions and discovery results to the services
// that handle them. No tiling, focus, workspace, or floating policy lives here
// directly — this class is the seam that holds them in one place.

import Cocoa
import Combine

/// Long-lived orchestrator that owns every subsystem and routes work between them.
///
/// Lifecycle is bracketed by ``start()`` and ``stop()``. Between those calls
/// `WindowManager` keeps its services live, registers global mouse and workspace
/// observers, and runs a periodic discovery poll that drives tiling and focus
/// updates. Construction wires the dependency graph; everything past `init` is
/// orchestration glue.
///
/// Threading: all methods run on the main thread. Mouse and Workspace observers
/// fire on the main run loop; the polling scheduler dispatches its callback there.
/// Subordinate services assume the same.
///
/// Ownership: this class holds the only strong reference to most subsystems.
/// Window-keyed lifecycle state lives in ``stateCache``; canonical focus state
/// in ``focusController``; date-gated suppression flags in ``suppressions``.
/// Closure handles plumb local helpers (e.g. `screenUnderCursor`,
/// `currentFocusedWindow`, `updateFocusBorder`) into services that need them
/// without giving those services a back-reference to this class.
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

    /// Wire the dependency graph and configure every subsystem callback.
    ///
    /// Construction is in three layers:
    /// 1. Build sub-managers that take only static dependencies.
    /// 2. Build the orchestration layer (`floatingController`,
    ///    `workspaceOrchestrator`, `pollingScheduler`, `dragSwapHandler`,
    ///    `actionDispatcher`) and attach the closure handles each one
    ///    needs from `WindowManager`-local helpers.
    /// 3. Subscribe to `UserConfig` `@Published` properties so runtime
    ///    config changes flow through to the right subsystem.
    ///
    /// Nothing observable starts running here — `start()` does the
    /// activation. `init` is safe to run before AX permission is granted.
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

    /// Bring the window manager up: install the hotkey tap, mouse monitors,
    /// workspace observers, and start the polling scheduler.
    ///
    /// Idempotent — repeated calls while running are no-ops. Initial tile is
    /// deferred by one second so AX has time to enumerate windows before the
    /// snapshot runs, and the polling scheduler is started only after the
    /// initial tile so its discovery diff cannot race the snapshot and claim
    /// every window as new.
    ///
    /// Side effects: subscribes to `NSWorkspace` activation/launch/terminate
    /// notifications, the `HIToolbox` menu-tracking notifications, screen
    /// parameter changes, and every relevant `@Published` property on the
    /// shared `UserConfig`.
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

    /// Tear down everything `start()` brought up.
    ///
    /// Restores hidden workspace windows to visible positions before
    /// detaching observers — without this, windows would remain stranded in
    /// the hide-corner sliver after the app quits or is toggled off. Stops
    /// the polling scheduler, removes mouse monitors, halts the hotkey tap,
    /// and hides every focus indicator. Safe to call when not running.
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

    /// Restore every window assigned to a non-visible workspace to a sane
    /// on-screen position. Called from `stop()` so workspace hiding does not
    /// leak across sessions or app-disable toggles. Restores to the captured
    /// `originalFrames` entry when present, otherwise cascades onto the main
    /// screen.
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

    /// Forwarded from the `HIToolbox` distributed notification when a menu
    /// (app menu, status item, context menu) opens. Suppresses FFM so the
    /// user can scrub through menu items without focus jumping behind.
    @objc private func menuTrackingBegan(_ note: Notification) {
        mouseTracker.menuTrackingBegan()
    }

    /// Counterpart to `menuTrackingBegan` — re-enables FFM when the menu
    /// closes.
    @objc private func menuTrackingEnded(_ note: Notification) {
        mouseTracker.menuTrackingEnded()
    }

    /// Stop and immediately start again. Used for runtime config changes
    /// that require rebuilding the hotkey tap and observer chain.
    func restart() {
        stop()
        start()
    }

    // MARK: - mouse tracking

    /// Install global NSEvent monitors for mouse move/down/drag/up.
    ///
    /// Each monitor delegates to `mouseTracker` (move) or local helpers
    /// (down/drag/up) that maintain the drag-detection scratchpad and the
    /// pre-drag focus-border state. The drag monitor hides the focus border
    /// for floating windows because the border only repositions on the 1Hz
    /// poll and would otherwise lag the live drag at 60Hz; mouseUp restores
    /// it after a short settle delay.
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

    /// Remove every NSEvent monitor installed by `startMouseTracking()` and
    /// clear the drag scratchpad. Idempotent.
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

    /// Apply focus-follows-mouse to `window` without changing z-order.
    /// Suppresses the dock-click workspace switch for half a second so the
    /// app activation kicked off by the AX focus call doesn't bounce the
    /// user to a different workspace.
    private func focusForFFM(_ window: HyprWindow) {
        suppressions.suppress("activation-switch", for: 0.5)
        window.focusWithoutRaise()
        updateFocusBorder(for: window)
    }

    /// Reposition the focus border around `window`, refresh the floating
    /// outlines, and rebuild the dim mask for the new focused window. Hides
    /// every visual indicator if the user has the focus border disabled or
    /// the window has no readable frame.
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

    /// Re-show the focus border on the tracked window after the Hypr key is
    /// released. macOS may have re-raised other windows during the chord
    /// (e.g. when the chord triggered an app activation); this re-asserts
    /// the floating-border z-order and refreshes the mask for the focused
    /// window. Runs at 0.05s and 0.25s to catch both fast and slow OS
    /// re-raise paths.
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

    /// Recompute the dim mask from the live tile positions and the current
    /// floating set, then push the result to `DimmingOverlay`. Called on
    /// focus change and after any tile update so the cutout shape tracks
    /// window moves, resizes, and workspace visibility changes.
    ///
    /// - Parameter focusedID: Override for the "bright" window. Defaults to
    ///   `focusBorder.trackedWindowID`, then `focusController.lastFocusedID`.
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

    /// Read live AX frames for every visible tile before dim or border
    /// computations.
    ///
    /// `stateCache.tiledPositions` only refreshes on poll/retile (1Hz timer
    /// plus activation/launch notifications). Between those events a window
    /// can resize or move — app self-resize, AX min-size kick-in, manual
    /// drag, pass-2 layout responding to a constraint — and the cache goes
    /// stale. Without the live re-read, `refreshDimming` and the border
    /// occlusion mask triggered by FFM or a click during that gap compute
    /// against the old rect, leaving the new rect partly bright and partly
    /// covered by stale dim (the "half-dim" artifact).
    ///
    /// Cost: one AX query per visible tile, paid on focus change, retile,
    /// and poll completion only.
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

    /// Re-establish a coherent focus on bare Hypr keydown.
    ///
    /// The visible focus border is the primary source of truth for intent,
    /// as long as the bordered window belongs to the cursor's workspace.
    /// When that fails, fallbacks are tried in priority order: the last
    /// recorded focus, floating window under the cursor (drawn on top),
    /// tiled window under the cursor, AX's reported focused window, and
    /// finally the nearest tiled window's center. Each candidate must be
    /// selectable in the cursor's current workspace context.
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

    /// Forward a mouse-up that followed a drag to `DragSwapHandler` for
    /// classification and possible swap application.
    private func handleMouseUp(startFrames: [CGWindowID: CGRect]) {
        dragSwapHandler.handleMouseUp(startFrames: startFrames)
    }

    // MARK: - action dispatch

    /// Hand an `Action` to the dispatcher. Wrapped here so the hotkey
    /// callback site stays terse and so subclasses or tests can intercept
    /// in one place.
    private func handleAction(_ action: Action) {
        actionDispatcher.dispatch(action)
    }

    /// Return the screen under the mouse cursor.
    ///
    /// Shared with `WorkspaceOrchestrator` and `ActionDispatcher` via
    /// closure handles. Focused-window-based detection is unreliable
    /// immediately after a workspace switch — the focused window can still
    /// belong to the previous screen — so cursor position is the
    /// authoritative signal.
    private func screenUnderCursor() -> NSScreen {
        let mouseNS = NSEvent.mouseLocation
        let cgY = displayManager.primaryScreenHeight - mouseNS.y
        return displayManager.screen(at: CGPoint(x: mouseNS.x, y: cgY))
            ?? displayManager.screens.first
            ?? NSScreen.main!
    }

    // MARK: - floating

    // public accessors for menu bar indicator

    /// `true` when at least one floating window is currently visible on any
    /// active workspace. Drives the `◆`/`◇` glyphs in the menu bar.
    var hasVisibleFloatingWindows: Bool {
        stateCache.floatingWindowIDs.contains { workspaceManager.isWindowVisible($0) }
    }

    /// Workspaces (1–9) that hold at least one live, non-hidden window.
    /// Hidden windows (minimized or closed apps still running) are excluded
    /// so the menu bar grid does not show ghost occupancy.
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

    /// Workspace currently visible on each enabled screen, in screen order.
    /// Disabled monitors are omitted entirely.
    func activeWorkspaces() -> [Int] {
        displayManager.screens
            .filter { !workspaceManager.isMonitorDisabled($0) }
            .map { workspaceManager.workspaceForScreen($0) }
    }

    // MARK: - disabled monitor handling

    /// React to a runtime change of `config.disabledMonitors`.
    ///
    /// On a newly-disabled monitor, every window the screen owns is removed
    /// from its tiling tree, dropped from workspace assignment, and
    /// auto-floated. On a re-enabled monitor, previously auto-floated
    /// windows (those with no workspace assignment) are unfloated so the
    /// next tile picks them up. Always finishes by reinitializing the
    /// monitor map and snapshot-tiling the result.
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

    /// Snapshot every window AX can see, classify each, then tile.
    ///
    /// Five phases run in order:
    /// 1. Prime tiling-engine min-size memory from live AX values.
    /// 2. Capture a one-time `originalFrame` per window so float toggles can
    ///    restore pre-tile geometry. Off-screen frames are skipped — after a
    ///    restart, windows may still be parked at the previous session's
    ///    hide-corner.
    /// 3. Auto-float bundle-ID-excluded apps and any window on a disabled
    ///    monitor. Disabled-monitor windows skip workspace assignment
    ///    entirely.
    /// 4. Assign each remaining window to its physical screen's active
    ///    workspace.
    /// 5. Distribute and tile.
    ///
    /// Called from `start()` after the initial AX-settle delay, on screen
    /// parameter changes, and from menu-driven "Retile All".
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

    /// Tile each enabled screen's active workspace with the windows
    /// assigned to it.
    ///
    /// Bypassed while an animation is in flight so the animator's parked
    /// frames are not stomped. Refreshes the position cache after applying
    /// frames so the menu bar indicator and dim mask track the new layout.
    ///
    /// - Parameter windows: Pre-fetched window list. When `nil`, AX is
    ///   re-queried. Callers that already have a fresh list pass it to
    ///   avoid the round trip.
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

    /// Retile with a slide animation between old and new tile rects.
    ///
    /// Five steps:
    /// 1. Capture before-frames for every visible non-floating window.
    /// 2. Run `prepare` to mutate state (remove from tree, toggle float,
    ///    swap, etc.).
    /// 3. Re-fetch the window list when `prepare` ran — the membership of
    ///    visible windows may have changed.
    /// 4. Compute new layout rects via `prepareTileLayout` per screen and
    ///    build slide transitions for windows that moved.
    /// 5. Drive the animator; after it completes, apply the final layout
    ///    with two-pass min-size resolution and refresh the position cache.
    ///
    /// Falls through to a synchronous tile when animations are disabled or
    /// another animation is already in flight. Only animates the windows
    /// whose rects changed — there is no fade or scale on the window the
    /// caller just mutated.
    ///
    /// - Parameter windows: Pre-fetched window list (optional, see
    ///   `tileAllVisibleSpaces`).
    /// - Parameter prepare: State mutation that produces the new layout.
    /// - Parameter completion: Runs after the animation settles or
    ///   immediately on the synchronous fall-through path.
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

    /// Spread every tiling-eligible window across workspaces so no single
    /// workspace is forced past its dwindle depth.
    ///
    /// Visible workspaces (one per enabled screen, left-to-right) fill
    /// first; further workspaces cycle through screens for spillover. The
    /// focused window is moved to slot zero so it lands on the first
    /// visible workspace. Anything that does not fit even in the ninth
    /// workspace is auto-floated. Called once at startup and from "Retile
    /// All" so a fresh launch with many windows produces a balanced layout
    /// instead of piling everything on the primary screen.
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

    /// Resolve a window by ID against a fresh list, falling back to the
    /// cache. Used by code paths that need to operate on a window even when
    /// AX no longer reports it (e.g. mid-hide).
    private func findWindow(_ wid: CGWindowID, in allWindows: [HyprWindow]) -> HyprWindow? {
        allWindows.first { $0.windowID == wid } ?? stateCache.cachedWindows[wid]
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

    /// Return the window the user actually intends to control.
    ///
    /// AX's `kAXFocusedWindowAttribute` lags or diverges from reality for
    /// multi-window apps (Finder, Teams); `focusWithoutRaise` — used by FFM
    /// and `Hypr+Arrow` — does not reliably update it. The internal focus
    /// tracker is the source of truth: it's updated on every focus action
    /// and on manual clicks, so it stays in sync with what the user
    /// actually pointed at last.
    ///
    /// Resolution order: `focusBorder.trackedWindowID` → `lastFocusedID`
    /// → AX's reported focused window → `nil`. Each candidate must be
    /// selectable in the cursor's current workspace.
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

    /// `true` when `windowID` is a valid focus target right now: either
    /// assigned to the cursor's workspace or a visible floating window.
    private func isSelectableInCurrentContext(_ windowID: CGWindowID, workspaceWindows: Set<CGWindowID>) -> Bool {
        if workspaceWindows.contains(windowID) { return true }
        return stateCache.floatingWindowIDs.contains(windowID) && workspaceManager.isWindowVisible(windowID)
    }

    /// Snapshot tile frames at mouse-down so `DragSwapHandler` can compare
    /// against post-drag rects to detect a swap target. Also notes the
    /// floating window under the cursor (if any) so the drag monitor knows
    /// to hide that floater's border for the drag duration.
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

    /// Hit-test the cursor against floating and tiled windows and record
    /// the result in `focusController`. Called from `leftMouseDown` so a
    /// manual click wins over any stale FFM tracker state — without this,
    /// commands routed via `currentFocusedWindow()` would target the
    /// previously-hovered window instead of what the user just clicked.
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

    /// Forget every trace of `id` from cache state and the engine, workspace,
    /// and focus references. Idempotent. Used for one-shot cleanups; the
    /// discovery apply-loop calls the two halves separately so it can clear
    /// cache state for a batch in one pass.
    private func forgetWindow(_ id: CGWindowID) {
        stateCache.forget(id)
        applyForgottenIDExternalCleanup(id)
    }

    /// Engine/workspace/focus half of forgetting an id. Drops engine
    /// min-size memory, removes workspace assignment, and clears any focus
    /// or border state that pointed at the window.
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

    /// Forget every window owned by `pid`. Called on app termination —
    /// handles the case where an app dies while some of its windows are
    /// hidden or minimized; those ids would otherwise leak in cache state
    /// forever because the gone-detection path skips windows already
    /// missing from `knownWindowIDs`.
    private func forgetApp(_ pid: pid_t) {
        let ids = discovery.forgetApp(pid)
        guard !ids.isEmpty else { return }
        for id in ids {
            tilingEngine.removeWindowID(id)
            applyForgottenIDExternalCleanup(id)
        }
        hyprLog(.debug, .lifecycle, "forgetApp pid=\(pid) cleaned \(ids.count) window(s)")
        // discovery.forgetApp already cleared knownWindowIDs, so the scheduled
        // poll's diff returns no changes and needsRetile is false. apply new
        // frames here so the surrounding tiles expand into the freed slot
        // instead of waiting for the next user action to trigger a retile.
        animatedRetile()
    }


    /// `true` when at least 25% of `frame` overlaps `screenRect`. Used to
    /// decide whether a captured frame represents a real on-screen position
    /// or a hide-corner sliver from a previous session.
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

    /// Collect frames for every visible floating window in `source`,
    /// optionally inset by `-padding` (negative inset enlarges) so dim
    /// cutouts can leave breathing room around the floater outline.
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

    /// Refresh `stateCache.tiledPositions` and `cachedWindows` from current
    /// AX data, then update floating outlines, the menu bar indicator, the
    /// focus-border position, and the dim mask.
    ///
    /// Called after every operation that may have changed window geometry
    /// (tile, animate, drag-end, workspace switch, config tweak). Keeps the
    /// downstream visual layer (border, dim, menu bar dots) in sync with
    /// the live tile state without re-running the tiling algorithm.
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

    /// Recompute floater frames and push them into the focus border. Each
    /// floater gets a persistent outline at the floating border color so
    /// the user can spot a floater that ended up behind a tile.
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

    /// Compute per-border occluder rects and push them into the focus
    /// border so each border layer is masked to its window's visible
    /// region.
    ///
    /// The border panels live at `.floating` window level, which means
    /// they render above other-app windows by default — including over
    /// HyprMac-tracked windows that are visually above the bordered window
    /// in macOS z-order. To honor real z-order, this method walks
    /// `CGWindowListCopyWindowInfo` (front-to-back) and collects the rects
    /// of every higher-z tracked window that overlaps the bordered
    /// window. The border layer's mask cuts those occluders out so the
    /// border does not draw over windows that are visually on top of it.
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

    /// Render the dot-grid string for the menu bar indicator and publish it
    /// to `MenuBarState.shared` for SwiftUI consumption.
    ///
    /// Encoding: `●` active, `◆` active+floating, `○` occupied, `◇`
    /// occupied+floating, `·` empty. The string is truncated at the
    /// highest-numbered active or occupied workspace so empty trailing
    /// dots do not pad the menu bar.
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

    /// Workspaces that hold at least one live (non-hidden) floating window.
    /// Drives the diamond glyphs (`◆` / `◇`) in the menu bar grid.
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

    /// Run a single discovery diff and hand the result to the dispatcher's
    /// apply-loop.
    ///
    /// Drops the poll entirely when an animation is in flight (the
    /// animator's parked frames would look like stale geometry to
    /// discovery) or when a mouse button is down (the user is dragging or
    /// clicking through controls; window state is mid-transition). Both
    /// guards are about whether to poll *at all* — once `applyChanges` is
    /// called, the apply-loop runs unconditionally.
    ///
    /// Coalesced with notification-driven schedules by `PollingScheduler`,
    /// which also honors the `cross-swap-in-flight` suppression so a
    /// cross-monitor drag-swap completes without pollers stomping on its
    /// in-flight tree mutations.
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

    /// React to an app coming to the foreground.
    ///
    /// Three responsibilities:
    /// 1. Note when the dock is the active app so FFM can be suppressed
    ///    while dock popups (downloads, stacks) are open.
    /// 2. If the activation was not suppressed (FFM, workspace switch,
    ///    floater-raise) and the activated app has no visible window, jump
    ///    to a workspace that does — this is the "dock-click takes me to
    ///    that app's workspace" affordance. Returns early when it fires;
    ///    the workspace switch will trigger its own poll.
    /// 3. Otherwise, schedule a discovery poll and re-raise floating
    ///    windows after a brief settle so they stay visually on top.
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


    /// React to a new app launch. Half-second delay gives the app time to
    /// open its first window before discovery runs.
    @objc private func appDidLaunch(_ notification: Notification) {
        pollingScheduler.schedule(after: 0.5)
    }

    /// React to an app terminating. Prunes every window owned by the dead
    /// pid before scheduling a poll — without this, hidden or minimized
    /// windows would leak in cache state forever, since the gone-detection
    /// path can only see windows still in `knownWindowIDs`.
    @objc private func appDidTerminate(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            forgetApp(app.processIdentifier)
        }
        pollingScheduler.schedule()
    }

    /// React to an app being hidden or unhidden (Cmd-H, Hide Others, etc.).
    /// Short delay lets AX settle before discovery picks up the change.
    @objc private func appVisibilityChanged(_ notification: Notification) {
        pollingScheduler.schedule(after: 0.3)
    }

    /// React to a screen configuration change (monitor connect/disconnect,
    /// resolution change, dock position).
    ///
    /// Order is load-bearing: `DisplayManager.refresh` runs automatically
    /// via the same notification, then `WorkspaceManager.initializeMonitors`
    /// must run before `TilingEngine.handleDisplayChange` so the
    /// home-screen lookup the engine consults is current. Reversing the
    /// order would prune the home-screen mapping first and orphan the
    /// migration.
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

    /// Handler for the `.hyprMacRetileAll` notification posted from the
    /// menu bar's "Retile All" action.
    @objc private func retileAllRequested() {
        hyprLog(.debug, .lifecycle, "retile all spaces requested")
        snapshotAndTile()
    }
}
