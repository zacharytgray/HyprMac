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
    let floatingController = FloatingWindowController()
    let keybindOverlay = KeybindOverlayController()

    private(set) var workspaceManager: WorkspaceManager!
    private(set) var tilingEngine: TilingEngine!

    // tracks known window IDs so we can detect new/closed ones
    private var knownWindowIDs: Set<CGWindowID> = []

    // stores original frames before tiling (for float toggle restore)
    private var originalFrames: [CGWindowID: CGRect] = [:]

    // tracks which windows are floating
    private var floatingWindowIDs: Set<CGWindowID> = []

    // track which PID owns each window (for close vs hide detection)
    private var windowOwners: [CGWindowID: pid_t] = [:]

    // windows that disappeared but app is still running (minimized/hidden)
    private var hiddenWindowIDs: Set<CGWindowID> = []

    // expected tiled positions — for drag detection and focus-follows-mouse
    private var tiledPositions: [CGWindowID: CGRect] = [:]

    // cached HyprWindow objects from last poll (for focus-follows-mouse)
    private var cachedWindows: [CGWindowID: HyprWindow] = [:]

    // polling timer
    private var pollTimer: Timer?

    // mouse tracking
    private var mouseMoveMonitor: Any?
    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?
    private var mouseDragMonitor: Any?
    private var mouseButtonDown = false
    private var mouseDraggedSinceDown = false
    private var mouseDownTiledFrames: [CGWindowID: CGRect] = [:]

    // window whose focus border was hidden when a drag started — re-shown on mouseUp.
    // we hide rather than try to follow, because we'd need 60Hz AX polling per window
    // and that's prohibitively expensive.
    private var preDragFocusedID: CGWindowID = 0

    // suppress appDidActivate workspace switching (survives async notification delivery)
    private var suppressActivationSwitchUntil: Date = .distantPast

    // guard against re-entrant raiseFloatingWindows (also used by suppressions)
    private var isRaisingFloaters = false

    // coalesce rapid polls from overlapping notifications
    private var pendingPoll = false

    // live config reload
    private var configObservers: Set<AnyCancellable> = []
    private var isRunning = false

    init(config: UserConfig) {
        self.config = config
        self.workspaceManager = WorkspaceManager(displayManager: displayManager)
        self.tilingEngine = TilingEngine(displayManager: displayManager)

        hotkeyManager.onAction = { [weak self] action in
            self?.mouseTracker.suppressMouseFocusUntil = Date().addingTimeInterval(0.3)
            self?.handleAction(action)
        }

        hotkeyManager.onHyprKeyDown = { [weak self] in
            self?.ensureFocus()
        }

        // wire up mouse tracker dependencies
        mouseTracker.isFocusFollowsMouseEnabled = { [weak self] in self?.config.focusFollowsMouse ?? false }
        mouseTracker.isMouseButtonDown = { [weak self] in self?.mouseButtonDown ?? false }
        mouseTracker.isAnimating = { [weak self] in self?.animator.isAnimating ?? false }
        mouseTracker.primaryScreenHeight = { [weak self] in self?.displayManager.primaryScreenHeight ?? 0 }
        mouseTracker.screenAt = { [weak self] pt in self?.displayManager.screen(at: pt) }
        mouseTracker.floatingWindowIDs = { [weak self] in self?.floatingWindowIDs ?? [] }
        mouseTracker.isWindowVisible = { [weak self] wid in self?.workspaceManager.isWindowVisible(wid) ?? false }
        mouseTracker.cachedWindow = { [weak self] wid in self?.cachedWindows[wid] }
        mouseTracker.tiledPositions = { [weak self] in self?.tiledPositions ?? [:] }
        mouseTracker.onFocusForFFM = { [weak self] w in self?.focusForFFM(w) }
        mouseTracker.onUpdateFocusBorder = { [weak self] w in self?.updateFocusBorder(for: w) }
        mouseTracker.onHideFocusBorder = { [weak self] in
            self?.focusBorder.hide()
            self?.dimmingOverlay.hideAll()
        }

        // wire up floating controller
        floatingController.isWindowVisible = { [weak self] wid in self?.workspaceManager.isWindowVisible(wid) ?? false }
        floatingController.cachedWindow = { [weak self] wid in self?.cachedWindows[wid] }
        floatingController.screenAt = { [weak self] pt in self?.displayManager.screen(at: pt) }
        floatingController.screenID = { [weak self] s in self?.workspaceManager.screenID(for: s) ?? 0 }
        floatingController.screens = { [weak self] in self?.displayManager.screens ?? [] }

        tilingEngine.onAutoFloat = { [weak self] window in
            guard let self = self else { return }
            window.isFloating = true
            self.floatingWindowIDs.insert(window.windowID)
            if let original = self.originalFrames[window.windowID] {
                window.setFrame(original)
            }
            hyprLog("auto-floated '\(window.title ?? "?")' — screen full")
        }

        // react to enabled toggling (including mid-flight config rewrites from iCloud sync)
        config.$enabled
            .dropFirst() // skip initial value — start() handles that
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self = self else { return }
                if enabled && !self.isRunning {
                    hyprLog("config re-enabled, starting")
                    self.start()
                } else if !enabled && self.isRunning {
                    hyprLog("config disabled, stopping")
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
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.pollWindowChanges()
            }
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
            hyprLog("keybinds reloaded (\(newBinds.count) binds)")
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
                hyprLog("max splits updated: \(newSplits)")
            }.store(in: &configObservers)

        config.$disabledMonitors
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newDisabled in
                guard let self = self else { return }
                self.workspaceManager.disabledMonitors = newDisabled
                // unfloat windows on newly-disabled monitors from their tiling trees
                self.handleDisabledMonitorChange()
                hyprLog("disabled monitors updated: \(newDisabled)")
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

        hyprLog("started")
    }

    func stop() {
        restoreAllWindows()
        isRunning = false
        pollTimer?.invalidate()
        pollTimer = nil
        stopMouseTracking()
        hotkeyManager.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        focusBorder.hide(); dimmingOverlay.hideAll()
        hyprLog("stopped")
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

            if let original = originalFrames[wid] {
                window.setFrame(original)
                hyprLog("restored '\(window.title ?? "?")' to original frame")
            } else {
                // cascade onto main screen
                let x = screenRect.origin.x + 50
                let y = screenRect.origin.y + 50
                let w = min(screenRect.width * 0.6, 1200)
                let h = min(screenRect.height * 0.6, 800)
                window.setFrame(CGRect(x: x, y: y, width: w, height: h))
                hyprLog("restored '\(window.title ?? "?")' to main screen")
            }
        }

        hyprLog("all windows restored to visible positions")
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
            self.captureMouseDownTiledFrames()
            // sync our focus tracker with the click — without this, manual clicks
            // leave lastMouseFocusedID stale and currentFocusedWindow() routes
            // commands to whatever was previously hovered, not what the user clicked
            self.syncFocusTrackerToCursor()
        }
        // when the user drags a floating window, its frame changes 60Hz but our
        // border only repositions on poll (1Hz) — so it lags behind ugly. hide
        // the border for the duration of the drag and restore it on mouseUp.
        mouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            guard let self = self else { return }
            self.mouseDraggedSinceDown = true
            guard self.preDragFocusedID == 0 else { return }
            guard let tid = self.focusBorder.trackedWindowID else { return }
            // only hide for floating windows — tiled windows can't be free-dragged
            guard self.floatingWindowIDs.contains(tid) else { return }
            self.preDragFocusedID = tid
            self.focusBorder.hide(); self.dimmingOverlay.hideAll()
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            let shouldDetectDrag = self?.mouseDraggedSinceDown ?? false
            let startFrames = self?.mouseDownTiledFrames ?? [:]
            self?.mouseButtonDown = false
            self?.mouseDraggedSinceDown = false
            self?.mouseDownTiledFrames.removeAll()
            if shouldDetectDrag {
                self?.handleMouseUp(startFrames: startFrames)
            }
            // restore the focus border on whatever floating window we hid it for,
            // after a brief settle delay so we read its final position
            if let id = self?.preDragFocusedID, id != 0 {
                self?.preDragFocusedID = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    guard let self = self, let w = self.cachedWindows[id] else { return }
                    self.updateFocusBorder(for: w)
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
    }

    private func focusForFFM(_ window: HyprWindow) {
        suppressActivationSwitchUntil = Date().addingTimeInterval(0.5)
        window.focusWithoutRaise()
        updateFocusBorder(for: window)
    }

    private func updateFocusBorder(for window: HyprWindow) {
        guard config.showFocusBorder, let frame = window.frame else {
            focusBorder.hide(); dimmingOverlay.hideAll()
            dimmingOverlay.hideAll()
            return
        }
        let isFloating = floatingWindowIDs.contains(window.windowID)
        focusBorder.accentCGColor = isFloating
            ? config.resolvedFloatingBorderColor.cgColor
            : config.resolvedFocusBorderColor.cgColor
        focusBorder.show(around: frame, windowID: window.windowID)
        refreshDimming(focusedID: window.windowID)
    }

    // recompute the dim mask from current tiled positions. called on focus
    // change and after any tile update so the shape stays accurate when
    // windows move, resize, or a workspace switch changes what's visible.
    private func refreshDimming(focusedID: CGWindowID? = nil) {
        dimmingOverlay.enabled = config.dimInactiveWindows
        dimmingOverlay.setIntensity(CGFloat(config.dimIntensity))
        dimmingOverlay.primaryScreenHeight = displayManager.primaryScreenHeight
        let fid = focusedID ?? focusBorder.trackedWindowID ?? mouseTracker.lastMouseFocusedID
        dimmingOverlay.update(focusedID: fid, tiledRects: tiledPositions, screens: displayManager.screens)
    }

    // recapture focus on bare hypr keydown — ensures border + keyboard focus
    // are on a valid tiled window even if mouse drifted or user clicked outside.
    // if a floating window already has focus, leave it alone so hypr combos
    // (like hypr+shift+T to re-tile) work on the floating window.
    private func ensureFocus() {
        mouseTracker.suppressMouseFocusUntil = Date().addingTimeInterval(0.3)

        // if a visible floating window already has focus, keep it
        if let focused = accessibility.getFocusedWindow(),
           floatingWindowIDs.contains(focused.windowID),
           workspaceManager.isWindowVisible(focused.windowID) {
            updateFocusBorder(for: focused)
            return
        }

        let screen = screenUnderCursor()
        let workspace = workspaceManager.workspaceForScreen(screen)
        let wsWindows = workspaceManager.windowIDs(onWorkspace: workspace)

        // convert mouse to CG coords
        let mouseNS = NSEvent.mouseLocation
        let cgY = displayManager.primaryScreenHeight - mouseNS.y
        let cgPoint = CGPoint(x: mouseNS.x, y: cgY)

        // tier 1: tiled window under cursor
        for (wid, rect) in tiledPositions {
            if wsWindows.contains(wid), rect.contains(cgPoint),
               let w = cachedWindows[wid] {
                w.focusWithoutRaise()
                mouseTracker.lastMouseFocusedID = wid
                updateFocusBorder(for: w)
                return
            }
        }

        // tier 2: any tiled window on this workspace
        for (wid, _) in tiledPositions {
            if wsWindows.contains(wid), let w = cachedWindows[wid] {
                w.focusWithoutRaise()
                mouseTracker.lastMouseFocusedID = wid
                updateFocusBorder(for: w)
                return
            }
        }

        // tier 3: whatever AX says is focused — just show the border
        if let focused = accessibility.getFocusedWindow(),
           workspaceManager.isWindowVisible(focused.windowID) {
            updateFocusBorder(for: focused)
        }
    }

    private func handleMouseUp(startFrames: [CGWindowID: CGRect]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.detectDragSwap(startFrames: startFrames)
        }
    }

    private func detectDragSwap(startFrames: [CGWindowID: CGRect]) {
        guard !animator.isAnimating else { return }

        // skip drag detection if the user was dragging a floating window —
        // floating windows can nudge tiled windows slightly, causing false
        // snapBack retiles that disrupt the layout
        if let focused = accessibility.getFocusedWindow(),
           floatingWindowIDs.contains(focused.windowID) {
            return
        }

        let allWindows = accessibility.getAllWindows()

        dragManager.floatingWindowIDs = floatingWindowIDs
        dragManager.tiledPositions = tiledPositions

        let result = dragManager.detect(
            allWindows: allWindows,
            cachedWindows: cachedWindows,
            startFrames: startFrames,
            screenAt: { [weak self] pt in self?.displayManager.screen(at: pt) },
            workspaceForScreen: { [weak self] s in self?.workspaceManager.workspaceForScreen(s) ?? 1 }
        )

        switch result {
        case .resize(let r):
            hyprLog("manual resize detected: '\(r.window.title ?? "?")'")
            tilingEngine.applyResize(r.window, newFrame: r.newFrame, onWorkspace: r.workspace, screen: r.screen)
            updatePositionCache(windows: allWindows)

        case .swap(let s):
            if s.crossMonitor {
                hyprLog("cross-monitor swap: '\(s.dragged.title ?? "?")' ↔ '\(s.target.title ?? "?")'")
                if let srcScreen = s.sourceScreen, let tgtScreen = s.targetScreen {
                    let srcWs = workspaceManager.workspaceForScreen(srcScreen)
                    let tgtWs = workspaceManager.workspaceForScreen(tgtScreen)
                    workspaceManager.moveWindow(s.dragged.windowID, toWorkspace: tgtWs)
                    workspaceManager.moveWindow(s.target.windowID, toWorkspace: srcWs)
                }
                tilingEngine.crossSwapWindows(s.dragged, s.target)
                updatePositionCache(windows: allWindows)
            } else if let screen = s.sourceScreen {
                let workspace = workspaceManager.workspaceForScreen(screen)
                hyprLog("drag swap: '\(s.dragged.title ?? "?")' ↔ '\(s.target.title ?? "?")'")

                guard tilingEngine.canSwapWindows(s.dragged, s.target, onWorkspace: workspace, screen: screen) else {
                    rejectSwap(s.dragged, reason: "drag swap would violate min-size constraints")
                    updatePositionCache(windows: allWindows)
                    return
                }

                if config.animateWindows,
                   let draggedFrame = s.dragged.frame,
                   let targetFrame = s.target.frame,
                   let layouts = tilingEngine.computeSwapLayout(s.dragged, s.target, onWorkspace: workspace, screen: screen) {
                    var transitions: [WindowAnimator.FrameTransition] = []
                    for (w, toRect) in layouts {
                        let fromRect: CGRect
                        if w.windowID == s.dragged.windowID { fromRect = draggedFrame }
                        else if w.windowID == s.target.windowID { fromRect = targetFrame }
                        else { continue }
                        transitions.append(.init(window: w, from: fromRect, to: toRect))
                    }
                    animator.animate(transitions, duration: config.animationDuration) { [weak self] in
                        self?.tilingEngine.applyComputedLayout(onWorkspace: workspace, screen: screen)
                        self?.updatePositionCache()
                    }
                } else {
                    tilingEngine.swapWindows(s.dragged, s.target, onWorkspace: workspace, screen: screen)
                    updatePositionCache(windows: allWindows)
                }
            }

        case .dragToEmpty(let d):
            hyprLog("cross-monitor move to empty desktop")
            let r = displayManager.cgRect(for: d.targetScreen)
            d.dragged.setFrame(CGRect(
                x: r.midX - r.width / 4,
                y: r.midY - r.height / 4,
                width: r.width / 2,
                height: r.height / 2
            ))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.tileAllVisibleSpaces()
            }

        case .snapBack:
            hyprLog("drag snap-back")
            tileAllVisibleSpaces(windows: allWindows)

        case .none:
            break
        }
    }

    // MARK: - action dispatch

    private func handleAction(_ action: Action) {
        switch action {
        case .focusDirection(let dir):
            focusInDirection(dir)
        case .swapDirection(let dir):
            swapInDirection(dir)
        case .switchDesktop(let num):
            switchWorkspace(num)
        case .moveToDesktop(let num):
            moveToWorkspace(num)
        case .moveWorkspaceToMonitor(let dir):
            moveCurrentWorkspaceToMonitor(dir)
        case .toggleFloating:
            toggleFloating()
        case .toggleSplit:
            toggleSplit()
        case .showKeybinds:
            showKeybindOverlay()
        case .launchApp(let bundleID):
            appLauncher.launchOrFocus(bundleID: bundleID)
        case .focusMenuBar:
            warpToMenuBar()
        case .focusFloating:
            focusFloatingWindow()
        case .closeWindow:
            closeWindow()
        case .cycleWorkspace(let delta):
            cycleOccupiedWorkspace(delta: delta)
        }
    }

    // MARK: - close window

    private func closeWindow() {
        guard let target = currentFocusedWindow() else { return }
        var closeButton: AnyObject?
        let err = AXUIElementCopyAttributeValue(target.element, kAXCloseButtonAttribute as CFString, &closeButton)
        if err == .success, let button = closeButton, CFGetTypeID(button) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }

    // MARK: - menu bar warp

    private func warpToMenuBar() {
        let mouseNS = NSEvent.mouseLocation
        let cgY = displayManager.primaryScreenHeight - mouseNS.y
        let cgPoint = CGPoint(x: mouseNS.x, y: cgY)

        guard let screen = displayManager.screen(at: cgPoint) else { return }
        let frame = screen.frame
        let primaryH = displayManager.primaryScreenHeight

        // warp to top-left of this screen's menu bar (CG coords)
        let menuBarY = primaryH - frame.maxY + 12 // ~center of 25px menu bar
        let menuBarX = frame.origin.x + 40 // past the Apple menu
        CGWarpMouseCursorPosition(CGPoint(x: menuBarX, y: menuBarY))
        CGAssociateMouseAndMouseCursorPosition(0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    // MARK: - focus

    private func focusInDirection(_ direction: Direction) {
        guard let focused = currentFocusedWindow() else { return }
        // only consider windows on visible workspaces — hidden corner windows must be excluded
        let windows = accessibility.getAllWindows().filter { workspaceManager.isWindowVisible($0.windowID) }

        if let target = accessibility.windowInDirection(direction, from: focused, among: windows) {
            target.focusWithoutRaise()
            cursorManager.warpToCenter(of: target)
            mouseTracker.lastMouseFocusedID = target.windowID
            updateFocusBorder(for: target)
        }
    }

    // MARK: - swap

    private func swapInDirection(_ direction: Direction) {
        guard let focused = currentFocusedWindow() else { return }
        guard let screen = displayManager.screen(for: focused) ?? displayManager.screens.first else { return }
        let workspace = workspaceManager.workspaceForScreen(screen)
        let windows = accessibility.getAllWindows().filter { workspaceManager.isWindowVisible($0.windowID) }

        guard let target = accessibility.windowInDirection(direction, from: focused, among: windows) else { return }
        guard tilingEngine.canSwapWindows(focused, target, onWorkspace: workspace, screen: screen) else {
            rejectSwap(focused, reason: "swap would violate min-size constraints")
            return
        }

        if config.animateWindows,
           let focusedFrame = focused.frame,
           let targetFrame = target.frame,
           let layouts = tilingEngine.computeSwapLayout(focused, target, onWorkspace: workspace, screen: screen) {
            // build transitions from current positions to computed targets
            var transitions: [WindowAnimator.FrameTransition] = []
            for (w, toRect) in layouts {
                let fromRect: CGRect
                if w.windowID == focused.windowID { fromRect = focusedFrame }
                else if w.windowID == target.windowID { fromRect = targetFrame }
                else { continue }
                transitions.append(.init(window: w, from: fromRect, to: toRect))
            }

            animator.animate(transitions, duration: config.animationDuration) { [weak self] in
                // snap final state with two-pass min-size resolution
                self?.tilingEngine.applyComputedLayout(onWorkspace: workspace, screen: screen)
                self?.cursorManager.warpToCenter(of: focused)
                self?.updatePositionCache()
            }
        } else {
            tilingEngine.swapWindows(focused, target, onWorkspace: workspace, screen: screen)
            cursorManager.warpToCenter(of: focused)
            updatePositionCache()
        }
    }

    private func rejectSwap(_ window: HyprWindow, reason: String) {
        hyprLog("\(reason) — rejected swap")
        NSSound.beep()
        if let frame = window.frame {
            focusBorder.flashError(around: frame, windowID: window.windowID, window: window)
        }
    }

    // MARK: - workspace switching

    // always use cursor position to determine which screen the user is on.
    // focused window can be stale (e.g. after switching to an empty workspace,
    // the focused window still belongs to the previous screen).
    private func screenUnderCursor() -> NSScreen {
        let mouseNS = NSEvent.mouseLocation
        let cgY = displayManager.primaryScreenHeight - mouseNS.y
        return displayManager.screen(at: CGPoint(x: mouseNS.x, y: cgY))
            ?? displayManager.screens.first
            ?? NSScreen.main!
    }

    // cycle through occupied workspaces on the current monitor (delta: +1 next, -1 prev).
    // "occupied" = has at least one window assigned to it.
    private func cycleOccupiedWorkspace(delta: Int) {
        let screen = screenUnderCursor()
        let current = workspaceManager.workspaceForScreen(screen)
        let total = workspaceManager.workspaceCount

        let screenSID = workspaceManager.screenID(for: screen)

        // collect occupied workspaces that belong to this monitor (home screen matches)
        let occupied = Set((1...total).filter { ws in
            workspaceManager.workspaceHomeScreen[ws] == screenSID &&
            !workspaceManager.windowIDs(onWorkspace: ws).isEmpty
        })

        guard !occupied.isEmpty else { return }

        // walk in the requested direction, wrapping around, until we find an occupied workspace
        var candidate = current
        for _ in 1...total {
            candidate = (candidate - 1 + delta + total) % total + 1
            if occupied.contains(candidate) {
                switchWorkspace(candidate)
                return
            }
        }
    }

    private func switchWorkspace(_ number: Int) {
        // suppress FFM and activation-triggered switches during and after this switch.
        // must outlive the synchronous scope because best.focus() queues async notifications.
        suppressActivationSwitchUntil = Date().addingTimeInterval(0.5)
        mouseTracker.suppressMouseFocusUntil = Date().addingTimeInterval(0.3)

        let currentScreen = screenUnderCursor()

        let allWindows = accessibility.getAllWindows()
        let result = workspaceManager.switchWorkspace(number, cursorScreen: currentScreen)

        if result.alreadyVisible {
            // workspace is showing on result.screen — just focus it
            let visibleWindows = allWindows.filter { result.toShow.contains($0.windowID) }
            if let best = visibleWindows.first(where: { !floatingWindowIDs.contains($0.windowID) })
                ?? visibleWindows.first {
                best.focus()
                cursorManager.warpToCenter(of: best)
                mouseTracker.lastMouseFocusedID = best.windowID
                updateFocusBorder(for: best)
            } else {
                let rect = displayManager.cgRect(for: result.screen)
                CGWarpMouseCursorPosition(CGPoint(x: rect.midX, y: rect.midY))
                focusBorder.hide(); dimmingOverlay.hideAll()
            }
            return
        }

        // batch: hide old + restore floating new in one tight pass
        for wid in result.toHide {
            if let w = findWindow(wid, in: allWindows) {
                if floatingWindowIDs.contains(wid) { workspaceManager.saveFloatingFrame(w) }
                workspaceManager.hideInCorner(w, on: result.screen)
            }
        }
        for wid in result.toShow where floatingWindowIDs.contains(wid) {
            if let w = findWindow(wid, in: allWindows) {
                workspaceManager.restoreFloatingFrame(w)
            }
        }

        // retile immediately — no delay between hide and show
        tileAllVisibleSpaces()

        // focus best tiled window on the new workspace; if none, fall back to
        // any floating window before giving up. only warp+hide if truly empty.
        let newWorkspaceWindows = allWindows.filter { result.toShow.contains($0.windowID) }
        let tiled = newWorkspaceWindows.first { !floatingWindowIDs.contains($0.windowID) }
        if let best = tiled ?? newWorkspaceWindows.first {
            best.focus()
            cursorManager.warpToCenter(of: best)
            mouseTracker.lastMouseFocusedID = best.windowID
            updateFocusBorder(for: best)
        } else {
            let rect = displayManager.cgRect(for: result.screen)
            CGWarpMouseCursorPosition(CGPoint(x: rect.midX, y: rect.midY))
            focusBorder.hide(); dimmingOverlay.hideAll()
        }

        NotificationCenter.default.post(name: .hyprMacWorkspaceChanged, object: nil)
    }

    private func moveToWorkspace(_ number: Int) {
        guard let focused = currentFocusedWindow() else { return }
        tilingEngine.primeMinimumSizes([focused])
        guard let screen = displayManager.screen(for: focused) ?? displayManager.screens.first else { return }

        // window on a disabled monitor — send it to the target workspace as a tiled window
        let onDisabledMonitor = workspaceManager.isMonitorDisabled(screen)

        let currentWorkspace = onDisabledMonitor ? nil : Optional(workspaceManager.workspaceForScreen(screen))

        if let cw = currentWorkspace, number == cw {
            hyprLog("window already on workspace \(number)")
            return
        }

        let isFloating = floatingWindowIDs.contains(focused.windowID)

        // when coming from disabled monitor, unfloat so it enters tiling on target
        let willTile = onDisabledMonitor || !isFloating

        // check capacity on target workspace before moving a tiled window
        if willTile {
            let targetScreen = workspaceManager.screenForWorkspace(number)
                ?? workspaceManager.homeScreenForWorkspace(number)
                ?? screen

            if let visibleScreen = workspaceManager.screenForWorkspace(number) {
                if !tilingEngine.canFitWindow(focused, onWorkspace: number, screen: visibleScreen) {
                    hyprLog("workspace \(number) can't fit '\(focused.title ?? "?")' on \(visibleScreen.localizedName) — rejected move")
                    NSSound.beep()
                    if let frame = focused.frame {
                        focusBorder.flashError(around: frame, windowID: focused.windowID, window: focused)
                    }
                    return
                }
            } else {
                // exclude hidden windows (minimized/closed but app still running) from count
                let wids = workspaceManager.windowIDs(onWorkspace: number).subtracting(hiddenWindowIDs)
                let tiledCount = wids.filter { !floatingWindowIDs.contains($0) }.count
                let maxDepth = tilingEngine.maxDepth(for: targetScreen)
                let maxWindows = 1 << maxDepth // 2^maxDepth — smart insert backtracks to fill all slots
                if tiledCount >= maxWindows {
                    hyprLog("workspace \(number) full (\(tiledCount) tiled, max \(maxWindows)) — rejected move")
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
            floatingWindowIDs.remove(focused.windowID)
            focused.isFloating = false
            hyprLog("unfloating '\(focused.title ?? "?")' from disabled monitor → workspace \(number)")
        }

        // animate remaining windows filling the gap
        animatedRetile(prepare: { [self] in
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
        }) {
            NotificationCenter.default.post(name: .hyprMacWorkspaceChanged, object: nil)
        }
    }

    // MARK: - move workspace to adjacent monitor

    private func moveCurrentWorkspaceToMonitor(_ direction: Direction) {
        let currentScreen = screenUnderCursor()

        // can't move workspaces from/to disabled monitors
        if workspaceManager.isMonitorDisabled(currentScreen) {
            hyprLog("moveWorkspaceToMonitor: current monitor is disabled")
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
            hyprLog("moveWorkspaceToMonitor: only left/right supported")
            return
        }

        guard targetIdx >= 0 && targetIdx < screens.count else {
            hyprLog("moveWorkspaceToMonitor: no monitor in that direction")
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
            if let w = findWindow(wid, in: allWindows) {
                if floatingWindowIDs.contains(wid) { workspaceManager.saveFloatingFrame(w) }
                workspaceManager.hideInCorner(w, on: targetScreen)
            }
        }

        // target's old workspace windows: need to be hidden (displaced, no longer visible)
        let displacedWindows = workspaceManager.windowIDs(onWorkspace: result.targetOldWs)
        if !workspaceManager.isWorkspaceVisible(result.targetOldWs) {
            for wid in displacedWindows {
                if let w = findWindow(wid, in: allWindows) {
                    if floatingWindowIDs.contains(wid) { workspaceManager.saveFloatingFrame(w) }
                    workspaceManager.hideInCorner(w, on: targetScreen)
                }
            }
        }

        // fallback workspace windows: need to appear on source screen
        let fallbackWindows = workspaceManager.windowIDs(onWorkspace: result.fallbackWs)
        for wid in fallbackWindows where floatingWindowIDs.contains(wid) {
            if let w = findWindow(wid, in: allWindows) {
                workspaceManager.restoreFloatingFrame(w)
            }
        }

        tileAllVisibleSpaces()

        // restore floating windows on moved workspace (now on target screen)
        for wid in movedWindows where floatingWindowIDs.contains(wid) {
            if let w = findWindow(wid, in: allWindows) {
                workspaceManager.restoreFloatingFrame(w)
            }
        }

        NotificationCenter.default.post(name: .hyprMacWorkspaceChanged, object: nil)
    }

    private func showKeybindOverlay() {
        keybindOverlay.toggle(keybinds: config.keybinds)
    }

    // MARK: - split toggle

    private func toggleSplit() {
        guard let focused = currentFocusedWindow(),
              let screen = displayManager.screen(for: focused) ?? displayManager.screens.first else { return }
        let workspace = workspaceManager.workspaceForScreen(screen)

        hyprLog("toggleSplit on '\(focused.title ?? "?")'")

        if config.animateWindows {
            // capture current frames before the toggle
            let windows = accessibility.getAllWindows().filter { workspaceManager.isWindowVisible($0.windowID) }
            let currentFrames = Dictionary(uniqueKeysWithValues: windows.compactMap { w -> (CGWindowID, CGRect)? in
                guard let f = w.frame else { return nil }
                return (w.windowID, f)
            })

            if let layouts = tilingEngine.computeToggleSplitLayout(focused, onWorkspace: workspace, screen: screen) {
                var transitions: [WindowAnimator.FrameTransition] = []
                for (w, toRect) in layouts {
                    guard let fromRect = currentFrames[w.windowID], fromRect != toRect else { continue }
                    transitions.append(.init(window: w, from: fromRect, to: toRect))
                }

                if !transitions.isEmpty {
                    animator.animate(transitions, duration: config.animationDuration) { [weak self] in
                        self?.tilingEngine.applyComputedLayout(onWorkspace: workspace, screen: screen)
                        self?.updatePositionCache()
                    }
                    return
                }
            }
        }

        tilingEngine.toggleSplit(focused, onWorkspace: workspace, screen: screen)
        updatePositionCache()
    }

    // MARK: - floating

    // public accessors for menu bar indicator
    var hasVisibleFloatingWindows: Bool {
        floatingWindowIDs.contains { workspaceManager.isWindowVisible($0) }
    }

    func occupiedWorkspaces() -> Set<Int> {
        var result = Set<Int>()
        for ws in 1...9 {
            // exclude hidden windows (minimized/closed but app still running)
            let live = workspaceManager.windowIDs(onWorkspace: ws).subtracting(hiddenWindowIDs)
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

    private func focusFloatingWindow() {
        mouseTracker.suppressMouseFocusUntil = Date().addingTimeInterval(0.3)
        suppressActivationSwitchUntil = Date().addingTimeInterval(0.5)

        guard let target = floatingController.focusFloating(
            floatingWindowIDs: floatingWindowIDs,
            getAllWindows: { [weak self] in self?.accessibility.getAllWindows() ?? [] },
            getFocusedWindow: { [weak self] in self?.accessibility.getFocusedWindow() },
            displayManager: displayManager,
            isFrameVisible: { [weak self] frame, screenRect in self?.isFrameVisible(frame, on: screenRect) ?? false }
        ) else {
            hyprLog("no visible floating windows")
            return
        }

        target.focus()
        cursorManager.warpToCenter(of: target)
        mouseTracker.lastMouseFocusedID = target.windowID
        updateFocusBorder(for: target)
    }

    private func toggleFloating() {
        guard let focused = currentFocusedWindow(),
              let screen = displayManager.screen(for: focused) ?? displayManager.screens.first else { return }

        // can't toggle tiling on disabled monitors — everything is floating there
        if workspaceManager.isMonitorDisabled(screen) {
            hyprLog("toggleFloating: monitor disabled, no tiling available")
            return
        }

        let workspace = workspaceManager.workspaceForScreen(screen)

        let wasFloating = floatingWindowIDs.contains(focused.windowID)

        if wasFloating {
            // floating → tiled: animate surrounding windows making room
            // reassign workspace in case the window was dragged to a different monitor
            workspaceManager.moveWindow(focused.windowID, toWorkspace: workspace)
            animatedRetile(prepare: { [self] in
                floatingWindowIDs.remove(focused.windowID)
                focused.isFloating = false

                if let evicted = tilingEngine.forceInsertWindow(focused, toWorkspace: workspace, on: screen) {
                    evicted.isFloating = true
                    floatingWindowIDs.insert(evicted.windowID)
                    let screenRect = displayManager.cgRect(for: screen)
                    if let original = originalFrames[evicted.windowID],
                       isFrameVisible(original, on: screenRect) {
                        evicted.setFrame(original)
                    } else {
                        let sz = evicted.size ?? CGSize(width: 800, height: 600)
                        evicted.position = CGPoint(x: screenRect.midX - sz.width / 2, y: screenRect.midY - sz.height / 2)
                    }
                    hyprLog("tiling '\(focused.title ?? "?")' — bumped '\(evicted.title ?? "?")' to floating")
                } else {
                    hyprLog("tiling window '\(focused.title ?? "?")'")
                }
            })
        } else {
            // tiled → floating: animate remaining windows filling the gap
            focusBorder.hide(); dimmingOverlay.hideAll()
            animatedRetile(prepare: { [self] in
                floatingWindowIDs.insert(focused.windowID)
                focused.isFloating = true
                tilingEngine.removeWindow(focused, fromWorkspace: workspace)

                let screenRect = displayManager.cgRect(for: screen)
                if let original = originalFrames[focused.windowID],
                   isFrameVisible(original, on: screenRect) {
                    focused.position = original.origin
                    focused.size = original.size
                    hyprLog("floated window '\(focused.title ?? "?")' → restored \(original)")
                } else {
                    let currentSize = focused.size ?? CGSize(width: 800, height: 600)
                    let centeredOrigin = CGPoint(
                        x: screenRect.midX - currentSize.width / 2,
                        y: screenRect.midY - currentSize.height / 2
                    )
                    focused.position = centeredOrigin
                    hyprLog("floated window '\(focused.title ?? "?")' → centered on screen (bad original frame)")
                }
            })
        }
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
                if !floatingWindowIDs.contains(w.windowID) {
                    floatingWindowIDs.insert(w.windowID)
                    w.isFloating = true
                    hyprLog("disabled monitor change: floated '\(w.title ?? "?")'")
                }
            }
        }

        // windows on re-enabled monitors: unfloat and let snapshotAndTile pick them up
        for screen in displayManager.screens where !workspaceManager.isMonitorDisabled(screen) {
            for w in allWindows {
                guard let wScreen = displayManager.screen(for: w),
                      wScreen == screen else { continue }
                // only unfloat if it was auto-floated (no workspace assignment = was on disabled monitor)
                if floatingWindowIDs.contains(w.windowID) && workspaceManager.workspaceFor(w.windowID) == nil {
                    floatingWindowIDs.remove(w.windowID)
                    w.isFloating = false
                    hyprLog("re-enabled monitor: unfloated '\(w.title ?? "?")'")
                }
            }
        }

        workspaceManager.initializeMonitors()
        snapshotAndTile()
    }

    // MARK: - tiling

    // check if a window belongs to an excluded app (auto-float)
    private func isExcludedApp(_ window: HyprWindow) -> Bool {
        guard let bundleID = NSRunningApplication(processIdentifier: window.ownerPID)?.bundleIdentifier else {
            return false
        }
        return config.excludedBundleIDs.contains(bundleID)
    }

    func snapshotAndTile() {
        let allWindows = accessibility.getAllWindows()
        tilingEngine.primeMinimumSizes(allWindows)
        for w in allWindows {
            if let frame = w.frame, originalFrames[w.windowID] == nil {
                // only save if the frame is actually visible on some screen.
                // after a restart, windows may still be at the previous session's hide corner.
                let onScreen = displayManager.screens.contains { screen in
                    isFrameVisible(frame, on: displayManager.cgRect(for: screen))
                }
                if onScreen {
                    originalFrames[w.windowID] = frame
                }
            }
            knownWindowIDs.insert(w.windowID)
            windowOwners[w.windowID] = w.ownerPID

            // auto-float excluded apps
            if isExcludedApp(w) && !floatingWindowIDs.contains(w.windowID) {
                floatingWindowIDs.insert(w.windowID)
                w.isFloating = true
                hyprLog("auto-float excluded app: '\(w.title ?? "?")'")
            }

            // auto-float windows on disabled monitors — don't assign workspace
            if let screen = displayManager.screen(for: w), workspaceManager.isMonitorDisabled(screen) {
                if !floatingWindowIDs.contains(w.windowID) {
                    floatingWindowIDs.insert(w.windowID)
                    w.isFloating = true
                    hyprLog("auto-float on disabled monitor: '\(w.title ?? "?")'")
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
            if floatingWindowIDs.contains(w.windowID) {
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

            hyprLog("retile: workspace=\(workspace) screen=\(workspaceManager.screenID(for: screen)), \(workspaceWindows.count) windows")
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
                  !floatingWindowIDs.contains(w.windowID),
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
            if floatingWindowIDs.contains(w.windowID) { w.isFloating = true }
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

            let layouts = tilingEngine.computeTileLayout(workspaceWindows, onWorkspace: workspace, screen: screen)
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
        let keepFloating = Set(allWindows.filter { isExcludedApp($0) }.map { $0.windowID })
        for wid in floatingWindowIDs where !keepFloating.contains(wid) && allWids.contains(wid) {
            floatingWindowIDs.remove(wid)
            if let w = allWindows.first(where: { $0.windowID == wid }) {
                w.isFloating = false
            }
        }

        // gather all tiling window IDs (from visible workspaces + unassigned)
        var tilingWids: [CGWindowID] = []
        for screen in screens {
            let ws = workspaceManager.workspaceForScreen(screen)
            for wid in workspaceManager.windowIDs(onWorkspace: ws) where !floatingWindowIDs.contains(wid) {
                tilingWids.append(wid)
            }
        }
        for w in allWindows where !floatingWindowIDs.contains(w.windowID) {
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
            floatingWindowIDs.insert(wid)
            if let w = allWindows.first(where: { $0.windowID == wid }) {
                w.isFloating = true
                if let original = originalFrames[wid] { w.setFrame(original) }
                hyprLog("all workspaces full — auto-floating '\(w.title ?? "?")'")
            }
            widIdx += 1
        }

        // hide windows on non-visible workspaces
        for wid in tilingWids where !floatingWindowIDs.contains(wid) {
            guard let assignedWs = workspaceManager.workspaceFor(wid),
                  !workspaceManager.isWorkspaceVisible(assignedWs) else { continue }
            if let w = allWindows.first(where: { $0.windowID == wid }) {
                let screen = workspaceManager.homeScreenForWorkspace(assignedWs) ?? screens[0]
                workspaceManager.hideInCorner(w, on: screen)
            }
        }

        hyprLog("distributed \(tilingWids.count) windows across \(slotsUsed) slot(s), \(screens.count) monitor(s)")
    }

    // find a window by ID — checks live list first, falls back to cache
    private func findWindow(_ wid: CGWindowID, in allWindows: [HyprWindow]) -> HyprWindow? {
        allWindows.first { $0.windowID == wid } ?? cachedWindows[wid]
    }

    // assign window to the active workspace on its physical screen (for startup/snapshot)
    private func assignToScreenWorkspace(_ window: HyprWindow) {
        guard workspaceManager.workspaceFor(window.windowID) == nil else { return }
        if let screen = displayManager.screen(for: window) ?? displayManager.screens.first {
            let ws = workspaceManager.workspaceForScreen(screen)
            workspaceManager.assignWindow(window.windowID, toWorkspace: ws)
        }
    }

    // assign new window to a workspace based on where it physically opened.
    // prefer the window's own screen (where macOS actually placed it) — falls
    // back to cursor screen only when the window has no usable frame yet.
    // never trusts a stale prior assignment: a recycled CGWindowID could carry
    // a leftover entry pointing at a workspace the user hasn't used in days.
    private func assignNewWindow(_ window: HyprWindow) {
        let physical = displayManager.screen(for: window)
        let screen = physical ?? screenUnderCursor()
        guard !workspaceManager.isMonitorDisabled(screen) else { return }
        let ws = workspaceManager.workspaceForScreen(screen)
        // overwrite any stale entry — assignWindow handles old-set cleanup
        workspaceManager.assignWindow(window.windowID, toWorkspace: ws)
    }

    // returns the window the user actually intends to control. AX's notion of
    // "focused window" can lag or flat-out diverge from reality for multi-window
    // apps (Finder, Teams) — focusWithoutRaise (used by FFM and Hypr+Arrow) does
    // not reliably update kAXFocusedWindowAttribute. our own lastMouseFocusedID
    // tracker is updated on every focus action *and* on manual clicks, so it
    // stays in sync with what the user actually pointed at last.
    private func currentFocusedWindow() -> HyprWindow? {
        if mouseTracker.lastMouseFocusedID != 0,
           let w = cachedWindows[mouseTracker.lastMouseFocusedID] {
            return w
        }
        return accessibility.getFocusedWindow()
    }

    // hit-test the cursor against tiled and floating windows, update tracker.
    // called from leftMouseDown so a manual click immediately wins over any
    // stale FFM tracker state.
    private func captureMouseDownTiledFrames() {
        mouseDownTiledFrames.removeAll()
        for w in accessibility.getAllWindows() {
            guard workspaceManager.isWindowVisible(w.windowID),
                  !floatingWindowIDs.contains(w.windowID),
                  let frame = w.frame else { continue }
            mouseDownTiledFrames[w.windowID] = frame
        }
    }

    private func syncFocusTrackerToCursor() {
        let mouseNS = NSEvent.mouseLocation
        let cgY = displayManager.primaryScreenHeight - mouseNS.y
        let cgPoint = CGPoint(x: mouseNS.x, y: cgY)

        // floating windows take precedence (drawn on top)
        for wid in floatingWindowIDs {
            guard workspaceManager.isWindowVisible(wid),
                  let w = cachedWindows[wid], let frame = w.frame else { continue }
            if frame.contains(cgPoint) {
                mouseTracker.lastMouseFocusedID = wid
                return
            }
        }
        for (wid, rect) in tiledPositions where rect.contains(cgPoint) {
            mouseTracker.lastMouseFocusedID = wid
            return
        }
    }

    // central per-window cleanup — prune every dict that keys on windowID.
    // safe to call on already-forgotten IDs (idempotent).
    private func forgetWindow(_ id: CGWindowID) {
        knownWindowIDs.remove(id)
        hiddenWindowIDs.remove(id)
        originalFrames.removeValue(forKey: id)
        floatingWindowIDs.remove(id)
        windowOwners.removeValue(forKey: id)
        tiledPositions.removeValue(forKey: id)
        cachedWindows.removeValue(forKey: id)
        tilingEngine.forgetMinimumSize(windowID: id)
        workspaceManager.removeWindow(id)
        if mouseTracker.lastMouseFocusedID == id {
            mouseTracker.lastMouseFocusedID = 0
        }
        if focusBorder.trackedWindowID == id {
            focusBorder.hide(); dimmingOverlay.hideAll()
        }
    }

    // forget every window we knew about for a given pid. handles the case where
    // an app terminates while some of its windows are hidden/minimized — those
    // ids would otherwise leak in hiddenWindowIDs/windowOwners/etc forever.
    private func forgetApp(_ pid: pid_t) {
        let ids = windowOwners.compactMap { $0.value == pid ? $0.key : nil }
        for id in ids { forgetWindow(id) }
    }

    // detect tiled windows that physically drifted to a different screen than
    // their recorded workspace lives on (e.g. user dragged across monitors,
    // macOS dock-clicked an app and raised a window on the wrong screen, etc.)
    // and reassign so state matches reality. without this, the window renders
    // on screen B but tiling treats it as belonging to screen A's workspace —
    // any operation on either side desyncs further.
    private func reconcileWindowScreens(_ allWindows: [HyprWindow]) -> Bool {
        guard !animator.isAnimating else { return false }
        let visibleWorkspaces = Set(workspaceManager.monitorWorkspace.values)
        var reassigned = false
        for w in allWindows {
            guard let recordedWs = workspaceManager.workspaceFor(w.windowID) else { continue }
            // only check windows whose recorded workspace is currently on screen
            guard visibleWorkspaces.contains(recordedWs) else { continue }
            // floating windows can be anywhere by design — skip
            guard !floatingWindowIDs.contains(w.windowID) else { continue }
            guard let physicalScreen = displayManager.screen(for: w) else { continue }
            // skip if the window sits on a disabled monitor — handled elsewhere
            guard !workspaceManager.isMonitorDisabled(physicalScreen) else { continue }
            let physicalWs = workspaceManager.workspaceForScreen(physicalScreen)
            guard physicalWs != recordedWs else { continue }
            // also ignore windows whose recorded screen and physical screen are
            // the same — guards against transient frame reads during retile
            if let recordedScreen = workspaceManager.screenForWorkspace(recordedWs),
               recordedScreen == physicalScreen { continue }
            workspaceManager.moveWindow(w.windowID, toWorkspace: physicalWs)
            hyprLog("drift reconcile: '\(w.title ?? "?")' ws\(recordedWs) → ws\(physicalWs) (now on \(physicalScreen.localizedName))")
            reassigned = true
        }
        return reassigned
    }

    // if the focus border is hidden but the cursor's screen's workspace has any
    // visible window, focus one. prevents getting stuck with no focus target —
    // the user shouldn't have to click a window to get keyboard focus back.
    private func ensureFocusInvariant() {
        guard config.showFocusBorder else { return }
        // don't steal focus from a native menu that's currently tracking —
        // SLPSPostEventRecordTo + panel reordering both dismiss menus
        guard !mouseTracker.menuTracking else { return }
        // border is already showing on a live window — nothing to do
        if let tid = focusBorder.trackedWindowID, cachedWindows[tid] != nil {
            return
        }
        let screen = screenUnderCursor()
        guard !workspaceManager.isMonitorDisabled(screen) else { return }
        let workspace = workspaceManager.workspaceForScreen(screen)
        let wsWindows = workspaceManager.windowIDs(onWorkspace: workspace)
            .subtracting(hiddenWindowIDs)
        guard !wsWindows.isEmpty else { return }

        // prefer whatever AX says is focused if it's on this workspace
        if let focused = accessibility.getFocusedWindow(),
           wsWindows.contains(focused.windowID) {
            mouseTracker.lastMouseFocusedID = focused.windowID
            updateFocusBorder(for: focused)
            return
        }
        // any tiled window on this workspace
        for (wid, _) in tiledPositions where wsWindows.contains(wid) {
            if let w = cachedWindows[wid] {
                w.focusWithoutRaise()
                mouseTracker.lastMouseFocusedID = wid
                updateFocusBorder(for: w)
                return
            }
        }
        // fall back to any visible window on this workspace (floating, etc.)
        for wid in wsWindows {
            if let w = cachedWindows[wid] {
                w.focusWithoutRaise()
                mouseTracker.lastMouseFocusedID = wid
                updateFocusBorder(for: w)
                return
            }
        }
    }

    // sweep state for ids that are no longer alive anywhere. catches drift from
    // edge cases (race conditions, terminated apps whose windows weren't seen
    // disappearing first, hidden windows whose owners died).
    private func reconcileWindowState(runningPIDs: Set<pid_t>) {
        // hidden windows whose owner pid died — fully forget
        for id in hiddenWindowIDs {
            if let pid = windowOwners[id], !runningPIDs.contains(pid) {
                forgetWindow(id)
            }
        }
        // workspace assignments for ids we no longer track at all
        let live = knownWindowIDs.union(hiddenWindowIDs)
        for (id, _) in workspaceManager.allWindowWorkspaces() where !live.contains(id) {
            forgetWindow(id)
        }
        // floating set / originalFrames / windowOwners shouldn't outlive known+hidden either
        for id in floatingWindowIDs where !live.contains(id) { forgetWindow(id) }
        for (id, _) in originalFrames where !live.contains(id) { forgetWindow(id) }
        for (id, _) in windowOwners where !live.contains(id) { forgetWindow(id) }
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

    private func updatePositionCache(windows: [HyprWindow]? = nil) {
        let allWindows = windows ?? accessibility.getAllWindows()
        tilingEngine.primeMinimumSizes(allWindows)
        tiledPositions.removeAll()
        cachedWindows.removeAll()
        for w in allWindows {
            guard workspaceManager.isWindowVisible(w.windowID) else { continue }
            cachedWindows[w.windowID] = w
            if !floatingWindowIDs.contains(w.windowID), let frame = w.cachedFrame ?? w.frame {
                tiledPositions[w.windowID] = frame
            }
        }
        updateMenuBarState()

        // keep focus border tracking window position (retile, resize, etc.)
        if let tid = focusBorder.trackedWindowID, let w = cachedWindows[tid], let frame = w.frame {
            focusBorder.updatePosition(frame)
        }
        refreshDimming()
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
        let liveFloating = floatingWindowIDs.subtracting(hiddenWindowIDs)
        for ws in 1...9 {
            let wsWindows = workspaceManager.windowIDs(onWorkspace: ws)
            if !wsWindows.isDisjoint(with: liveFloating) {
                result.insert(ws)
            }
        }
        return result
    }

    // MARK: - poll

    private func pollWindowChanges() {
        guard !animator.isAnimating else { return }
        guard !mouseButtonDown else { return }
        let allWindows = accessibility.getAllWindows()
        tilingEngine.primeMinimumSizes(allWindows)
        let currentIDs = Set(allWindows.map { $0.windowID })

        var changed = false

        // check for returning hidden windows
        for w in allWindows {
            if hiddenWindowIDs.contains(w.windowID) {
                hiddenWindowIDs.remove(w.windowID)
                knownWindowIDs.insert(w.windowID)
                windowOwners[w.windowID] = w.ownerPID

                changed = true
                hyprLog("window returned: '\(w.title ?? "?")' (\(w.windowID))")
            }
        }

        // detect new windows
        for w in allWindows {
            if !knownWindowIDs.contains(w.windowID) {
                if let frame = w.frame {
                    let onScreen = displayManager.screens.contains { screen in
                        isFrameVisible(frame, on: displayManager.cgRect(for: screen))
                    }
                    if onScreen {
                        originalFrames[w.windowID] = frame
                    }
                }
                knownWindowIDs.insert(w.windowID)
                windowOwners[w.windowID] = w.ownerPID

                // auto-float excluded apps
                if isExcludedApp(w) {
                    floatingWindowIDs.insert(w.windowID)
                    w.isFloating = true
                    hyprLog("auto-float excluded app: '\(w.title ?? "?")'")
                }

                // auto-float on disabled monitors — skip workspace assignment
                if let screen = displayManager.screen(for: w), workspaceManager.isMonitorDisabled(screen) {
                    if !floatingWindowIDs.contains(w.windowID) {
                        floatingWindowIDs.insert(w.windowID)
                        w.isFloating = true
                        hyprLog("auto-float on disabled monitor: '\(w.title ?? "?")'")
                    }
                    changed = true
                    hyprLog("new window (disabled monitor): '\(w.title ?? "?")' (\(w.windowID))")
                    continue
                }

                // assign by physical screen — using cursor was unreliable: with
                // multi-monitor + display-reconfig churn, screenUnderCursor could
                // return a screen with a high workspace number the user wasn't
                // even on, dropping the new window into ws 7/8 unexpectedly
                assignNewWindow(w)

                changed = true
                hyprLog("new window: '\(w.title ?? "?")' (\(w.windowID))")
            }
        }

        // detect gone windows
        let gone = knownWindowIDs.subtracting(currentIDs)
        var focusedWindowGone = false
        let runningPIDs = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
        if !gone.isEmpty {
            for id in gone {
                if id == mouseTracker.lastMouseFocusedID { focusedWindowGone = true }
                tiledPositions.removeValue(forKey: id)
                cachedWindows.removeValue(forKey: id)

                if let pid = windowOwners[id], runningPIDs.contains(pid) {
                    // app still running — window was minimized, hidden, or closed.
                    // track as hidden regardless of workspace visibility so un-minimize
                    // is detected correctly even for windows on hidden workspaces.
                    knownWindowIDs.remove(id)
                    hiddenWindowIDs.insert(id)
                    changed = true
                    if workspaceManager.isWindowVisible(id) {
                        hyprLog("window hidden: \(id)")
                    } else {
                        hyprLog("window hidden (inactive ws): \(id)")
                    }
                } else {
                    // app terminated — full cleanup
                    forgetWindow(id)
                    changed = true
                    hyprLog("window gone: \(id)")
                }
            }
        }

        // sweep stale entries — catches leaks from terminated apps whose hidden
        // windows never showed up in the gone set, and any other drift
        reconcileWindowState(runningPIDs: runningPIDs)

        // detect cross-screen drift: a window's recorded workspace no longer
        // matches the screen it physically sits on (manual drag, errant click)
        if reconcileWindowScreens(allWindows) { changed = true }

        if changed {
            // animate surrounding windows sliding to fill gaps / make room
            animatedRetile(windows: allWindows)
        }

        // if the FFM-tracked window disappeared, refocus to whatever tiled window
        // is under the cursor now. without this, focus gets stuck because
        // handleMouseMove only fires on actual mouse movement.
        if focusedWindowGone {
            mouseTracker.refocusUnderCursor()
        }

        // catch-all: ensure something on the active workspace has focus + border
        ensureFocusInvariant()

        // periodically re-raise floating windows so they don't get stuck
        // behind full-screen tiled windows (no activation event to trigger raise)
        if !floatingWindowIDs.isEmpty {
            raiseFloatingWindows()
        }
    }

    // MARK: - observers

    @objc private func appDidActivate(_ notification: Notification) {
        // suppress FFM while dock popups (downloads, stacks) are open
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            mouseTracker.dockIsActive = (app.bundleIdentifier == "com.apple.dock")
        }

        // dock-click workspace switch — only when NOT suppressed by FFM/switch/raise
        if Date() > suppressActivationSwitchUntil {
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                let pid = app.processIdentifier
                let visibleWorkspaces = Set(workspaceManager.monitorWorkspace.values)

                // only consider windows still tracked (not hidden/closed)
                let appWindows = windowOwners
                    .filter { $0.value == pid && knownWindowIDs.contains($0.key) && !hiddenWindowIDs.contains($0.key) }

                let appWorkspaces = appWindows.compactMap { (wid, _) in workspaceManager.workspaceFor(wid) }
                let hasVisibleWindow = appWorkspaces.contains { visibleWorkspaces.contains($0) }

                if !hasVisibleWindow {
                    if let targetWS = appWorkspaces.filter({ !visibleWorkspaces.contains($0) }).min() {
                        switchWorkspace(targetWS)
                        return
                    }
                }
            }
        }

        schedulePoll()

        // re-raise floating windows after any app activation (e.g. user clicked a tiled window).
        // must always run — even when activation switch is suppressed — so floaters stay on top.
        if !floatingWindowIDs.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.raiseFloatingWindows()
            }
        }
    }

    private func raiseFloatingWindows() {
        guard !isRaisingFloaters else { return }
        // skip while a native menu is tracking — the post-raise focusWithoutRaise
        // below synthesizes key-focus events that dismiss context menus
        guard !mouseTracker.menuTracking else { return }
        isRaisingFloaters = true
        defer { isRaisingFloaters = false }

        let toRaise = floatingController.floatingWindowsBehindTiled(
            floatingWindowIDs: floatingWindowIDs,
            tiledPositions: tiledPositions
        )
        guard !toRaise.isEmpty else { return }

        let previousFocusID = mouseTracker.lastMouseFocusedID
        let previousWindow = cachedWindows[previousFocusID]

        suppressActivationSwitchUntil = Date().addingTimeInterval(0.5)
        mouseTracker.suppressMouseFocusUntil = Date().addingTimeInterval(0.15)

        for wid in toRaise {
            guard let w = cachedWindows[wid] else { continue }
            AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        }

        // immediately restore focus to the tiled window the user was interacting with.
        // this prevents the raise from stealing focus and triggering an FFM cascade.
        if let prev = previousWindow, !floatingWindowIDs.contains(prev.windowID) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                prev.focusWithoutRaise()
                self?.updateFocusBorder(for: prev)
            }
        }
    }

    // coalesced poll scheduling — all notification handlers funnel through here
    private func schedulePoll(delay: TimeInterval = 0.2) {
        guard !pendingPoll else { return }
        pendingPoll = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.pendingPoll = false
            self.pollWindowChanges()
        }
    }

    @objc private func appDidLaunch(_ notification: Notification) {
        schedulePoll(delay: 0.5)
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        // proactively prune state for the dead pid — without this, hidden/minimized
        // windows owned by the app would leak in windowOwners/hiddenWindowIDs/etc
        // (they're not in knownWindowIDs anymore so the gone-detect path skips them).
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            forgetApp(app.processIdentifier)
        }
        schedulePoll()
    }

    @objc private func appVisibilityChanged(_ notification: Notification) {
        schedulePoll(delay: 0.3)
    }

    @objc private func screenParametersChanged() {
        hyprLog("screen parameters changed — reinitializing workspaces")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.focusBorder.primaryScreenHeight = self.displayManager.primaryScreenHeight
            self.workspaceManager.initializeMonitors()
            self.snapshotAndTile()
        }
    }

    @objc private func retileAllRequested() {
        hyprLog("retile all spaces requested")
        snapshotAndTile()
    }
}
