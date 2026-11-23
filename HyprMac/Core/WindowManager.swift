// Central orchestrator. Wires every subsystem together, owns the long-lived
// references, and routes hotkey actions and discovery results to the services
// that handle them. It also holds the policy that has no service home yet:
// the mouse gesture timeline, the display settle, and the focus chrome.

import Cocoa
import Combine

/// Long-lived orchestrator that owns every subsystem and routes work between them.
///
/// Lifecycle is bracketed by ``start()`` and ``stop()``. Between those calls
/// `WindowManager` keeps its services live, registers global mouse and workspace
/// observers, and runs a periodic discovery poll that drives tiling and focus
/// updates. Construction wires the dependency graph.
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
    let displayManager = DisplayManager()
    let cursorManager = CursorManager()
    let appLauncher = AppLauncherManager()
    let config: UserConfig
    let focusBorder = FocusBorder()
    let focusBrackets = FocusBrackets()
    let dimmingOverlay = DimmingOverlay()
    let focusGlide = FocusGlide()
    private let screenshotPicker = ScreenshotPickerWatcher()
    let mouseTracker = MouseTrackingManager()
    let keybindOverlay = KeybindOverlayController()
    let workspaceOverview = WorkspaceOverviewController()

    // status bar export (state.json + hook). every publish point below ends
    // in refreshWorkspaceOverview, which notes the change; focus notes its own
    private let statusExporter: StatusExporter = {
        // one publisher, so writes and the clear share a queue and a hook runner
        let publisher = StatusFilePublisher()
        return StatusExporter(
            schedule: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) },
            publish: publisher.publish, clear: publisher.clear)
    }()
    private var statusConfigObservation: AnyCancellable?
    // the float and tile rules: watched so a change, from the menu, an
    // action or Settings, reaches the open windows at once
    private var floatingRuleSync: FloatingRuleSync?
    private(set) lazy var floatingRuleCommands = FloatingRuleCommands(config: config)
    let windowRulesOverlay = WindowRulesOverlayController()
    let failedTilePrompt = FailedTilePromptController()
    private let failedTilePolicy = FailedTilePromptPolicy(defaults: .standard)

    private(set) var workspaceManager: WorkspaceManager!
    private(set) var tilingEngine: TilingEngine!

    // window-keyed state cache. see WindowStateCache for what it owns.
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
    // the current left press was a real click on a window. read at mouse-up
    private var realClickInProgress = false
    // a restack refresh is queued; later triggers ride along with it
    private var restackRefreshPending = false

    // verified tiled drag capture and completion, and its live preview.
    private var tiledDrag: TiledDragController!
    private var tiledDragFeedback: TiledDragFeedbackCoordinator!

    // per-action routing. handleAction runs the gates first.
    private var actionDispatcher: ActionDispatcher!

    private var statusPresenter: WorkspaceStatusPresenter!
    private var placement: WindowPlacement!
    private var focusResolver: FocusResolver!

    // workspace switch / move / move-to-monitor workflows.
    private var workspaceOrchestrator: WorkspaceOrchestrator!
    private var scratchpad: ScratchpadController!

    // periodic discovery timer + coalesced notification-driven polls.
    // constructed in init() so the closure can capture self weakly.
    private var pollingScheduler: PollingScheduler!

    // one bounded retry, then an explicit float, for a newcomer a failed
    // admission left outside the tree.
    private let admissionRecovery = AdmissionRecovery()
    private let minimaRevalidation = MinimaRevalidation()

    // one tiling pass plus the bookkeeping it owes, so nothing it strands goes
    // untracked. the recovery's own passes and the orchestrator's destination
    // layout call the engine directly.
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

    // re-polls an app's announced window until a poll admits it
    private var discoveryFollowUp = DiscoveryFollowUp()
    // a press whose mouse-up never came, checked when it defers a poll
    private var stalePress = StalePressCheck()

    // mouse tracking
    private var mouseMoveMonitor: Any?
    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?
    private var mouseDragMonitor: Any?
    // the compact menu bar badge follows the cursor's screen when nothing has focus
    private var cursorScreenWatch = CursorScreenWatch()
    private var mouseDragLifecycle = MouseDragLifecycleState()
    private var mouseButtonDown: Bool { mouseDragLifecycle.buttonDown }
    private var mouseDraggedSinceDown: Bool { mouseDragLifecycle.sawDragEvent }
    private var mouseDownPointCG: CGPoint?
    private var mouseDownFloatingWindowID: CGWindowID = 0
    // window-list frame of that floater and the cursor, read together at
    // the press. the drag anchor is this pair: a frame read at one moment
    // with a cursor from another bakes the gap in as an offset
    private var mouseDownFloatingFrame: CGRect?
    private var mouseDownFloatingCursorCG: CGPoint?

    // window whose focus border was hidden when a drag started — re-shown on mouseUp.
    // we hide rather than try to follow, because we'd need 60Hz AX polling per window
    // and that's prohibitively expensive.
    private var preDragFocusedID: CGWindowID {
        get { mouseDragLifecycle.preDragFocusedID }
        set { mouseDragLifecycle.preDragFocusedID = newValue }
    }

    // armed when a drag starts on a visible floating window. drives
    // dimmingOverlay.setDragOverride so the bright carve hole tracks the
    // floater live (normal dim mode), and moves the floater outline with it,
    // instead of both trailing on the discovery poll.
    private lazy var dimDrag = FloatingDimDragTracker(
        setCarve: { [weak self] id, rect in
            guard let self, self.floaterDragFollow.carve else { return }
            self.dimmingOverlay.setDragOverride(id: id, rect: rect)
        },
        setLiveFrame: { [weak self] id, frame in
            guard let self, self.floaterDragFollow.outline else { return }
            self.focusBorder.followFloaterDrag(id, to: frame)
        },
        clearCarve: { [dimmingOverlay, focusBorder] in
            dimmingOverlay.clearDragOverride()
            focusBorder.endFloaterDrag()
        })
    // what the armed drag moves, decided at the press
    private var floaterDragFollow = FloaterDragFollow(carve: false, outline: false)

    // true while the Hypr key is physically held. drives focusBrackets — when held,
    // every focus change re-targets the brackets so they track Hypr+arrow even
    // across workspace switches (which transiently hide the focus border).
    private var hyprHeld = false

    // bumped each time the dock activates; the watchdog closure compares against this
    // before clearing dockIsActive so re-activations cancel earlier pending clears.
    private var dockActivationToken: UInt64 = 0

    // date-gated suppression flags. owned here, shared with subsystems via closures.
    // keys: activation-switch, mouse-focus, workspace-transition.
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
    /// Display key of the last settled topology. The auto-save on the first
    /// notification of a transition files the departing layout under this
    /// key — by then `displayManager.screens` already reflects the new one.
    private var settledDisplayKey = ""
    /// the launch restore runs once per process; resuming from pause
    /// restarts the manager but is not a launch
    private var didRunLaunchRestore = false
    private let layoutStore = LayoutSnapshotStore.shared
    private let relaunchHandoffStore = RelaunchHandoffStore.shared

    /// Wire the dependency graph and configure every subsystem callback.
    ///
    /// Construction is in three layers:
    /// 1. Build sub-managers that take only static dependencies.
    /// 2. Build the orchestration layer (including `floatingController`,
    ///    `workspaceOrchestrator`, `pollingScheduler`, `tiledDrag`,
    ///    `actionDispatcher`) and attach the closure handles each one
    ///    needs from `WindowManager`-local helpers.
    /// 3. Route runtime config changes through `ConfigUpdateCoordinator` to
    ///    the right subsystem.
    ///
    /// The recovery hotkey tap starts here so pause/resume works even when
    /// tiling launches disabled. Window discovery and tiling start in `start()`.
    init(config: UserConfig) {
        self.config = config
        self.focusController = FocusStateController(focusBorder: focusBorder)
        self.workspaceManager = WorkspaceManager(displayManager: displayManager)
        self.workspaceManager.onParkFailed = { [weak self] in self?.pollingScheduler.schedule(after: 0.3, trigger: .park) }
        self.tilingEngine = TilingEngine(displayManager: displayManager)
        self.tilingEngine.keepFixedSizeHints(in: .shared)
        self.discovery = WindowDiscoveryService(
            stateCache: stateCache,
            accessibility: accessibility,
            displayManager: displayManager,
            workspaceManager: workspaceManager
        )
        self.discovery.windowSpaces = WindowSpaces.answers
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
        self.workspaceOrchestrator.screenUnderCursor = { [weak self] in self?.displayManager.screenUnderCursor() ?? NSScreen.main! }
        self.workspaceOrchestrator.keepsCursorOnSwitch = { [weak self] in
            self?.config.keepCursorOnWorkspaceSwitch ?? false
        }
        self.workspaceOrchestrator.currentFocusedWindow = { [weak self] in self?.focusResolver.currentFocusedWindow() }
        self.workspaceOrchestrator.updateFocusBorder = { [weak self] w in self?.updateFocusBorder(for: w) }
        self.workspaceOrchestrator.updatePositionCache = { [weak self] in self?.updatePositionCache() }
        self.workspaceOrchestrator.tileAllVisibleSpaces = { [weak self] windows in
            self?.tileAllVisibleSpaces(windows: windows)
        }
        self.workspaceOrchestrator.retile = { [weak self] prepare, completion in
            self?.retile(prepare: prepare, completion: completion)
        }
        // the HUD goes up before the hide/retile/focus pass, not after it
        self.workspaceOrchestrator.onWillSwitch = { [weak self] workspace, screen in
            self?.workspaceOverview.showSwitchHUD(workspace: workspace, screen: screen)
        }
        self.workspaceOrchestrator.onRevealMissed = { [weak self] in self?.pollingScheduler.schedule(after: 0.3, trigger: .reveal) }
        self.workspaceOrchestrator.onFloatersRevealed = { [weak self] windows in self?.markRevealedFloaters(windows) }
        self.workspaceOrchestrator.onDidSwitch = { [weak self] workspace, _ in
            // the switch's recordFocus already ran, so this sticks
            self?.statusPresenter.lastSwitchedWorkspace = workspace
            self?.statusPresenter.updateMenuBarState()
            self?.refreshWorkspaceOverview()
        }
        self.workspaceOrchestrator.floatRule = { [weak self] window in
            self?.floatingController.floatRule(for: window)
        }
        self.workspaceOrchestrator.noteManualTile = { [weak self] id in
            self?.floatingController.noteManualChoice(id, floating: false)
        }
        self.workspaceOrchestrator.isScratchpadWindow = { [weak self] id in
            self?.scratchpad.contains(id) ?? false
        }
        self.workspaceOrchestrator.noteAdmission = { [weak self] result in
            self?.admissionRecovery.note(result)
        }
        // overview and keybind list open where the cursor is, like every hypr action
        self.workspaceOverview.screenUnderCursor = { [weak self] in self?.displayManager.screenUnderCursor() }
        self.keybindOverlay.screenUnderCursor = { [weak self] in self?.displayManager.screenUnderCursor() }
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
        scratchpad.screenUnderCursor = { [weak self] in self?.displayManager.screenUnderCursor() }
        scratchpad.currentFocusedWindow = { [weak self] in self?.focusResolver.currentFocusedWindow() }
        scratchpad.updatePositionCache = { [weak self] in self?.updatePositionCache() }
        scratchpad.updateFocusBorder = { [weak self] w in self?.updateFocusBorder(for: w) }
        scratchpad.refocusUnderCursor = { [weak self] in self?.mouseTracker.refocusUnderCursor() }
        scratchpad.isNeverTile = { [weak self] w in self?.floatingController.isNeverTile(w) ?? false }
        scratchpad.noteManualChoice = { [weak self] id, floating in
            self?.floatingController.noteManualChoice(id, floating: floating)
        }
        scratchpad.retile = { [weak self] prepare, completion in
            self?.retile(prepare: prepare, completion: completion)
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
        // workspace-transition covers switches, moves, the scratchpad, display settle
        // and wake (1.5 to 6 s), so drift can't fire on stale AX frames.
        // mouseButtonDown lives here (not as a drop-guard in pollWindowChanges)
        // so a create/destroy event arriving mid-drag defers and fires on
        // mouseUp instead of being lost until the 10s reconcile.
        pollingScheduler.isSuppressed = { [weak self] in
            guard let self else { return false }
            // hover clears a press whose mouse-up never came, but only on a
            // move. typing with the pointer still kept every poll deferred
            if self.stalePress.isStale(pressHeld: self.mouseButtonDown,
                                       physicalDown: self.mouseTracker.isPhysicalButtonDown(),
                                       now: CFAbsoluteTimeGetCurrent()) {
                hyprLog(.notice, .mouse, "press state stuck with no button held — clearing so the deferred poll runs")
                self.clearStalePress()
            }
            return self.mouseButtonDown
                || self.tiledDrag.isFinishingDrag
                || self.suppressions.isSuppressed(.workspaceTransition)
        }
        pollingScheduler.suppressionReason = { [weak self] in
            guard let self else { return "stopped" }
            if self.mouseButtonDown { return "mouse button down" }
            if self.tiledDrag.isFinishingDrag { return "tiled drag finishing" }
            let left = self.suppressions.remaining(.workspaceTransition).map { " (\(Int(($0 * 1000).rounded()))ms left)" } ?? ""
            return "workspace transition" + left
        }
        // a transition's end is known, so a deferred poll runs right then
        // rather than up to one 0.3 s step later
        pollingScheduler.suppressionEndsIn = { [weak self] in
            guard let self, !self.mouseButtonDown, !self.tiledDrag.isFinishingDrag else { return nil }
            return self.suppressions.remaining(.workspaceTransition)
        }
        // a window opened right after a switch is tiled once the switch is
        // done, not when its hold ends. existing windows still wait
        pollingScheduler.admitsNewWindowsDuringHold = { [weak self] in
            guard let self else { return false }
            return SwitchHoldAdmission.allows(
                heldOnlyBySwitch: self.suppressions.isHeldOnlyByWorkspaceSwitch(.workspaceTransition),
                switchSettled: self.workspaceOrchestrator.isSwitchSettled,
                mouseButtonDown: self.mouseButtonDown,
                finishingDrag: self.tiledDrag.isFinishingDrag,
                displayTransitionPending: self.displayTransitionPending,
                sessionInterrupted: self.discovery.isSessionInterrupted)
        }
        pollingScheduler.onAdmitDuringHold = { [weak self] in self?.admitNewWindowsDuringHold() }

        hotkeyManager.onAction = { [weak self] action in
            guard let self else { return }
            // hotkeys arrive through an event tap, which the lock screen's
            // secure input keeps key events from, so one firing means the
            // session is in use again
            self.discovery.endSessionInterruption(evidence: "hotkey press")
            self.performUserAction(action)
        }

        hotkeyManager.sharesHomeMonitor = { [weak self] a, b in
            guard let wm = self?.workspaceManager,
                  let sa = wm.homeScreenForWorkspace(a),
                  let sb = wm.homeScreenForWorkspace(b) else { return false }
            return wm.screenID(for: sa) == wm.screenID(for: sb)
        }

        hotkeyManager.onHyprKeyDown = { [weak self] in
            guard let self, self.config.enabled else { return }
            self.hyprHeld = true
            let mousePressActive = self.mouseDragLifecycle.buttonDown
            self.mouseDragLifecycle.noteHyprKeyDown()
            // a latched Hypr turns the drop into a swap
            self.tiledDrag.refreshPreview()
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
                    self.focusResolver.ensureFocus()
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
        mouseTracker.onStalePress = { [weak self] in self?.clearStalePress() }
        mouseTracker.mouseTargetAt = { [weak self] point in
            guard let self else { return 0 }
            let number = NSWindow.windowNumber(at: self.displayManager.flippedY(point),
                                               belowWindowWithWindowNumber: 0)
            return CGWindowID(clamping: number)
        }
        mouseTracker.primaryScreenHeight = { [weak self] in self?.displayManager.primaryScreenHeight ?? 0 }
        mouseTracker.screenAt = { [weak self] pt in self?.displayManager.screen(at: pt) }
        mouseTracker.floatingWindowIDs = { [weak self] in self?.stateCache.floatingWindowIDs ?? [] }
        mouseTracker.isWindowVisible = { [weak self] wid in self?.focusResolver.isInteractive(wid) ?? false }
        // our own panels sit over other windows; hover must not reach through them
        mouseTracker.isOwnUIOpen = { OwnPanelTracker.shared.isAnyOpen }
        mouseTracker.cachedWindow = { [weak self] wid in self?.stateCache.cachedWindows[wid] }
        mouseTracker.tiledPositions = { [weak self] in
            guard let self else { return [:] }
            // the background tiles and the layer's tiles overlap
            guard self.scratchpad.isVisible else { return self.stateCache.tiledPositions }
            return self.stateCache.tiledPositions.filter { self.scratchpad.isSummoned($0.key) }
        }
        mouseTracker.onFocusForFFM = { [weak self] w in self?.focusForFFM(w) }
        mouseTracker.onUpdateFocusBorder = { [weak self] w in self?.updateFocusBorder(for: w) }
        mouseTracker.isMouseFocusSuppressed = { [weak self] in self?.suppressions.isSuppressed(.mouseFocus) ?? false }
        mouseTracker.lastFocusedID = { [weak self] in self?.focusController.lastFocusedID ?? 0 }
        mouseTracker.recordFocus = { [weak self] id, reason in self?.focusController.recordFocus(id, reason: reason) }

        // fast path for getFocusedWindow: resolve the focused element's
        // CGWindowID against the last discovery snapshot before falling back
        // to a full AX walk.
        accessibility.cachedWindowLookup = { [weak self] wid in self?.stateCache.cachedWindows[wid] }

        // wire up floating controller — closure handles for WM-side helpers.
        floatingController.retile = { [weak self] prepare in
            self?.retile(prepare: prepare)
        }
        floatingController.updateFocusBorder = { [weak self] w in self?.updateFocusBorder(for: w) }
        floatingController.updatePositionCache = { [weak self] in self?.updatePositionCache() }
        floatingController.isMenuTracking = { [weak self] in self?.mouseTracker.menuTracking ?? false }
        floatingController.isScratchpadVisible = { [weak self] in self?.scratchpad.isVisible ?? false }
        floatingController.excludedBundleIDs = { [weak self] in Set(self?.config.excludedBundleIDs ?? []) }
        floatingController.floatingRules = { [weak self] in self?.config.floatingRules ?? [] }
        discovery.hasManualChoice = { [weak self] id in self?.floatingController.manualChoice(for: id) != nil }
        floatingController.isDisplayTransitionPending = { [weak self] in self?.displayTransitionPending ?? false }
        floatingController.onMaximizeEnded = { [weak self] screen in
            self?.workspaceOverview.showFullscreenHUD(isOn: false, screen: screen)
            self?.statusPresenter.updateMenuBarState()
        }
        floatingController.findPopup = { [weak self] windows, front in
            self?.mouseTracker.livePopup(in: windows, frontmostPID: front)
        }
        floatingController.rejectFloatToTile = { [weak self] w, reason in
            guard let self, let frame = w.frame ?? self.stateCache.cachedWindows[w.windowID]?.frame else { return }
            self.focusBorder.flashError(around: frame, windowID: w.windowID,
                                        message: FloatToTileRejectionMessage.text(for: reason))
        }

        // the restore must not lift the tile back over the floater it just raised
        floatingController.onRestack = { [weak self] in self?.scheduleRestackRefresh(after: 0.02) }

        // hover, Hypr+Arrow and focus repair go through the router. newcomers
        // in admission recovery are drawn over the tiles like floaters, as in
        // clickFocusTarget, so they count as covers and not as tiles.
        tiledFocusRouter.raiseFloatersBeforeFocus = { [weak self] target in
            self?.floatingController.raiseFloatersBeforeFocus(target)
        }
        tiledFocusRouter.liftOverFloaters = { [weak self] target in
            self?.floatingController.liftOverFloaters(target)
        }
        suppressions.frontmostPID = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
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
            self?.tiledDragFeedback.reconcileRecovery(workspace: workspace, screen: screen,
                                                      result: result)
        }

        self.tiledDragFeedback = makeTiledDragFeedback()
        self.tiledDrag = TiledDragController(
            config: config,
            displayManager: displayManager,
            tilingEngine: tilingEngine,
            workspaceManager: workspaceManager,
            stateCache: stateCache,
            minimaRevalidation: minimaRevalidation,
            scratchpad: scratchpad,
            focusController: focusController,
            focusBorder: focusBorder,
            focusBrackets: focusBrackets,
            feedback: tiledDragFeedback)
        tiledDrag.isManagerRunning = { [weak self] in self?.isRunning ?? false }
        tiledDrag.pressPoint = { [weak self] in self?.mouseDownPointCG }
        tiledDrag.releaseRequestsSwap = { [weak self] in
            guard let self else { return false }
            return self.mouseDragLifecycle.releaseRequestsSwap(hyprHeld: self.hyprHeld)
        }
        tiledDrag.visibleFloatingWindows = { [weak self] in self?.focusResolver.visibleFloatingWindows() ?? [] }
        // read at the press, just after notePressedFloater refreshed the list
        tiledDrag.pressHit = { [weak self] point in
            guard let self, self.mouseTracker.stackedWindows() != nil else { return nil }
            return self.mouseTracker.hitTest(at: point)
        }
        tiledDrag.isFullscreenSuppressed = { [weak self] w in self?.isFullscreenSuppressed(focused: w) ?? false }
        tiledDrag.refreshDimming = { [weak self] rects in self?.refreshDimming(tiledRectsOverride: rects) }
        tiledDrag.schedulePoll = { [weak self] in self?.pollingScheduler.schedule(trigger: .drag) }
        focusBorder.onErrorFeedbackFinishedToken = { [weak self] token in
            self?.tiledDragFeedback.errorFinished(token: token)
        }
        focusBorder.onErrorFeedbackFinished = { [weak self] in
            guard let self else { return }
            guard self.isRunning, self.config.showFocusBorder,
                  let focused = self.focusResolver.currentFocusedWindow() else { return }
            self.updateFocusBorder(for: focused)
        }
        driftMonitor.isSuspended = { [weak self] in
            guard let self else { return true }
            return self.mouseButtonDown
                || self.tiledDrag.isFinishingDrag
                || self.displayTransitionPending
                || self.suppressions.isSuppressed(.workspaceTransition)
        }

        // action dispatcher — owns the per-Action routing.
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
        actionDispatcher.currentFocusedWindow = { [weak self] in self?.focusResolver.currentFocusedWindow() }
        actionDispatcher.updateFocusBorder = { [weak self] w in self?.updateFocusBorder(for: w) }
        actionDispatcher.updatePositionCache = { [weak self] in self?.updatePositionCache() }
        actionDispatcher.screenUnderCursor = { [weak self] in self?.displayManager.screenUnderCursor() ?? NSScreen.main! }
        actionDispatcher.applyForgottenIDCleanup = { [weak self] id in self?.applyForgottenIDExternalCleanup(id) }
        actionDispatcher.retile = { [weak self] windows in
            self?.retile(windows: windows) ?? []
        }
        actionDispatcher.refocusUnderCursor = { [weak self] in self?.mouseTracker.refocusUnderCursor() }
        actionDispatcher.refreshPositionCache = { [weak self] windows in
            self?.updatePositionCache(windows: windows)
        }
        actionDispatcher.isMenuTracking = { [weak self] in self?.mouseTracker.menuTracking ?? false }
        actionDispatcher.heldWindowIDs = { [weak self] in
            guard let self else { return [] }
            return self.heldWindowIDs
        }
        actionDispatcher.openPopup = { [weak self] in self?.mouseTracker.openPopup(maxAge: 0) }
        actionDispatcher.focusWindow = { [weak self] w, reason in
            self?.tiledFocusRouter.focus(w, reason: reason, fallback: .activate)
        }
        actionDispatcher.toggleScratchpad = { [weak self] in self?.scratchpad.toggle() }
        actionDispatcher.moveToScratchpad = { [weak self] in self?.scratchpad.sendFocusedWindow() }
        actionDispatcher.scratchpadLayer = { [weak self] in self?.scratchpad.visibleLayer }
        actionDispatcher.scratchpadLayoutChanged = { [weak self] in self?.scratchpad.syncTiledFrames() }
        actionDispatcher.refocusScratchpad = { [weak self] in
            self?.scratchpad.refocusMember(reason: "ensureInvariant-scratchpad")
        }
        actionDispatcher.admitToScratchpad = { [weak self] w in self?.scratchpad.admitNewWindow(w) ?? false }
        actionDispatcher.adoptPinnedToScratchpad = { [weak self] w in
            guard let self else { return }
            self.scratchpad.adoptPinned(w, summon: !self.displayTransitionPending)
        }
        actionDispatcher.scratchpadDiscovery = { [weak self] gone, returned in
            self?.scratchpad.noteDiscovery(goneIDs: gone, returned: returned)
        }
        actionDispatcher.scratchpadTabSwitch = { [weak self] hidden, shown in
            self?.scratchpad.noteTabSwitch(from: hidden, to: shown)
        }
        actionDispatcher.enforceScratchpadFocus = { [weak self] in self?.scratchpad.enforceFocus() }
        actionDispatcher.saveLayout = { [weak self] in self?.saveLayoutSnapshot(manual: true) }
        actionDispatcher.restoreLayout = { [weak self] in self?.restoreLayoutSnapshot(manual: true) }
        actionDispatcher.retileAll = { [weak self] in self?.retileAllRequested() }
        actionDispatcher.showWindowRules = { [weak self] in
            guard let self else { return }
            // Hypr+I again closes it
            if self.windowRulesOverlay.isShowing {
                self.windowRulesOverlay.close()
                return
            }
            guard let focused = self.focusResolver.currentFocusedWindow() else { return }
            self.showWindowRules(for: focused.windowID)
        }
        floatingRuleCommands.window = { [weak self] id in
            guard let self, self.stateCache.knownWindowIDs.contains(id),
                  !self.stateCache.hiddenWindowIDs.contains(id) else { return nil }
            return self.stateCache.cachedWindows[id]
        }
        floatingRuleCommands.isFloating = { [weak self] id in self?.stateCache.floatingWindowIDs.contains(id) ?? false }
        floatingRuleCommands.clearManualChoice = { [weak self] id in self?.floatingController.forgetManualChoice(id) }
        failedTilePrompt.chooseRules = { [weak self] id in self?.showWindowRules(for: id) }
        windowRulesOverlay.restoreFocus = { [weak self] id in
            guard let self, let window = self.stateCache.cachedWindows[id] else { return }
            window.focus()
            self.focusController.recordFocus(id, reason: "rules-overlay-closed")
        }
        windowRulesOverlay.perform = { [weak self] row, match, id in
            guard let commands = self?.floatingRuleCommands else { return }
            switch row {
            case .floatApp: commands.setAppRule(id, action: .float)
            case .tileApp: commands.setAppRule(id, action: .tile)
            case .floatTitle: if let match { commands.setTitleRule(id, match: match, action: .float) }
            case .tileTitle: if let match { commands.setTitleRule(id, match: match, action: .tile) }
            case .forget: commands.forget(id)
            }
        }
        floatingRuleCommands.refuse = { [weak self] window, message in
            guard let self, let frame = window.frame ?? self.stateCache.cachedWindows[window.windowID]?.frame else {
                NSSound.beep()
                return
            }
            self.focusBorder.flashError(around: frame, windowID: window.windowID, message: message)
        }
        actionDispatcher.exemptFromDrift = { [weak self] id in self?.discovery.exemptFromDrift(id) }
        actionDispatcher.endDriftExemption = { [weak self] id in self?.discovery.endDriftExemption(id) }
        actionDispatcher.cancelAdmissionRecovery = { [weak self] id, reason in
            self?.admissionRecovery.cancel(id, reason: reason)
        }
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

        self.statusPresenter = WorkspaceStatusPresenter(
            config: config,
            accessibility: accessibility,
            displayManager: displayManager,
            workspaceManager: workspaceManager,
            tilingEngine: tilingEngine,
            stateCache: stateCache,
            scratchpad: scratchpad,
            focusController: focusController)
        self.placement = WindowPlacement(
            config: config,
            accessibility: accessibility,
            displayManager: displayManager,
            workspaceManager: workspaceManager,
            tilingEngine: tilingEngine,
            stateCache: stateCache,
            floatingController: floatingController,
            scratchpad: scratchpad,
            actionDispatcher: actionDispatcher,
            workspaceOrchestrator: workspaceOrchestrator)
        self.focusResolver = FocusResolver(
            displayManager: displayManager,
            workspaceManager: workspaceManager,
            stateCache: stateCache,
            accessibility: accessibility,
            focusController: focusController,
            focusBorder: focusBorder,
            scratchpad: scratchpad,
            suppressions: suppressions,
            tiledFocusRouter: tiledFocusRouter)
        focusResolver.updateFocusBorder = { [weak self] w in self?.updateFocusBorder(for: w) }

        configureStatusExport()
        configureLiveConfigUpdates()
        hotkeyManager.updateHyprKey(config.hyprKey)
        hotkeyManager.updateKeybinds(config.keybinds)
        hotkeyManager.start()
        hotkeyManager.updateTilingEnabled(config.enabled)
        hotkeyManager.updateDoubleTapCapsLock(config.doubleTapHyprTogglesCapsLock)
    }

    private func configureStatusExport() {
        statusExporter.isEnabled = { [weak self] in
            guard let self else { return false }
            return self.isRunning && self.config.statusExportEnabled
        }
        statusExporter.hookCommand = { [weak self] in self?.config.statusHookCommand }
        statusExporter.snapshot = { [weak self] in self?.statusPresenter.statusSnapshot() }
        focusController.onChange = { [weak self] in
            // the badge and state.json show the focused window's workspace again
            self?.statusPresenter.lastSwitchedWorkspace = nil
            self?.statusExporter.noteChange()
            self?.endMaximizeIfFocusLeft()
            self?.statusPresenter.updateMenuBarState()
        }
        tilingEngine.onMaximizeChanged = { [weak self] workspace, screen, isOn in
            guard let self, self.isRunning, !self.displayTransitionPending else { return }
            self.statusPresenter.updateMenuBarState()
            guard let screen, self.workspaceManager.isWorkspaceVisible(workspace) else { return }
            self.workspaceOverview.showFullscreenHUD(isOn: isOn, screen: screen)
        }
        statusPresenter.maximizedFloaterIDs = { [weak self] in self?.floatingController.maximizedIDs ?? [] }
        actionDispatcher.onFloaterMaximizeChanged = { [weak self] screen, isOn in
            self?.workspaceOverview.showFullscreenHUD(isOn: isOn, screen: screen)
            self?.statusPresenter.updateMenuBarState()
        }
        // workspace names, the toggle itself. objectWillChange fires before
        // the write, so the note waits a turn to see the new value
        statusConfigObservation = config.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.statusExporter.noteChange()
        }
        floatingController.markRulesApplied()
        // an edit here moves open windows; a reload (iCloud, Nix, a hand
        // edit) or a reset doesn't, as Never tile edits never did
        floatingRuleSync = FloatingRuleSync(
            config: config,
            applyLocalEdit: { [weak self] in self?.floatingRulesChanged() },
            rebase: { [weak self] in self?.floatingController.markRulesApplied() })
    }

    /// Observe the model's post-mutation signal once and route a complete
    /// snapshot. A disk reload emits only after all fields have been applied.
    private func configureLiveConfigUpdates() {
        let coordinator = configUpdateCoordinator

        coordinator.onEnabled = { [weak self] enabled in
            guard let self else { return }
            self.hotkeyManager.updateTilingEnabled(enabled)
            // paused, Caps Lock goes back to being Caps Lock (#94)
            KeyRemapper.applyHyprKey(self.config.hyprKey, enabled: enabled)
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
            // no remap for a key picked while paused; resume installs it
            KeyRemapper.applyHyprKey(key, enabled: self?.config.enabled ?? true)
            self?.hotkeyManager.updateHyprKey(key)
        }
        coordinator.onLayoutGeometry = { [weak self] gap, padding in
            guard let self else { return }
            self.tilingEngine.gapSize = gap
            self.tilingEngine.outerPadding = padding
            if self.isRunning { self.retile() }
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
        coordinator.onOuterPaddingOverride = { [weak self] padding in
            guard let self else { return }
            self.tilingEngine.outerPaddingPerMonitor = padding
            if self.isRunning { self.retile() }
        }
        coordinator.onWorkspaceMonitors = { [weak self] mapping, perSet in
            guard let self else { return }
            self.workspaceManager.workspaceMonitors = mapping
            self.workspaceManager.workspaceMonitorsPerDisplaySet = perSet
            // homes moved, not windows: the same reconcile a monitor
            // plug or unplug runs carries the trees to them
            if self.isRunning { self.reconcileAfterDisplayChange() }
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
        coordinator.onDoubleTapCapsLock = { [weak self] on in
            self?.hotkeyManager.updateDoubleTapCapsLock(on)
        }

        coordinator.observe(config)
    }

    private func applyChromeConfig(_ state: RuntimeConfigState, changes: ChromeConfigChanges) {
        let focusColor = state.focusBorderColorHex.flatMap(NSColor.fromHex) ?? .hyprCyan
        let floatingColor = state.floatingBorderColorHex.flatMap(NSColor.fromHex) ?? .hyprMagenta
        let bracketColor = state.focusBracketColorHex.flatMap(NSColor.fromHex)
            ?? UserConfigDefaults.focusBracketColor

        // before .colors, so a repaint in the same update uses the new fill
        if changes.contains(.focusFlash) {
            focusBorder.flashesOnFocus = state.focusBorderFlash
        }
        if changes.contains(.colors) {
            let trackedID = focusBorder.trackedWindowID ?? 0
            let trackedColor = stateCache.floatingWindowIDs.contains(trackedID)
                ? floatingColor : focusColor
            focusBorder.refreshAppearance(
                focusColor: trackedColor.cgColor,
                floatingColor: floatingColor.cgColor)
        }
        if changes.contains(.bracketAppearance) || changes.contains(.colors) {
            let markedID = focusBrackets.trackedWindowID ?? 0
            focusBrackets.applyAppearance(
                style: state.focusBracketStyle,
                color: FocusMarkColor.resolve(
                    focusedIsFloating: stateCache.floatingWindowIDs.contains(markedID),
                    markColor: bracketColor.cgColor,
                    floatingColor: floatingColor.cgColor),
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
        }
        if changes.contains(.visibility) || changes.contains(.bracketAppearance) {
            focusBorder.setFloaterMarks(
                FloaterMarkStyle.resolve(showFocusBorder: state.showFocusBorder,
                                         bracketStyle: state.focusBracketStyle))
        }
        if changes.contains(.visibility) {
            if state.showFocusBorder, isRunning {
                let focusedID = focusBorder.trackedWindowID ?? focusController.lastFocusedID
                if let focused = stateCache.cachedWindows[focusedID] {
                    updateFocusBorder(for: focused)
                } else {
                    refreshFloatingBorders(windows: Array(stateCache.cachedWindows.values))
                }
            } else if isRunning {
                // corners mode outlines the floaters without a focus border
                refreshFloatingBorders(windows: Array(stateCache.cachedWindows.values))
            }
        } else if changes.contains(.bracketAppearance), isRunning {
            // style on or off decides whether the floaters are outlined
            refreshFloatingBorders(windows: Array(stateCache.cachedWindows.values))
        }
        if changes.contains(.dimming) || changes.contains(.windowCornerRadius) {
            if isRunning { refreshDimming() }
        }
    }

    /// Bring the window manager up: mouse monitors, workspace observers and
    /// the polling scheduler. The hotkey tap is already up from `init`.
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
            self.discoveryFollowUp.noteEvent("\(kind)", pid: pid, now: CFAbsoluteTimeGetCurrent())
            switch kind {
            case .windowDestroyed:
                self.destroyRecheck.noteDestroy(pid: pid)
                self.pollingScheduler.schedule(trigger: .destroy)
            case .windowCreated, .windowDeminiaturized:
                // trailing: a poll already pending can run ms after this,
                // before AX lists the window. the watch re-polls if this one
                // misses it too
                self.discoveryFollowUp.watch(pid: pid, reason: "\(kind)", blindRetry: true,
                                             now: CFAbsoluteTimeGetCurrent())
                let outcome = self.pollingScheduler.schedule(after: 0.2, trigger: .create, trailing: true)
                hyprLog(.notice, .discovery, "ax \(kind) pid=\(pid): \(outcome.description)"
                        + (self.pollHoldReason.map { ", polls held: \($0)" } ?? ""))
            case .windowMiniaturized:
                self.pollingScheduler.schedule(after: 0.2)
            case .focusedWindowChanged:
                self.scheduleFocusPoll(pid: pid, via: "axFocus", after: 0.15)
                self.scheduleRestackRefresh(after: 0.05)
            case .mainWindowChanged:
                // a new main window usually came forward. it needs a poll
                // only if the app has a window on screen no poll has seen,
                // or the window is one discovery holds as hidden: a
                // background tab selected again sends nothing else, and its
                // tile kept the tab that left until the next reconcile
                if let main = self.accessibility.focusedWindowID(ofPID: pid),
                   self.stateCache.hiddenWindowIDs.contains(main) {
                    self.pollingScheduler.schedule(after: 0.15, trigger: .focus)
                } else {
                    self.pollIfUnseenWindow(pid: pid, via: "axMain", after: 0.15)
                }
                self.scheduleRestackRefresh(after: 0.05)
            }
        }

        tilingEngine.gapSize = config.gapSize
        tilingEngine.outerPadding = config.outerPadding
        tilingEngine.maxSplitsPerMonitor = config.maxSplitsPerMonitor
        tilingEngine.outerPaddingPerMonitor = config.outerPaddingPerMonitor
        scratchpad.tiledRegionInset = config.scratchpadRegionInset
        scratchpad.tileNewMembers = config.scratchpadTileByDefault
        focusBorder.isEnabled = config.showFocusBorder
        focusBorder.flashesOnFocus = config.focusBorderFlash
        focusBorder.setFloaterMarks(floaterMarks)
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
        workspaceManager.workspaceMonitors = config.workspaceMonitors
        workspaceManager.workspaceMonitorsPerDisplaySet = config.workspaceMonitorsPerDisplaySet
        hotkeyManager.updateHyprKey(config.hyprKey)
        hotkeyManager.updateKeybinds(config.keybinds)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.isRunning else { return }
            self.workspaceManager.initializeMonitors()
            self.settledDisplayKey = LayoutSnapshotStore.displayKey(screens: self.displayManager.screens)
            let initialWindows = self.snapshotAndTile()
            if !self.didRunLaunchRestore {
                self.didRunLaunchRestore = true
                // an update relaunch puts the desk back as it was. any
                // other launch follows the Restore at launch setting
                let key = LayoutSnapshotStore.displayKey(screens: self.displayManager.screens)
                if let handoff = self.relaunchHandoffStore.take(displayKey: key) {
                    self.restoreRelaunchHandoff(handoff, windows: initialWindows)
                } else if self.config.restoreLayoutOnLaunch {
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
            // windows as new, and trigger a retile that blocks the correct
            // initial distribution. the timer is now a slow (10s) safety net;
            // AX notifications above are the primary trigger.
            self.pollingScheduler.start()
            self.statusPresenter.dumpState(reason: "startup")
        }

        // SIGUSR1 dumps state on demand over ssh. the default handler
        // kills the process, so ignore it first and let the dispatch
        // source pick it up on the main thread.
        signal(SIGUSR1, SIG_IGN)
        let dumpSignal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        dumpSignal.setEventHandler { [weak self] in self?.statusPresenter.dumpState(reason: "SIGUSR1") }
        dumpSignal.resume()
        dumpStateSignalSource = dumpSignal

        startMouseTracking()
        screenshotPicker.onChange = { [weak self] open in
            guard let self, self.isRunning else { return }
            if open {
                self.dimmingOverlay.hideImmediately()
            } else {
                self.refreshDimming()
            }
        }
        screenshotPicker.start()

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
        // before isRunning drops, while the export still counts as on.
        // keepPauseShortcut false is the quit
        statusExporter.clear(quitting: !keepPauseShortcut)
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
        tiledDrag.cancel()
        tiledDrag.endTiledDropPreview()
        tiledDragFeedback.reset()
        tilingEngine.endAllMaximized()
        floatingController.forgetAllMaximized()
        _ = tilingEngine.beginLayoutGeneration()
        restoreAllWindows()
        axNotifications.detachAll()
        pollingScheduler.stop()
        discoveryFollowUp = DiscoveryFollowUp()
        screenshotPicker.stop()
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

    // MARK: - mouse tracking

    /// Install global NSEvent monitors for mouse move/down/drag/up.
    ///
    /// Each monitor delegates to `mouseTracker` (move) or local helpers
    /// (down/drag/up) that maintain the drag-detection scratchpad and the
    /// pre-drag focus-border state. The drag monitor hides the focus border
    /// for floating windows because the border only repositions on the
    /// discovery poll and would otherwise lag the live drag at 60Hz; mouseUp restores
    /// it after a short settle delay.
    /// The move monitor also feeds `noteCursorScreen`, with or without
    /// focus-follows-mouse.
    private func startMouseTracking() {
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.mouseTracker.handleMouseMove()
            self?.noteCursorScreen()
        }
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return }
            self.mouseDragLifecycle.beginPress(hyprHeld: self.hyprHeld)
            self.stalePress.reset()
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
            let downNS = self.displayManager.flippedY(downCG)
            self.mouseDownPointCG = downCG
            // a press is what opens a menu, so the next hover must read a fresh list
            self.mouseTracker.invalidateWindowListCache()
            // before the AX-heavy capture below, so the floater has not moved yet
            self.notePressedFloater()
            self.tiledDrag.handleMouseDown(at: downCG)
            self.armFloaterDrag()
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
            // remember a real click on a window for the check at mouse-up.
            // our own synthetic clicks and Hypr gestures do not count.
            self.realClickInProgress = false
            if case .window = hit, !self.hyprHeld, !Self.isOwnSyntheticEvent(event) {
                self.realClickInProgress = true
            }
            // scratchpad is quasimodal: a click outside every member dismisses
            // it in the same tick, so the click lands on the tile it aimed at
            if self.scratchpad.isVisible {
                let cgPoint = self.displayManager.flippedY(downNS)
                self.scratchpad.handleMouseDown(atCG: cgPoint, synthetic: Self.isOwnSyntheticEvent(event))
            }
        }
        // when the user drags a floating window, its frame changes 60Hz but the
        // poll only reads it every so often. the dim carve and the floater
        // outline follow the live drag rect instead; the focused border hides
        // for the drag and comes back on mouseUp.
        mouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self = self else { return }
            self.mouseDragLifecycle.observeDrag(hyprHeld: self.hyprHeld)
            self.tiledDrag.updateTiledDropPreview(event)
            self.dimDrag.update(cursorCG: self.displayManager.flippedY(NSEvent.mouseLocation))
            guard self.preDragFocusedID == 0 else { return }
            guard let tid = self.focusBorder.trackedWindowID else { return }
            // only hide for floating windows — tiled windows can't be free-dragged
            guard self.stateCache.floatingWindowIDs.contains(tid) else { return }
            self.preDragFocusedID = tid
            self.focusBorder.hide()
            // the scrim stays: re-shown later it would come back above the members
            if !self.scratchpad.isVisible { self.dimmingOverlay.hideAll() }
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            let shouldDetectDrag = self?.mouseDraggedSinceDown ?? false
            let draggedFloatingID = self?.mouseDownFloatingWindowID ?? 0
            let draggedFloatingFrame = self?.mouseDownFloatingFrame
            var floaterDragged = false
            // the drop decides now; the preview has said all it can
            self?.tiledDrag.endTiledDropPreview()
            if shouldDetectDrag { self?.endMaximizeIfMoved() }
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
                    swapRequested: self.mouseDragLifecycle.releaseRequestsSwap(hyprHeld: self.hyprHeld))
                self.tiledDrag.handleMouseUp(release)
                // a click lifts the tile, which is fine: it has focus now. the tile
                // that lost focus may still cover a floater, so check for that,
                // and redraw the cutouts once the stack settles.
                let wasRealClick = self.realClickInProgress
                self.realClickInProgress = false
                if wasRealClick, !isDrag, !release.swapRequested {
                    DispatchQueue.main.asyncAfter(deadline: .now() + FloatingWindowController.clickRaiseDelay) { [weak self] in
                        // a new press means a double click; its own mouse-up decides
                        guard let self, self.isRunning, !self.mouseButtonDown else { return }
                        self.floatingController.raiseBehind()
                    }
                }
                self.scheduleRestackRefresh(after: 0.06)
            }
            self?.mouseDragLifecycle.finishPress()
            self?.mouseTracker.invalidateWindowListCache()
            self?.mouseDownPointCG = nil
            self?.mouseDownFloatingWindowID = 0
            self?.mouseDownFloatingFrame = nil
            self?.mouseDownFloatingCursorCG = nil
            if self?.dimDrag.isArmed == true {
                self?.dimDrag.finish()
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
            // syncTracker last recorded. retry the refocus 200ms later, through the
            // tracker's own gates.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.mouseTracker.refocusUnderCursor(afterMouseUp: true)
            }
        }
    }

    /// The compact badge and state.json fall back to the cursor's screen,
    /// so a move to another screen redraws the badge and notes an export
    /// change. Throttled; nothing with one screen. A screen change also
    /// ends a switch's hold, in any style.
    private func noteCursorScreen() {
        guard displayManager.screens.count > 1, cursorScreenWatch.noteMove() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + CursorScreenWatch.delay) { [weak self] in
            guard let self else { return }
            let cursorScreen = self.displayManager.screenUnderCursor()
            let screen = self.workspaceManager.screenID(for: cursorScreen)
            guard self.cursorScreenWatch.check(screen: screen) else { return }
            // the switch's own warp lands on the switched-to screen, so that one doesn't count
            if self.workspaceManager.workspaceForScreen(cursorScreen) != self.statusPresenter.lastSwitchedWorkspace {
                self.statusPresenter.lastSwitchedWorkspace = nil
            }
            // no-op with the export off
            self.statusExporter.noteChange()
            // the style is read here, not on every move
            guard self.isRunning, MenuBarStyle.stored == .compact else { return }
            self.statusPresenter.updateMenuBarState()
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
        mouseMoveMonitor = nil
        mouseDownMonitor = nil
        mouseDragMonitor = nil
        mouseUpMonitor = nil
        tiledDrag.endTiledDropPreview()
        mouseDownPointCG = nil
        mouseDownFloatingWindowID = 0
        mouseDownFloatingFrame = nil
        mouseDownFloatingCursorCG = nil
        realClickInProgress = false
        // teardown can land mid-drag — drop the overlay's override too or a
        // stale carve hole survives until the next full update
        dimDrag.finish()
    }

    /// Drops a press whose mouse-up never arrived. Hover found the state
    /// down with no button held.
    private func clearStalePress() {
        mouseDragLifecycle.finishPress()
        tiledDrag.cancel()
        tiledDrag.endTiledDropPreview()
        mouseDownPointCG = nil
        mouseDownFloatingWindowID = 0
        mouseDownFloatingFrame = nil
        mouseDownFloatingCursorCG = nil
        realClickInProgress = false
        dimDrag.finish()
        mouseTracker.invalidateWindowListCache()
    }

    /// `true` for a mouse event HyprMac posted itself, such as the hover
    /// path's synthetic click. Those never count as the user's click.
    static func isOwnSyntheticEvent(_ event: NSEvent) -> Bool {
        guard let cg = event.cgEvent else { return false }
        return cg.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
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
              config.dimInactiveWindows || floaterMarks != .none,
              stateCache.floatingWindowIDs.contains(where: workspaceManager.isWindowVisible) else { return }
        restackRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.restackRefreshPending = false
            // a press may be a drag, which hides the dim and border itself;
            // its mouse-up schedules another pass. a finishing tiled drag
            // redraws when it settles.
            guard self.isRunning, !self.mouseButtonDown,
                  !self.tiledDrag.isFinishingDrag else { return }
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
    /// directly into the target process. That path lifts the window, which is
    /// what the floater rule wants: the focused window sits above a floater.
    private func focusForFFM(_ window: HyprWindow) {
        // while the scratchpad is up, hovering the dimmed tiles behind it
        // must not steal focus — the layer is quasimodal
        if scratchpad.isVisible && !scratchpad.isSummoned(window.windowID) { return }
        suppressions.suppress(.activationSwitch, for: SuppressionDelay.activationSwitch)
        tiledFocusRouter.focus(window, reason: "ffm", fallback: .activateAndClick)
        updateFocusBorder(for: window)
    }

    /// `true` when a fullscreen window is currently driving the active Space.
    /// Checks `window` first (commonly the new focus target), falls back to
    /// the active app's focused-window AX query. Results are not cached:
    /// two AX reads per call, on focus change rather than every frame.
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

    /// Reposition the focus border around `window`, refresh the floating
    /// outlines, and rebuild the dim mask for the new focused window.
    ///
    /// The border and dim paths are independent: each respects its own
    /// config toggle. Disabling the border doesn't disable dim (and vice
    /// versa) — `refreshDimming` always runs and reads
    /// `config.dimInactiveWindows` itself.
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
        // the chrome goes where the window is drawn. some apps' AX frame
        // stops updating (onScreenFrame)
        let drawnFrame = window.onScreenFrame()
        if hyprHeld, let frame = drawnFrame {
            focusBrackets.applyAppearance(
                style: config.focusBracketStyle,
                color: focusMarkColor(for: window.windowID),
                radius: config.resolvedFocusBracketRadius,
                thickness: config.resolvedFocusBracketThickness,
                length: config.resolvedFocusBracketLength)
            focusBrackets.show(around: frame, windowID: window.windowID,
                               glide: focusGlide.traversal(from: focusBrackets.frame, to: frame))
            focusGlide.startTraversal()
        }
        if config.showFocusBorder, let frame = drawnFrame {
            focusBorder.accentCGColor = stateCache.floatingWindowIDs.contains(window.windowID)
                ? config.resolvedFloatingBorderColor.cgColor
                : config.resolvedFocusBorderColor.cgColor
            focusBorder.show(around: frame, windowID: window.windowID,
                             glide: focusGlide.traversal(from: focusBorder.frame, to: frame))
            focusGlide.startTraversal()
            // cache-based on both paths — this runs on every FFM focus
            // change, and the floating branch used to re-enumerate the
            // whole desktop. floatingFrames reads live AX frames from the
            // cached windows; a floater created since the last poll gets
            // its outline on the next poll (<1s).
            refreshFloatingBorders()
        } else {
            focusBorder.hidePersistentBorder()
            // corners mode still marks the floaters; none hides them
            refreshFloatingBorders()
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
        guard let frame = window.onScreenFrame() else { return }
        focusBrackets.applyAppearance(
            style: config.focusBracketStyle,
            color: focusMarkColor(for: fid),
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
        // cache-based: this fires on every Hypr release and previously ran
        // up to three full-desktop enumerations (one here + two delayed
        // reasserts). the border geometry comes from live frame reads of
        // cached windows either way. corners mode re-masks its floater outlines
        // here too; the focused-border reassert below needs borders.
        guard isRunning, config.enabled, floaterMarks != .none else { return }
        refreshFloatingBorders()
        guard Self.permitsHyprReleaseReassert(
            isRunning: isRunning,
            enabled: config.enabled,
            showFocusBorder: config.showFocusBorder) else { return }

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
        // the dim stays down while a screenshot picker is up
        if screenshotPicker.isOpen {
            dimmingOverlay.hideImmediately()
            return
        }
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
        let floaters = floatingFrames(from: Array(stateCache.cachedWindows.values),
                                      listed: listedFrames(), expandedBy: 2)
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

    // MARK: - action dispatch

    /// Run an action through the gates, then the dispatcher. Called from the
    /// hotkey path and the menu bar.
    func handleAction(_ action: Action) {
        // the menu bar calls in here too, and nobody reaches it while locked
        discovery.endSessionInterruption(evidence: "action")
        // any other action moves on from the window the overlay is about
        if action != .showWindowRules { windowRulesOverlay.noteOtherAction() }
        let decision = ActionPolicy.decide(action,
                                           displayTransitionPending: displayTransitionPending,
                                           scratchpadVisible: scratchpad.isVisible)
        if decision.cancelsRecovery {
            admissionRecovery.cancelAll(reason: "later press")
        }
        let glides = armFocusGlide(for: action)
        defer { if glides { disarmFocusGlide() } }
        switch decision.outcome {
        case .toggleOverview:
            let overview = statusPresenter.workspaceOverviewSnapshots()
            workspaceOverview.toggle(snapshots: overview.workspaces, scratchpad: overview.scratchpad)
        case .dropMidDisplayTransition:
            // workspace flows park/unpark and then focus+warp. mid-display-
            // transition the tile pass is deferred, so the target workspace
            // would stay parked with the cursor warped to the 1px park sliver.
            // drop them for the settle window (a few seconds around wake), with
            // a beep so the press does not look lost
            hyprLog(.notice, .lifecycle, "workspace action dropped mid-display-transition")
            NSSound.beep()
        case .scratchpad(let route):
            switch route {
            case .ejectThenDispatch:
                if !scratchpad.ejectFocusedWindow() {
                    scratchpad.hide(reason: .workspaceAction)
                }
                actionDispatcher.dispatch(action)
            case .hideThenDispatch:
                scratchpad.hide(reason: .workspaceAction)
                actionDispatcher.dispatch(action)
            case .refuse:
                NSSound.beep()
            case .toggleMember:
                // membership stays sticky: only Shift+S / Shift+N take a member
                // out. while the layer is up only a member can be the focused
                // window, so the send only beeps when there is none.
                if !scratchpad.toggleTilingOfFocusedMember() {
                    scratchpad.sendFocusedWindow()
                }
            case .cycleSummoned:
                scratchpad.cycleSummoned()
            case .focusMemberElseDispatch(let bundleID):
                if !scratchpad.focusMember(ofBundleID: bundleID) {
                    actionDispatcher.dispatch(action)
                }
            }
        case .dispatch:
            actionDispatcher.dispatch(action)
        }
    }

    // MARK: - focus glide

    // the engine reports this press's passes only while armed
    private func armFocusGlide(for action: Action) -> Bool {
        guard focusGlide.arm(for: action, enabled: config.animateFocusIndicator) else { return false }
        focusGlide.primaryScreenHeight = displayManager.primaryScreenHeight
        focusGlide.brackets = focusBrackets
        focusGlide.border = focusBorder
        tilingEngine.onTeleportWillWrite = { [weak self] in self?.focusGlide.willWrite($0) }
        return true
    }

    private func disarmFocusGlide() {
        tilingEngine.onTeleportWillWrite = nil
        focusGlide.disarm()
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
                    stateCache.setFloating(true, window: w)
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
                    stateCache.setFloating(false, window: w)
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
        placement.classifyAndAssign(allWindows)
        placement.distributeWindowsAcrossWorkspaces(allWindows)
        // the redistribute moved windows off hidden workspaces whose trees
        // never get re-diffed. also clears a dup left by any older path
        tilingEngine.dropMisassignedMembers(workspaceFor: workspaceManager.workspaceFor)
        tileAllVisibleSpaces()
        return allWindows
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
        placement.classifyAndAssign(allWindows)
        placement.reparkHiddenWorkspaceWindows(allWindows)
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
        layoutRestorer(ref: { [weak self] in self?.windowRef(for: $0) })
    }

    private func layoutRestorer(ref: @escaping (HyprWindow) -> SavedWindowRef?) -> LayoutRestorer {
        LayoutRestorer(
            engine: tilingEngine, orchestrator: workspaceOrchestrator,
            workspaceManager: workspaceManager, stateCache: stateCache,
            recovery: admissionRecovery,
            isScratchpad: { [scratchpad = scratchpad!] in scratchpad.contains($0) },
            ref: ref)
    }

    // MARK: - update relaunch

    /// Whether a native fullscreen window is in front: a movie, a game, slides.
    func isFullscreenAppInFront() -> Bool {
        isFullscreenSuppressed(focused: nil)
    }

    /// Write down where every window is, for the launch that follows an
    /// update. Called just before the updater quits HyprMac, while the
    /// workspaces and trees are still live.
    func saveRelaunchHandoff() {
        guard isRunning else { return }
        let ghosts = stateCache.hiddenWindowIDs
        let exact = layoutRestorer(ref: { RelaunchHandoff.ref(id: $0.windowID, pid: $0.ownerPID) })
        func key(_ id: CGWindowID) -> RelaunchHandoff.WindowKey? {
            stateCache.windowOwners[id].map { RelaunchHandoff.WindowKey(id: id, pid: $0) }
        }
        let floaters = stateCache.floatingWindowIDs.sorted().compactMap { id -> RelaunchHandoff.Floater? in
            guard !ghosts.contains(id), !scratchpad.contains(id), let key = key(id),
                  let workspace = workspaceManager.workspaceFor(id) else { return nil }
            // a parked floater's real frame is the one saved when it was hidden
            let frame = workspaceManager.isWorkspaceVisible(workspace)
                ? stateCache.cachedWindows[id]?.frame
                : workspaceManager.savedFloatingFrame(for: id)
            return RelaunchHandoff.Floater(window: key, workspace: workspace, frame: frame)
        }
        let handoff = RelaunchHandoff(
            savedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
            displayKey: LayoutSnapshotStore.displayKey(screens: displayManager.screens),
            visibleWorkspaces: workspaceManager.enabledScreensLeftToRight()
                .map(workspaceManager.workspaceForScreen),
            focused: key(focusController.lastFocusedID),
            workspaces: exact.capture(),
            floaters: floaters,
            scratchpad: scratchpad.members.subtracting(ghosts).sorted().compactMap(key))
        do {
            try relaunchHandoffStore.write(handoff)
            let tiled = handoff.workspaces.reduce(0) { $0 + $1.refs.count }
            hyprLog(.notice, .lifecycle, "relaunch handoff saved: \(tiled) tiled on \(handoff.workspaces.count) workspaces,"
                    + " \(floaters.count) floating, \(handoff.scratchpad.count) in the scratchpad,"
                    + " showing \(handoff.visibleWorkspaces)")
        } catch {
            hyprLog(.warning, .lifecycle, "relaunch handoff not written: \(error)")
        }
    }

    /// Put the desk back the way `saveRelaunchHandoff` found it. Runs once,
    /// right after the launch tile has spread the windows out on its own.
    private func restoreRelaunchHandoff(_ handoff: RelaunchHandoff, windows allWindows: [HyprWindow]) {
        let live = Dictionary(allWindows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        // a window counts only if the same process still owns that id
        func window(_ key: RelaunchHandoff.WindowKey) -> HyprWindow? {
            live[key.id].flatMap { $0.ownerPID == key.pid ? $0 : nil }
        }

        // each monitor back on the workspace it was showing, before any
        // window moves, so the moves know which destinations are on screen
        for workspace in handoff.visibleWorkspaces where !workspaceManager.isWorkspaceVisible(workspace) {
            workspaceOrchestrator.switchWorkspace(workspace)
        }

        // scratchpad members rejoin the layer, parked
        // (a pinned app's window is already there from the launch tile)
        var stashed = 0
        for key in handoff.scratchpad {
            guard let w = window(key) else { continue }
            if !scratchpad.contains(w.windowID) {
                scratchpad.adoptPinned(w, summon: false, reason: "update relaunch")
            }
            if scratchpad.contains(w.windowID) { stashed += 1 }
        }

        // the launch tile put every floater in a tree. take them out again
        // before the trees are rebuilt, then send each to its workspace
        var floated: [(floater: RelaunchHandoff.Floater, window: HyprWindow)] = []
        for floater in handoff.floaters {
            guard let w = window(floater.window), !scratchpad.contains(w.windowID) else { continue }
            if !stateCache.floatingWindowIDs.contains(w.windowID) {
                if let workspace = workspaceManager.workspaceFor(w.windowID) {
                    tilingEngine.removeWindow(w, fromWorkspace: workspace)
                }
                stateCache.setFloating(true, window: w)
            }
            floated.append((floater, w))
        }
        workspaceOrchestrator.moveWindows(floated.map { ($0.window, $0.floater.workspace) })
        for (floater, w) in floated {
            guard workspaceManager.workspaceFor(w.windowID) == floater.workspace,
                  let frame = floater.frame else { continue }
            if workspaceManager.isWorkspaceVisible(floater.workspace) {
                w.placeFloating(frame, reason: "update relaunch, saved frame", displayManager: displayManager)
            } else {
                // parked. it takes this frame when its workspace is shown
                workspaceManager.setSavedFloatingFrame(frame, for: w.windowID)
            }
        }

        // tiled windows: back to their workspaces, in the saved tree shapes
        let exact = layoutRestorer(ref: { RelaunchHandoff.ref(id: $0.windowID, pid: $0.ownerPID) })
        let outcome = exact.restore(handoff.layoutSnapshot, windows: allWindows)
        tileAllVisibleSpaces()
        updatePositionCache()

        if let focused = handoff.focused.flatMap(window),
           workspaceManager.isWindowVisible(focused.windowID) {
            tiledFocusRouter.focus(focused, reason: "update relaunch", fallback: .activate)
            focusController.recordFocus(focused.windowID, reason: "update relaunch")
        }
        hyprLog(.notice, .lifecycle, "relaunch handoff restored: \(outcome.logSummary);"
                + " \(floated.count) of \(handoff.floaters.count) floating,"
                + " \(stashed) of \(handoff.scratchpad.count) in the scratchpad,"
                + " showing \(handoff.visibleWorkspaces)")
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
            hyprLog(.notice, .lifecycle, "retile deferred mid-display-transition")
            return []
        }
        let allWindows = freshWalk(windows)

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
            // a workspace being shown is where an explicit move to a hidden
            // destination finally gets its one attempt. the marker is spent
            // on this pass whatever it says.
            results.append(admissionPass.run(workspaceWindows, onWorkspace: workspace, screen: screen))
        }

        updatePositionCache(windows: allWindows)
        // a workspace that just became visible is new evidence about any
        // newcomer parked on it
        offerRecoveryEvidence()
        return results
    }

    /// Run `prepare`, retile every visible workspace, run `completion`.
    @discardableResult
    private func retile(
        windows: [HyprWindow]? = nil,
        prepare: (() -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) -> [TilingEngine.AdmissionResult] {
        prepare?()
        let results = tileAllVisibleSpaces(windows: windows)
        completion?()
        return results
    }

    /// Note the floater a press lands on, its window-list frame and the
    /// cursor, read together, so the dim carve and the floater outline can
    /// follow the drag from a consistent pair.
    ///
    /// The window list, not AX: some windows' AX frame stops updating
    /// (CARROT Weather), and AX lags a moving window by about 100 ms. The
    /// frontmost window under the cursor wins, so a floater pressed where it
    /// overlaps another floater is still the one dragged.
    private func notePressedFloater() {
        mouseDownFloatingWindowID = 0
        mouseDownFloatingFrame = nil
        mouseDownFloatingCursorCG = nil
        let cursor = displayManager.flippedY(NSEvent.mouseLocation)
        guard let windows = mouseTracker.stackedWindows(maxAge: 0),
              let pressed = WindowStacking.pressedFloater(
                at: cursor, in: windows,
                floaterIDs: stateCache.floatingWindowIDs.filter(workspaceManager.isWindowVisible),
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                ownPID: getpid(), mouseTarget: mouseTracker.mouseTargetAt) else { return }
        mouseDownFloatingWindowID = pressed.id
        mouseDownFloatingFrame = pressed.frame
        mouseDownFloatingCursorCG = cursor
    }

    /// One notice line per floater drag, read once the drop has settled,
    /// and a second one if the frame is still changing a second later.
    /// HyprMac writes no frame for a plain floater drag, so a size change
    /// here came from the app or macOS. Any frame HyprMac writes to a
    /// floater logs its own `floating frame write:` line.
    private func noteFloaterDrag(_ id: CGWindowID, from start: CGRect?, settled: Bool = false) {
        guard let window = stateCache.cachedWindows[id], let frame = window.onScreenFrame() else { return }
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
            guard let self, let later = self.stateCache.cachedWindows[id]?.onScreenFrame(),
                  later != frame else { return }
            self.noteFloaterDrag(id, from: start, settled: true)
        }
    }

    /// Arm the live drag follow if the press landed on a visible ordinary
    /// floating window and something follows it: the dim carve (normal dim
    /// mode) or the floater outline (`FloaterDragFollow`). The anchor is the
    /// pair `notePressedFloater` read together: the window-list frame and
    /// the cursor. A frame from AX here once paired a pre-drag position
    /// with a mid-flick cursor and offset the carve for the whole drag.
    private func armFloaterDrag() {
        dimDrag.disarm()
        floaterDragFollow = .resolve(dimInactive: config.dimInactiveWindows,
                                     scratchpadVisible: scratchpad.isVisible, marks: floaterMarks)
        guard floaterDragFollow.arms, mouseDownFloatingWindowID != 0,
              let frame = mouseDownFloatingFrame, let cursor = mouseDownFloatingCursorCG else { return }
        let id = mouseDownFloatingWindowID
        dimDrag.arm(id: id,
                    readFrame: { WindowStacking.bounds(of: id) },
                    startFrame: frame, downPointCG: cursor)
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
        let cgPoint = displayManager.flippedY(mouseNS)

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

    /// Engine/workspace/focus half of forgetting an id. Drops engine
    /// min-size memory, removes workspace assignment, and clears any focus
    /// or border state that pointed at the window.
    private func applyForgottenIDExternalCleanup(_ id: CGWindowID) {
        admissionRecovery.forget(id)
        minimaRevalidation.forget(id)
        driftMonitor.forget(id)
        floatingController.forgetMaximized(id)
        // gone for good, app quit included: its next life starts without it
        floatingController.forgetManualChoice(id)
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
        retile()
    }


    /// Collect frames for every visible floating window in `source`,
    /// optionally inset by `-padding` (negative inset enlarges) so dim
    /// cutouts can leave breathing room around the floater outline.
    private func floatingFrames(from source: [HyprWindow], listed: [CGWindowID: CGRect],
                                expandedBy padding: CGFloat = 0) -> [CGWindowID: CGRect] {
        Self.floatingFrames(from: source, floatingIDs: stateCache.floatingWindowIDs,
                            isVisible: workspaceManager.isWindowVisible,
                            listed: listed, expandedBy: padding)
    }

    /// Each visible floater's frame as the window server draws it
    /// (`onScreenFrame`), else its cached AX frame.
    static func floatingFrames(from source: [HyprWindow], floatingIDs: Set<CGWindowID>,
                               isVisible: (CGWindowID) -> Bool, listed: [CGWindowID: CGRect],
                               expandedBy padding: CGFloat = 0) -> [CGWindowID: CGRect] {
        var frames: [CGWindowID: CGRect] = [:]
        for w in source {
            guard floatingIDs.contains(w.windowID), isVisible(w.windowID),
                  let frame = w.onScreenFrame(listed: listed) ?? w.cachedFrame else { continue }
            frames[w.windowID] = padding == 0 ? frame : frame.insetBy(dx: -padding, dy: -padding)
        }
        return frames
    }

    /// On-screen window frames by id, from the mouse tracker's short-lived
    /// window list, so the chrome refresh shares one list read with hover
    /// and the dim. Empty when the list is unavailable: frames then come
    /// from AX.
    private func listedFrames() -> [CGWindowID: CGRect] {
        guard let windows = mouseTracker.stackedWindows() else { return [:] }
        return Self.listedFrames(windows)
    }

    static func listedFrames(_ windows: [StackedWindow]) -> [CGWindowID: CGRect] {
        var frames: [CGWindowID: CGRect] = [:]
        for w in windows where frames[w.windowID] == nil {
            if let bounds = w.bounds { frames[w.windowID] = bounds }
        }
        return frames
    }

    /// Refresh `stateCache.tiledPositions` and `cachedWindows` from current
    /// AX data, then update floating outlines, the menu bar indicator, the
    /// focus-border position, and the dim mask.
    ///
    /// Called after every operation that may have changed window geometry
    /// (tile, drag-end, workspace switch, config tweak). Keeps the
    /// downstream visual layer (border, dim, menu bar dots) in sync with
    /// the live tile state without re-running the tiling algorithm.
    /// `cachedWindows` holds only visible windows after this.
    ///
    /// `windows` may be a walk taken before a layout pass. Each window then
    /// takes the frame the pass read back (`adoptNewerCachedFrame`); the
    /// walk's own frame is the one the pass replaced.
    private func updatePositionCache(windows: [HyprWindow]? = nil) {
        tiledRectsMemo = nil // geometry may have changed — force live re-reads
        // and the window list: the chrome below reads frames from it
        mouseTracker.invalidateWindowListCache()
        let listed = listedFrames()
        let allWindows = windows ?? accessibility.getAllWindows()
        tilingEngine.primeMinimumSizes(allWindows)
        stateCache.tiledPositions.removeAll()
        stateCache.cachedWindows.removeAll()
        // a pass that ran after this walk moved windows through the trees'
        // own objects. the walk still says where they were before it
        let treeObjects = tilingEngine.treeWindowObjects()
        for w in allWindows {
            guard workspaceManager.isWindowVisible(w.windowID) else { continue }
            w.adoptNewerCachedFrame(from: treeObjects[w.windowID])
            stateCache.cachedWindows[w.windowID] = w
            guard let frame = w.cachedFrame ?? w.frame else { continue }
            if stateCache.floatingWindowIDs.contains(w.windowID)
                || tilingEngine.isCoveredByMaximized(w.windowID) {
                continue
            } else {
                stateCache.tiledPositions[w.windowID] = frame
            }
        }
        refreshFloatingBorders(windows: allWindows, listed: listed)
        statusPresenter.updateMenuBarState()
        refreshWorkspaceOverview(windows: allWindows)

        // keep focus border tracking window position (retile, resize, etc.)
        if let tid = focusBorder.trackedWindowID, let w = stateCache.cachedWindows[tid],
           let frame = w.onScreenFrame(listed: listed) {
            focusBorder.updatePosition(frame)
            refreshFloatingBorders(windows: allWindows, listed: listed)
        }
        // brackets follow the same window if visible (Hypr held during retile)
        if focusBrackets.isVisible, let bid = focusBrackets.trackedWindowID,
           let w = stateCache.cachedWindows[bid], let frame = w.onScreenFrame(listed: listed) {
            focusBrackets.updatePosition(frame)
            // a float toggle mid-press changes the mark color
            focusBrackets.recolor(focusMarkColor(for: bid))
        }
        refreshDimming()
    }

    /// What marks the visible floaters: outlines or nothing.
    private var floaterMarks: FloaterMarkStyle {
        .resolve(showFocusBorder: config.showFocusBorder, bracketStyle: config.focusBracketStyle)
    }

    /// The focus marks take the Floating color on a floating window.
    private func focusMarkColor(for windowID: CGWindowID) -> CGColor {
        FocusMarkColor.resolve(
            focusedIsFloating: stateCache.floatingWindowIDs.contains(windowID),
            markColor: config.resolvedFocusBracketColor.cgColor,
            floatingColor: config.resolvedFloatingBorderColor.cgColor)
    }

    /// Recompute floater frames and push them into the focus border. Each
    /// floater gets a persistent outline at the floating border color so
    /// the user can spot a floater that ended up behind a tile. It draws in
    /// Corners mode too, with no focus border.
    private func refreshFloatingBorders(windows: [HyprWindow]? = nil,
                                        listed: [CGWindowID: CGRect]? = nil) {
        if floaterMarks != .none {
            let source = windows ?? Array(stateCache.cachedWindows.values)
            var frames = floatingFrames(from: source, listed: listed ?? listedFrames())
            // prime the radius cache for each visible floater so the
            // bundle-id override table applies (otherwise resolve()
            // falls back to osDefault for every floating window).
            // while the scratchpad is up, ordinary floaters sit beneath the
            // scrim — their border panels (at .floating level) would glow
            // above it. only members get outlines.
            if scratchpad.isVisible {
                frames = frames.filter { scratchpad.isSummoned($0.key) }
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

    /// A floater the switch could not reveal came out of the hide corner
    /// later. Outline it now instead of at the next refresh.
    private func markRevealedFloaters(_ windows: [HyprWindow]) {
        guard isRunning else { return }
        for w in windows { stateCache.cachedWindows[w.windowID] = w }
        let fid = focusBorder.trackedWindowID ?? focusController.lastFocusedID
        guard !isFullscreenSuppressed(focused: stateCache.cachedWindows[fid]) else { return }
        refreshFloatingBorders()
        refreshDimming()
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
        guard floaterMarks != .none else { return }
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
        // the floater's glow reaches past its frame, so a window in front
        // that only touches the glow hides it too
        let glowReach = FocusBorder.floaterPanelExpansion
        for (fid, frect) in floaterFrames {
            guard let fz = zIndex[fid] else { continue }
            let panelRect = frect.insetBy(dx: -glowReach, dy: -glowReach)
            var list: [CGRect] = []
            for (id, rect) in trackedRects where id != fid {
                guard let z = zIndex[id], z < fz else { continue }
                if rect.intersects(panelRect) { list.append(rect) }
            }
            if !list.isEmpty { floaterOccluders[fid] = list }
        }

        focusBorder.applyOcclusion(
            focusedOccluders: focusedOccluders,
            floaterOccluders: floaterOccluders)
    }

    /// Live overview: new windows, closes, moves and retiles show up while
    /// Hypr+O is open. No-op (and no AX walk) while it is closed.
    private func refreshWorkspaceOverview(windows: [HyprWindow]? = nil) {
        // the switch, the poll and the position cache all end here, so a
        // status bar hears of every change the overview would show
        statusExporter.noteChange()
        workspaceOverview.refreshIfOpen { statusPresenter.workspaceOverviewSnapshots(windows: windows) }
    }

    /// Focus reached a tile under a maximized window: another app was
    /// activated, a directional move, or a pick in the overview. That tile
    /// is on top now, so the layout comes back. Off the focus path, since
    /// this writes frames.
    private func endMaximizeIfFocusLeft() {
        let id = focusController.lastFocusedID
        guard id != 0, !tilingEngine.isMaximized(id),
              tilingEngine.maximizeLocation(involving: id) != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusController.lastFocusedID == id,
                  !self.tilingEngine.isMaximized(id),
                  let location = self.tilingEngine.maximizeLocation(involving: id) else { return }
            self.tilingEngine.endMaximize(onWorkspace: location.workspace, screen: location.screen)
            self.updatePositionCache()
        }
    }

    /// A maximized window the user just dragged or resized goes back to its
    /// tile. Only visible ones: a hidden one is parked in the corner.
    private func endMaximizeIfMoved() {
        let moved = tilingEngine.maximizedOffTarget(liveFrame: { WindowStacking.bounds(of: $0) })
            .filter { workspaceManager.isWorkspaceVisible($0.workspace) }
        for location in moved {
            tilingEngine.endMaximize(onWorkspace: location.workspace, screen: location.screen)
        }
        // a floater has no tile to go back to. it stays where it was dropped
        let movedFloaters = floatingController.forgetMaximizedIfMoved(liveFrame: { id in
            self.workspaceManager.isWindowVisible(id) ? WindowStacking.bounds(of: id) : nil
        })
        if let id = movedFloaters.first, let frame = WindowStacking.bounds(of: id),
           let screen = displayManager.screen(containingMostOf: frame) {
            workspaceOverview.showFullscreenHUD(isOn: false, screen: screen)
        }
        guard !moved.isEmpty || !movedFloaters.isEmpty else { return }
        updatePositionCache()
    }

    /// A keybind press or an action link. Pause and resume always work; the
    /// rest need tiling on, except the two read-only overlays.
    private func performUserAction(_ action: Action) {
        if action == .toggleTiling {
            config.enabled.toggle()
            return
        }
        guard Self.runsWhilePaused(action) || config.enabled else { return }
        suppressions.suppress(.mouseFocus, for: SuppressionDelay.mouseFocus)
        handleAction(action)
        // a workspace switch or the scratchpad mid-drag changes where the
        // drop would land, even with the pointer standing still
        tiledDrag.refreshPreview()
    }

    static func runsWhilePaused(_ action: Action) -> Bool {
        action == .toggleTiling || action == .showKeybinds || action == .showWorkspaceOverview
    }

    /// A `hyprmac://` link from a status bar or another app. The status
    /// links take the same paths as the switch keybind and the overview's
    /// window pick; an action link runs exactly like its keybind.
    func handleExternalURL(_ command: ExternalCommand) {
        guard ExternalCommand.isAllowed(command, externalControl: config.externalControlEnabled,
                                        statusExport: config.statusExportEnabled) else {
            hyprLog(.debug, .lifecycle, "hyprmac:// link ignored: not turned on")
            return
        }
        switch command {
        case .workspace(let workspace):
            guard isRunning else { return }
            handleAction(.switchWorkspace(workspace))
        case .focus(let workspace):
            guard isRunning else { return }
            // a repeat click cycles that workspace's windows
            if !displayTransitionPending,
               let next = ExternalCommand.nextFocusTarget(on: workspace, in: statusPresenter.statusSnapshot()) {
                scratchpad.hide(reason: .workspaceAction)
                workspaceOrchestrator.switchWorkspace(workspace, preferredWindowID: next)
            } else {
                handleAction(.switchWorkspace(workspace))
            }
        case .action(let action):
            hyprLog(.debug, .lifecycle, "hyprmac:// action \(ActionDispatcher.discriminator(for: action))")
            performUserAction(action)
        }
    }

    // MARK: - poll

    /// Run a single discovery diff and hand the result to the dispatcher's
    /// apply-loop.
    ///
    /// Mouse-down is handled by `PollingScheduler`, which defers rather than
    /// drops. Once `applyChanges` is called, the apply-loop runs unconditionally.
    ///
    /// Coalesced with notification-driven schedules by `PollingScheduler`,
    /// which stays suppressed until verified drag completion finishes.
    private func pollWindowChanges() {
        // mouse-down is handled by the scheduler's isSuppressed closure so
        // event polls defer instead of dropping; this guard only backstops
        // a hypothetical direct call landing mid-drag.
        guard !mouseButtonDown else { return }

        let fire = pollingScheduler.currentFire
        let allWindows = accessibility.getAllWindows()
        let now = Date()
        let gap = lastPollAt.map { "\(Int(now.timeIntervalSince($0) * 1000))ms since last" } ?? "first poll"
        lastPollAt = now
        hyprLog(.debug, .discovery, "poll: \(allWindows.count) windows, \(gap), trigger \(fire?.summary ?? "direct")")
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
            floatingRules: config.floatingRules,
            focusedWindowID: focusController.lastFocusedID,
            unreadableWindowIDs: accessibility.unreadableWindowIDs
        )
        // locked or asleep: this snapshot is not the desktop. a drift
        // re-apply or a recovery attempt from it would lay the trees out
        // without the windows it is missing
        if changes.heldForInterruption { return }
        windowRulesOverlay.noteWindowsGone(changes.goneIDs.union(changes.fullyForgottenIDs))
        adoptRecreatedElements(allWindows)
        // an off-screen hold ends on its own; the poll that hides the
        // window, or finds it back, is asked for then, not at the next
        // ten-second reconcile
        if let wait = discovery.secondsUntilAHoldEnds {
            pollingScheduler.schedule(after: wait + 0.05, trigger: .hold)
        }
        if let wait = discovery.secondsUntilARetryIsDue { pollingScheduler.schedule(after: wait, trigger: .axRetry) }
        // read before the apply: its focus fallback can front another app
        let returnTarget = userHiddenReturnTarget(changes)
        let retileResults = actionDispatcher.applyChanges(changes, allWindows: allWindows,
                                                          cursorPlacement: cursorPlacementGate(fire))
        // the switch walks AX again, so this snapshot's frames are stale for
        // the park repair below
        if let returnTarget { followUserHiddenReturn(returnTarget) }
        // a member a tile pass held out because its app did not answer gets
        // its frame once the app does. a retile this poll already wrote it
        var retiled = changes.needsRetile
        let released = tilingEngine.releaseHeldWindows(readable: Set(allWindows.map(\.windowID)))
        if !released.isEmpty, !retiled {
            hyprLog(.notice, .discovery, "held windows readable again: \(released.sorted()) — retiling")
            retile(windows: allWindows)
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
        if returnTarget == nil { placement.repairParkedWindows(allWindows) }
        tiledDragFeedback.reconcile(with: retileResults, allWindows: allWindows)
        refreshWorkspaceOverview(windows: allWindows)
        // a guarded cycle diffed nothing, so it can't have seen the close —
        // don't spend a recheck attempt on it, and don't let the slower
        // destroy re-poll coalesce away the prompt one.
        if changes.requestsRecheck {
            // a real mass close is delayed by this, a partial snapshot gets
            // the time it needs to fill in. at 0.1 s the three skips the
            // guard allows were over in a third of a second
            pollingScheduler.schedule(after: 0.5, trigger: .recheck)
        } else if destroyRecheck.resolve(goneIDs: changes.goneIDs, ownersBefore: ownersBefore,
                                         runningPIDs: runningPIDs) {
            hyprLog(.debug, .discovery, "destroy recheck: closed window not yet gone from the snapshot — re-polling")
            pollingScheduler.schedule(after: DestroyRecheck.delay, trigger: .recheck)
        }
        settleDiscoveryFollowUps(changes, allWindows: allWindows, fire: fire)
    }

    /// Whether this poll may send an app's first window to the cursor's
    /// monitor: not a reconcile tick, and not while the displays change.
    private func cursorPlacementGate(_ fire: PollingScheduler.Fire?) -> ActionDispatcher.CursorPlacementGate {
        if displayTransitionPending { return .displayTransition }
        if fire?.isReconcileOnly == true { return .reconcilePoll }
        return .open
    }

    /// The admit-only pass a finished workspace switch's hold allows
    /// (`SwitchHoldAdmission`). Walks the windows and admits only the ones
    /// discovery has never known, through the ordinary assignment and
    /// verified tile pass. Everything else this walk shows (gone, hidden,
    /// returned, drift) is left to the full poll the hold still defers.
    private func admitNewWindowsDuringHold() {
        guard !mouseButtonDown else { return }
        let fire = pollingScheduler.currentFire
        let allWindows = accessibility.getAllWindows()
        // the retile lays out every visible workspace from this walk
        var members: Set<CGWindowID> = []
        for screen in displayManager.screens where !workspaceManager.isMonitorDisabled(screen) {
            members.formUnion(workspaceManager.windowIDs(onWorkspace: workspaceManager.workspaceForScreen(screen)))
        }
        members.subtract(stateCache.floatingWindowIDs)
        members.subtract(stateCache.hiddenWindowIDs)
        let missing = SwitchHoldAdmission.missingTiledMembers(
            members, listed: Set(allWindows.map(\.windowID)), held: tilingEngine.heldWindowIDsSource())
        guard missing.isEmpty else {
            hyprLog(.notice, .discovery, "admit-only pass skipped: tiled \(missing.sorted()) missing from the walk"
                    + " — left to the poll after the workspace transition")
            return
        }
        let changes = discovery.computeAdmissions(
            snapshot: allWindows,
            excludedBundleIDs: Set(config.excludedBundleIDs),
            floatingRules: config.floatingRules,
            unreadableWindowIDs: accessibility.unreadableWindowIDs)
        if !changes.newWindows.isEmpty {
            let left = suppressions.remaining(.workspaceTransition).map { Int(($0 * 1000).rounded()) } ?? 0
            axNotifications.ensureWindowSubscriptions(for: changes.newWindows)
            tilingEngine.primeMinimumSizes(changes.newWindows)
            hyprLog(.notice, .discovery, "admitted \(changes.newWindows.map(\.windowID).sorted()) during workspace"
                    + " transition (\(left)ms left on the hold), \(fire?.summary ?? "direct")")
            actionDispatcher.applyAdmissions(changes, allWindows: allWindows,
                                             cursorPlacement: cursorPlacementGate(fire))
        }
        settleDiscoveryFollowUps(changes, allWindows: allWindows, fire: fire)
    }

    /// After a poll: say how a reconcile tick came to be the one that found
    /// a window, and re-poll an app whose announced window this poll missed.
    private func settleDiscoveryFollowUps(_ changes: WindowChanges, allWindows: [HyprWindow],
                                          fire: PollingScheduler.Fire?) {
        let now = CFAbsoluteTimeGetCurrent()
        let stack = WindowStacking.onScreen() ?? []
        let unknown = DiscoveryFollowUp.unknownOnScreen(
            stack, known: stateCache.knownWindowIDs, hidden: stateCache.hiddenWindowIDs, ownPID: getpid())
        var admitted: [pid_t: [CGWindowID]] = [:]
        for w in changes.newWindows + changes.returned { admitted[w.ownerPID, default: []].append(w.windowID) }
        let trigger = "(" + (fire?.summary ?? "direct") + ")"

        // discovery's own look found a window no watch was waiting on. a
        // watched app's admission gets the watch's line below instead
        if fire?.triggers.contains(.axRetry) == true {
            for (pid, ids) in admitted.sorted(by: { $0.key < $1.key }) where discoveryFollowUp.watches[pid] == nil {
                hyprLog(.notice, .discovery, "ax retry pid=\(pid): admitted \(ids.sorted()), poll \(trigger)")
            }
        }

        // the event path should have found these. the line says whether an
        // event came and how long the window sat there
        if fire?.isReconcileOnly == true {
            var found: [pid_t: [CGWindowID]] = [:]
            for w in changes.newWindows { found[w.ownerPID, default: []].append(w.windowID) }
            for (pid, ids) in found.sorted(by: { $0.key < $1.key }) {
                let seen = ids.compactMap { discoveryFollowUp.onScreenMS($0, now: now) }.max()
                let event = discoveryFollowUp.lastEvent[pid].map {
                    "last ax event from it: \($0.kind) \(Int(((now - $0.at) * 1000).rounded()))ms ago"
                } ?? "no ax event from it since launch"
                let create = discoveryFollowUp.lastCreate[pid].map {
                    "last windowCreated \(Int(((now - $0) * 1000).rounded()))ms ago"
                } ?? "no windowCreated"
                hyprLog(.notice, .discovery, "reconcile poll found new window(s) \(ids.sorted()) of pid=\(pid): "
                        + (seen.map { "on screen at least \($0)ms" } ?? "no earlier poll or focus check saw it on screen")
                        + "; \(event); \(create)")
            }
        }

        func walk(_ pid: pid_t) -> String {
            let cg = stack.filter { $0.ownerPID == pid && $0.layer == 0 }
            let unreadable = cg.filter { accessibility.unreadableWindowIDs.contains($0.windowID) }.count
            return "AX \(allWindows.filter { $0.ownerPID == pid }.count), CG \(cg.count), "
                + "unknown on screen \((unknown[pid] ?? []).sorted()), unreadable \(unreadable)"
        }
        for outcome in discoveryFollowUp.afterPoll(admitted: admitted, unknown: unknown, now: now) {
            switch outcome {
            case let .admitted(pid, ids, afterMS, retries, reason):
                hyprLog(.notice, .discovery, "new-window watch pid=\(pid) (\(reason)): admitted \(ids) "
                        + "\(afterMS)ms after the event, retries \(retries), poll \(trigger)")
            case let .retry(pid, delay, attempt, _, reason):
                hyprLog(.notice, .discovery, "new-window watch pid=\(pid) (\(reason)): poll \(trigger) admitted nothing — "
                        + "\(walk(pid)); retry \(attempt)/\(DiscoveryFollowUp.backoff.count) in \(Int(delay * 1000))ms")
                pollingScheduler.schedule(after: delay, trigger: .followUp)
            case let .gaveUp(pid, retries, left, afterMS, reason):
                // the walk's own quick looks can outlast the watch
                let looking = left.filter(discovery.windowsAwaitingALook.contains)
                hyprLog(.notice, .discovery, "new-window watch pid=\(pid) (\(reason)): nothing admitted after "
                        + "\(retries) retries, \(afterMS)ms — \(walk(pid)); "
                        + (looking.isEmpty ? "left to the reconcile" : "ax retry still due for \(looking)"))
            case let .settled(pid, retries, reason):
                hyprLog(.debug, .discovery, "new-window watch pid=\(pid) (\(reason)): nothing unknown on screen "
                        + "after \(retries) retries — done")
            }
        }
    }

    /// Poll after a focus change unless it landed on a window discovery
    /// already manages on screen (`FocusPollGate`).
    private func scheduleFocusPoll(pid: pid_t, via: String, after delay: TimeInterval) {
        let focused = accessibility.focusedWindowID(ofPID: pid)
        let needed = FocusPollGate.needsPoll(
            focusedID: focused,
            scratchpadUp: scratchpad.isVisible,
            known: stateCache.knownWindowIDs,
            hidden: stateCache.hiddenWindowIDs,
            onVisibleWorkspace: { workspaceManager.workspaceFor($0).map(workspaceManager.isWorkspaceVisible) ?? false })
        if needed {
            pollingScheduler.schedule(after: delay, trigger: .focus)
        } else if !pollIfUnseenWindow(pid: pid, via: via, after: delay) {
            hyprLog(.debug, .discovery, "focus poll skipped: wid=\(focused ?? 0) via=\(via)")
        }
    }

    /// Poll when `pid` has a window on screen that discovery does not know
    /// and no poll has walked past yet. An app that sends no create still
    /// sends focus and main-window changes when a window opens, and the
    /// focused one can be a window discovery already knows. One window list
    /// read per event; the walk only when such a window is there.
    @discardableResult
    private func pollIfUnseenWindow(pid: pid_t, via: String, after delay: TimeInterval) -> Bool {
        guard let stack = WindowStacking.onScreen() else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        let unknown = DiscoveryFollowUp.unknownOnScreen(
            stack.filter { $0.ownerPID == pid }, known: stateCache.knownWindowIDs,
            hidden: stateCache.hiddenWindowIDs, ownPID: getpid())[pid] ?? []
        let unseen = discoveryFollowUp.unpolled(unknown, now: now)
        guard !unseen.isEmpty else { return false }
        discoveryFollowUp.watch(pid: pid, reason: via, blindRetry: false, now: now)
        let outcome = pollingScheduler.schedule(after: delay, trigger: .newWindow, trailing: true)
        hyprLog(.notice, .discovery, "ax \(via) pid=\(pid): window(s) \(unseen.sorted()) on screen that no poll has seen — "
                + outcome.description + (pollHoldReason.map { ", polls held: \($0)" } ?? ""))
        return true
    }

    /// What holds polls off right now, nil when nothing does.
    private var pollHoldReason: String? {
        guard mouseButtonDown || tiledDrag.isFinishingDrag
                || suppressions.isSuppressed(.workspaceTransition) else { return nil }
        return pollingScheduler.suppressionReason()
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
                  !tilingEngine.isMaximized(window.windowID),
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

    /// What every pass needs first: walk (unless the caller already did),
    /// prime minima, stamp floaters. A pass that skips one drops tiles.
    private func freshWalk(_ windows: [HyprWindow]? = nil) -> [HyprWindow] {
        let allWindows = windows ?? accessibility.getAllWindows()
        tilingEngine.primeMinimumSizes(allWindows)
        stateCache.stampFloating(allWindows)
        adoptRecreatedElements(allWindows)
        return allWindows
    }

    /// Swap in the walk's object for every window whose app re-created its
    /// AX element and kept the window id. The trees and `cachedWindows` are
    /// the two places that keep an object across walks. Left alone, hover
    /// focus on that window failed with -25202, its synthetic click had no
    /// frame, and every tiled drag on its workspace was refused with the
    /// red shake, because the capture reads each tile through the tree.
    private func adoptRecreatedElements(_ walk: [HyprWindow]) {
        let inTrees = tilingEngine.adoptRecreatedWindows(from: walk)
        let inCache = stateCache.adoptRecreatedWindows(from: walk)
        for id in inTrees.union(inCache).sorted() {
            let bundle = walk.first { $0.windowID == id }?.bundleID ?? "none"
            hyprLog(.notice, .discovery, "AX element re-created: wid=\(id) bundle=\(bundle)"
                    + " — window object replaced (tree=\(inTrees.contains(id)) cache=\(inCache.contains(id)))")
        }
    }

    /// One ordinary verified layout pass for a key whose windows drifted.
    /// Nothing special: the same path a retile takes, down to the
    /// bookkeeping, so a refusal rolls back, marks the key, and hands
    /// whatever it stranded to the recovery exactly as it always would.
    @discardableResult
    private func reapplyLayout(onWorkspace workspace: Int, screen: NSScreen) -> TilingEngine.AdmissionResult {
        let allWindows = freshWalk()
        let assigned = workspaceManager.windowIDs(onWorkspace: workspace)
        let windows = allWindows.filter { assigned.contains($0.windowID) }
        let result = admissionPass.run(windows, onWorkspace: workspace, screen: screen)
        updatePositionCache(windows: allWindows)
        return result
    }

    // MARK: - observers

    /// React to an app coming to the foreground.
    ///
    /// In order:
    /// 1. Note when the dock is the active app so FFM can be suppressed
    ///    while dock popups (downloads, stacks) are open.
    /// 2. Tell the scratchpad, and spend any expected-activation note.
    /// 3. If the activation was not suppressed (FFM, workspace switch,
    ///    floater-raise) and the activated app has no visible window, jump
    ///    to a workspace that does — this is the "dock-click takes me to
    ///    that app's workspace" affordance. Returns early when it fires;
    ///    the workspace switch will trigger its own poll.
    /// 4. Otherwise, schedule a discovery poll and re-raise floating
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
        if !causedByHyprMac && !suppressions.isSuppressed(.activationSwitch) {
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                let pid = app.processIdentifier
                let visibleWorkspaces = Set(workspaceManager.monitorWorkspace.values)

                let appWindows = trackedWindows(ofApp: pid)

                let appWorkspaces = appWindows.compactMap { (wid, _) in workspaceManager.workspaceFor(wid) }
                switch DockAffordance.decide(appWorkspaces: appWorkspaces,
                                             visibleWorkspaces: visibleWorkspaces,
                                             scratchpadWorkspace: ScratchpadController.workspace,
                                             scratchpadVisible: scratchpad.isVisible) {
                case .none:
                    break
                case .showScratchpad:
                    let member = appWindows.keys.first { scratchpad.contains($0) }
                    hyprLog(.notice, .lifecycle, "dock-affordance: \(app.bundleIdentifier ?? "?") lives in scratchpad — auto-showing layer")
                    scratchpad.show(focusing: member)
                    return
                case .switchWorkspace(let targetWS):
                    let bid = app.bundleIdentifier ?? "?"
                    let wsSorted = appWorkspaces.sorted()
                    let widList = appWindows.map { "\($0.key)→ws\(workspaceManager.workspaceFor($0.key) ?? -1)" }.joined(separator: ",")
                    hyprLog(.notice, .lifecycle, "dock-affordance: \(bid) pid=\(pid) appWorkspaces=\(wsSorted) visible=\(visibleWorkspaces.sorted()) wids=[\(widList)] → switchWorkspace(\(targetWS))")
                    workspaceOrchestrator.switchWorkspace(targetWS)
                    return
                }
            }
        }

        // our own activation lands on a window we chose; only the user's can
        // bring one discovery has not seen
        if causedByHyprMac, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            scheduleFocusPoll(pid: app.processIdentifier, via: "activation", after: 0.2)
        } else {
            pollingScheduler.schedule(trigger: .activation)
        }
        // activation brings windows forward; floater cutouts follow the new stack
        scheduleRestackRefresh(after: 0.1)

        // an app activation can leave a floater behind a tile that no longer has focus.
        // must always run, even when activation switch is suppressed.
        // not while a click is in flight: its mouse-up runs the same check,
        // and a raise racing the popup the click is opening dismisses it
        if !stateCache.floatingWindowIDs.isEmpty, !realClickInProgress, !mouseButtonDown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.isRunning, !self.mouseButtonDown else { return }
                self.floatingController.raiseBehind()
            }
        }
    }


    /// The app's windows still tracked: not hidden, minimized or closed.
    private func trackedWindows(ofApp pid: pid_t) -> [CGWindowID: pid_t] {
        stateCache.windowOwners.filter {
            $0.value == pid && stateCache.knownWindowIDs.contains($0.key)
                && !stateCache.hiddenWindowIDs.contains($0.key)
        }
    }

    /// A minimized window of the frontmost app came back on a hidden
    /// workspace while the app shows nothing (issue #73). Its activation ran
    /// before the return and found no window, so without this the park
    /// repair hides the window again and the user stays where they were.
    private func userHiddenReturnTarget(_ changes: WindowChanges) -> (windowID: CGWindowID, workspace: Int)? {
        // mid-transition the switch would be dropped; the park repair runs
        guard !changes.returnedFromUserHide.isEmpty, !displayTransitionPending,
              let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let returned = changes.returnedFromUserHide.filter { stateCache.windowOwners[$0] == front }
        guard !returned.isEmpty else { return nil }
        let wsOf = { (id: CGWindowID) in self.workspaceManager.workspaceFor(id) }
        guard let target = DockAffordance.returnTarget(
            returnedWorkspaces: returned.compactMap(wsOf),
            appWorkspaces: trackedWindows(ofApp: front).keys.compactMap(wsOf),
            visibleWorkspaces: Set(workspaceManager.monitorWorkspace.values),
            scratchpadWorkspace: ScratchpadController.workspace,
            scratchpadVisible: scratchpad.isVisible
        ), let id = returned.filter({ wsOf($0) == target }).min() else { return nil }
        return (id, target)
    }

    private func followUserHiddenReturn(_ target: (windowID: CGWindowID, workspace: Int)) {
        hyprLog(.notice, .lifecycle, "minimized return: \(target.windowID) came back on hidden ws\(target.workspace) with its app in front — switching there")
        scratchpad.hide(reason: .workspaceAction)
        workspaceOrchestrator.switchWorkspace(target.workspace, preferredWindowID: target.windowID)
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
        if isFullscreenSuppressed(focused: focusResolver.currentFocusedWindow()) {
            focusBorder.hide()
            focusBorder.hideFloatingBorders()
            dimmingOverlay.hideAll()
        } else if let w = focusResolver.currentFocusedWindow() {
            updateFocusBorder(for: w)
        }
    }

    /// The interruption notifications after which the Caps Lock remap is
    /// checked: the ones that bring the user back.
    static let remapRecheckNotifications: Set<String> = [
        NSWorkspace.didWakeNotification.rawValue,
        NSWorkspace.screensDidWakeNotification.rawValue,
        NSWorkspace.sessionDidBecomeActiveNotification.rawValue,
        "com.apple.screenIsUnlocked",
    ]

    /// Wake / lock / unlock / session-change. Any of these can drop an
    /// in-flight Hypr keyUp without triggering tap-disabled. Reset hotkey
    /// state so the next regular keystroke isn't packed with a phantom
    /// Hypr modifier (the "sticky Caps Lock" bug from a different angle).
    @objc private func systemInterruption(_ notification: Notification) {
        hyprLog(.notice, .hotkey, "system interruption (\(notification.name.rawValue)) — resetting hotkey state")
        lastSystemInterruptionAt = Date()
        hotkeyManager.resetTrackingAfterTapInterruption()
        // the Caps Lock remap is shared with every other HyprMac that ran
        // since; one that quit took it with it, and the Hypr key was a
        // plain Caps Lock until the next launch. asked when the user comes
        // back, not when the session goes away
        if Self.remapRecheckNotifications.contains(notification.name.rawValue) {
            KeyRemapper.reassertHyprKey(UserConfig.shared.hyprKey, enabled: UserConfig.shared.enabled)
        }
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
        suppressions.suppress(.workspaceTransition, for: SuppressionDelay.systemInterruption)
        hyprLog(.notice, .lifecycle, "discovery suppressed 4s around system interruption")
        // lock and display sleep last longer than that. discovery holds
        // every missing window from the start of the span to its end
        discovery.noteSystemInterruption(notification.name.rawValue)
        // a reconcile that came due during the span was deferred against the
        // desk as the lock left it, usually one screen. now that the span is
        // over the settle beat is measured from here, and the deferred timer
        // is superseded so it cannot fire against that stale fingerprint
        // while the external displays are still re-handshaking
        if DisplaySettle.resettlesAfterInterruption(transitionPending: displayTransitionPending,
                                                    sessionInterrupted: discovery.isSessionInterrupted) {
            displayChangeGeneration += 1
            suppressions.suppress(.workspaceTransition, for: DisplaySettle.wakeSettleWindow + 1)
            hyprLog(.notice, .lifecycle, "display reconcile settles \(Int(DisplaySettle.wakeSettleWindow))s from the end of the interruption")
            scheduleDisplayReconcile(stabilityWindow: DisplaySettle.wakeSettleWindow)
        }
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
        pollingScheduler.schedule(after: 0.5, trigger: .launch)
    }

    /// React to an app terminating. Prunes every window owned by the dead
    /// pid before scheduling a poll — without this, hidden or minimized
    /// windows would leak in cache state forever, since the gone-detection
    /// path can only see windows still in `knownWindowIDs`.
    @objc private func appDidTerminate(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            axNotifications.detach(pid: app.processIdentifier)
            forgetApp(app.processIdentifier)
            discoveryFollowUp.forget(pid: app.processIdentifier)
        }
        pollingScheduler.schedule(trigger: .terminate)
    }

    /// React to an app being hidden or unhidden (Cmd-H, Hide Others, etc.).
    /// Short delay lets AX settle before discovery picks up the change.
    @objc private func appVisibilityChanged(_ notification: Notification) {
        // shown again: a window that closed while it was hidden still holds its slot
        if notification.name == NSWorkspace.didUnhideApplicationNotification,
           let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            discovery.appWasShown(app.processIdentifier)
        }
        pollingScheduler.schedule(after: 0.3, trigger: .visibility)
    }

    /// React to a screen configuration change (monitor connect/disconnect,
    /// resolution change, dock position).
    ///
    /// Saves the departing layout, hides the scratchpad, holds polls and arms
    /// the settle. The migration order is in `reconcileAfterDisplayChange`.
    @objc private func screenParametersChanged() {
        // macOS fires this for events that don't alter the layout — app
        // quits and color profile changes. those used to pay
        // the full 3s discovery suppression + scratchpad hide before the
        // debounce concluded "unchanged"; with event-driven discovery a
        // spurious 3s suppression starves window ingestion, so bail first.
        // mid-debounce fires (displayTransitionPending) must keep flowing
        // through the generation machinery below.
        if DisplaySettle.isSpuriousNotification(transitionPending: displayTransitionPending,
                                                fingerprint: displayFingerprint(),
                                                lastSettledFingerprint: lastDisplayFingerprint) {
            hyprLog(.debug, .lifecycle, "screenParametersChanged: fingerprint unchanged — ignoring spurious fire")
            return
        }
        let names = displayManager.screens.map { $0.localizedName }.joined(separator: ", ")
        hyprLog(.notice, .lifecycle, "screenParametersChanged fired (current screens: [\(names)])")
        // snapshot the departing layout on the FIRST notification of a
        // transition — before macOS shuffles windows onto surviving screens
        // and before the trees migrate. later fires in the same debounce
        // would re-save the piled-up state under the same key.
        if DisplaySettle.savesDepartingLayout(transitionPending: displayTransitionPending,
                                              settledKey: settledDisplayKey) {
            saveLayoutSnapshot(manual: false, displayKey: settledDisplayKey)
        }
        // the scratchpad can't survive a topology change — reconcile would
        // park its visible members under a live scrim
        scratchpad.hide(reason: .displayChange)
        // hold discovery off through the settle window. a poll between the
        // topology change and the reconcile below reads windows at their
        // OS-shuffled positions and drift-reassigns them to whatever
        // workspace happens to own the screen they got dumped on.
        suppressions.suppress(.workspaceTransition, for: SuppressionDelay.displaySettle)
        displayTransitionPending = true
        displayChangeGeneration += 1
        // after a wake the displays come back one at a time over several
        // seconds, and a two-second beat reconciled the one-screen desk in
        // between as real
        let recentWake = DisplaySettle.isRecentWake(
            sinceInterruption: Date().timeIntervalSince(lastSystemInterruptionAt))
        if recentWake {
            suppressions.suppress(.workspaceTransition, for: DisplaySettle.wakeSettleWindow + 1)
        }
        scheduleDisplayReconcile(stabilityWindow: DisplaySettle.stabilityWindow(recentWake: recentWake))
    }

    /// Reconcile only once the topology has been stable for a beat. Wake
    /// reattaches displays one at a time over several seconds — a fixed
    /// short delay reconciled each transient config as real, re-homing
    /// every workspace against a one-screen topology and back.
    private func scheduleDisplayReconcile(stabilityWindow: TimeInterval = DisplaySettle.normalStabilityWindow) {
        let gen = displayChangeGeneration
        let fingerprintAtSchedule = displayFingerprint()
        DispatchQueue.main.asyncAfter(deadline: .now() + stabilityWindow) { [weak self] in
            guard let self else { return }
            let decision = DisplaySettle.timerDecision(
                generationAtSchedule: gen,
                currentGeneration: self.displayChangeGeneration,
                sessionInterrupted: self.discovery.isSessionInterrupted,
                fingerprintAtSchedule: fingerprintAtSchedule,
                lastSettledFingerprint: self.lastDisplayFingerprint,
                currentFingerprint: { self.displayFingerprint() })
            let fingerprint: String
            switch decision {
            case .superseded:
                return
            case .deferredByInterruption:
                // a reconcile from the partial window list would re-home every
                // workspace and tile without the windows it is missing
                hyprLog(.notice, .lifecycle, "display reconcile deferred: session interrupted")
                self.suppressions.suppress(.workspaceTransition, for: stabilityWindow + 1)
                self.scheduleDisplayReconcile(stabilityWindow: stabilityWindow)
                return
            case .stillChanging:
                // the polls stay held off for the whole beat, not three seconds
                // of a five-second one
                self.suppressions.suppress(.workspaceTransition, for: stabilityWindow + 1)
                self.scheduleDisplayReconcile(stabilityWindow: stabilityWindow)
                return
            case .backAsItWas:
                // the first poll read the windows macOS moved as the user moving
                // a whole workspace across screens. one retile puts them back;
                // over frames that already stand it only reads
                hyprLog(.notice, .lifecycle, "screen layout back as it was after a transition — retiling")
                self.displayTransitionPending = false
                self.suppressions.suppress(.workspaceTransition, for: SuppressionDelay.displaySettle)
                self.tileAllVisibleSpaces()
                // a rule change that waited out the transition
                self.floatingRulesChanged()
                return
            case .reconcile(let settled):
                fingerprint = settled
            }
            self.lastDisplayFingerprint = fingerprint
            let departedKey = self.settledDisplayKey
            self.settledDisplayKey = LayoutSnapshotStore.displayKey(screens: self.displayManager.screens)
            self.focusBorder.primaryScreenHeight = self.displayManager.primaryScreenHeight
            self.focusBrackets.primaryScreenHeight = self.displayManager.primaryScreenHeight
            // cover the reconcile itself plus a settle tail — the retile it
            // runs moves every window, and the first post-reconcile poll
            // must not read those moves as drift.
            self.suppressions.suppress(.workspaceTransition, for: SuppressionDelay.displaySettle)
            self.displayTransitionPending = false
            // the fingerprint refreshed DisplayManager; initializeMonitors runs
            // before TilingEngine.handleDisplayChange so the home-screen
            // lookup the engine consults is current.
            self.reconcileAfterDisplayChange(
                restoreSavedLayout: DisplaySettle.restoresAfterSettle(from: departedKey, to: self.settledDisplayKey))
            // a rule change that waited out the transition
            self.floatingRulesChanged()
        }
    }

    /// Stable string identity for the current monitor layout. Used to
    /// drop spurious `didChangeScreenParameters` fires.
    private func displayFingerprint() -> String {
        displayManager.refreshedFingerprint()
    }

    @objc private func tiledDropPreviewWorkspacesChanged() {
        tiledDrag.refreshPreview()
    }

    /// Handler for Retile All: the `.hyprMacRetileAll` notification posted
    /// from the menu bar and the `retileAll` keybind (Hypr+R).
    /// The float and tile rules changed: re-apply the difference to the
    /// open windows. Paused, nothing moves; the next start classifies every
    /// window under the new rules anyway.
    private func floatingRulesChanged() {
        guard isRunning else {
            floatingController.markRulesApplied()
            return
        }
        let windows = FloatingRuleSync.windowsToReapply(
            cached: Array(stateCache.cachedWindows.values), walked: accessibility.getAllWindows(),
            known: stateCache.knownWindowIDs)
        guard floatingController.rulesChanged(windows: windows) != nil else { return }
        statusPresenter.updateMenuBarState()
        updateFocusedWindowRuleInfo()
    }

    /// Fill the menu bar's "Focused window" section when the menu opens.
    /// The window is fixed then: the rows act on it, whatever hover does
    /// while the menu is up.
    func refreshFocusedWindowRuleInfo() {
        let id = isRunning ? focusResolver.currentFocusedWindow()?.windowID : nil
        MenuBarState.shared.focusedWindowRule = id.flatMap(floatingRuleCommands.info(for:))
    }

    /// After a rule change: the same window, its new rule. nil once it's gone.
    private func updateFocusedWindowRuleInfo() {
        guard let id = MenuBarState.shared.focusedWindowRule?.windowID else { return }
        MenuBarState.shared.focusedWindowRule = floatingRuleCommands.info(for: id)
    }

    /// The once-per-app offer after a new window couldn't tile. Asked a
    /// moment later, so a window that tiled or got a rule meanwhile, or
    /// that the user toggled, is left alone.
    private func offerFailedTilePrompt(_ id: CGWindowID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.isRunning, self.stateCache.knownWindowIDs.contains(id),
                  let window = self.stateCache.cachedWindows[id],
                  self.workspaceManager.workspaceFor(id).map(self.workspaceManager.isWorkspaceVisible) == true
            else { return }
            let bundleID = window.bundleID ?? NSRunningApplication(processIdentifier: window.ownerPID)?.bundleIdentifier
            guard self.failedTilePolicy.shouldPrompt(
                bundleID: bundleID,
                isFloating: self.stateCache.floatingWindowIDs.contains(id),
                coveredByRule: window.floatingVerdict(self.config.floatingRuleBook) != nil,
                hasManualChoice: self.floatingController.manualChoice(for: id) != nil),
                  let bundleID else { return }
            self.failedTilePolicy.markAsked(bundleID)
            let appName = NSRunningApplication(processIdentifier: window.ownerPID)?.localizedName ?? bundleID
            self.failedTilePrompt.show(windowID: id, appName: appName, frame: window.frame)
        }
    }

    /// The window rules overlay, on the window with this id.
    func showWindowRules(for id: CGWindowID) {
        guard isRunning, let info = floatingRuleCommands.info(for: id) else { return }
        let window = stateCache.cachedWindows[id]
        let icon = window.flatMap { NSRunningApplication(processIdentifier: $0.ownerPID)?.icon }
        windowRulesOverlay.show(info, ownerPID: window?.ownerPID, over: window?.frame, icon: icon)
    }

    @objc private func retileAllRequested() {
        hyprLog(.debug, .lifecycle, "retile all spaces requested")
        scratchpad.hide(reason: .workspaceAction)
        snapshotAndTile()
    }
}

private extension WindowManager {
    private func makeTiledDragFeedback() -> TiledDragFeedbackCoordinator {
        TiledDragFeedbackCoordinator(
            currentGeneration: { [tilingEngine = tilingEngine!] in tilingEngine.currentLayoutGeneration },
            displayID: { TiledDragController.tiledDragDisplayID($0) },
            screens: { [displayManager] in displayManager.screens },
            windowIDsOnWorkspace: { [workspaceManager = workspaceManager!] in workspaceManager.windowIDs(onWorkspace: $0) },
            workspaceFor: { [workspaceManager = workspaceManager!] in workspaceManager.workspaceFor($0) },
            isFloating: { [weak self] in self?.isFloating($0) ?? false },
            allWindows: { [accessibility] in accessibility.getAllWindows() },
            isAwaitingRetry: { [admissionRecovery] in admissionRecovery.phase(of: $0) == .awaitingRetry },
            hasActiveRetry: { [admissionRecovery] in admissionRecovery.hasActiveRetry(workspace: $0, screen: $1) },
            beep: { NSSound.beep() },
            showFailure: { [focusBorder] completion in
                let frame = completion.snapshot.originalFrames[completion.snapshot.draggedID]
                    ?? completion.snapshot.context.usableFrame
                return focusBorder.flashError(around: frame, windowID: completion.snapshot.draggedID,
                                              message: "Could not restore the tiled layout")
            },
            cancelFailure: { [focusBorder] in focusBorder.cancelErrorFeedback(token: $0) })
    }
}

private extension WindowManager {
    /// What the last walk could not read, and what the last poll held. A
    /// walk since that poll (a switch's, a reveal retry's) that read a
    /// window ends its hold: discovery's set only changes in a poll.
    var heldWindowIDs: Set<CGWindowID> {
        accessibility.unreadableWindowIDs
            .union(discovery.heldWindowIDs.subtracting(accessibility.readWindowIDs))
    }

    /// Give `admissionRecovery` its probes and its two actions.
    ///
    /// Everything it can do is here: run one more tiling pass with only the
    /// newcomer's older minima ignored, and float a window where it stands.
    /// It has no handle on workspace assignment, so the fallback cannot turn
    /// into `routeUnfittedWindow` by another name.
    private func wireAdmissionRecovery() {
        // the hold, owned by the engine: every pass asks, so a move onto a
        // workspace that holds an unreadable window, a scratchpad show and
        // the recovery's passes keep the held leaf like the retile does
        tilingEngine.heldWindowIDsSource = { [weak self] in
            guard let self else { return [] }
            return self.heldWindowIDs
                .subtracting(self.stateCache.floatingWindowIDs)
                .subtracting(self.stateCache.hiddenWindowIDs)
        }
        // a window sent to the cursor's monitor rolls back to where it opened
        tilingEngine.newcomerOriginSource = { [weak self] id in
            self?.actionDispatcher.cursorMoveOrigin(id)
        }
        // the tile a new window splits: the one HyprMac last focused
        tilingEngine.splitTargetSource = { [weak self] in
            guard let self else { return nil }
            let id = self.focusBorder.trackedWindowID ?? self.focusController.lastFocusedID
            return id == 0 ? nil : id
        }
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
            let allWindows = self.freshWalk()
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
        admissionRecovery.sharingOneBudget = { [weak self] body in
            guard let self else { return body() }
            self.tilingEngine.sharingOnePassBudget(body)
        }
        admissionRecovery.budgetLeft = { [weak self] in self?.tilingEngine.passBudgetLeft ?? false }
        admissionRecovery.floatInPlace = { [weak self] window, reason in
            // no cache refresh here: the run follows its floats with the
            // fallback retile, which walks once and refreshes the cache for
            // the key. a walk per float was eight walks for eight windows
            self?.floatingController.floatInPlace(window, reason: reason)
            // HyprMac tried, failed twice, and gave up: offer a rule once
            self?.offerFailedTilePrompt(window.windowID)
        }
        admissionRecovery.isTiled = { [weak self] id in
            guard let self, let workspace = self.workspaceManager.workspaceFor(id),
                  let screen = self.workspaceManager.homeScreenForWorkspace(workspace) else { return false }
            return self.tilingEngine.windowIDs(inTreeForWorkspace: workspace, screen: screen).contains(id)
        }
        admissionRecovery.clearUnverified = { [weak self] workspace, screen in
            self?.tilingEngine.clearUnverifiedGeometry(forWorkspace: workspace, screen: screen)
        }
        // the same pass a drift re-apply runs, so anything it strands still
        // reaches the newcomer recovery
        admissionRecovery.retileVacated = { [weak self] workspace, screen in
            self?.reapplyLayout(onWorkspace: workspace, screen: screen)
        }
        admissionRecovery.isLayoutSuspended = { [weak self] in
            self?.driftMonitor.isSuspended() ?? true
        }
        admissionRecovery.retileAfterFallback = { [weak self] workspace, screen in
            guard let self else { return [] }
            let allWindows = self.freshWalk()
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
