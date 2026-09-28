// Central orchestrator. Wires every subsystem together, owns the long-lived
// references, and routes hotkey actions and discovery results to the services
// that handle them. No tiling, focus, workspace, or floating policy lives here
// directly — this class is the seam that holds them in one place.

import Cocoa

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
    let focusBorder = FocusBorder()
    let focusBrackets = FocusBrackets()
    let dimmingOverlay = DimmingOverlay()
    let mouseTracker = MouseTrackingManager()
    let dragManager = DragManager()
    let keybindOverlay = KeybindOverlayController()
    let workspaceOverview = WorkspaceOverviewController()

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

    // per-app AXObserver fan-out. primary discovery trigger — its events
    // funnel into pollingScheduler.schedule(after:); the timer is a safety net.
    private let axNotifications = AXNotificationService()

    // floating-window lifecycle: float/tile toggle, cycle-focus, raise-behind, auto-float predicate.
    private(set) var floatingController: FloatingWindowController!

    // focus for HyprMac-initiated focus changes. a tile a floater covers is
    // focused without being lifted over the floater.
    private let tiledFocusRouter = TiledFocusRouter()
    // the current left press, if it was a real click on a window. consumed
    // at mouse-up by the click re-raise.
    private var clickPress: ClickPress?
    // a restack refresh is queued; later triggers ride along with it
    private var restackRefreshPending = false

    // verified tiled drag capture and completion.
    private var tiledDragHandler: TiledDragHandler!
    private var tiledDragFeedback = TiledDragFeedbackReconciler()
    private var pendingTiledDragCompletion: TiledDragCompletion?
    private var activeTiledDragFeedback: (key: TiledDragFeedbackKey,
                                           layoutGeneration: UInt64, borderToken: Int)?

    // live highlight of where a tiled drag will land. the frames come from
    // the press capture and the trees, never from AX while the pointer moves
    private let dropPreviewPanel = TiledDropPreviewPanel()
    private lazy var dropPreview = TiledDragPreviewSession(presenter: .init(
        show: { [weak self] rect in self?.dropPreviewPanel.show(rect) },
        hide: { [weak self] in self?.dropPreviewPanel.hide() }))
    // per drag: each other display's tree as a drop there would find it,
    // kept while its workspace and tree stay what they were
    private var dropPreviewTargets: [CGDirectDisplayID: (workspace: Int, target: TiledDragCrossTarget)] = [:]
    private var dragOptionDown = false
    private var dragFlagsMonitor: Any?

    // Action → service routing. dispatch(_:) replaces the handleAction switch.
    private var actionDispatcher: ActionDispatcher!

    // workspace switch / move / move-to-monitor workflows.
    // delegates to workspaceManager + tilingEngine; no new policy lives there.
    private var workspaceOrchestrator: WorkspaceOrchestrator!
    private var scratchpad: ScratchpadController!

    // periodic discovery timer + coalesced notification-driven polls.
    // constructed in init() so the closure can capture self weakly.
    private var pollingScheduler: PollingScheduler!

    // one bounded retry, then an explicit float, for a newcomer a failed
    // admission left outside the tree.
    private let admissionRecovery = AdmissionRecovery()
    private let minimaRevalidation = MinimaRevalidation()

    // one tiling pass plus the bookkeeping it owes. every production retile
    // goes through this, so nothing it strands goes untracked.
    private var admissionPass: AdmissionPass {
        AdmissionPass(engine: tilingEngine, revalidation: minimaRevalidation,
                      recovery: admissionRecovery)
    }

    // a tiled window whose app put it back where it wanted, after our write
    // was accepted. one bounded re-apply per episode, driven by the poll.
    private let driftMonitor = TiledDriftMonitor()

    // SIGUSR1 → dumpState. armed in start(), cancelled in stop().
    private var dumpStateSignalSource: DispatchSourceSignal?

    // wall clock of the last poll, so the file log can show the gap
    // between a destroy notification and the poll that acted on it.
    private var lastPollAt: Date?

    // mouse tracking
    private var mouseMoveMonitor: Any?
    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?
    private var mouseDragMonitor: Any?
    private var mouseDragLifecycle = MouseDragLifecycleState()
    private var mouseButtonDown: Bool {
        get { mouseDragLifecycle.buttonDown }
        set { mouseDragLifecycle.buttonDown = newValue }
    }
    private var mouseDraggedSinceDown: Bool {
        get { mouseDragLifecycle.sawDragEvent }
        set { mouseDragLifecycle.sawDragEvent = newValue }
    }
    private var mouseDownPointCG: CGPoint?
    private var mouseDownFloatingWindowID: CGWindowID = 0
    // CG frame of that floater, read in the same mouse-down enumeration —
    // the dim-drag anchor must come from here, not a fresh AX read at arm
    // time (which pairs a pre-drag frame with a mid-flick cursor position)
    private var mouseDownFloatingFrame: CGRect?

    // window whose focus border was hidden when a drag started — re-shown on mouseUp.
    // we hide rather than try to follow, because we'd need 60Hz AX polling per window
    // and that's prohibitively expensive.
    private var preDragFocusedID: CGWindowID {
        get { mouseDragLifecycle.preDragFocusedID }
        set { mouseDragLifecycle.preDragFocusedID = newValue }
    }

    // armed when a drag starts on a visible floating window while dim is on
    // (normal mode). drives dimmingOverlay.setDragOverride so the bright carve
    // hole tracks the floater live instead of trailing on the discovery poll.
    private struct DimDragState {
        // startFrame + downPointCG are the tracking anchor and MUST be a
        // consistent pair, both sampled at mouse-down (frame from the
        // mouse-down enumeration, point from the event). during a title-bar
        // drag the OS keeps windowOrigin == startOrigin + (cursor − downPoint)
        // exactly, so delta math off this pair is lag-free. never re-anchor
        // to an AX position read mid-drag — those lag a fast drag, and pairing
        // a stale origin with a live cursor bakes the lag in as a permanent
        // carve offset for the rest of the drag.
        let id: CGWindowID
        let window: HyprWindow
        let startFrame: CGRect       // CG top-left frame at mouse-down
        let downPointCG: CGPoint     // click point from the mouse-down event
        var confirmed = false        // an AX read saw the window actually moving
        var resizing = false         // classified as a resize → track the live frame
        var lastSizeCheck: TimeInterval = 0
    }
    private var dimDrag: DimDragState?

    // true while the Hypr key is physically held. drives focusBrackets — when held,
    // every focus change re-targets the brackets so they track Hypr+arrow even
    // across workspace switches (which transiently hide the focus border).
    private var hyprHeld = false

    // bumped each time the dock activates; the watchdog closure compares against this
    // before clearing dockIsActive so re-activations cancel earlier pending clears.
    private var dockActivationToken: UInt64 = 0

    // date-gated suppression flags. owned here, shared with subsystems via closures.
    // keys in use: "activation-switch" (gates appDidActivate workspace switch),
    // "mouse-focus" (will migrate from MouseTrackingManager in a follow-up commit).
    let suppressions = SuppressionRegistry()

    // live config reload
    private lazy var configUpdateCoordinator = ConfigUpdateCoordinator(
        initial: RuntimeConfigState(config))
    private var isRunning = false

    // fingerprint of the last display layout we acted on. macOS posts
    // didChangeScreenParametersNotification for things that don't actually
    // change the screen list (FaceTime/Teams call init, app quits that
    // deregister display callbacks, color profile bumps), and our handler
    // runs the destructive redistribute every time. guard against no-op fires.
    private var lastDisplayFingerprint: String = ""
    /// when the session was last interrupted: sleep, wake, lock, unlock. a
    /// topology change soon after a wake settles more slowly, because
    /// displays reattach one at a time over several seconds
    private var lastSystemInterruptionAt = Date.distantPast
    static let wakeSettleWindow: TimeInterval = 5.0
    static let recentWakeSpan: TimeInterval = 20.0
    /// Pending destroy notifications whose poll has not yet seen the close.
    private var destroyRecheck = DestroyRecheck()
    /// Monotonic token for the display-change stability debounce — a newer
    /// notification supersedes any pending stability check.
    private var displayChangeGeneration = 0
    /// True from a screen-parameters notification until the settled
    /// reconcile (or unchanged-skip) runs. Retiles are deferred while set —
    /// tiling against half-migrated trees spawns fresh z-ordered duplicates
    /// that then win the migration over the real trees.
    private var displayTransitionPending = false
    private var retileSkippedDuringTransition = false
    /// Display key of the last settled topology. The auto-save on the first
    /// notification of a transition files the departing layout under this
    /// key — by then `displayManager.screens` already reflects the new one.
    private var settledDisplayKey = ""
    /// the launch restore runs once per process; resuming from pause
    /// restarts the manager but is not a launch
    private var didRunLaunchRestore = false
    private let layoutStore = LayoutSnapshotStore.shared

    /// Wire the dependency graph and configure every subsystem callback.
    ///
    /// Construction is in three layers:
    /// 1. Build sub-managers that take only static dependencies.
    /// 2. Build the orchestration layer (`floatingController`,
    ///    `workspaceOrchestrator`, `pollingScheduler`, `tiledDragHandler`,
    ///    `actionDispatcher`) and attach the closure handles each one
    ///    needs from `WindowManager`-local helpers.
    /// 3. Subscribe to `UserConfig` `@Published` properties so runtime
    ///    config changes flow through to the right subsystem.
    ///
    /// The recovery hotkey tap starts here so pause/resume works even when
    /// tiling launches disabled. Window discovery and tiling start in `start()`.
    init(config: UserConfig) {
        self.config = config
        self.focusController = FocusStateController(focusBorder: focusBorder)
        self.workspaceManager = WorkspaceManager(displayManager: displayManager)
        self.workspaceManager.onParkFailed = { [weak self] in self?.pollingScheduler.schedule(after: 0.3) }
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
            suppressions: suppressions,
            revalidation: minimaRevalidation
        )
        self.workspaceOrchestrator.screenUnderCursor = { [weak self] in self?.screenUnderCursor() ?? NSScreen.main! }
        self.workspaceOrchestrator.currentFocusedWindow = { [weak self] in self?.currentFocusedWindow() }
        self.workspaceOrchestrator.updateFocusBorder = { [weak self] w in self?.updateFocusBorder(for: w) }
        self.workspaceOrchestrator.updatePositionCache = { [weak self] in self?.updatePositionCache() }
        self.workspaceOrchestrator.tileAllVisibleSpaces = { [weak self] in self?.tileAllVisibleSpaces() }
        self.workspaceOrchestrator.animatedRetile = { [weak self] prepare, completion in
            self?.animatedRetile(prepare: prepare, completion: completion)
        }
        // the HUD goes up before the hide/retile/focus pass, not after it
        self.workspaceOrchestrator.onWillSwitch = { [weak self] workspace, screen in
            self?.workspaceOverview.showSwitchHUD(workspace: workspace, screen: screen)
        }
        self.workspaceOrchestrator.onDidSwitch = { [weak self] _, _ in
            self?.updateMenuBarState()
        }
        self.workspaceOrchestrator.excludedBundleIDs = { [weak self] in
            Set(self?.config.excludedBundleIDs ?? [])
        }
        self.workspaceOrchestrator.isScratchpadWindow = { [weak self] id in
            self?.scratchpad.contains(id) ?? false
        }
        self.workspaceOrchestrator.noteAdmission = { [weak self] result in
            self?.admissionRecovery.note(result)
        }
        self.workspaceOverview.onSelectWorkspace = { [weak self] workspace in
            guard let self, self.config.enabled else { return }
            self.handleAction(.switchWorkspace(workspace))
        }
        self.workspaceOverview.onSelectWindow = { [weak self] workspace, windowID in
            guard let self, self.config.enabled else { return }
            // a workspace action, like the ones handleAction routes
            self.scratchpad.hide(reason: .workspaceAction)
            self.workspaceOrchestrator.switchWorkspace(workspace, preferredWindowID: windowID)
        }
        self.scratchpad = ScratchpadController(
            workspaceManager: workspaceManager,
            stateCache: stateCache,
            accessibility: accessibility,
            displayManager: displayManager,
            tilingEngine: tilingEngine,
            focusController: focusController,
            focusBorder: focusBorder,
            suppressions: suppressions
        )
        scratchpad.screenUnderCursor = { [weak self] in self?.screenUnderCursor() }
        scratchpad.currentFocusedWindow = { [weak self] in self?.currentFocusedWindow() }
        scratchpad.updatePositionCache = { [weak self] in self?.updatePositionCache() }
        scratchpad.updateFocusBorder = { [weak self] w in self?.updateFocusBorder(for: w) }
        scratchpad.refocusUnderCursor = { [weak self] in self?.mouseTracker.refocusUnderCursor() }
        scratchpad.isNeverTile = { [weak self] w in self?.floatingController.isNeverTile(w) ?? false }
        scratchpad.animatedRetile = { [weak self] prepare, completion in
            self?.animatedRetile(prepare: prepare, completion: completion)
        }
        scratchpad.raiseScrim = { [weak self] in
            guard let self else { return }
            self.refreshDimming()
            self.dimmingOverlay.orderFrontAll()
        }
        scratchpad.lowerScrimBelow = { [weak self] wid in
            self?.dimmingOverlay.orderBelow(windowNumber: Int(wid))
        }
        self.pollingScheduler = PollingScheduler { [weak self] in
            self?.pollWindowChanges()
        }
        // workspace-transition is set by switchWorkspace and moveToWorkspace for 0.6s
        // so drift detection can't fire on stale-AX-read frames mid-transition.
        // mouseButtonDown lives here (not as a drop-guard in pollWindowChanges)
        // so a create/destroy event arriving mid-drag defers and fires on
        // mouseUp instead of being lost until the 10s reconcile.
        pollingScheduler.isSuppressed = { [weak self] in
            guard let self else { return false }
            return self.mouseButtonDown
                || self.tiledDragHandler.isFinishingDrag
                || self.suppressions.isSuppressed("workspace-transition")
        }

        hotkeyManager.onAction = { [weak self] action in
            guard let self else { return }
            // hotkeys arrive through an event tap, which the lock screen's
            // secure input keeps key events from, so one firing means the
            // session is in use again
            self.discovery.endSessionInterruption(evidence: "hotkey press")
            if action == .toggleTiling {
                self.config.enabled.toggle()
                return
            }
            guard self.config.enabled || action == .showKeybinds || action == .showWorkspaceOverview else { return }
            self.suppressions.suppress("mouse-focus", for: 0.15)
            self.handleAction(action)
            // a workspace switch or the scratchpad mid-drag changes where the
            // drop would land, even with the pointer standing still
            self.dropPreview.refresh()
        }

        hotkeyManager.onHyprKeyDown = { [weak self] in
            guard let self, self.config.enabled else { return }
            self.hyprHeld = true
            let mousePressActive = self.mouseDragLifecycle.buttonDown
            self.mouseDragLifecycle.noteHyprKeyDown()
            // a latched Hypr turns the drop into a swap
            self.dropPreview.refresh()
            // Do not repair focus while a mouse gesture is in flight. A stale
            // tracker can otherwise focus a fallback window and redirect the
            // native title-bar drag when Hypr is pressed mid-gesture.
            // Nor while a menu is open: a bare Hypr press must not close it.
            if !mousePressActive {
                if self.mouseTracker.menuTracking {
                    hyprLog(.debug, .focus, "ensureFocus skipped: menu tracking")
                } else if let popup = self.mouseTracker.openPopup(maxAge: 0) {
                    hyprLog(.notice, .focus, "ensureFocus skipped: popup wid=\(popup.windowID) layer=\(popup.layer)")
                } else {
                    self.ensureFocus()
                }
            }
            // visual cue: corner brackets snap inward around the focused
            // window so the user sees which window the next Hypr action
            // will target. shown regardless of focus-border setting.
            self.showFocusBracketsForCurrentFocus()
        }
        hotkeyManager.onHyprKeyUp = { [weak self] in
            self?.hyprHeld = false
            self?.focusBrackets.hide()
            self?.reassertFocusBorderAfterHyprRelease()
        }

        // wire up mouse tracker dependencies
        mouseTracker.isFocusFollowsMouseEnabled = { [weak self] in self?.config.focusFollowsMouse ?? false }
        mouseTracker.hoverThrottleInterval = { [weak self] in
            1.0 / Double(HoverResponseRate.effectiveHz(
                for: self?.config.mouseHoverPollHz ?? UserConfigDefaults.mouseHoverPollHz))
        }
        mouseTracker.isMouseButtonDown = { [weak self] in self?.mouseButtonDown ?? false }
        mouseTracker.primaryScreenHeight = { [weak self] in self?.displayManager.primaryScreenHeight ?? 0 }
        mouseTracker.screenAt = { [weak self] pt in self?.displayManager.screen(at: pt) }
        mouseTracker.floatingWindowIDs = { [weak self] in self?.stateCache.floatingWindowIDs ?? [] }
        mouseTracker.isWindowVisible = { [weak self] wid in self?.isInteractive(wid) ?? false }
        mouseTracker.cachedWindow = { [weak self] wid in self?.stateCache.cachedWindows[wid] }
        mouseTracker.tiledPositions = { [weak self] in
            guard let self else { return [:] }
            // the background tiles and the layer's tiles overlap
            guard self.scratchpad.isVisible else { return self.stateCache.tiledPositions }
            return self.stateCache.tiledPositions.filter { self.scratchpad.isSummoned($0.key) }
        }
        mouseTracker.onFocusForFFM = { [weak self] w in self?.focusForFFM(w) }
        mouseTracker.onUpdateFocusBorder = { [weak self] w in self?.updateFocusBorder(for: w) }
        mouseTracker.isMouseFocusSuppressed = { [weak self] in self?.suppressions.isSuppressed("mouse-focus") ?? false }
        mouseTracker.lastFocusedID = { [weak self] in self?.focusController.lastFocusedID ?? 0 }
        mouseTracker.recordFocus = { [weak self] id, reason in self?.focusController.recordFocus(id, reason: reason) }
        mouseTracker.onHideFocusBorder = { [weak self] in
            self?.focusBorder.hidePersistentBorder()
            self?.dimmingOverlay.hideAll()
        }

        // fast path for getFocusedWindow: resolve the focused element's
        // CGWindowID against the last discovery snapshot before falling back
        // to a full AX walk.
        accessibility.cachedWindowLookup = { [weak self] wid in self?.stateCache.cachedWindows[wid] }

        // wire up floating controller — closure handles for WM-side helpers.
        floatingController.animatedRetile = { [weak self] prepare in
            self?.animatedRetile(prepare: prepare)
        }
        floatingController.updateFocusBorder = { [weak self] w in self?.updateFocusBorder(for: w) }
        floatingController.updatePositionCache = { [weak self] in self?.updatePositionCache() }
        floatingController.isMenuTracking = { [weak self] in self?.mouseTracker.menuTracking ?? false }
        floatingController.isScratchpadVisible = { [weak self] in self?.scratchpad.isVisible ?? false }
        floatingController.excludedBundleIDs = { [weak self] in Set(self?.config.excludedBundleIDs ?? []) }
        floatingController.findPopup = { [weak self] windows, front in
            self?.mouseTracker.livePopup(in: windows, frontmostPID: front)
        }
        floatingController.rejectFloatToTile = { [weak self] w, reason in
            guard let self, let frame = w.frame ?? self.stateCache.cachedWindows[w.windowID]?.frame else { return }
            self.focusBorder.flashError(around: frame, windowID: w.windowID, window: w,
                                        message: FloatToTileRejectionMessage.text(for: reason))
        }

        // the restore must not lift the tile back over the floater it just raised
        floatingController.restoreFocusWithoutRaise = { [weak self] w in
            self?.tiledFocusRouter.focus(w, reason: "raise-restore", fallback: .activate)
        }
        floatingController.refocusClickedTile = { [weak self] w, done in
            guard let self else { return }
            self.tiledFocusRouter.focus(w, reason: "click-reraise", fallback: .activate, onResult: done)
        }
        floatingController.isTiledWindow = { [weak self] wid in self?.isRoutedTile(wid) ?? false }
        floatingController.onRestack = { [weak self] in self?.scheduleRestackRefresh(after: 0.02) }

        // hover, Hypr+Arrow and focus repair go through the router. newcomers
        // in admission recovery are drawn over the tiles like floaters, as in
        // clickFocusTarget, so they count as covers and not as tiles.
        tiledFocusRouter.visibleFloaterIDs = { [weak self] in
            guard let self else { return [] }
            return self.stateCache.floatingWindowIDs.union(self.admissionRecovery.pendingWindowIDs)
                .filter { self.isInteractive($0) }
        }
        tiledFocusRouter.isTiled = { [weak self] wid in self?.isRoutedTile(wid) ?? false }
        tiledFocusRouter.lastFocusedID = { [weak self] in self?.focusController.lastFocusedID ?? 0 }
        tiledFocusRouter.focusGeneration = { [weak self] in self?.focusController.generation ?? 0 }
        tiledFocusRouter.openPopup = { [weak self] in self?.mouseTracker.openPopup(maxAge: 0) }
        tiledFocusRouter.isMenuTracking = { [weak self] in self?.mouseTracker.menuTracking ?? false }
        tiledFocusRouter.noteActivation = { [weak self] pid in self?.suppressions.expectActivation(of: pid) }
        // every focus HyprMac asks a window for, whichever path asks
        HyprWindow.activationObserver = { [weak self] pid in self?.suppressions.expectActivation(of: pid) }
        // the usual path can lift the tile over a floater
        let usualFocus = tiledFocusRouter.usualFocus
        tiledFocusRouter.usualFocus = { [weak self] window, fallback in
            usualFocus(window, fallback)
            self?.scheduleRestackRefresh(after: 0.1)
        }

        wireAdmissionRecovery()
        admissionRecovery.terminalOutcome = { [weak self] workspace, screen, result in
            self?.reconcileTiledDragRecovery(workspace: workspace, screen: screen,
                                             result: result)
        }

        self.tiledDragHandler = makeTiledDragHandler()
        focusBorder.onErrorFeedbackFinishedToken = { [weak self] token in
            guard let self else { return }
            if let active = self.activeTiledDragFeedback, active.borderToken == token {
                self.tiledDragFeedback.feedbackFinished(generation: active.layoutGeneration)
                self.activeTiledDragFeedback = nil
                if !self.tiledDragFeedback.hasPendingFeedback {
                    self.pendingTiledDragCompletion = nil
                }
            }
        }
        focusBorder.onErrorFeedbackFinished = { [weak self] in
            guard let self else { return }
            guard self.isRunning, self.config.showFocusBorder,
                  let focused = self.currentFocusedWindow() else { return }
            self.updateFocusBorder(for: focused)
        }
        driftMonitor.isSuspended = { [weak self] in
            guard let self else { return true }
            return self.mouseButtonDown
                || self.tiledDragHandler.isFinishingDrag
                || self.displayTransitionPending
                || self.suppressions.isSuppressed("workspace-transition")
        }

        // action dispatcher — owns the per-Action routing previously in handleAction.
        self.actionDispatcher = ActionDispatcher(
            stateCache: stateCache,
            accessibility: accessibility,
            displayManager: displayManager,
            cursorManager: cursorManager,
            workspaceManager: workspaceManager,
            tilingEngine: tilingEngine,
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
        actionDispatcher.animatedRetile = { [weak self] windows in
            self?.animatedRetile(windows: windows) ?? []
        }
        actionDispatcher.refocusUnderCursor = { [weak self] in self?.mouseTracker.refocusUnderCursor() }
        actionDispatcher.isMenuTracking = { [weak self] in self?.mouseTracker.menuTracking ?? false }
        actionDispatcher.openPopup = { [weak self] in self?.mouseTracker.openPopup(maxAge: 0) }
        actionDispatcher.focusWindow = { [weak self] w, reason in
            self?.tiledFocusRouter.focus(w, reason: reason, fallback: .activate)
                ?? TiledFocusRouter.Route(path: .usual, targetFrame: nil, coveringFrames: [])
        }
        actionDispatcher.toggleScratchpad = { [weak self] in self?.scratchpad.toggle() }
        actionDispatcher.moveToScratchpad = { [weak self] in self?.scratchpad.sendFocusedWindow() }
        actionDispatcher.scratchpadLayer = { [weak self] in self?.scratchpad.visibleLayer }
        actionDispatcher.scratchpadLayoutChanged = { [weak self] in self?.scratchpad.syncTiledFrames() }
        actionDispatcher.refocusScratchpad = { [weak self] in
            self?.scratchpad.refocusMember(reason: "ensureInvariant-scratchpad")
        }
        actionDispatcher.admitToScratchpad = { [weak self] w in self?.scratchpad.admitNewWindow(w) ?? false }
        actionDispatcher.scratchpadDiscovery = { [weak self] gone, returned in
            self?.scratchpad.noteDiscovery(goneIDs: gone, returned: returned)
        }
        actionDispatcher.enforceScratchpadFocus = { [weak self] in self?.scratchpad.enforceFocus() }
        actionDispatcher.saveLayout = { [weak self] in self?.saveLayoutSnapshot(manual: true) }
        actionDispatcher.restoreLayout = { [weak self] in self?.restoreLayoutSnapshot(manual: true) }
        actionDispatcher.retileAll = { [weak self] in self?.retileAllRequested() }
        actionDispatcher.followPinnedWindow = { [weak self] windowID, workspace in
            guard let self else { return }
            // a workspace switch like any other: not mid-transition, and the
            // scratchpad layer doesn't survive it
            guard !self.displayTransitionPending else {
                hyprLog(.notice, .lifecycle, "window rule follow dropped mid-display-transition")
                return
            }
            self.scratchpad.hide(reason: .workspaceAction)
            self.workspaceOrchestrator.switchWorkspace(workspace, preferredWindowID: windowID)
        }

        configureLiveConfigUpdates()
        hotkeyManager.updateHyprKey(config.hyprKey)
        hotkeyManager.updateKeybinds(config.keybinds)
        hotkeyManager.start()
        hotkeyManager.updateTilingEnabled(config.enabled)
        hotkeyManager.start()
    }

    /// Observe the model's post-mutation signal once and route a complete
    /// snapshot. A disk reload emits only after all fields have been applied.
    private func configureLiveConfigUpdates() {
        let coordinator = configUpdateCoordinator

        coordinator.onEnabled = { [weak self] enabled in
            guard let self else { return }
            self.hotkeyManager.updateTilingEnabled(enabled)
            if enabled && !self.isRunning {
                hyprLog(.debug, .lifecycle, "config re-enabled, starting")
                self.start()
            } else if !enabled && self.isRunning {
                hyprLog(.debug, .lifecycle, "config disabled, stopping")
                self.stop()
            }
        }
        coordinator.onKeybinds = { [weak self] binds in
            self?.hotkeyManager.updateKeybinds(binds)
            hyprLog(.debug, .lifecycle, "keybinds reloaded (\(binds.count) binds)")
        }
        coordinator.onHyprKey = { [weak self] key in
            KeyRemapper.applyHyprKey(key)
            self?.hotkeyManager.updateHyprKey(key)
        }
        coordinator.onLayoutGeometry = { [weak self] gap, padding in
            guard let self else { return }
            self.tilingEngine.gapSize = gap
            self.tilingEngine.outerPadding = padding
            if self.isRunning { self.animatedRetile() }
        }
        coordinator.onMaximumSplits = { [weak self] splits in
            guard let self else { return }
            self.tilingEngine.maxSplitsPerMonitor = splits
            if self.isRunning { self.snapshotAndTile() }
            hyprLog(.debug, .lifecycle, "max splits updated: \(splits)")
        }
        coordinator.onDisabledMonitors = { [weak self] disabled in
            guard let self else { return }
            self.workspaceManager.disabledMonitors = disabled
            if self.isRunning { self.handleDisabledMonitorChange() }
            hyprLog(.debug, .lifecycle, "disabled monitors updated: \(disabled)")
        }
        coordinator.onChrome = { [weak self] state, changes in
            self?.applyChromeConfig(state, changes: changes)
        }
        coordinator.onScratchpadRegion = { [weak self] inset in
            guard let self else { return }
            self.scratchpad.tiledRegionInset = inset
            if self.isRunning { self.scratchpad.relayoutVisibleLayer() }
        }
        coordinator.onScratchpadEntryMode = { [weak self] on in
            self?.scratchpad.tileNewMembers = on
        }

        coordinator.observe(config)
    }

    private func applyChromeConfig(_ state: RuntimeConfigState, changes: ChromeConfigChanges) {
        let focusColor = state.focusBorderColorHex.flatMap(NSColor.fromHex) ?? .hyprCyan
        let floatingColor = state.floatingBorderColorHex.flatMap(NSColor.fromHex) ?? .hyprMagenta
        let bracketColor = state.focusBracketColorHex.flatMap(NSColor.fromHex)
            ?? UserConfigDefaults.focusBracketColor

        if changes.contains(.colors) {
            let trackedID = focusBorder.trackedWindowID ?? 0
            let trackedColor = stateCache.floatingWindowIDs.contains(trackedID)
                ? floatingColor : focusColor
            focusBorder.refreshAppearance(
                focusColor: trackedColor.cgColor,
                floatingColor: floatingColor.cgColor)
        }
        if changes.contains(.bracketAppearance) {
            focusBrackets.applyAppearance(
                style: state.focusBracketStyle,
                color: bracketColor.cgColor,
                radius: state.focusBracketRadius,
                thickness: state.focusBracketThickness,
                length: state.focusBracketLength)
            if FocusBracketAppearanceUpdate.shouldShow(
                isRunning: isRunning,
                hyprHeld: hyprHeld,
                style: state.focusBracketStyle,
                isVisible: focusBrackets.isVisible) {
                showFocusBracketsForCurrentFocus()
            }
        }
        if changes.contains(.fadeDuration) {
            focusBorder.fadeDurationSec = state.chromeFadeDurationSec
            dimmingOverlay.fadeDurationSec = state.chromeFadeDurationSec
        }
        if changes.contains(.windowCornerRadius) {
            focusBorder.refreshCornerRadius()
        }
        if changes.contains(.visibility) {
            focusBorder.isEnabled = state.showFocusBorder
            if state.showFocusBorder, isRunning {
                let focusedID = focusBorder.trackedWindowID ?? focusController.lastFocusedID
                if let focused = stateCache.cachedWindows[focusedID] {
                    updateFocusBorder(for: focused)
                } else {
                    refreshFloatingBorders(windows: Array(stateCache.cachedWindows.values))
                }
            }
        }
        if changes.contains(.dimming) || changes.contains(.windowCornerRadius) {
            if isRunning { refreshDimming() }
        }
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
    /// parameter changes. Configuration observation is installed once in init.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastDisplayFingerprint = displayFingerprint()

        // route AX notifications into the coalescing scheduler. these are the
        // primary discovery triggers; the scheduler's timer is a safety net.
        // schedule() already re-checks suppressions at schedule and fire time,
        // so no extra guards here. create/miniaturize/deminiaturize get a 0.2s
        // debounce to let AX settle; focus is snappier at 0.15s; destroy uses
        // the 0.2s default.
        axNotifications.onEvent = { [weak self] kind, pid in
            guard let self else { return }
            hyprLog(.debug, .discovery, "ax event: \(kind) pid=\(pid)")
            switch kind {
            case .windowDestroyed:
                self.destroyRecheck.noteDestroy(pid: pid)
                self.pollingScheduler.schedule()
            case .windowCreated, .windowMiniaturized, .windowDeminiaturized:
                self.pollingScheduler.schedule(after: 0.2)
            case .focusedWindowChanged:
                self.pollingScheduler.schedule(after: 0.15)
                self.scheduleRestackRefresh(after: 0.05)
            case .mainWindowChanged:
                // a new main window usually came forward; nothing to discover
                self.scheduleRestackRefresh(after: 0.05)
            }
        }

        tilingEngine.gapSize = config.gapSize
        tilingEngine.outerPadding = config.outerPadding
        tilingEngine.maxSplitsPerMonitor = config.maxSplitsPerMonitor
        scratchpad.tiledRegionInset = config.scratchpadRegionInset
        scratchpad.tileNewMembers = config.scratchpadTileByDefault
        focusBorder.isEnabled = config.showFocusBorder
        focusBorder.primaryScreenHeight = displayManager.primaryScreenHeight
        focusBorder.fadeDurationSec = config.chromeFadeDurationSec
        focusBrackets.primaryScreenHeight = displayManager.primaryScreenHeight
        focusBrackets.applyAppearance(
            style: config.focusBracketStyle,
            color: config.resolvedFocusBracketColor.cgColor,
            radius: config.resolvedFocusBracketRadius,
            thickness: config.resolvedFocusBracketThickness,
            length: config.resolvedFocusBracketLength)
        focusBorder.refreshAppearance(
            focusColor: config.resolvedFocusBorderColor.cgColor,
            floatingColor: config.resolvedFloatingBorderColor.cgColor)
        dimmingOverlay.fadeDurationSec = config.chromeFadeDurationSec
        workspaceManager.disabledMonitors = config.disabledMonitors
        hotkeyManager.updateHyprKey(config.hyprKey)
        hotkeyManager.updateKeybinds(config.keybinds)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.isRunning else { return }
            self.spaceManager.setup()
            self.workspaceManager.initializeMonitors()
            self.settledDisplayKey = LayoutSnapshotStore.displayKey(screens: self.displayManager.screens)
            let initialWindows = self.snapshotAndTile()
            if !self.didRunLaunchRestore {
                self.didRunLaunchRestore = true
                if self.config.restoreLayoutOnLaunch {
                    self.restoreLayoutSnapshot(manual: false, windows: initialWindows)
                }
            }
            // attach AX observers after the initial tile so their events feed
            // the same coalescing scheduler. this covers the app-level
            // subscriptions (create / focus), then immediately adds window-level
            // subscriptions (destroy / miniaturize) for the initial snapshot.
            AXNotificationService.activateInitialSubscriptions(
                initialWindows: initialWindows,
                attach: self.axNotifications.attachToRunningApps,
                subscribe: self.axNotifications.ensureWindowSubscriptions
            )
            // start the reconcile timer only after the initial tile so
            // pollWindowChanges can't race against snapshotAndTile, claim all
            // windows as new, and trigger an animation that blocks the correct
            // initial distribution. the timer is now a slow (10s) safety net;
            // AX notifications above are the primary trigger.
            self.pollingScheduler.start()
            self.dumpState(reason: "startup")
        }

        // SIGUSR1 dumps state on demand over ssh. the default handler
        // kills the process, so ignore it first and let the dispatch
        // source pick it up on the main thread.
        signal(SIGUSR1, SIG_IGN)
        let dumpSignal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        dumpSignal.setEventHandler { [weak self] in self?.dumpState(reason: "SIGUSR1") }
        dumpSignal.resume()
        dumpStateSignalSource = dumpSignal

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
        // clear stuck dockIsActive if the dock app deactivates without another app taking front
        wsnc.addObserver(self, selector: #selector(appDidDeactivate(_:)),
                         name: NSWorkspace.didDeactivateApplicationNotification, object: nil)

        // sleep / wake / lock — any of these can drop the Hypr keyUp event
        // without triggering tap-disabled, leaving hyprKeyDown stuck true.
        wsnc.addObserver(self, selector: #selector(systemInterruption(_:)),
                         name: NSWorkspace.didWakeNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(systemInterruption(_:)),
                         name: NSWorkspace.screensDidWakeNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(systemInterruption(_:)),
                         name: NSWorkspace.screensDidSleepNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(systemInterruption(_:)),
                         name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(systemInterruption(_:)),
                         name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(systemInterruption(_:)),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(systemInterruption(_:)),
            name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil
        )

        // hide chrome when entering a fullscreen Space, restore when leaving.
        // catches green-button / Cmd-Ctrl-F / browser HTML5 fullscreen since
        // each moves the window into its own Space.
        wsnc.addObserver(self, selector: #selector(activeSpaceDidChange(_:)),
                         name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

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
        // a workspace that changed under a drag changes where it would land
        NotificationCenter.default.addObserver(
            self, selector: #selector(tiledDropPreviewWorkspacesChanged),
            name: .hyprMacWorkspaceChanged, object: nil
        )

        if LogConfig.persistentFileLog {
            hyprLog(.notice, .lifecycle, "file log: \(DebugLogFile.shared.fileURL.path)")
        }
        hyprLog(.debug, .lifecycle, "started")
    }

    /// Tear down everything `start()` brought up.
    ///
    /// Restores hidden workspace windows to visible positions before
    /// detaching observers — without this, windows would remain stranded in
    /// the hide-corner sliver after the app quits or is toggled off. Stops
    /// the polling scheduler, removes mouse monitors, and hides every focus
    /// indicator. The hotkey tap stays available for the pause/resume binding
    /// unless this is final application teardown. Safe to call when not running.
    func stop(keepPauseShortcut: Bool = true) {
        isRunning = false
        hyprHeld = false
        focusBrackets.hide()
        admissionRecovery.cancelAll(reason: "stop")
        minimaRevalidation.cancelAll(reason: "stop")
        // the observers go below, so no end notification would reach a span
        discovery.endSessionInterruption(evidence: "stop")
        driftMonitor.reset()
        dumpStateSignalSource?.cancel()
        dumpStateSignalSource = nil
        tiledDragHandler.cancel()
        endTiledDropPreview()
        tiledDragFeedback.cancel()
        pendingTiledDragCompletion = nil
        activeTiledDragFeedback = nil
        _ = tilingEngine.beginLayoutGeneration()
        restoreAllWindows()
        axNotifications.detachAll()
        pollingScheduler.stop()
        stopMouseTracking()
        if !keepPauseShortcut { hotkeyManager.stop() }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        focusBorder.hide()
        focusBorder.hideFloatingBorders()
        dimmingOverlay.hideAll()
        hyprLog(.debug, .lifecycle, "stopped")
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
            pendingRecovery: tilingEngine.pendingRecoveryWindowIDs,
            unverifiedGeometry: tilingEngine.unverifiedGeometryWindowIDs
        )

        hyprLog(.notice, .lifecycle, "state dump (\(reason))")
        for line in dump.lines() {
            hyprLog(.notice, .lifecycle, line)
        }
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

            // once HyprMac stops every window is a free window, so these
            // go through the same clamp as a floater
            if let original = stateCache.originalFrames[wid] {
                window.placeFloating(original, reason: "stop, original frame",
                                     displayManager: displayManager)
            } else {
                // cascade onto main screen
                let x = screenRect.origin.x + 50
                let y = screenRect.origin.y + 50
                let w = min(screenRect.width * 0.6, 1200)
                let h = min(screenRect.height * 0.6, 800)
                window.placeFloating(CGRect(x: x, y: y, width: w, height: h),
                                     reason: "stop, cascade onto the main screen",
                                     on: mainScreen, displayManager: displayManager)
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
    /// for floating windows because the border only repositions on the
    /// discovery poll and would otherwise lag the live drag at 60Hz; mouseUp restores
    /// it after a short settle delay.
    private func startMouseTracking() {
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.mouseTracker.handleMouseMove()
        }
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return }
            self.mouseDragLifecycle.beginPress(hyprHeld: self.hyprHeld)
            self.mouseDownFloatingWindowID = 0
            self.mouseDownFloatingFrame = nil
            // the event carries the exact click location. sampling
            // NSEvent.mouseLocation inside the handler instead reads
            // wherever the cursor has moved to by the time the AX-heavy
            // capture below finishes — on a fast grab-and-flick that
            // mis-anchors the dim carve (permanent offset) and can make
            // the floater hit-test miss entirely.
            let downCG = TiledDragEvent.point(event: event,
                                              primaryHeight: self.displayManager.primaryScreenHeight)
            let downNS = CGPoint(x: downCG.x,
                                 y: self.displayManager.primaryScreenHeight - downCG.y)
            self.mouseDownPointCG = downCG
            // a press is what opens a menu, so the next hover must read a fresh list
            self.mouseTracker.invalidateWindowListCache()
            self.tiledDragHandler.handleMouseDown(at: downCG)
            self.armDimDragIfFloating(downPointNS: downNS)
            // a menu open at the OS level eats clicks before we'd see them
            // here, so a global mouseDown reaching us is unambiguous proof
            // there is no menu currently tracking. clears the flag if a
            // dropped HIToolbox end-notification left it stuck.
            if self.mouseTracker.menuTracking {
                hyprLog(.notice, .mouse, "leftMouseDown with menuTracking=true — clearing stuck flag")
                self.mouseTracker.menuTrackingEnded()
            }
            // sync our focus tracker with the click — without this, manual clicks
            // leave focusController.lastFocusedID stale and currentFocusedWindow() routes
            // commands to whatever was previously hovered, not what the user clicked.
            // a click on a menu item or panel of the frontmost app is not a click
            // on the window under it.
            let hit = self.mouseTracker.hitTest(at: downCG, maxAge: 0)
            if case .blocked = hit {
                hyprLog(.debug, .mouse, "click on a raised window of the front app — focus tracker left alone")
            } else {
                self.syncFocusTrackerToCursor(at: downNS, hit: hit)
            }
            // remember a real click on a window for the re-raise at mouse-up.
            // our own synthetic clicks and Hypr gestures do not count.
            self.clickPress = nil
            if case .window(let wid) = hit, !self.hyprHeld, !Self.isOwnSyntheticEvent(event) {
                self.clickPress = ClickPress(windowID: wid, point: downCG,
                                             popupOpen: self.mouseTracker.openPopup() != nil)
            }
            // scratchpad is quasimodal: a click outside every member dismisses
            // it in the same tick, so the click lands on the tile it aimed at
            if self.scratchpad.isVisible {
                let cgPoint = CGPoint(x: downNS.x,
                                      y: self.displayManager.primaryScreenHeight - downNS.y)
                self.scratchpad.handleMouseDown(atCG: cgPoint, synthetic: Self.isOwnSyntheticEvent(event))
            }
        }
        // when the user drags a floating window, its frame changes 60Hz but our
        // border only repositions on the discovery poll — so it lags behind ugly. hide
        // the border for the duration of the drag and restore it on mouseUp.
        mouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self = self else { return }
            self.mouseDragLifecycle.observeDrag(hyprHeld: self.hyprHeld)
            self.updateTiledDropPreview(event)
            if self.mouseDownFloatingWindowID != 0 {
                self.focusBorder.hideFloatingBorder(for: self.mouseDownFloatingWindowID)
            }
            self.updateDimDrag()
            guard self.preDragFocusedID == 0 else { return }
            guard let tid = self.focusBorder.trackedWindowID else { return }
            // only hide for floating windows — tiled windows can't be free-dragged
            guard self.stateCache.floatingWindowIDs.contains(tid) else { return }
            self.preDragFocusedID = tid
            self.focusBorder.hide()
            // the scrim stays: re-shown later it would come back above the members
            if !self.scratchpad.isVisible { self.dimmingOverlay.hideAll() }
        }
        // Option held during a tiled drag turns its drop into a swap, and the
        // preview must say so even when the pointer is standing still
        dragFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, self.dropPreview.isActive else { return }
            self.dragOptionDown = event.modifierFlags.contains(.option)
            self.dropPreview.refresh()
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            let shouldDetectDrag = self?.mouseDraggedSinceDown ?? false
            let draggedFloatingID = self?.mouseDownFloatingWindowID ?? 0
            let draggedFloatingFrame = self?.mouseDownFloatingFrame
            var floaterDragged = false
            // the drop decides now; the preview has said all it can
            self?.endTiledDropPreview()
            if let self {
                let primaryHeight = self.displayManager.primaryScreenHeight
                let releasePoint = TiledDragEvent.point(event: event, primaryHeight: primaryHeight)
                // a .leftMouseDragged fires on a pixel of hand jitter, so the flag
                // alone turns ordinary clicks into drag transactions. pointer
                // travel from the press point is what actually decides.
                let isDrag = TiledDragEvent.isDrag(from: self.mouseDownPointCG,
                                                   to: releasePoint,
                                                   sawDragEvent: shouldDetectDrag)
                let travel = TiledDragEvent.travel(from: self.mouseDownPointCG, to: releasePoint)
                hyprLog(.debug, .mouse, "gesture: sawDragEvent=\(shouldDetectDrag) "
                        + "travel=\(travel.map { String(format: "%.1f", Double($0)) } ?? "?") "
                        + "threshold=\(String(format: "%g", Double(TilingConfig.dragThresholdPx))) "
                        + "drag=\(isDrag)")
                floaterDragged = isDrag && draggedFloatingID != 0
                let release = TiledDragEvent.release(
                    event: event,
                    primaryHeight: primaryHeight,
                    sawDragEvent: isDrag,
                    swapRequested: self.mouseDragLifecycle.releaseRequestsSwap(
                        hyprHeld: self.hyprHeld,
                        optionDown: event.modifierFlags.contains(.option)))
                self.tiledDragHandler.handleMouseUp(release)
                // a click lifts the tile over any floater it overlaps. put the
                // floater back, and redraw the cutouts once the stack settles.
                let press = self.clickPress
                self.clickPress = nil
                if let press, !isDrag, !release.swapRequested {
                    DispatchQueue.main.asyncAfter(deadline: .now() + FloatingWindowController.clickRaiseDelay) { [weak self] in
                        // a new press means a double click; its own mouse-up decides
                        guard let self, self.isRunning, !self.mouseButtonDown else { return }
                        self.floatingController.raiseAfterClick(press)
                    }
                }
                self.scheduleRestackRefresh(after: 0.06)
            }
            self?.mouseDragLifecycle.finishPress()
            self?.mouseTracker.invalidateWindowListCache()
            self?.mouseDownPointCG = nil
            self?.mouseDownFloatingWindowID = 0
            self?.mouseDownFloatingFrame = nil
            if self?.dimDrag != nil {
                self?.dimDrag = nil
                self?.dimmingOverlay.clearDragOverride()
            }
            if draggedFloatingID != 0 {
                let noteDrag = floaterDragged
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                    self?.updatePositionCache()
                    if noteDrag {
                        self?.noteFloaterDrag(draggedFloatingID, from: draggedFloatingFrame)
                    }
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
            // belt-and-suspenders: re-resolve FFM after the click sequence settles.
            // fast click+move-back leaves the cursor stationary post-mouseUp, so no
            // further .mouseMoved fires and FFM gets stuck on whatever the click
            // syncTracker last recorded. force a refocus 200ms later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.mouseTracker.refocusUnderCursor()
            }
        }
    }

    /// Remove every NSEvent monitor installed by `startMouseTracking()` and
    /// clear the drag scratchpad. Idempotent.
    private func stopMouseTracking() {
        mouseDragLifecycle.resetForStop()
        if let m = mouseMoveMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseDownMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseDragMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m) }
        if let m = dragFlagsMonitor { NSEvent.removeMonitor(m) }
        mouseMoveMonitor = nil
        mouseDownMonitor = nil
        mouseDragMonitor = nil
        mouseUpMonitor = nil
        dragFlagsMonitor = nil
        endTiledDropPreview()
        mouseDownPointCG = nil
        mouseDownFloatingWindowID = 0
        mouseDownFloatingFrame = nil
        clickPress = nil
        // teardown can land mid-drag — drop the overlay's override too or a
        // stale carve hole survives until the next full update
        dimDrag = nil
        dimmingOverlay.clearDragOverride()
    }

    /// `true` for a mouse event HyprMac posted itself, such as the hover
    /// path's synthetic click. Those never count as the user's click.
    static func isOwnSyntheticEvent(_ event: NSEvent) -> Bool {
        guard let cg = event.cgEvent else { return false }
        return cg.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
    }

    /// A tile as the focus router and the click re-raise see it: in the
    /// tiled set, not floating, and not a newcomer waiting in admission
    /// recovery (those sit over the tiles like floaters).
    private func isRoutedTile(_ wid: CGWindowID) -> Bool {
        stateCache.tiledPositions[wid] != nil
            && !stateCache.floatingWindowIDs.contains(wid)
            && !admissionRecovery.pendingWindowIDs.contains(wid)
    }

    /// Re-read the stack and redraw what depends on it: the floater
    /// cutouts in the dim and the floater outlines' occlusion.
    ///
    /// Called where z-order can change: after a click's mouse-up, a focused
    /// or main window change, an app activation, a raise-behind or click
    /// re-raise, and the usual focus path. Triggers inside the delay ride
    /// along with the queued refresh, which reads fresh lists when it
    /// fires. Does nothing without a visible floater. Each refresh costs
    /// two window-list reads with the border on (its occlusion reads its
    /// own), one with it off, plus an AX frame read per tile.
    private func scheduleRestackRefresh(after delay: TimeInterval) {
        guard isRunning, !restackRefreshPending,
              config.dimInactiveWindows || config.showFocusBorder,
              stateCache.floatingWindowIDs.contains(where: workspaceManager.isWindowVisible) else { return }
        restackRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.restackRefreshPending = false
            // a press may be a drag, which hides the dim and border itself;
            // its mouse-up schedules another pass. a finishing tiled drag
            // redraws when it settles.
            guard self.isRunning, !self.mouseButtonDown,
                  !self.tiledDragHandler.isFinishingDrag else { return }
            let fid = self.focusBorder.trackedWindowID ?? self.focusController.lastFocusedID
            guard !self.isFullscreenSuppressed(focused: self.stateCache.cachedWindows[fid]) else { return }
            self.mouseTracker.invalidateWindowListCache()
            self.refreshFloatingBorders()
            self.refreshDimming()
        }
    }

    /// Apply focus-follows-mouse to `window`.
    /// Suppresses the dock-click workspace switch for half a second so the
    /// app activation kicked off by the AX focus call doesn't bounce the
    /// user to a different workspace.
    ///
    /// On Tahoe, AX writes + SkyLight + `NSRunningApplication.activate()` are all
    /// silently rejected from a `.accessory` app's mouse-move handler context, so
    /// the usual path adds `focusViaSyntheticClick`, which posts a leftMouseDown/Up
    /// directly into the target process. That path lifts the window. When a
    /// floater covers the target tile, `TiledFocusRouter` first tries SkyLight
    /// alone, checks whether focus landed, and only then falls back.
    private func focusForFFM(_ window: HyprWindow) {
        // while the scratchpad is up, hovering the dimmed tiles behind it
        // must not steal focus — the layer is quasimodal
        if scratchpad.isVisible && !scratchpad.isSummoned(window.windowID) { return }
        suppressions.suppress("activation-switch", for: 0.5)
        tiledFocusRouter.focus(window, reason: "ffm", fallback: .activateAndClick)
        updateFocusBorder(for: window)
    }

    /// Reposition the focus border around `window`, refresh the floating
    /// outlines, and rebuild the dim mask for the new focused window.
    ///
    /// The border and dim paths are independent: each respects its own
    /// config toggle. Disabling the border doesn't disable dim (and vice
    /// versa) — `refreshDimming` always runs and reads
    /// `config.dimInactiveWindows` itself.
    /// `true` when a fullscreen window is currently driving the active Space.
    /// Checks `window` first (commonly the new focus target), falls back to
    /// the active app's focused-window AX query. Results are not cached —
    /// the AX call is one round-trip and `updateFocusBorder` runs on focus
    /// change, not on every frame.
    private func isFullscreenSuppressed(focused window: HyprWindow?) -> Bool {
        if let w = window, w.isFullscreen { return true }
        // also check the AX-reported focused window of the frontmost app;
        // covers cases where `window` is a HyprMac-tracked tile but the
        // user has clicked into a non-tracked fullscreen overlay (some
        // video players spawn a separate fullscreen window).
        if let app = NSWorkspace.shared.frontmostApplication {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            var focusedRaw: AnyObject?
            let err = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &focusedRaw)
            if err == .success, let focusedEl = focusedRaw {
                var fsRaw: AnyObject?
                let fsErr = AXUIElementCopyAttributeValue(focusedEl as! AXUIElement, "AXFullScreen" as CFString, &fsRaw)
                if fsErr == .success, let n = fsRaw as? NSNumber, n.boolValue {
                    return true
                }
            }
        }
        return false
    }

    private func updateFocusBorder(for window: HyprWindow) {
        // suppress all chrome when a fullscreen window is in play — green
        // button, Cmd-Ctrl-F, browser HTML5 fullscreen, fullscreen video.
        // HyprMac panels are .canJoinAllSpaces so they'd otherwise draw on
        // top of the fullscreen content.
        if isFullscreenSuppressed(focused: window) {
            focusBorder.hide()
            focusBorder.hideFloatingBorders()
            focusBrackets.hide()
            dimmingOverlay.hideAll()
            return
        }
        // brackets follow focus changes while Hypr is held (e.g. Hypr+arrow
        // shifts focus mid-press, workspace switch hides the border).
        if hyprHeld, let frame = window.frame {
            focusBrackets.applyAppearance(
                style: config.focusBracketStyle,
                color: config.resolvedFocusBracketColor.cgColor,
                radius: config.resolvedFocusBracketRadius,
                thickness: config.resolvedFocusBracketThickness,
                length: config.resolvedFocusBracketLength)
            focusBrackets.show(around: frame, windowID: window.windowID)
        }
        if config.showFocusBorder, let frame = window.frame {
            focusBorder.accentCGColor = stateCache.floatingWindowIDs.contains(window.windowID)
                ? config.resolvedFloatingBorderColor.cgColor
                : config.resolvedFocusBorderColor.cgColor
            WindowCornerRadius.prime(for: window)
            focusBorder.show(around: frame, windowID: window.windowID)
            // cache-based on both paths — this runs on every FFM focus
            // change, and the floating branch used to re-enumerate the
            // whole desktop. floatingFrames reads live AX frames from the
            // cached windows; a floater created since the last poll gets
            // its outline on the next poll (<1s).
            refreshFloatingBorders()
        } else {
            focusBorder.hidePersistentBorder()
            focusBorder.hideFloatingBorders()
        }
        refreshDimming(focusedID: window.windowID)
    }

    /// Show focus brackets around whichever window `ensureFocus` settled on.
    /// Resolves the focused window via the same chain `refreshDimming` uses
    /// (border-tracked → lastFocused), then pulls the live frame from the
    /// state cache. No-op when no focused window can be resolved or it's
    /// fullscreen-suppressed.
    private func showFocusBracketsForCurrentFocus() {
        let fid = focusBorder.trackedWindowID ?? focusController.lastFocusedID
        guard fid != 0, let window = stateCache.cachedWindows[fid] else { return }
        if isFullscreenSuppressed(focused: window) { return }
        guard let frame = window.frame else { return }
        focusBrackets.applyAppearance(
            style: config.focusBracketStyle,
            color: config.resolvedFocusBracketColor.cgColor,
            radius: config.resolvedFocusBracketRadius,
            thickness: config.resolvedFocusBracketThickness,
            length: config.resolvedFocusBracketLength)
        focusBrackets.show(around: frame, windowID: fid)
    }

    /// Re-show the focus border on the tracked window after the Hypr key is
    /// released. macOS may have re-raised other windows during the chord
    /// (e.g. when the chord triggered an app activation); this re-asserts
    /// the floating-border z-order and refreshes the mask for the focused
    /// window. Runs at 0.05s and 0.25s to catch both fast and slow OS
    /// re-raise paths.
    private func reassertFocusBorderAfterHyprRelease() {
        guard Self.permitsHyprReleaseReassert(
            isRunning: isRunning,
            enabled: config.enabled,
            showFocusBorder: config.showFocusBorder) else { return }
        // cache-based: this fires on every Hypr release and previously ran
        // up to three full-desktop enumerations (one here + two delayed
        // reasserts). the border geometry comes from live frame reads of
        // cached windows either way.
        refreshFloatingBorders()

        guard let tid = focusBorder.trackedWindowID,
              stateCache.floatingWindowIDs.contains(tid) else { return }

        func reassert() {
            guard Self.permitsHyprReleaseReassert(
                isRunning: isRunning,
                enabled: config.enabled,
                showFocusBorder: config.showFocusBorder) else { return }
            if let window = stateCache.cachedWindows[tid] {
                window.isFloating = true
                updateFocusBorder(for: window)
                refreshFloatingBorders()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            reassert()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            reassert()
        }
    }

    static func permitsHyprReleaseReassert(
        isRunning: Bool,
        enabled: Bool,
        showFocusBorder: Bool
    ) -> Bool {
        isRunning && enabled && showFocusBorder
    }

    // scratchpad scrim fill: 4% magenta composited over `intensity` black,
    // flattened to one opaque-alpha color (black rgb is 0, so only magenta
    // contributes color; result alpha is the over-composite of the two).
    private static func scrimFill(intensity: CGFloat) -> NSColor {
        let tintA: CGFloat = 0.04
        let m = NSColor.hyprMagenta.usingColorSpace(.sRGB) ?? .magenta
        let outA = tintA + intensity * (1 - tintA)
        let scale = tintA / outA
        return NSColor(srgbRed: m.redComponent * scale,
                       green: m.greenComponent * scale,
                       blue: m.blueComponent * scale,
                       alpha: outA)
    }

    /// Recompute the dim mask from the live tile positions and the current
    /// floating set, then push the result to `DimmingOverlay`. Called on
    /// focus change and after any tile update so the cutout shape tracks
    /// window moves, resizes, and workspace visibility changes.
    ///
    /// - Parameter focusedID: Override for the "bright" window. Defaults to
    ///   `focusBorder.trackedWindowID`, then `focusController.lastFocusedID`.
    private func refreshDimming(focusedID: CGWindowID? = nil,
                                tiledRectsOverride: [CGWindowID: CGRect]? = nil) {
        // scratchpad scrim: dim every monitor edge-to-edge at .normal level.
        // members are raised ABOVE it at show time (stack recency, not
        // carve-outs), so nothing is carved and member drags never touch the
        // scrim. runs regardless of the dim-inactive-windows setting — the
        // scrim is what makes the layer read as a deliberate surface.
        if scratchpad.isVisible {
            dimmingOverlay.enabled = true
            dimmingOverlay.panelLevel = .normal
            // scrim = 45% black with a faint magenta tint over it, so the
            // summoned floating layer reads as magenta territory. pre-blend
            // 4% magenta over 45% black into one fill color.
            dimmingOverlay.fillOverride = Self.scrimFill(intensity: ScratchpadController.scrimIntensity)
            dimmingOverlay.setIntensity(ScratchpadController.scrimIntensity)
            dimmingOverlay.primaryScreenHeight = displayManager.primaryScreenHeight
            var screenCovers: [CGWindowID: CGRect] = [:]
            for (i, screen) in displayManager.screens.enumerated() {
                screenCovers[CGWindowID(UInt32.max - 1 - UInt32(i))] = displayManager.cgRect(for: screen)
            }
            dimmingOverlay.update(
                focusedID: CGWindowID(UInt32.max),
                tiledRects: screenCovers,
                floatingRects: [:],
                screens: displayManager.screens
            )
            return
        }
        // not in scrim mode — back to pure black focus dim.
        dimmingOverlay.fillOverride = nil
        let fid = focusedID ?? focusBorder.trackedWindowID ?? focusController.lastFocusedID
        let focusedWindow = stateCache.cachedWindows[fid]
        if isFullscreenSuppressed(focused: focusedWindow) {
            dimmingOverlay.hideAll()
            return
        }
        dimmingOverlay.enabled = config.dimInactiveWindows
        dimmingOverlay.panelLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        dimmingOverlay.setIntensity(CGFloat(config.dimIntensity))
        dimmingOverlay.primaryScreenHeight = displayManager.primaryScreenHeight
        let tiles = tiledRectsOverride ?? currentTiledRects()
        let floaters = floatingFrames(from: Array(stateCache.cachedWindows.values), expandedBy: 2)
        dimmingOverlay.update(
            focusedID: fid,
            tiledRects: tiles,
            floatingRects: floaters,
            floatingOccluders: floaterOccluders(floaters, tiles: tiles),
            screens: displayManager.screens
        )
    }

    /// The tiles stacked above each floater, from the window list, so the
    /// dim cuts a floater's hole only where the floater is in front. Reads
    /// the mouse tracker's short-lived list, which the restack refresh drops
    /// first. No floaters, no read.
    private func floaterOccluders(_ floaters: [CGWindowID: CGRect],
                                  tiles: [CGWindowID: CGRect]) -> [CGWindowID: [CGRect]] {
        guard !floaters.isEmpty, config.dimInactiveWindows,
              let windows = mouseTracker.stackedWindows() else { return [:] }
        return WindowStacking.occluders(ofFloaters: floaters, covers: tiles, in: windows)
    }

    /// Read live AX frames for every visible tile before dim or border
    /// computations.
    ///
    /// `stateCache.tiledPositions` only refreshes on poll/retile (the
    /// reconcile timer plus AX / activation / launch notifications). Between those events a window
    /// can resize or move — app self-resize, AX min-size kick-in, manual
    /// drag, pass-2 layout responding to a constraint — and the cache goes
    /// stale. Without the live re-read, `refreshDimming` and the border
    /// occlusion mask triggered by FFM or a click during that gap compute
    /// against the old rect, leaving the new rect partly bright and partly
    /// covered by stale dim (the "half-dim" artifact).
    ///
    /// Cost: one AX query per visible tile, paid on focus change, retile,
    /// and poll completion only.
    ///
    /// Short-TTL memo: a single visual pass (dim + border occlusion, and
    /// the post-retile border reposition) calls this 2-3 times with no
    /// geometry change in between — the memo collapses those to one AX
    /// read per tile. `updatePositionCache` invalidates it at entry so a
    /// pass that follows a retile always re-reads.
    private var tiledRectsMemo: (rects: [CGWindowID: CGRect], at: TimeInterval)?

    private func currentTiledRects() -> [CGWindowID: CGRect] {
        let now = ProcessInfo.processInfo.systemUptime
        if let memo = tiledRectsMemo, now - memo.at < 0.05 {
            return memo.rects
        }
        var rects: [CGWindowID: CGRect] = [:]
        for id in stateCache.tiledPositions.keys {
            if let w = stateCache.cachedWindows[id], let live = w.frame ?? w.cachedFrame {
                rects[id] = live
            } else if let fallback = stateCache.tiledPositions[id] {
                rects[id] = fallback
            }
        }
        tiledRectsMemo = (rects, now)
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
        suppressions.suppress("mouse-focus", for: 0.15)

        // scratchpad is quasimodal: focus belongs to a summoned member. the
        // resolver below is scoped to the cursor's *background* workspace
        // (screenUnderCursor never maps to ws 0), so letting it run would
        // focus — and front — a tile under the cursor, dismissing the layer.
        // just re-assert the current member and stop.
        if scratchpad.isVisible {
            let current = focusBorder.trackedWindowID ?? focusController.lastFocusedID
            if scratchpad.isSummoned(current), let w = stateCache.cachedWindows[current] {
                w.focusWithoutRaise()
                updateFocusBorder(for: w)
            } else {
                scratchpad.refocusMember(reason: "ensureFocus-scratchpad")
            }
            return
        }

        let screen = screenUnderCursor()
        let workspace = workspaceManager.workspaceForScreen(screen)
        let wsWindows = workspaceManager.windowIDs(onWorkspace: workspace)

        // the user switched apps behind our back: Cmd-Tab, a Dock click, an
        // app that opened its own window. the app in front wins over what
        // we remember, when its focused window is a valid target here.
        // within one app AX focus is not trusted (multi-window apps lag
        // and diverge), so only a change of app counts. a bare Hypr press
        // used to activate the remembered window and yank focus back
        if let front = NSWorkspace.shared.frontmostApplication,
           let remembered = stateCache.cachedWindows[focusBorder.trackedWindowID ?? focusController.lastFocusedID],
           front.processIdentifier != remembered.ownerPID,
           let focused = accessibility.getFocusedWindow(),
           focused.ownerPID == front.processIdentifier,
           isSelectableInCurrentContext(focused.windowID, workspaceWindows: wsWindows) {
            hyprLog(.notice, .focus, "ensureFocus: front app changed to \(focused.windowID) — adopting it")
            focusController.recordFocus(focused.windowID, reason: "ensureFocus-frontApp")
            updateFocusBorder(for: focused)
            return
        }

        if let tid = focusBorder.trackedWindowID,
           isSelectableInCurrentContext(tid, workspaceWindows: wsWindows),
           let w = stateCache.cachedWindows[tid] {
            focusController.recordFocus(tid, reason: "ensureFocus-trackedID")
            tiledFocusRouter.focus(w, reason: "ensureFocus", fallback: .activate)
            updateFocusBorder(for: w)
            return
        }

        if focusController.lastFocusedID != 0,
           isSelectableInCurrentContext(focusController.lastFocusedID, workspaceWindows: wsWindows),
           let w = stateCache.cachedWindows[focusController.lastFocusedID] {
            tiledFocusRouter.focus(w, reason: "ensureFocus", fallback: .activate)
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
                focusController.recordFocus(wid, reason: "ensureFocus-tiled")
                tiledFocusRouter.focus(w, reason: "ensureFocus", fallback: .activate)
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
            focusController.recordFocus(wid, reason: "ensureFocus-fallback")
            tiledFocusRouter.focus(w, reason: "ensureFocus", fallback: .activate)
            updateFocusBorder(for: w)
        }
    }

    // MARK: - action dispatch

    /// Hand an `Action` to the dispatcher. Wrapped here so the hotkey
    /// callback site stays terse and so subclasses or tests can intercept
    /// in one place. Also called from the menu bar (cheat-sheet row).
    func handleAction(_ action: Action) {
        // the menu bar calls in here too, and nobody reaches it while locked
        discovery.endSessionInterruption(evidence: "action")
        if action == .showWorkspaceOverview {
            let overview = workspaceOverviewSnapshots()
            workspaceOverview.toggle(snapshots: overview.workspaces, scratchpad: overview.scratchpad)
            return
        }
        if Self.cancelsPendingRecovery(action) {
            admissionRecovery.cancelAll(reason: "later press")
        }
        // workspace flows park/unpark and then focus+warp. mid-display-
        // transition the tile pass is deferred, so the target workspace
        // would stay parked with the cursor warped to the 1px park sliver.
        // drop them for the settle window (a few seconds around wake).
        if displayTransitionPending, Self.isDroppedMidDisplayTransition(action) {
            hyprLog(.notice, .lifecycle, "workspace action dropped mid-display-transition")
            return
        }
        // workspace flows dismiss the scratchpad first (Hyprland-style: the
        // layer never survives a workspace change), then run normally —
        // their own focus/warp supersedes any restore. float-toggle and
        // floater-cycle get scratchpad semantics while the layer is up:
        // toggling a member into the dimmed workspace's tree, or cycling
        // into invisible floaters under the scrim, both read as broken.
        if scratchpad.isVisible {
            switch action {
            case .moveToWorkspace, .moveToWorkspaceAndFollow, .moveWindowToMonitor:
                // move a summoned member OUT to another workspace/monitor:
                // eject it into tiling on the current monitor first (leaves
                // it unfloated + focused + the layer dismissed), then let the
                // normal move flow relocate it. non-member focus just dismisses.
                if !scratchpad.ejectFocusedWindow() {
                    scratchpad.hide(reason: .workspaceAction)
                }
            case .switchWorkspace, .cycleWorkspace:
                scratchpad.hide(reason: .workspaceAction)
            case .moveToNextEmptyWorkspace:
                NSSound.beep()
                return
            case .toggleFloating:
                // Hypr+T on a summoned member toggles it tiled<->floating
                // within the layer (membership stays sticky — only Shift+S /
                // Shift+N take a member out). while the layer is up only a
                // member can be the focused window, so the send below only
                // beeps when there is none.
                if scratchpad.toggleTilingOfFocusedMember() { return }
                scratchpad.sendFocusedWindow()
                return
            case .focusFloating:
                scratchpad.cycleSummoned()
                return
            case .launchApp(let bundleID):
                // an app with a member up: focus the member. activating the
                // app would bring its other windows forward over the scrim
                if scratchpad.focusMember(ofBundleID: bundleID) { return }
            default:
                break
            }
        }
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

        // windows on re-enabled monitors: unfloat and let the reconcile pick them up
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

        // enable/disable shifts every workspace's static home (the modulo
        // formula counts enabled screens) — reconcile preserves workspace
        // assignments instead of redistributing everything.
        reconcileAfterDisplayChange()
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
    /// Called from `start()` after the initial AX-settle delay, from
    /// menu-driven "Retile All", and on max-splits config changes. NOT
    /// called on screen parameter changes — `reconcileAfterDisplayChange`
    /// handles those without rewriting workspace assignments.
    @discardableResult
    func snapshotAndTile() -> [HyprWindow] {
        let allWindows = accessibility.getAllWindows()
        classifyAndAssign(allWindows)
        distributeWindowsAcrossWorkspaces(allWindows)
        tileAllVisibleSpaces()
        return allWindows
    }

    /// Classification half of the snapshot: capture original frames,
    /// register ownership, auto-float excluded apps and disabled-monitor
    /// windows, and assign unassigned windows to their physical screen's
    /// active workspace. Idempotent — already-known windows keep their
    /// state and workspace assignment.
    private func classifyAndAssign(_ allWindows: [HyprWindow]) {
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
                stateCache.floatingWindowIDs.insert(w.windowID)
                w.isFloating = true
                hyprLog(.debug, .lifecycle, "auto-float \(reason.rawValue): '\(w.title ?? "?")'")
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
    }

    /// Non-destructive reaction to a monitor topology change.
    ///
    /// Unlike `snapshotAndTile`, workspace assignments and the floating
    /// set are preserved: `initializeMonitors` remaps which workspace is
    /// visible per screen, `handleDisplayChange` migrates BSP trees to
    /// each workspace's current home, hidden-workspace windows are
    /// re-parked (the global park corner moves when the rightmost
    /// monitor changes), and visible workspaces retile onto their homes.
    /// The previous behavior — full `snapshotAndTile` with
    /// `distributeWindowsAcrossWorkspaces` — rewrote every window's
    /// workspace assignment and un-floated manual floats on every
    /// monitor connect/disconnect.
    private func reconcileAfterDisplayChange(restoreSavedLayout: Bool = false) {
        // every pending recovery captured a screen that may no longer own
        // its workspace
        admissionRecovery.cancelAll(reason: "display change")
        driftMonitor.reset()
        minimaRevalidation.cancelAll(reason: "display change")
        workspaceManager.initializeMonitors()
        tilingEngine.handleDisplayChange(
            currentScreens: displayManager.screens,
            homeScreenForWorkspace: { [weak self] ws in
                self?.workspaceManager.homeScreenForWorkspace(ws)
            }
        )
        let allWindows = accessibility.getAllWindows()
        classifyAndAssign(allWindows)
        reparkHiddenWorkspaceWindows(allWindows)
        tileAllVisibleSpaces(windows: allWindows)
        // a known display configuration came back — put windows on the
        // workspaces the saved layout had them on. only the settled
        // reconcile asks for this: the Settings monitor toggle reuses the
        // reconcile under an unchanged key and must not undo itself.
        if restoreSavedLayout {
            restoreLayoutSnapshot(manual: false, windows: allWindows)
        }
    }

    // MARK: - layout snapshots

    /// Serialise every regular workspace's tree under `displayKey`
    /// (default: the current topology). Floaters, scratchpad members, and
    /// windows without a workspace are in no tree, so they are never saved.
    ///
    /// - Returns: `false` when nothing was saved — no tiled windows, an
    ///   automatic save yielding to a manual snapshot, or a failed write.
    @discardableResult
    private func saveLayoutSnapshot(manual: Bool, displayKey: String? = nil) -> Bool {
        let key = displayKey ?? LayoutSnapshotStore.displayKey(screens: displayManager.screens)
        let workspaces = layoutRestorer.capture()
        guard !workspaces.isEmpty else {
            hyprLog(.debug, .lifecycle, "layout save skipped — no tiled windows for '\(key)'")
            if manual { showLayoutHUD(title: "Nothing to save", detail: "No tiled windows", failed: true) }
            return false
        }
        do {
            let saved = try layoutStore.save(displayKey: key, workspaces: workspaces, manual: manual)
            if manual {
                let count = workspaces.reduce(0) { $0 + $1.refs.count }
                showLayoutHUD(title: "Saved", detail: "\(count) window\(count == 1 ? "" : "s")", failed: false)
            }
            return saved
        } catch {
            if manual { showLayoutHUD(title: "Couldn't save", detail: "The snapshot file couldn't be written", failed: true) }
            return false
        }
    }

    /// Bring back the saved layout for the current topology through
    /// `LayoutRestorer`, then log the outcome and, for a manual restore,
    /// say whether it was complete, partial, or failed.
    ///
    /// - Parameter windows: pre-fetched window list; AX is queried when nil.
    /// - Returns: `false` when there is no snapshot for this topology.
    @discardableResult
    private func restoreLayoutSnapshot(manual: Bool, windows: [HyprWindow]? = nil) -> Bool {
        let key = LayoutSnapshotStore.displayKey(screens: displayManager.screens)
        let snapshot = layoutStore.snapshot(for: key)
        let allWindows = snapshot == nil ? [] : (windows ?? accessibility.getAllWindows())
        let outcome = layoutRestorer.restore(snapshot, windows: allWindows)
        if !outcome.rebuilt.isEmpty { updatePositionCache(windows: allWindows) }

        hyprLog(outcome.hasSnapshot ? .notice : .debug, .lifecycle,
                "layout restore '\(key)' (\(manual ? "manual" : "auto")): \(outcome.logSummary)")
        if manual {
            let hud = outcome.hud
            showLayoutHUD(title: hud.title, detail: hud.detail, failed: hud.failed)
        }
        return outcome.hasSnapshot
    }

    private var layoutRestorer: LayoutRestorer {
        LayoutRestorer(
            engine: tilingEngine, orchestrator: workspaceOrchestrator,
            workspaceManager: workspaceManager, stateCache: stateCache,
            recovery: admissionRecovery,
            isScratchpad: { [scratchpad] in scratchpad.contains($0) },
            ref: { [weak self] in self?.windowRef(for: $0) })
    }

    private func windowRef(for window: HyprWindow) -> SavedWindowRef? {
        guard let bundleID = NSRunningApplication(processIdentifier: window.ownerPID)?.bundleIdentifier,
              !bundleID.isEmpty else { return nil }
        return SavedWindowRef(bundleID: bundleID, title: SavedWindowRef.normalizedTitle(window.title ?? ""))
    }

    /// Same HUD as a workspace switch, on the screen under the cursor.
    /// Manual save/restore only — the automatic paths stay silent.
    private func showLayoutHUD(title: String, detail: String?, failed: Bool) {
        let mouse = NSEvent.mouseLocation
        let screens = displayManager.screens.filter { !workspaceManager.isMonitorDisabled($0) }
        guard let screen = screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? screens.first else { return }
        workspaceOverview.showStatusHUD(caption: "LAYOUT", title: title, detail: detail,
                                        failed: failed, screen: screen)
    }

    /// Re-park every window assigned to a hidden workspace at the current
    /// global hide position. After a monitor connect/disconnect the
    /// rightmost screen — and with it the park corner — can move; windows
    /// left at the old corner would sit fully visible mid-screen (or on a
    /// dead coordinate) while their workspace is still hidden.
    private func reparkHiddenWorkspaceWindows(_ allWindows: [HyprWindow]) {
        for w in allWindows {
            guard let ws = workspaceManager.workspaceFor(w.windowID),
                  !workspaceManager.isWorkspaceVisible(ws),
                  let screen = workspaceManager.homeScreenForWorkspace(ws) ?? displayManager.screens.first
            else { continue }
            workspaceManager.hideInCorner(w, on: screen)
        }
    }

    /// Tile each enabled screen's active workspace with the windows
    /// assigned to it.
    ///
    /// Refreshes the position cache after applying frames so the menu bar
    /// indicator and dim mask track the new layout.
    ///
    /// - Parameter windows: Pre-fetched window list. When `nil`, AX is
    ///   re-queried. Callers that already have a fresh list pass it to
    ///   avoid the round trip.
    @discardableResult
    func tileAllVisibleSpaces(windows: [HyprWindow]? = nil) -> [TilingEngine.AdmissionResult] {
        // mid-display-transition, screens carry new origins but trees haven't
        // migrated — tiling now creates fresh empty trees at the new keys and
        // batch-inserts everything in snapshot order, and that duplicate then
        // wins the migration over the real tree. reconcile retiles when the
        // topology settles.
        if displayTransitionPending {
            retileSkippedDuringTransition = true
            hyprLog(.notice, .lifecycle, "retile deferred mid-display-transition")
            return []
        }
        let allWindows = windows ?? accessibility.getAllWindows()
        tilingEngine.primeMinimumSizes(allWindows)

        for w in allWindows {
            if stateCache.floatingWindowIDs.contains(w.windowID) {
                w.isFloating = true
            }
        }

        // for each enabled monitor, tile the windows that belong to its active workspace
        var results: [TilingEngine.AdmissionResult] = []
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
            // members this walk could not read keep their leaves: the window
            // server still shows them, so the slot is theirs, and no frame
            // goes out to an app that is not answering. the poll retiles the
            // key once they read again. discovery's own holds — a window off
            // the screen its app still lists — keep their leaves the same
            // way, unless this walk has the window back
            let held = accessibility.unreadableWindowIDs.union(discovery.heldWindowIDs)
                .intersection(widsOnWorkspace)
                .subtracting(workspaceWindows.map(\.windowID))
                .subtracting(stateCache.floatingWindowIDs)
                .subtracting(stateCache.hiddenWindowIDs)
            if !held.isEmpty {
                hyprLog(.notice, .lifecycle, "retile: ws\(workspace) holds \(held.sorted()) — leaves kept, no frame written")
            }
            // a workspace being shown is where an explicit move to a hidden
            // destination finally gets its one attempt. the marker is spent
            // on this pass whatever it says.
            results.append(tilingEngine.withHeldWindows(held) {
                admissionPass.run(workspaceWindows, onWorkspace: workspace, screen: screen)
            })
        }

        updatePositionCache(windows: allWindows)
        // a workspace that just became visible is new evidence about any
        // newcomer parked on it
        offerRecoveryEvidence()
        return results
    }

    /// Retile with a slide animation between old and new tile rects.
    ///
    /// Run `prepare`, retile every visible workspace, run `completion`.
    /// Animations were stripped — this is now just a sequenced retile.
    /// Name kept so existing call sites compile unchanged.
    @discardableResult
    private func animatedRetile(
        windows: [HyprWindow]? = nil,
        prepare: (() -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) -> [TilingEngine.AdmissionResult] {
        prepare?()
        let results = tileAllVisibleSpaces(windows: windows)
        completion?()
        return results
    }

    /// Spread every tiling-eligible window across workspaces so no single
    /// workspace is forced past its dwindle depth.
    ///
    /// Workspaces fill in numeric order, with each workspace's capacity
    /// derived from its statically anchored monitor. Anything that does not
    /// fit even in the ninth workspace is auto-floated. Called once at
    /// startup and from "Retile All" so a fresh launch with many windows
    /// produces a compact layout instead of piling everything on one screen.
    private func distributeWindowsAcrossWorkspaces(_ allWindows: [HyprWindow]) {
        hyprLog(.notice, .lifecycle, "distributeWindowsAcrossWorkspaces ENTER — full redistribute about to run (this rewrites workspace assignments)")
        let screens = displayManager.screens.filter { !workspaceManager.isMonitorDisabled($0) }
            .sorted { $0.frame.origin.x < $1.frame.origin.x }
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

        // any remaining (all 9 workspaces full) — auto-float
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
        let screen = screenUnderCursor()
        let workspace = workspaceManager.workspaceForScreen(screen)
        let wsWindows = workspaceManager.windowIDs(onWorkspace: workspace)
        let bid = focusBorder.trackedWindowID ?? 0
        let lid = focusController.lastFocusedID

        if let tid = focusBorder.trackedWindowID,
           isSelectableInCurrentContext(tid, workspaceWindows: wsWindows),
           let w = stateCache.cachedWindows[tid] {
            hyprLog(.debug, .focus, "currentFocused → border=\(tid) ws=\(workspace) screen=\(screen.localizedName) (border=\(bid) last=\(lid))")
            return w
        }

        if focusController.lastFocusedID != 0,
           isSelectableInCurrentContext(focusController.lastFocusedID, workspaceWindows: wsWindows),
           let w = stateCache.cachedWindows[focusController.lastFocusedID] {
            hyprLog(.debug, .focus, "currentFocused → last=\(focusController.lastFocusedID) ws=\(workspace) screen=\(screen.localizedName) (border=\(bid) last=\(lid))")
            return w
        }

        if let focused = accessibility.getFocusedWindow(),
           isSelectableInCurrentContext(focused.windowID, workspaceWindows: wsWindows) {
            hyprLog(.debug, .focus, "currentFocused → ax=\(focused.windowID) ws=\(workspace) screen=\(screen.localizedName) (border=\(bid) last=\(lid))")
            return focused
        }

        // nothing focused inside the layer: act on its most recent member
        if let member = scratchpad.focusTarget {
            hyprLog(.debug, .focus, "currentFocused → scratchpad member=\(member.windowID) (border=\(bid) last=\(lid))")
            return member
        }

        hyprLog(.debug, .focus, "currentFocused → nil ws=\(workspace) screen=\(screen.localizedName) (border=\(bid) last=\(lid))")
        return nil
    }

    /// `true` when `id` may take focus now. While the scratchpad is up only
    /// its summoned members do; the workspace under the scrim is out.
    private func isInteractive(_ id: CGWindowID) -> Bool {
        scratchpad.isVisible ? scratchpad.isSummoned(id) : workspaceManager.isWindowVisible(id)
    }

    /// `true` when `windowID` is a valid focus target right now: either
    /// assigned to the cursor's workspace or a visible floating window.
    private func isSelectableInCurrentContext(_ windowID: CGWindowID, workspaceWindows: Set<CGWindowID>) -> Bool {
        // a summoned scratchpad member is a valid target while the layer is up,
        // whether floating or tiled-within-the-layer. tiled members aren't in
        // floatingWindowIDs, so without this the untile (Hypr+T) resolver
        // can't find them and the toggle silently no-ops.
        // and while it's up nothing else is: the workspace under the scrim is out
        if scratchpad.isVisible { return scratchpad.isSummoned(windowID) }
        if workspaceWindows.contains(windowID) { return true }
        return stateCache.floatingWindowIDs.contains(windowID) && workspaceManager.isWindowVisible(windowID)
    }

    /// Accept the verified mouse-down frame batch. Also note the floating
    /// window under the click (if any) — and its frame — so the
    /// drag monitor knows to hide that floater's border for the drag
    /// duration and the dim carve can anchor to a consistent pair.
    private func acceptTiledDragCapture(_ frames: [CGWindowID: CGRect]) {
        mouseDownFloatingWindowID = 0
        mouseDownFloatingFrame = nil
        guard let point = mouseDownPointCG else { return }
        let hits = frames.filter {
            stateCache.floatingWindowIDs.contains($0.key) && $0.value.contains(point)
        }
        guard hits.count == 1, let hit = hits.first else { return }
        mouseDownFloatingWindowID = hit.key
        mouseDownFloatingFrame = hit.value
    }

    /// One notice line per floater drag, read once the drop has settled,
    /// and a second one if the frame is still changing a second later.
    /// HyprMac writes no frame for a plain floater drag, so a size change
    /// here came from the app or macOS. Any frame HyprMac writes to a
    /// floater logs its own `floating frame write:` line.
    private func noteFloaterDrag(_ id: CGWindowID, from start: CGRect?, settled: Bool = false) {
        guard let window = stateCache.cachedWindows[id], let frame = window.frame else { return }
        let destination = displayManager.screen(containingMostOf: frame)
        let fits = destination.map { frame.clamped(into: displayManager.cgRect(for: $0)) == frame } ?? false
        let resized = start.map { abs($0.width - frame.width) > 1 || abs($0.height - frame.height) > 1 }
        let startText = start.map {
            FloatingFramePlacement.describe($0) + " on "
                + FloatingFramePlacement.describe(displayManager.screen(containingMostOf: $0))
        } ?? "unread"
        hyprLog(.notice, .floating, "floater drag\(settled ? " +1s" : ""): wid=\(id)"
                + " from=\(startText)"
                + " to=\(FloatingFramePlacement.describe(frame))"
                + " on \(FloatingFramePlacement.describe(destination))"
                + " resized=\(resized.map(String.init) ?? "unknown") fitsUsable=\(fits)")
        guard !settled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let later = self.stateCache.cachedWindows[id]?.frame,
                  later != frame else { return }
            self.noteFloaterDrag(id, from: start, settled: true)
        }
    }

    private func visibleFloatingWindows() -> [HyprWindow] {
        stateCache.floatingWindowIDs.compactMap { id in
            guard isInteractive(id) else { return nil }
            return stateCache.cachedWindows[id]
        }
    }

    /// Arm the live dim-carve override if the press landed on a visible
    /// ordinary floating window and dim is active (normal mode). Reuses the
    /// hit AND the frame read by verified tiled-drag capture — no new AX
    /// queries. The anchor pair must be sampled consistently: the frame
    /// from the mouse-down enumeration with the event's click point. A
    /// fresh `w.frame` here still reports the pre-drag position (Tahoe AX
    /// reads lag) while a live cursor read is already mid-flick — that
    /// mismatch permanently offset the carve by the initial flick distance.
    private func armDimDragIfFloating(downPointNS: NSPoint) {
        dimDrag = nil
        guard config.dimInactiveWindows, !scratchpad.isVisible,
              mouseDownFloatingWindowID != 0 else { return }
        let id = mouseDownFloatingWindowID
        guard let w = stateCache.cachedWindows[id] else { return }
        guard let frame = mouseDownFloatingFrame ?? w.frame else { return }

        let downCG = CGPoint(x: downPointNS.x, y: displayManager.primaryScreenHeight - downPointNS.y)
        dimDrag = DimDragState(id: id, window: w, startFrame: frame, downPointCG: downCG)
    }

    /// Push the live carve rect for the armed floater.
    ///
    /// Confirmation gate: the carve holds still until an AX read sees the
    /// window's origin actually moving under this press. Content drags (text
    /// selection, scrollbar, a click on a window merely overlapping this
    /// floater's frame) never move the window, so they never confirm and the
    /// cursor can't pull the carve off a stationary window.
    ///
    /// Once confirmed, tracking is pure delta math off the MOUSE-DOWN anchor
    /// pair (`startFrame` + `downPointCG`) — not the position that confirmed.
    /// The confirming AX read lags a fast drag; the down-event pair is exact,
    /// so the carve lands on the window's true position regardless of how far
    /// the flick outran AX. No AX reads remain in the confirmed-move hot path.
    /// A throttled size probe flips to live-frame reads once a resize is
    /// detected (delta math can't model resizes).
    private func updateDimDrag() {
        guard var drag = dimDrag else { return }
        let mouseNS = NSEvent.mouseLocation
        let curCG = CGPoint(x: mouseNS.x, y: displayManager.primaryScreenHeight - mouseNS.y)

        // resize probe (~10Hz) runs confirmed or not: a left/top-edge resize
        // moves the origin too and would otherwise confirm as a move and
        // delta-track with a frozen size.
        if !drag.resizing {
            let now = ProcessInfo.processInfo.systemUptime
            if now - drag.lastSizeCheck > 0.1 {
                drag.lastSizeCheck = now
                if let sz = drag.window.size,
                   abs(sz.width - drag.startFrame.width) > 2 ||
                   abs(sz.height - drag.startFrame.height) > 2 {
                    drag.resizing = true
                    drag.confirmed = true
                }
            }
        }

        if !drag.confirmed {
            // per-event position probe until confirmed — a real drag confirms
            // within the first couple events, a content drag keeps the carve
            // parked. 3px guard clears AX position noise so a stationary
            // window never false-confirms.
            if let pos = drag.window.position,
               hypot(pos.x - drag.startFrame.origin.x, pos.y - drag.startFrame.origin.y) > 3 {
                drag.confirmed = true
            } else {
                // window hasn't moved: the carve stays where the last full
                // update painted it (on the window). nothing to stamp.
                dimDrag = drag
                return
            }
        }

        let liveRect: CGRect
        if drag.resizing {
            liveRect = drag.window.frame ?? drag.startFrame
        } else {
            liveRect = drag.startFrame.offsetBy(dx: curCG.x - drag.downPointCG.x,
                                                dy: curCG.y - drag.downPointCG.y)
        }
        dimDrag = drag
        // match floatingFrames(expandedBy: 2): negative inset enlarges
        dimmingOverlay.setDragOverride(id: drag.id, rect: liveRect.insetBy(dx: -2, dy: -2))
    }

    /// Hit-test the click point against floating and tiled windows and
    /// record the result in `focusController`. Called from `leftMouseDown`
    /// so a manual click wins over any stale FFM tracker state — without
    /// this, commands routed via `currentFocusedWindow()` would target the
    /// previously-hovered window instead of what the user just clicked.
    /// Takes the event's click location so a fast post-click drag can't
    /// move the hit test off the clicked window, and the window-list hit at
    /// that point, which knows when a tile has buried a floater.
    private func syncFocusTrackerToCursor(at mouseNS: NSPoint, hit: WindowStacking.Hit) {
        let cgY = displayManager.primaryScreenHeight - mouseNS.y
        let cgPoint = CGPoint(x: mouseNS.x, y: cgY)

        // floaters and newcomers in explicit recovery are both drawn over
        // the tiles, so both are hit-tested before the tiled rects
        let overlayIDs = stateCache.floatingWindowIDs.union(admissionRecovery.pendingWindowIDs)
        let overlayFrames = overlayIDs.sorted().compactMap { wid -> (id: CGWindowID, frame: CGRect)? in
            guard workspaceManager.isWindowVisible(wid),
                  let frame = stateCache.cachedWindows[wid]?.frame else { return nil }
            return (wid, frame)
        }
        var stackHit: CGWindowID?
        if case .window(let wid) = hit { stackHit = wid }
        guard let target = Self.clickFocusTarget(at: cgPoint, overlayFrames: overlayFrames,
                                                 tiledPositions: stateCache.tiledPositions,
                                                 recoveryIDs: admissionRecovery.pendingWindowIDs,
                                                 stackHit: stackHit) else { return }
        focusController.recordFocus(target.id, reason: target.reason)
    }

    /// Whether a settled display change should restore the saved layout.
    /// Only a different display set does: a Dock resize, an arrangement
    /// drag, or a primary-display change keeps the key, and restoring there
    /// would undo whatever the user arranged since the last save.
    static func restoresAfterSettle(from departedKey: String, to settledKey: String) -> Bool {
        departedKey != settledKey
    }

    /// Actions that wait out a display transition. Save and restore are in
    /// here too: mid-transition the topology key and the trees are both in
    /// flux, so a save would file a half-migrated layout and a restore would
    /// be undone by the settle reconcile.
    static func isDroppedMidDisplayTransition(_ action: Action) -> Bool {
        switch action {
        case .switchWorkspace, .moveToWorkspace, .moveToWorkspaceAndFollow, .moveWindowToMonitor,
             .cycleWorkspace, .moveToNextEmptyWorkspace, .saveLayout, .restoreLayout, .retileAll:
            return true
        default:
            return false
        }
    }

    /// Whether `action` makes an armed admission retry stale.
    ///
    /// Whatever the user just asked for is newer than a retry armed off a
    /// layout they have already moved past. Focus and informational actions
    /// preserve recovery, as does showing the workspace a newcomer has been waiting
    /// for, and forgetting it here would hand it a fresh timer on the reveal
    /// retile instead of its one remaining attempt.
    ///
    /// Resize, swap and split toggle preserve it too. They only rework the
    /// live tree, which never holds a stranded window, so nothing they do
    /// gives it another attempt: a move to a visible workspace followed by a
    /// quick resize used to leave the window assigned, in no tree, and with
    /// nothing scheduled.
    static func cancelsPendingRecovery(_ action: Action) -> Bool {
        switch action {
        case .switchWorkspace, .cycleWorkspace, .focusDirection, .focusFloating,
             .focusMenuBar, .showKeybinds, .showWorkspaceOverview, .launchApp,
             .runCommand, .saveLayout, .resizeDirection, .swapDirection, .toggleSplit:
            return false
        default: return true
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
        admissionRecovery.forget(id)
        minimaRevalidation.forget(id)
        driftMonitor.forget(id)
        tilingEngine.forgetMinimumSize(windowID: id)
        workspaceManager.removeWindow(id)
        scratchpad.forget(id)
        if focusController.lastFocusedID == id {
            focusController.recordFocus(0, reason: "forgetWindow")
        }
        if focusBorder.trackedWindowID == id {
            focusBorder.hide()
            // the scrim stays: re-shown later it would come back above the members
            if !scratchpad.isVisible { dimmingOverlay.hideAll() }
        }
        focusBorder.hideFloatingBorder(for: id)
        WindowCornerRadius.forget(id)
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
        tiledRectsMemo = nil // geometry may have changed — force live re-reads
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
        // brackets follow the same window if visible (Hypr held during retile)
        if focusBrackets.isVisible, let bid = focusBrackets.trackedWindowID,
           let w = stateCache.cachedWindows[bid], let frame = w.frame {
            focusBrackets.updatePosition(frame)
        }
        refreshDimming()
    }

    /// Recompute floater frames and push them into the focus border. Each
    /// floater gets a persistent outline at the floating border color so
    /// the user can spot a floater that ended up behind a tile.
    private func refreshFloatingBorders(windows: [HyprWindow]? = nil) {
        if config.showFocusBorder {
            let source = windows ?? Array(stateCache.cachedWindows.values)
            var frames = floatingFrames(from: source)
            // prime the radius cache for each visible floater so the
            // bundle-id override table applies (otherwise resolve()
            // falls back to osDefault for every floating window).
            // while the scratchpad is up, ordinary floaters sit beneath the
            // scrim — their border panels (at .floating level) would glow
            // above it. only members get outlines.
            if scratchpad.isVisible {
                frames = frames.filter { scratchpad.isSummoned($0.key) }
            }
            for w in source where frames[w.windowID] != nil {
                WindowCornerRadius.prime(for: w)
            }
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

    /// Publish workspace glyphs and monitor snapshots for the menu.
    private func updateMenuBarState() {
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

    private func workspaceOverviewSnapshots() -> (workspaces: [WorkspaceSnapshot], scratchpad: [WorkspaceWindowSnapshot]) {
        let active = Set(activeWorkspaces())
        let currentWindows = Dictionary(accessibility.getAllWindows().map { ($0.windowID, $0) },
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

    // MARK: - poll

    /// Run a single discovery diff and hand the result to the dispatcher's
    /// apply-loop.
    ///
    /// Drops the poll entirely when a mouse button is down (the user is
    /// dragging or clicking through controls; window state is mid-transition).
    /// Once `applyChanges` is called, the apply-loop runs unconditionally.
    ///
    /// Coalesced with notification-driven schedules by `PollingScheduler`,
    /// which stays suppressed until verified drag completion finishes.
    private func pollWindowChanges() {
        // mouse-down is handled by the scheduler's isSuppressed closure so
        // event polls defer instead of dropping; this guard only backstops
        // a hypothetical direct call landing mid-drag.
        guard !mouseButtonDown else { return }

        let allWindows = accessibility.getAllWindows()
        let now = Date()
        let gap = lastPollAt.map { "\(Int(now.timeIntervalSince($0) * 1000))ms since last" } ?? "first poll"
        lastPollAt = now
        hyprLog(.debug, .discovery, "poll: \(allWindows.count) windows, \(gap)")
        // add window-level AX subscriptions (destroy / miniaturize) for any
        // new windows in this snapshot — deduped by CGWindowID inside.
        axNotifications.ensureWindowSubscriptions(for: allWindows)
        tilingEngine.primeMinimumSizes(allWindows)
        let runningPIDs = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
        // owners as of before the diff — computeChanges forgets closed ids
        let ownersBefore = stateCache.windowOwners

        let changes = discovery.computeChanges(
            snapshot: allWindows,
            runningPIDs: runningPIDs,
            excludedBundleIDs: Set(config.excludedBundleIDs),
            focusedWindowID: focusController.lastFocusedID,
            unreadableWindowIDs: accessibility.unreadableWindowIDs
        )
        // locked or asleep: this snapshot is not the desktop. a drift
        // re-apply or a recovery attempt from it would lay the trees out
        // without the windows it is missing
        if changes.heldForInterruption { return }
        let retileResults = actionDispatcher.applyChanges(changes, allWindows: allWindows)
        // a member a tile pass held out because its app did not answer gets
        // its frame once the app does. a retile this poll already wrote it
        var retiled = changes.needsRetile
        let released = tilingEngine.releaseHeldWindows(readable: Set(allWindows.map(\.windowID)))
        if !released.isEmpty, !retiled {
            hyprLog(.notice, .discovery, "held windows readable again: \(released.sorted()) — retiling")
            animatedRetile(windows: allWindows)
            retiled = true
        }
        // a poll is the real event that says a window came back, became
        // readable, or went away — the only thing that can unblock a
        // recovery waiting on evidence
        offerRecoveryEvidence()
        // a retile already rewrote every frame on the affected keys, so the
        // frames in this snapshot are what it replaced. drift is the
        // question for a poll that changed nothing.
        if !retiled { applyTiledDrift(allWindows) }
        repairParkedWindows(allWindows)
        reconcileTiledDragFeedback(with: retileResults, allWindows: allWindows)
        // a guarded cycle diffed nothing, so it can't have seen the close —
        // don't spend a recheck attempt on it, and don't let the slower
        // destroy re-poll coalesce away the prompt one.
        if changes.requestsRecheck {
            // a real mass close is delayed by this, a partial snapshot gets
            // the time it needs to fill in. at 0.1 s the three skips the
            // guard allows were over in a third of a second
            pollingScheduler.schedule(after: 0.5)
        } else if destroyRecheck.resolve(goneIDs: changes.goneIDs, ownersBefore: ownersBefore,
                                         runningPIDs: runningPIDs) {
            hyprLog(.debug, .discovery, "destroy recheck: closed window not yet gone from the snapshot — re-polling")
            pollingScheduler.schedule(after: DestroyRecheck.delay)
        }
    }

    /// Same-screen drift: hand this poll's tiled frames to the monitor and
    /// carry out whatever it decides.
    ///
    /// Only members of a published tree on a visible workspace are offered.
    /// `intendedTileRects` omits an unverified key whole, so a window whose
    /// geometry the engine cannot speak for never produces a reading, and
    /// the scratchpad layer is skipped outright — its rects come from the
    /// layer region, not the screen.
    private func applyTiledDrift(_ allWindows: [HyprWindow]) {
        let intended = tilingEngine.intendedTileRects()
        guard !intended.isEmpty else { return }
        var readings: [TiledDriftReading] = []
        for window in allWindows {
            guard let workspace = workspaceManager.workspaceFor(window.windowID),
                  workspace != ScratchpadController.workspace,
                  workspaceManager.isWorkspaceVisible(workspace),
                  !isFloating(window.windowID),
                  let rect = intended[window.windowID],
                  let screen = workspaceManager.homeScreenForWorkspace(workspace),
                  let actual = window.cachedFrame ?? window.frame
            else { continue }
            readings.append(TiledDriftReading(windowID: window.windowID, workspace: workspace,
                                              screen: screen, actual: actual, intended: rect))
        }

        for decision in driftMonitor.note(readings) {
            switch decision {
            case let .reapply(workspace, screen, _):
                reapplyLayout(onWorkspace: workspace, screen: screen)
            case let .abandon(workspace, screen, windowID):
                tilingEngine.markUnverifiedGeometry(
                    forWorkspace: workspace, screen: screen,
                    reason: "\(windowID) drifted again after its one re-apply")
            }
        }
    }

    /// Floating by either store. The fresh window objects a poll builds
    /// carry no flag of their own, so asking one is asking nothing; the
    /// recovery and the revalidation ask the same question this way.
    private func isFloating(_ id: CGWindowID) -> Bool {
        stateCache.floatingWindowIDs.contains(id)
            || (stateCache.cachedWindows[id]?.isFloating ?? false)
    }

    /// One ordinary verified layout pass for a key whose windows drifted.
    /// Nothing special: the same path a retile takes, down to the
    /// bookkeeping, so a refusal rolls back, marks the key, and hands
    /// whatever it stranded to the recovery exactly as it always would.
    private func reapplyLayout(onWorkspace workspace: Int, screen: NSScreen) {
        let allWindows = accessibility.getAllWindows()
        tilingEngine.primeMinimumSizes(allWindows)
        for w in allWindows where stateCache.floatingWindowIDs.contains(w.windowID) {
            w.isFloating = true
        }
        let assigned = workspaceManager.windowIDs(onWorkspace: workspace)
        let windows = allWindows.filter { assigned.contains($0.windowID) }
        admissionPass.run(windows, onWorkspace: workspace, screen: screen)
        updatePositionCache(windows: allWindows)
    }

    /// Park self-repair: a hidden-workspace window the OS (or its own app)
    /// moved back on-screen would otherwise sit visible forever — nothing
    /// re-parks in steady state and drift deliberately ignores hidden-ws
    /// windows. Runs after applyChanges so a just-reassigned returned
    /// window (recycled-id reopen) is already on its visible workspace and
    /// exempt. Re-parking is idempotent, so a stale AX read of a window
    /// that is really parked just re-asserts the park.
    private func repairParkedWindows(_ allWindows: [HyprWindow]) {
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
            let isDock = (app.bundleIdentifier == "com.apple.dock")
            mouseTracker.dockIsActive = isDock
            if isDock {
                // watchdog: if no app activates after the dock for 5s (user dismissed
                // the popup with Escape, e.g.), clear it so FFM doesn't stay dead.
                let token = dockActivationToken &+ 1
                dockActivationToken = token
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                    guard let self = self, self.dockActivationToken == token,
                          self.mouseTracker.dockIsActive else { return }
                    hyprLog(.notice, .mouse, "dockIsActive watchdog — clearing after 5s with no other activation")
                    self.mouseTracker.dockIsActive = false
                }
            }
        }

        // scratchpad: an activation outside the layer dismisses it (Cmd-Tab,
        // Dock click). member/self/dock activations and show-grace churn are
        // filtered inside.
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            scratchpad.noteAppActivation(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
        }

        // an activation HyprMac asked for, a focus or a raise of its own, is
        // never the user's. the note is spent here whether or not the
        // half-second window below has run out under a slow retile
        var causedByHyprMac = false
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            causedByHyprMac = suppressions.consumeExpectedActivation(of: app.processIdentifier)
        }

        // dock-click workspace switch — only when NOT suppressed by FFM/switch/raise
        if !causedByHyprMac && !suppressions.isSuppressed("activation-switch") {
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                let pid = app.processIdentifier
                let visibleWorkspaces = Set(workspaceManager.monitorWorkspace.values)

                // only consider windows still tracked (not hidden/closed)
                let appWindows = stateCache.windowOwners
                    .filter { $0.value == pid && stateCache.knownWindowIDs.contains($0.key) && !stateCache.hiddenWindowIDs.contains($0.key) }

                let appWorkspaces = appWindows.compactMap { (wid, _) in workspaceManager.workspaceFor(wid) }
                let hasVisibleWindow = appWorkspaces.contains {
                    visibleWorkspaces.contains($0) || ($0 == ScratchpadController.workspace && scratchpad.isVisible)
                }

                if !hasVisibleWindow {
                    // all of the app's windows live in the hidden scratchpad:
                    // summon the layer instead of a workspace switch —
                    // switchWorkspace(0) would range-guard into a no-op and
                    // strand the activation.
                    let hiddenWs = appWorkspaces.filter { !visibleWorkspaces.contains($0) }
                    if hiddenWs.contains(ScratchpadController.workspace), !scratchpad.isVisible {
                        let member = appWindows.keys.first { scratchpad.contains($0) }
                        hyprLog(.notice, .lifecycle, "dock-affordance: \(app.bundleIdentifier ?? "?") lives in scratchpad — auto-showing layer")
                        scratchpad.show(focusing: member)
                        return
                    }
                    if let targetWS = hiddenWs.filter({ $0 != ScratchpadController.workspace }).min() {
                        let bid = app.bundleIdentifier ?? "?"
                        let wsSorted = appWorkspaces.sorted()
                        let widList = appWindows.map { "\($0.key)→ws\(workspaceManager.workspaceFor($0.key) ?? -1)" }.joined(separator: ",")
                        hyprLog(.notice, .lifecycle, "dock-affordance: \(bid) pid=\(pid) appWorkspaces=\(wsSorted) visible=\(visibleWorkspaces.sorted()) wids=[\(widList)] → switchWorkspace(\(targetWS))")
                        workspaceOrchestrator.switchWorkspace(targetWS)
                        return
                    }
                }
            }
        }

        pollingScheduler.schedule()
        // activation brings windows forward; floater cutouts follow the new stack
        scheduleRestackRefresh(after: 0.1)

        // re-raise floating windows after any app activation (e.g. user clicked a tiled window).
        // must always run — even when activation switch is suppressed — so floaters stay on top.
        // not while a click is in flight: the click's own re-raise owns that,
        // and a raise racing the popup the click is opening dismisses it
        if !stateCache.floatingWindowIDs.isEmpty, clickPress == nil, !mouseButtonDown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.isRunning, !self.mouseButtonDown else { return }
                self.floatingController.raiseBehind()
            }
        }
    }


    /// Clear `dockIsActive` if the deactivating app is the dock. macOS
    /// doesn't always fire `didActivate` for the next app (e.g. user
    /// dismisses a dock popup with Escape), so the watchdog covers that
    /// path; this is the fast cleanup when a sibling activation does fire.
    @objc private func appDidDeactivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.apple.dock" else { return }
        if mouseTracker.dockIsActive {
            mouseTracker.dockIsActive = false
        }
    }

    /// Active Space changed — most commonly because the user entered or
    /// left a fullscreen app's Space. Re-evaluate chrome visibility from
    /// the new focus target.
    @objc private func activeSpaceDidChange(_ notification: Notification) {
        if isFullscreenSuppressed(focused: currentFocusedWindow()) {
            focusBorder.hide()
            focusBorder.hideFloatingBorders()
            dimmingOverlay.hideAll()
        } else if let w = currentFocusedWindow() {
            updateFocusBorder(for: w)
        }
    }

    /// Wake / lock / unlock / session-change. Any of these can drop an
    /// in-flight Hypr keyUp without triggering tap-disabled. Reset hotkey
    /// state so the next regular keystroke isn't packed with a phantom
    /// Hypr modifier (the "sticky Caps Lock" bug from a different angle).
    @objc private func systemInterruption(_ notification: Notification) {
        hyprLog(.notice, .hotkey, "system interruption (\(notification.name.rawValue)) — resetting hotkey state")
        lastSystemInterruptionAt = Date()
        hotkeyManager.resetTrackingAfterTapInterruption()
        // also clear stuck dock flag and menu-tracking flag — sleep dialogs
        // and screen lock can leave either stale.
        mouseTracker.dockIsActive = false
        if mouseTracker.menuTracking {
            mouseTracker.menuTrackingEnded()
        }
        // hold discovery off around sleep/wake/lock. nothing else suppresses
        // polling at wake, so a partial AX snapshot (apps not yet responsive)
        // reads as mass-gone and OS-restored frames read as drift — both
        // dismantle the layout off bad data before any display-change
        // suppression arms.
        suppressions.suppress("workspace-transition", for: 4.0)
        hyprLog(.notice, .lifecycle, "discovery suppressed 4s around system interruption")
        // lock and display sleep last longer than that. discovery holds
        // every missing window from the start of the span to its end
        discovery.noteSystemInterruption(notification.name.rawValue)
        // park the scratchpad across sleep/lock so wake never finds visible
        // members with a stale scrim
        scratchpad.hide(reason: .displayChange)
    }

    /// React to a new app launch. Half-second delay gives the app time to
    /// open its first window before discovery runs.
    @objc private func appDidLaunch(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            // wire up event-driven discovery for the new app. attach is
            // idempotent and retries once if the app isn't AX-ready yet.
            axNotifications.attach(pid: app.processIdentifier)
        }
        pollingScheduler.schedule(after: 0.5)
    }

    /// React to an app terminating. Prunes every window owned by the dead
    /// pid before scheduling a poll — without this, hidden or minimized
    /// windows would leak in cache state forever, since the gone-detection
    /// path can only see windows still in `knownWindowIDs`.
    @objc private func appDidTerminate(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            axNotifications.detach(pid: app.processIdentifier)
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
    /// Order is load-bearing: fingerprinting refreshes DisplayManager, then
    /// `WorkspaceManager.initializeMonitors`
    /// must run before `TilingEngine.handleDisplayChange` so the
    /// home-screen lookup the engine consults is current. Reversing the
    /// order would prune the home-screen mapping first and orphan the
    /// migration.
    @objc private func screenParametersChanged() {
        // macOS fires this for events that don't alter the layout — app
        // quits and color profile changes. those used to pay
        // the full 3s discovery suppression + scratchpad hide before the
        // debounce concluded "unchanged"; with event-driven discovery a
        // spurious 3s suppression starves window ingestion, so bail first.
        // mid-debounce fires (displayTransitionPending) must keep flowing
        // through the generation machinery below.
        if !displayTransitionPending && displayFingerprint() == lastDisplayFingerprint {
            hyprLog(.debug, .lifecycle, "screenParametersChanged: fingerprint unchanged — ignoring spurious fire")
            return
        }
        let names = displayManager.screens.map { $0.localizedName }.joined(separator: ", ")
        hyprLog(.notice, .lifecycle, "screenParametersChanged fired (current screens: [\(names)])")
        // snapshot the departing layout on the FIRST notification of a
        // transition — before macOS shuffles windows onto surviving screens
        // and before the trees migrate. later fires in the same debounce
        // would re-save the piled-up state under the same key.
        if !displayTransitionPending, !settledDisplayKey.isEmpty {
            saveLayoutSnapshot(manual: false, displayKey: settledDisplayKey)
        }
        // the scratchpad can't survive a topology change — reconcile would
        // park its visible members under a live scrim
        scratchpad.hide(reason: .displayChange)
        // hold discovery off through the settle window. a poll between the
        // topology change and the reconcile below reads windows at their
        // OS-shuffled positions and drift-reassigns them to whatever
        // workspace happens to own the screen they got dumped on.
        suppressions.suppress("workspace-transition", for: 3.0)
        displayTransitionPending = true
        displayChangeGeneration += 1
        // after a wake the displays come back one at a time over several
        // seconds, and a two-second beat reconciled the one-screen desk in
        // between as real
        let recentWake = Date().timeIntervalSince(lastSystemInterruptionAt) < Self.recentWakeSpan
        if recentWake {
            suppressions.suppress("workspace-transition", for: Self.wakeSettleWindow + 1)
        }
        scheduleDisplayReconcile(stabilityWindow: recentWake ? Self.wakeSettleWindow : 2.0)
    }

    /// Reconcile only once the topology has been stable for a beat. Wake
    /// reattaches displays one at a time over several seconds — a fixed
    /// short delay reconciled each transient config as real, re-homing
    /// every workspace against a one-screen topology and back.
    private func scheduleDisplayReconcile(stabilityWindow: TimeInterval = 2.0) {
        let gen = displayChangeGeneration
        let fingerprintAtSchedule = displayFingerprint()
        DispatchQueue.main.asyncAfter(deadline: .now() + stabilityWindow) { [weak self] in
            guard let self else { return }
            // a newer notification owns the debounce now
            guard gen == self.displayChangeGeneration else { return }
            // the window list is partial while the session is locked or the
            // displays sleep. a reconcile from it would re-home every
            // workspace and tile without the windows it is missing, so it
            // waits for the span to end and settles again from there
            if self.discovery.isSessionInterrupted {
                hyprLog(.notice, .lifecycle, "display reconcile deferred: session interrupted")
                self.suppressions.suppress("workspace-transition", for: 3.0)
                self.scheduleDisplayReconcile(stabilityWindow: stabilityWindow)
                return
            }
            let fingerprint = self.displayFingerprint()
            if fingerprint != fingerprintAtSchedule {
                // changed without a fresh notification — keep waiting
                self.suppressions.suppress("workspace-transition", for: 3.0)
                self.scheduleDisplayReconcile(stabilityWindow: stabilityWindow)
                return
            }
            // skip if nothing actually changed. macOS fires the notification
            // for things that don't alter the screen list (call init, app
            // quits, color profile changes).
            if fingerprint == self.lastDisplayFingerprint {
                hyprLog(.notice, .lifecycle, "screen layout unchanged — skipping reconcile")
                self.displayTransitionPending = false
                if self.retileSkippedDuringTransition {
                    self.retileSkippedDuringTransition = false
                    self.tileAllVisibleSpaces()
                }
                return
            }
            self.lastDisplayFingerprint = fingerprint
            let departedKey = self.settledDisplayKey
            self.settledDisplayKey = LayoutSnapshotStore.displayKey(screens: self.displayManager.screens)
            self.focusBorder.primaryScreenHeight = self.displayManager.primaryScreenHeight
            self.focusBrackets.primaryScreenHeight = self.displayManager.primaryScreenHeight
            // cover the reconcile itself plus a settle tail — the retile it
            // runs moves every window, and the first post-reconcile poll
            // must not read those moves as drift.
            self.suppressions.suppress("workspace-transition", for: 3.0)
            self.displayTransitionPending = false
            self.retileSkippedDuringTransition = false
            // the fingerprint refreshed DisplayManager; initializeMonitors runs
            // before TilingEngine.handleDisplayChange so the home-screen
            // lookup the engine consults is current.
            self.reconcileAfterDisplayChange(
                restoreSavedLayout: Self.restoresAfterSettle(from: departedKey, to: self.settledDisplayKey))
        }
    }

    /// Stable string identity for the current monitor layout. Used to
    /// drop spurious `didChangeScreenParameters` fires.
    private func displayFingerprint() -> String {
        displayManager.refreshedFingerprint()
    }

    /// Handler for the `.hyprMacRetileAll` notification posted from the
    /// menu bar's "Retile All" action.
    @objc private func tiledDropPreviewWorkspacesChanged() {
        dropPreview.refresh()
    }

    /// Hide the drop preview and forget the drag's release trees.
    private func endTiledDropPreview() {
        dropPreview.end()
        dropPreviewTargets = [:]
    }

    @objc private func retileAllRequested() {
        hyprLog(.debug, .lifecycle, "retile all spaces requested")
        scratchpad.hide(reason: .workspaceAction)
        snapshotAndTile()
    }
}

private extension WindowManager {
    private func makeTiledDragHandler() -> TiledDragHandler {
        TiledDragHandler(
            capture: { [weak self] point, publish in
                guard let self, self.isRunning,
                      let screen = self.exactScreen(containing: point) else {
                    return .ineligible(.noTarget)
                }
                let displayID = self.tiledDragDisplayID(screen)
                return self.tilingEngine.captureTiledDrag(
                    pointer: point,
                    occludingWindows: self.visibleFloatingWindows(),
                    currentLocation: { [weak self] in
                        guard let self, self.isRunning else { return nil }
                        let matches = self.displayManager.screens.filter {
                            self.tiledDragDisplayID($0) == displayID
                        }
                        guard matches.count == 1, let screen = matches.first,
                              let workspace = self.tiledDragWorkspace(on: screen) else { return nil }
                        return (workspace, screen, self.stateCache.floatingWindowIDs)
                    },
                    onCapturedFrames: publish)
            },
            drop: { [weak self] snapshot, mode in
                guard let self, self.isRunning else { return .superseded }
                var releaseLocation: () -> (workspace: Int, screen: NSScreen,
                                            floatingIDs: Set<CGWindowID>)? = { nil }
                if case let .crossMonitor(pointer, _) = mode {
                    releaseLocation = self.tiledDragReleaseLocation(pointer, leaving: snapshot)
                }
                let outcome = self.tilingEngine.dropTiledDrag(
                    snapshot,
                    mode: mode,
                    currentLocation: { [weak self] in self?.tiledDragLocation(for: snapshot) },
                    releaseLocation: releaseLocation)
                // membership moves in the same step the engine published both
                // trees, so nothing between here and the report can split them
                if case let .acrossTrees(.committed, cross) = outcome {
                    for (id, workspace) in cross.moves.sorted(by: { $0.key < $1.key }) {
                        self.workspaceManager.moveWindow(id, toWorkspace: workspace)
                        self.minimaRevalidation.cancel(id, reason: "tiled drag across monitors")
                    }
                }
                return outcome
            },
            resolveTarget: { [weak self] pointer, snapshot in
                let onSourceTiles = snapshot.context.usableFrame.contains(pointer)
                // the planner the live preview uses, on the same press capture
                let target = TiledDropPlanner.sameTreeTarget(
                    pointer: pointer, draggedID: snapshot.draggedID,
                    sourceTiles: snapshot.context.usableFrame, sourceSlots: snapshot.originalFrames)
                self?.noteTiledDragRelease(pointer, snapshot: snapshot,
                                           onSourceTiles: onSourceTiles, target: target)
                return target
            },
            schedule: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            },
            capturedFrames: { [weak self] frames in self?.acceptTiledDragCapture(frames) },
            readCache: { [weak self] in self?.stateCache.tiledPositions ?? [:] },
            writeCache: { [weak self] frames in self?.stateCache.tiledPositions = frames },
            completion: { [weak self] completion in self?.completeTiledDrag(completion) },
            captureFailure: { [weak self] result in self?.reportTiledDragCaptureFailure(result) },
            isCrossMonitor: { [weak self] pointer, snapshot in
                guard let self, let screen = self.exactFullScreen(containing: pointer) else {
                    return false
                }
                return self.tiledDragDisplayID(screen) != snapshot.context.physicalDisplayID
            })
    }

    /// Start or move the live drop preview. Only a press the tiled capture
    /// took gets one, once it is past the drag threshold. Whether it shows
    /// is the drop's own call: see `tiledDropPreviewFrame`.
    private func updateTiledDropPreview(_ event: NSEvent) {
        let point = TiledDragEvent.point(event: event, primaryHeight: displayManager.primaryScreenHeight)
        dragOptionDown = event.modifierFlags.contains(.option)
        if !dropPreview.isActive {
            guard isRunning, config.enabled, let snapshot = tiledDragHandler.pressSnapshot,
                  TiledDragEvent.isDrag(from: mouseDownPointCG, to: point, sawDragEvent: true) else {
                return
            }
            dropPreviewTargets = [:]
            dropPreviewPanel.primaryScreenHeight = displayManager.primaryScreenHeight
            dropPreviewPanel.accentColor = config.resolvedDropPreviewColor
            dropPreviewPanel.cornerRadius = config.windowCornerRadius
            dropPreview.begin { [weak self] point in
                self?.tiledDropPreviewFrame(at: point, snapshot: snapshot)
            }
        }
        dropPreview.move(to: point)
    }

    /// Where the dragged window would land if released at `point`, nil where
    /// the drop would restore. The drop's own planner and candidates, fed
    /// the press capture and the trees; no AX.
    private func tiledDropPreviewFrame(at point: CGPoint, snapshot: TiledDragSnapshot) -> CGRect? {
        // a drop only acts on a move: an unmoved window is ignored and a
        // resize resizes. judged by the drop's own rule, on the window list
        // any layout since the press supersedes the drop, and there is then
        // nothing to show
        guard isRunning, tiledDragHandler.pressSnapshot?.generation == snapshot.generation,
              tilingEngine.currentLayoutGeneration == snapshot.generation,
              tiledDragGesture(snapshot) == .move else { return nil }
        let swap = mouseDragLifecycle.releaseRequestsSwap(hyprHeld: hyprHeld, optionDown: dragOptionDown)
        var release = TiledDropRelease.source
        var target: TiledDragCrossTarget?
        if let screen = exactFullScreen(containing: point),
           tiledDragDisplayID(screen) != snapshot.context.physicalDisplayID {
            let found = dropPreviewTarget(on: screen, snapshot: snapshot)
            target = found?.target
            release = .otherMonitor(slots: found?.slots)
        }
        let plan = TiledDropPlanner.plan(pointer: point, draggedID: snapshot.draggedID,
                                         sourceTiles: snapshot.context.usableFrame,
                                         sourceSlots: snapshot.originalFrames, release: release)
        return tilingEngine.tiledDragPreviewFrame(snapshot, plan: plan, swap: swap, target: target)
    }

    /// Another display's tree as a drop there would find it. The policy is
    /// asked every time, so a disabled monitor or the scratchpad refuses as
    /// it would at release, and a cached tree is kept only while its
    /// workspace is still the visible one and the tree itself is unchanged.
    private func dropPreviewTarget(on screen: NSScreen, snapshot: TiledDragSnapshot)
        -> (target: TiledDragCrossTarget, slots: [CGWindowID: CGRect])? {
        let displayID = tiledDragDisplayID(screen)
        guard case let .workspace(workspace) = tiledDragReleasePolicy(on: screen) else {
            dropPreviewTargets[displayID] = nil
            return nil
        }
        if let cached = dropPreviewTargets[displayID], cached.workspace == workspace,
           cached.target.currentContext() == cached.target.context {
            return (cached.target, Self.slots(of: cached.target))
        }
        guard let found = tilingEngine.tiledDragPreviewTarget(
            for: snapshot, location: (workspace, screen, stateCache.floatingWindowIDs)) else {
            dropPreviewTargets[displayID] = nil
            return nil
        }
        dropPreviewTargets[displayID] = (workspace, found)
        return (found, Self.slots(of: found))
    }

    private static func slots(of target: TiledDragCrossTarget) -> [CGWindowID: CGRect] {
        TiledDropPlanner.slots(of: target.tree, in: target.context.usableFrame,
                               gap: target.context.gap, padding: target.context.padding)
    }

    /// What the drag is doing to the dragged window right now, by the drop's
    /// own rule, from the window list rather than AX. A press that selects
    /// text is `.unmoved`, an edge drag `.resize`.
    private func tiledDragGesture(_ snapshot: TiledDragSnapshot) -> TiledDragGesture? {
        var id = UnsafeRawPointer(bitPattern: UInt(snapshot.draggedID))
        guard let ids = CFArrayCreate(kCFAllocatorDefault, &id, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]],
              let raw = list.first?[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return nil }
        return snapshot.gesture(to: bounds)
    }

    private func exactScreen(containing point: CGPoint) -> NSScreen? {
        let matches = displayManager.screens.filter { displayManager.cgRect(for: $0).contains(point) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// One notice line per tiled release: the point in global CG coordinates,
    /// the source and release screens, and the same-tree target with every
    /// source tile it weighed. The drop decision reads from here.
    private func noteTiledDragRelease(_ pointer: CGPoint, snapshot: TiledDragSnapshot,
                                      onSourceTiles: Bool, target: TiledDragTarget?) {
        func describe(_ screen: NSScreen?) -> String {
            guard let screen else { return "none" }
            return "'\(screen.localizedName)' display=\(tiledDragDisplayID(screen)) "
                + "full=\(displayManager.cgFullRect(for: screen))"
        }
        let source = displayManager.screens.first {
            tiledDragDisplayID($0) == snapshot.context.physicalDisplayID
        }
        var slots = snapshot.originalFrames
        slots.removeValue(forKey: snapshot.draggedID)
        let tiles = onSourceTiles
            ? " tiles=[\(TiledDragTargetResolver.trace(pointer: pointer, slots: slots))]" : ""
        hyprLog(.notice, .tiling, "tiled drag release: dragged=\(snapshot.draggedID) "
                + String(format: "point=cg(%g,%g) ", Double(pointer.x), Double(pointer.y))
                + "source=ws\(snapshot.context.workspace) on \(describe(source)) "
                + "sourceTiles=\(snapshot.context.usableFrame) onSourceTiles=\(onSourceTiles) "
                + "release=\(describe(exactFullScreen(containing: pointer))) "
                + "sameTree=\(target.map { "\($0.windowID) \($0.edge)" } ?? "none")" + tiles)
    }

    /// The one screen whose whole display holds `point`, menu bar and Dock
    /// included, so a release there still counts for that monitor.
    private func exactFullScreen(containing point: CGPoint) -> NSScreen? {
        let matches = displayManager.screens.filter { displayManager.cgFullRect(for: $0).contains(point) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Where a tiled drag released over another monitor lands: that screen's
    /// visible workspace, re-read on every call so the engine can tell when
    /// it goes stale. A screen that cannot take the window logs why once
    /// and yields nothing, and the drop restores.
    private func tiledDragReleaseLocation(_ pointer: CGPoint, leaving snapshot: TiledDragSnapshot)
        -> () -> (workspace: Int, screen: NSScreen, floatingIDs: Set<CGWindowID>)? {
        guard let screen = exactFullScreen(containing: pointer) else {
            hyprLog(.notice, .tiling, "tiled drag across monitors refused: release point on no screen")
            return { nil }
        }
        let displayID = tiledDragDisplayID(screen)
        guard displayID != snapshot.context.physicalDisplayID else { return { nil } }
        let policy = tiledDragReleasePolicy(on: screen)
        guard case let .workspace(workspace) = policy else {
            if case let .refused(reason) = policy {
                hyprLog(.notice, .tiling, "tiled drag across monitors refused on "
                        + "\(screen.localizedName): \(reason)")
            }
            return { nil }
        }
        return { [weak self] in
            guard let self, self.isRunning else { return nil }
            let matches = self.displayManager.screens.filter { self.tiledDragDisplayID($0) == displayID }
            guard matches.count == 1, let current = matches.first,
                  self.tiledDragReleasePolicy(on: current) == .workspace(workspace) else { return nil }
            return (workspace, current, self.stateCache.floatingWindowIDs)
        }
    }

    private func tiledDragReleasePolicy(on screen: NSScreen) -> TiledDragReleasePolicy {
        TiledDragReleasePolicy.resolve(
            monitorDisabled: workspaceManager.isMonitorDisabled(screen),
            scratchpadVisible: scratchpad.isVisible,
            visibleWorkspace: { workspaceManager.workspaceForScreen(screen) })
    }

    private func tiledDragLocation(for snapshot: TiledDragSnapshot)
        -> (workspace: Int, screen: NSScreen, floatingIDs: Set<CGWindowID>)? {
        guard isRunning else { return nil }
        let screens = displayManager.screens.filter {
            tiledDragDisplayID($0) == snapshot.context.physicalDisplayID
        }
        guard screens.count == 1, let screen = screens.first,
              tiledDragWorkspace(on: screen) == snapshot.context.workspace,
              snapshot.context.memberIDs.allSatisfy({
                  workspaceManager.workspaceFor($0) == snapshot.context.workspace
              }) else { return nil }
        return (snapshot.context.workspace, screen, stateCache.floatingWindowIDs)
    }

    /// The workspace a tiled drag on `screen` works in: the scratchpad's
    /// tree while it's up on that monitor, nil on the other monitors then
    /// (their tiles are under the scrim), else the screen's workspace.
    private func tiledDragWorkspace(on screen: NSScreen) -> Int? {
        if let layer = scratchpad.visibleLayer {
            guard tiledDragDisplayID(layer.screen) == tiledDragDisplayID(screen) else { return nil }
            return ScratchpadController.workspace
        }
        return workspaceManager.workspaceForScreen(screen)
    }

    private func tiledDragDisplayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? 0
    }

    private func completeTiledDrag(_ completion: TiledDragCompletion) {
        let affected = completion.snapshot.context.memberIDs
        // a drop onto another monitor wraps the ordinary outcome together
        // with the release screen's tree
        var outcome = completion.outcome
        var crossTree: TiledDragCrossTree?
        if case let .acrossTrees(result, cross) = completion.outcome {
            outcome = result
            crossTree = cross
        }
        if tiledDragFeedback.hasPendingFeedback {
            switch outcome {
            case .degraded:
                // beginDegraded reports the earlier failure before replacing it.
                break
            case .committed, .rejectedRestored:
                // every key this verified drop touched speaks for its members
                var verified = [(TiledDragFeedbackKey(
                    workspace: completion.snapshot.context.workspace,
                    displayID: completion.snapshot.context.physicalDisplayID), affected)]
                if let crossTree {
                    verified.append((TiledDragFeedbackKey(
                        workspace: crossTree.target.workspace,
                        displayID: crossTree.target.physicalDisplayID), crossTree.target.memberIDs))
                }
                var actions: [TiledDragDeferredFeedbackAction] = []
                let touched = verified.filter { tiledDragFeedback.isPending(for: $0.0) }
                if touched.isEmpty {
                    actions = tiledDragFeedback.reconcile(.noResult)
                }
                for (key, members) in touched {
                    actions += tiledDragFeedback.reconcile(.accepted(
                        key: key, generation: tilingEngine.currentLayoutGeneration,
                        publishedIDs: members, expectedIDs: members))
                }
                applyTiledDragFeedbackActions(actions, completion: pendingTiledDragCompletion)
                if !tiledDragFeedback.hasPendingFeedback {
                    pendingTiledDragCompletion = nil
                }
            case .ignored, .superseded, .acrossTrees:
                break
            }
        }
        let scope = crossTree == nil ? "" : " across monitors"
        hyprLog(.debug, .tiling, "tiled drag result: dragged=\(completion.snapshot.draggedID) "
                + "members=\(affected.union(crossTree?.target.memberIDs ?? []).sorted()) "
                + "outcome=\(Self.outcomeName(completion.outcome))")
        switch outcome {
        case let .rejectedRestored(reason, frames):
            hyprLog(.notice, .tiling, "tiled drag\(scope) rejected and restored: reason=\(reason.trace) actual=\(frames)")
        case let .degraded(candidateReason, restorationReason, frames, progress):
            let candidate = candidateReason?.trace ?? "nil"
            let restoration = restorationReason?.trace ?? "nil"
            let written = (progress?.possiblyWritten ?? []).sorted()
            hyprLog(.notice, .tiling, "tiled drag\(scope) degraded: candidate=\(candidate) restoration=\(restoration) "
                    + "written=\(written) actual=\(frames)")
        case .committed, .superseded, .ignored, .acrossTrees: break
        }
        switch outcome {
        case .superseded, .ignored: return
        case .committed, .rejectedRestored, .degraded, .acrossTrees: break
        }
        // the drop already moved membership with the trees
        var committedAcross: [CGWindowID: CGRect]?
        if crossTree != nil, case let .committed(_, frames, _) = outcome {
            focusController.recordFocus(completion.snapshot.draggedID,
                                        reason: "tiled drag across monitors")
            committedAcross = frames
        }
        if completion.snapshot.context.workspace == ScratchpadController.workspace {
            scratchpad.syncTiledFrames()
        }
        // the same per-window decisions the tiled-position cache just
        // applied, so the two cannot drift apart. a drop across monitors
        // brings the release screen's members in through the policy
        let actions = TiledDragCachePolicy.actions(for: completion.outcome,
                                                   draggedID: completion.snapshot.draggedID,
                                                   affectedIDs: affected)
        for (id, action) in actions {
            switch action {
            case let .refresh(frame): stateCache.cachedWindows[id]?.cachedFrame = frame
            case .invalidate: stateCache.cachedWindows[id]?.cachedFrame = nil
            case .preserve: break
            }
        }
        if let id = focusBorder.trackedWindowID, let action = actions[id] {
            switch action {
            case let .refresh(frame): focusBorder.updatePosition(frame)
            case .invalidate: focusBorder.hide()
            case .preserve: break
            }
        }
        if let id = focusBrackets.trackedWindowID, let action = actions[id] {
            switch action {
            case let .refresh(frame): if focusBrackets.isVisible { focusBrackets.updatePosition(frame) }
            case .invalidate: focusBrackets.hide()
            case .preserve: break
            }
        }
        // the dragged window keeps focus on its new monitor. the border goes
        // on the verified frame: a live AX read lags the write
        let draggedID = completion.snapshot.draggedID
        if let frame = committedAcross?[draggedID], config.showFocusBorder,
           let window = stateCache.cachedWindows[draggedID],
           !isFullscreenSuppressed(focused: window) {
            focusBorder.accentCGColor = config.resolvedFocusBorderColor.cgColor
            focusBorder.show(around: frame, windowID: draggedID)
        }
        if committedAcross != nil {
            NotificationCenter.default.post(name: .hyprMacWorkspaceChanged, object: nil)
        }
        refreshDimming(tiledRectsOverride: stateCache.tiledPositions)
        switch TiledDragFeedbackPolicy.feedback(for: completion.outcome) {
        case .rejected:
            NSSound.beep()
            let frame = completion.snapshot.originalFrames[completion.snapshot.draggedID]
                ?? completion.snapshot.context.usableFrame
            focusBorder.flashError(around: frame, windowID: completion.snapshot.draggedID, window: nil,
                                   message: "Arrangement rejected; previous positions restored")
        case .degraded:
            let key = TiledDragFeedbackKey(
                workspace: completion.snapshot.context.workspace,
                displayID: completion.snapshot.context.physicalDisplayID)
            // a drop across monitors also waits on the release screen's tree
            var releaseScreen: [TiledDragFeedbackKey: Set<CGWindowID>] = [:]
            if let crossTree {
                releaseScreen[TiledDragFeedbackKey(workspace: crossTree.target.workspace,
                                                   displayID: crossTree.target.physicalDisplayID)]
                    = crossTree.target.memberIDs
            }
            applyTiledDragFeedbackActions(tiledDragFeedback.beginDegraded(
                key: key, generation: tilingEngine.currentLayoutGeneration,
                affectedIDs: affected, alsoAwaiting: releaseScreen),
                completion: pendingTiledDragCompletion)
            pendingTiledDragCompletion = completion
            hyprLog(.notice, .tiling, "tiled drag degraded feedback deferred until reconciliation")
            pollingScheduler.schedule()
        case nil:
            break
        }
    }

    private static func outcomeName(_ outcome: TiledDragDropOutcome) -> String {
        switch outcome {
        case .ignored: return "ignored"
        case .committed: return "committed"
        case .rejectedRestored: return "rejectedRestored"
        case .degraded: return "degraded"
        case .superseded: return "superseded"
        case let .acrossTrees(result, cross):
            return "acrossTrees(\(outcomeName(result)) ws\(cross.target.workspace))"
        }
    }

    private func reportTiledDragCaptureFailure(_ result: TiledDragCaptureResult) {
        guard case let .unknown(reason) = result, let point = mouseDownPointCG else { return }
        hyprLog(.notice, .tiling, "tiled drag capture failed: reason=\(reason)")
        NSSound.beep()
        focusBorder.flashError(around: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2),
                               windowID: 0, window: nil, message: "Could not verify window positions")
    }

    private func reportTiledDragFailure(_ completion: TiledDragCompletion) -> Int? {
        let frame = completion.snapshot.originalFrames[completion.snapshot.draggedID]
            ?? completion.snapshot.context.usableFrame
        return focusBorder.flashError(around: frame, windowID: completion.snapshot.draggedID,
                                      window: nil, message: "Could not restore the tiled layout")
    }

    private func reconcileTiledDragFeedback(with results: [TilingEngine.AdmissionResult],
                                            allWindows: [HyprWindow]) {
        guard tiledDragFeedback.hasPendingFeedback else { return }
        let events = results.map { result -> TiledDragFeedbackReconciliation in
            let key = TiledDragFeedbackKey(
                workspace: result.workspace,
                displayID: tiledDragDisplayID(result.screen))
            if result.failure == nil, result.strandedIDs.isEmpty {
                let assigned = workspaceManager.windowIDs(onWorkspace: result.workspace)
                let expected = Set(allWindows.filter {
                    assigned.contains($0.windowID) && !isFloating($0.windowID)
                }.map(\.windowID))
                return .accepted(key: key, generation: result.generation,
                                 publishedIDs: result.publishedIDs, expectedIDs: expected)
            }
            return .failed(key: key, generation: result.generation,
                           requiredIDs: result.publishedIDs.union(result.strandedIDs),
                           recoveryPending: result.strandedIDs.contains {
                               admissionRecovery.phase(of: $0) == .awaitingRetry
                           })
        }
        var activeRetry = false
        for key in tiledDragFeedback.pendingKeys {
            guard let screen = displayManager.screens.first(where: {
                tiledDragDisplayID($0) == key.displayID
            }) else { continue }
            activeRetry = activeRetry
                || admissionRecovery.hasActiveRetry(workspace: key.workspace, screen: screen)
        }
        let actions = tiledDragFeedback.reconcileNewest(events, activeRetry: activeRetry)
        if !actions.isEmpty {
            applyTiledDragFeedbackActions(actions, completion: pendingTiledDragCompletion)
            pendingTiledDragCompletion = nil
        }
    }

    private func reconcileTiledDragRecovery(workspace: Int, screen: NSScreen,
                                            result: TilingEngine.AdmissionResult?) {
        guard tiledDragFeedback.hasPendingFeedback else { return }
        let key = TiledDragFeedbackKey(workspace: workspace,
                                       displayID: tiledDragDisplayID(screen))
        let event: TiledDragFeedbackReconciliation
        if let result, result.failure == nil, result.strandedIDs.isEmpty {
            let expected = Set(accessibility.getAllWindows().filter {
                workspaceManager.workspaceFor($0.windowID) == workspace && !isFloating($0.windowID)
            }.map(\.windowID))
            event = .accepted(key: key, generation: result.generation,
                              publishedIDs: result.publishedIDs, expectedIDs: expected)
        } else {
            event = .terminalFailure(key: key)
        }
        let actions = tiledDragFeedback.reconcile(event)
        guard !actions.isEmpty else { return }
        applyTiledDragFeedbackActions(actions, completion: pendingTiledDragCompletion)
        pendingTiledDragCompletion = nil
    }

    private func applyTiledDragFeedbackActions(_ actions: [TiledDragDeferredFeedbackAction],
                                               completion: TiledDragCompletion?) {
        for action in actions {
            switch action {
            case let .showDegraded(key, generation):
                guard let completion else { continue }
                NSSound.beep()
                if let token = reportTiledDragFailure(completion) {
                    activeTiledDragFeedback = (key, generation, token)
                }
            case let .cancelDegraded(key):
                hyprLog(.notice, .tiling, "tiled drag degraded feedback cancelled: verified reconciliation")
                if let active = activeTiledDragFeedback, active.key == key,
                   focusBorder.cancelErrorFeedback(token: active.borderToken) {
                    activeTiledDragFeedback = nil
                }
            }
        }
    }
}

private extension WindowManager {
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
        // parked window AX omits is looked up in the cache
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

    /// Give `admissionRecovery` its probes and its two actions.
    ///
    /// Everything it can do is here: run one more tiling pass with only the
    /// newcomer's older minima ignored, and float a window where it stands.
    /// It has no handle on workspace assignment, so the fallback cannot turn
    /// into `routeUnfittedWindow` by another name.
    private func wireAdmissionRecovery() {
        tilingEngine.pendingRecoverySource = { [weak self] in
            self?.admissionRecovery.pendingWindowIDs ?? []
        }
        minimaRevalidation.workspaceFor = { [weak self] id in self?.workspaceManager.workspaceFor(id) }
        minimaRevalidation.isFloating = { [weak self] id in self?.isFloating(id) ?? true }
        admissionRecovery.workspaceFor = { [weak self] id in self?.workspaceManager.workspaceFor(id) }
        admissionRecovery.homeScreenForWorkspace = { [weak self] ws in
            self?.workspaceManager.homeScreenForWorkspace(ws)
        }
        admissionRecovery.isWorkspaceVisible = { [weak self] ws in
            self?.workspaceManager.isWorkspaceVisible(ws) ?? false
        }
        admissionRecovery.isFloating = { [weak self] id in self?.isFloating(id) ?? true }
        admissionRecovery.isDisplayTransitionPending = { [weak self] in
            self?.displayTransitionPending ?? true
        }
        admissionRecovery.isSessionInterrupted = { [weak self] in
            self?.discovery.isSessionInterrupted ?? false
        }
        admissionRecovery.liveWindow = { [weak self] id in
            guard let self,
                  self.stateCache.knownWindowIDs.contains(id),
                  !self.stateCache.hiddenWindowIDs.contains(id),
                  let window = self.stateCache.cachedWindows[id],
                  let pid = self.stateCache.windowOwners[id],
                  NSRunningApplication(processIdentifier: pid) != nil
            else { return nil }
            return window
        }
        admissionRecovery.attempt = { [weak self] workspace, screen, bypass, keepOnTimeout in
            guard let self else { return AdmissionRecovery.AttemptResult() }
            let allWindows = self.accessibility.getAllWindows()
            self.tilingEngine.primeMinimumSizes(allWindows)
            for w in allWindows where self.stateCache.floatingWindowIDs.contains(w.windowID) {
                w.isFloating = true
            }
            let assigned = self.workspaceManager.windowIDs(onWorkspace: workspace)
            let windows = allWindows.filter { assigned.contains($0.windowID) }
            let result = self.tilingEngine.retryAdmission(
                windows, onWorkspace: workspace, screen: screen,
                bypassingMinimaBefore: bypass,
                refusingImpossibleArrangements: true,
                keepingUnverifiedOnTimeout: keepOnTimeout)
            self.updatePositionCache(windows: allWindows)
            return AdmissionRecovery.AttemptResult(
                placed: result.publishedIDs.intersection(bypass.keys),
                failure: result.failure,
                admission: result)
        }
        admissionRecovery.floatInPlace = { [weak self] window, reason in
            guard let self else { return }
            self.floatingController.floatInPlace(window, reason: reason)
            self.updatePositionCache()
        }
        admissionRecovery.clearUnverified = { [weak self] workspace, screen in
            self?.tilingEngine.clearUnverifiedGeometry(forWorkspace: workspace, screen: screen)
        }
        admissionRecovery.retileAfterFallback = { [weak self] workspace, screen in
            guard let self else { return [] }
            let allWindows = self.accessibility.getAllWindows()
            self.tilingEngine.primeMinimumSizes(allWindows)
            for w in allWindows where self.stateCache.floatingWindowIDs.contains(w.windowID) {
                w.isFloating = true
            }
            let assigned = self.workspaceManager.windowIDs(onWorkspace: workspace)
            let windows = allWindows.filter { assigned.contains($0.windowID) }
            // an ordinary pass, no bypass: the newcomer is floating now, so
            // this is the incumbents asking for their slots back.
            let result = self.tilingEngine.tileWindows(windows, onWorkspace: workspace,
                                                       screen: screen)
            self.updatePositionCache(windows: allWindows)
            return Set(windows.filter { !$0.isFloating
                                        && !result.publishedIDs.contains($0.windowID) }
                              .map(\.windowID))
        }
    }

    /// Offer every window still waiting on evidence a fresh look. Called
    /// from the discovery poll and after a retile, the two places that
    /// actually learn something new about a window; the recovery itself
    /// decides whether what it sees is enough to act on.
    private func offerRecoveryEvidence() {
        for id in admissionRecovery.pendingWindowIDs.sorted() {
            admissionRecovery.noteEvidence(for: id)
        }
    }


}

extension WindowManager {
    /// Which window a click at `point` should focus.
    ///
    /// Windows drawn over the tiles win: floaters, and newcomers in explicit
    /// recovery, which are in no tree and sit on top exactly like a floater.
    /// The tiled rects get a look only after those, so a recovery newcomer
    /// overlapping an incumbent's slot does not hand the click to the
    /// incumbent underneath it. A recovery newcomer says so in the reason:
    /// it is not floating, and a log that calls it floating sends the next
    /// reader looking in the wrong place.
    ///
    /// `stackHit` is the window the window list puts on top at the point.
    /// When it is one of ours it wins over the frame order: a floater a
    /// tile has buried does not take the click the tile received.
    static func clickFocusTarget(at point: CGPoint,
                                 overlayFrames: [(id: CGWindowID, frame: CGRect)],
                                 tiledPositions: [CGWindowID: CGRect],
                                 recoveryIDs: Set<CGWindowID> = [],
                                 stackHit: CGWindowID? = nil) -> (id: CGWindowID, reason: String)? {
        func overlayReason(_ id: CGWindowID) -> String {
            recoveryIDs.contains(id) ? "syncTracker-recovery" : "syncTracker-floating"
        }
        if let hit = stackHit {
            if overlayFrames.contains(where: { $0.id == hit }) { return (hit, overlayReason(hit)) }
            if tiledPositions[hit] != nil { return (hit, "syncTracker-tiled") }
        }
        for entry in overlayFrames where entry.frame.contains(point) {
            return (entry.id, overlayReason(entry.id))
        }
        for (wid, rect) in tiledPositions where rect.contains(point) {
            return (wid, "syncTracker-tiled")
        }
        return nil
    }
}
