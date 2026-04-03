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
    private var mouseButtonDown = false

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
        mouseTracker.onHideFocusBorder = { [weak self] in self?.focusBorder.hide() }

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
            print("[HyprMac] auto-floated '\(window.title ?? "?")' — screen full")
        }

        // react to enabled toggling (including mid-flight config rewrites from iCloud sync)
        config.$enabled
            .dropFirst() // skip initial value — start() handles that
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self = self else { return }
                if enabled && !self.isRunning {
                    print("[HyprMac] config re-enabled, starting")
                    self.start()
                } else if !enabled && self.isRunning {
                    print("[HyprMac] config disabled, stopping")
                    self.stop()
                }
            }.store(in: &configObservers)
    }

    func start() {
        guard config.enabled else {
            print("[HyprMac] disabled in config")
            return
        }
        guard !isRunning else { return }
        isRunning = true

        tilingEngine.gapSize = config.gapSize
        tilingEngine.outerPadding = config.outerPadding
        tilingEngine.maxSplitsPerMonitor = config.maxSplitsPerMonitor
        workspaceManager.disabledMonitors = config.disabledMonitors
        hotkeyManager.updateKeybinds(config.keybinds)
        hotkeyManager.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.spaceManager.setup()
            self?.workspaceManager.initializeMonitors()
            self?.snapshotAndTile()
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollWindowChanges()
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
            self, selector: #selector(retileRequested),
            name: .hyprMacRetile, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        // reload keybinds when config changes (no retile, just update hotkey table)
        config.$keybinds.sink { [weak self] newBinds in
            guard let self = self else { return }
            self.hotkeyManager.updateKeybinds(newBinds)
            print("[HyprMac] keybinds reloaded (\(newBinds.count) binds)")
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
                print("[HyprMac] max splits updated: \(newSplits)")
            }.store(in: &configObservers)

        config.$disabledMonitors
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newDisabled in
                guard let self = self else { return }
                self.workspaceManager.disabledMonitors = newDisabled
                // unfloat windows on newly-disabled monitors from their tiling trees
                self.handleDisabledMonitorChange()
                print("[HyprMac] disabled monitors updated: \(newDisabled)")
            }.store(in: &configObservers)

        print("[HyprMac] started")
    }

    func stop() {
        isRunning = false
        pollTimer?.invalidate()
        pollTimer = nil
        stopMouseTracking()
        hotkeyManager.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        focusBorder.hide()
        print("[HyprMac] stopped")
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
            self?.mouseButtonDown = true
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.mouseButtonDown = false
            self?.handleMouseUp()
        }
    }

    private func stopMouseTracking() {
        if let m = mouseMoveMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseDownMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m) }
        mouseMoveMonitor = nil
        mouseDownMonitor = nil
        mouseUpMonitor = nil
    }

    private func focusForFFM(_ window: HyprWindow) {
        suppressActivationSwitchUntil = Date().addingTimeInterval(0.5)
        window.focusWithoutRaise()
        updateFocusBorder(for: window)
    }

    private func updateFocusBorder(for window: HyprWindow) {
        guard config.showFocusBorder, let frame = window.frame else {
            focusBorder.hide()
            return
        }
        focusBorder.accentCGColor = config.resolvedFocusBorderColor.cgColor
        focusBorder.show(around: frame, windowID: window.windowID)
    }

    // recapture focus on bare hypr keydown — ensures border + keyboard focus
    // are on a valid tiled window even if mouse drifted or user clicked outside
    private func ensureFocus() {
        mouseTracker.suppressMouseFocusUntil = Date().addingTimeInterval(0.3)

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

    private func handleMouseUp() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.detectDragSwap()
        }
    }

    private func detectDragSwap() {
        guard !animator.isAnimating else { return }
        let allWindows = accessibility.getAllWindows()

        dragManager.floatingWindowIDs = floatingWindowIDs
        dragManager.tiledPositions = tiledPositions

        let result = dragManager.detect(
            allWindows: allWindows,
            cachedWindows: cachedWindows,
            screenAt: { [weak self] pt in self?.displayManager.screen(at: pt) },
            workspaceForScreen: { [weak self] s in self?.workspaceManager.workspaceForScreen(s) ?? 1 }
        )

        switch result {
        case .resize(let r):
            print("[HyprMac] manual resize detected: '\(r.window.title ?? "?")'")
            tilingEngine.applyResize(r.window, newFrame: r.newFrame, onWorkspace: r.workspace, screen: r.screen)
            updatePositionCache()

        case .swap(let s):
            if s.crossMonitor {
                print("[HyprMac] cross-monitor swap: '\(s.dragged.title ?? "?")' ↔ '\(s.target.title ?? "?")'")
                if let srcScreen = s.sourceScreen, let tgtScreen = s.targetScreen {
                    let srcWs = workspaceManager.workspaceForScreen(srcScreen)
                    let tgtWs = workspaceManager.workspaceForScreen(tgtScreen)
                    workspaceManager.moveWindow(s.dragged.windowID, toWorkspace: tgtWs)
                    workspaceManager.moveWindow(s.target.windowID, toWorkspace: srcWs)
                }
                tilingEngine.crossSwapWindows(s.dragged, s.target)
                updatePositionCache()
            } else if let screen = s.sourceScreen {
                let workspace = workspaceManager.workspaceForScreen(screen)
                print("[HyprMac] drag swap: '\(s.dragged.title ?? "?")' ↔ '\(s.target.title ?? "?")'")

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
                    updatePositionCache()
                }
            }

        case .dragToEmpty(let d):
            print("[HyprMac] cross-monitor move to empty desktop")
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
            print("[HyprMac] drag snap-back")
            tileAllVisibleSpaces()

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
        // prefer the FFM-tracked window (the one under cursor) over AX focused window,
        // because focusWithoutRaise doesn't update macOS's notion of "focused window"
        // for multi-window same-app scenarios
        let target = cachedWindows[mouseTracker.lastMouseFocusedID] ?? accessibility.getFocusedWindow()
        guard let target else { return }
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
        guard let focused = accessibility.getFocusedWindow() else { return }
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
        guard let focused = accessibility.getFocusedWindow() else { return }
        guard let screen = displayManager.screen(for: focused) ?? displayManager.screens.first else { return }
        let workspace = workspaceManager.workspaceForScreen(screen)
        let windows = accessibility.getAllWindows().filter { workspaceManager.isWindowVisible($0.windowID) }

        guard let target = accessibility.windowInDirection(direction, from: focused, among: windows) else { return }

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
                focusBorder.hide()
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

        // focus best tiled window on the new workspace, or warp cursor
        let newWorkspaceWindows = allWindows.filter {
            result.toShow.contains($0.windowID) && !floatingWindowIDs.contains($0.windowID)
        }
        if let best = newWorkspaceWindows.first {
            best.focus()
            cursorManager.warpToCenter(of: best)
            mouseTracker.lastMouseFocusedID = best.windowID
            updateFocusBorder(for: best)
        } else {
            let rect = displayManager.cgRect(for: result.screen)
            CGWarpMouseCursorPosition(CGPoint(x: rect.midX, y: rect.midY))
            focusBorder.hide()
        }

        NotificationCenter.default.post(name: .hyprMacWorkspaceChanged, object: nil)
    }

    private func moveToWorkspace(_ number: Int) {
        guard let focused = accessibility.getFocusedWindow() else { return }
        guard let screen = displayManager.screen(for: focused) ?? displayManager.screens.first else { return }

        // window on a disabled monitor — send it to the target workspace as a tiled window
        let onDisabledMonitor = workspaceManager.isMonitorDisabled(screen)

        let currentWorkspace = onDisabledMonitor ? nil : Optional(workspaceManager.workspaceForScreen(screen))

        if let cw = currentWorkspace, number == cw {
            print("[HyprMac] window already on workspace \(number)")
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
                if !tilingEngine.canFitWindow(onWorkspace: number, screen: visibleScreen) {
                    print("[HyprMac] workspace \(number) full on \(visibleScreen.localizedName) — rejected move")
                    NSSound.beep()
                    return
                }
            } else {
                let wids = workspaceManager.windowIDs(onWorkspace: number)
                let tiledCount = wids.filter { !floatingWindowIDs.contains($0) }.count
                let maxDepth = tilingEngine.maxDepth(for: targetScreen)
                if tiledCount >= maxDepth + 1 {
                    print("[HyprMac] workspace \(number) full (\(tiledCount) tiled, max \(maxDepth + 1)) — rejected move")
                    NSSound.beep()
                    return
                }
            }
        }

        // unfloat if coming from disabled monitor
        if onDisabledMonitor && isFloating {
            floatingWindowIDs.remove(focused.windowID)
            focused.isFloating = false
            print("[HyprMac] unfloating '\(focused.title ?? "?")' from disabled monitor → workspace \(number)")
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
            print("[HyprMac] moveWorkspaceToMonitor: current monitor is disabled")
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
            print("[HyprMac] moveWorkspaceToMonitor: only left/right supported")
            return
        }

        guard targetIdx >= 0 && targetIdx < screens.count else {
            print("[HyprMac] moveWorkspaceToMonitor: no monitor in that direction")
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
        guard let focused = accessibility.getFocusedWindow(),
              let screen = displayManager.screen(for: focused) ?? displayManager.screens.first else { return }
        let workspace = workspaceManager.workspaceForScreen(screen)

        print("[HyprMac] toggleSplit on '\(focused.title ?? "?")'")

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
            if !workspaceManager.windowIDs(onWorkspace: ws).isEmpty {
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
            print("[HyprMac] no visible floating windows")
            return
        }

        target.focus()
        cursorManager.warpToCenter(of: target)
        mouseTracker.lastMouseFocusedID = target.windowID
        updateFocusBorder(for: target)
    }

    private func toggleFloating() {
        guard let focused = accessibility.getFocusedWindow(),
              let screen = displayManager.screen(for: focused) ?? displayManager.screens.first else { return }

        // can't toggle tiling on disabled monitors — everything is floating there
        if workspaceManager.isMonitorDisabled(screen) {
            print("[HyprMac] toggleFloating: monitor disabled, no tiling available")
            return
        }

        let workspace = workspaceManager.workspaceForScreen(screen)

        let wasFloating = floatingWindowIDs.contains(focused.windowID)

        if wasFloating {
            // floating → tiled: animate surrounding windows making room
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
                    print("[HyprMac] tiling '\(focused.title ?? "?")' — bumped '\(evicted.title ?? "?")' to floating")
                } else {
                    print("[HyprMac] tiling window '\(focused.title ?? "?")'")
                }
            })
        } else {
            // tiled → floating: animate remaining windows filling the gap
            focusBorder.hide()
            animatedRetile(prepare: { [self] in
                floatingWindowIDs.insert(focused.windowID)
                focused.isFloating = true
                tilingEngine.removeWindow(focused, fromWorkspace: workspace)

                let screenRect = displayManager.cgRect(for: screen)
                if let original = originalFrames[focused.windowID],
                   isFrameVisible(original, on: screenRect) {
                    focused.position = original.origin
                    focused.size = original.size
                    print("[HyprMac] floated window '\(focused.title ?? "?")' → restored \(original)")
                } else {
                    let currentSize = focused.size ?? CGSize(width: 800, height: 600)
                    let centeredOrigin = CGPoint(
                        x: screenRect.midX - currentSize.width / 2,
                        y: screenRect.midY - currentSize.height / 2
                    )
                    focused.position = centeredOrigin
                    print("[HyprMac] floated window '\(focused.title ?? "?")' → centered on screen (bad original frame)")
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
                    print("[HyprMac] disabled monitor change: floated '\(w.title ?? "?")'")
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
                    print("[HyprMac] re-enabled monitor: unfloated '\(w.title ?? "?")'")
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
                print("[HyprMac] auto-float excluded app: '\(w.title ?? "?")'")
            }

            // auto-float windows on disabled monitors — don't assign workspace
            if let screen = displayManager.screen(for: w), workspaceManager.isMonitorDisabled(screen) {
                if !floatingWindowIDs.contains(w.windowID) {
                    floatingWindowIDs.insert(w.windowID)
                    w.isFloating = true
                    print("[HyprMac] auto-float on disabled monitor: '\(w.title ?? "?")'")
                }
                continue
            }

            assignToScreenWorkspace(w)
        }
        distributeWindowsAcrossWorkspaces()
        tileAllVisibleSpaces()
    }

    func tileAllVisibleSpaces() {
        guard !animator.isAnimating else { return }
        let allWindows = accessibility.getAllWindows()

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

            print("[HyprMac] retile: workspace=\(workspace) screen=\(workspaceManager.screenID(for: screen)), \(workspaceWindows.count) windows")
            tilingEngine.tileWindows(workspaceWindows, onWorkspace: workspace, screen: screen)
        }

        updatePositionCache()
    }

    // animated retile — captures before-frames, runs prepare(), computes new layout,
    // then animates existing windows sliding from old → new positions.
    // only animates the surrounding windows — no fade/scale on the window that triggered the change.
    private func animatedRetile(
        prepare: (() -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard config.animateWindows, !animator.isAnimating else {
            prepare?()
            tileAllVisibleSpaces()
            completion?()
            return
        }

        let allWindows = accessibility.getAllWindows()

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

        // compute new layout for each screen without applying
        var newLayouts: [(HyprWindow, CGRect)] = []
        let refreshedWindows = accessibility.getAllWindows()

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
            tileAllVisibleSpaces()
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

        // full redistribution: un-float everything except excluded apps.
        // the poll loop may have auto-floated windows before distribute ran.
        let excludedWids = Set(allWindows.filter { isExcludedApp($0) }.map { $0.windowID })
        for wid in floatingWindowIDs where !excludedWids.contains(wid) && allWids.contains(wid) {
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
            let cap = tilingEngine.maxDepth(for: slot.screen) + 1
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
                print("[HyprMac] all workspaces full — auto-floating '\(w.title ?? "?")'")
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

        print("[HyprMac] distributed \(tilingWids.count) windows across \(slotsUsed) slot(s), \(screens.count) monitor(s)")
    }

    // find a window by ID — checks live list first, falls back to cache
    private func findWindow(_ wid: CGWindowID, in allWindows: [HyprWindow]) -> HyprWindow? {
        allWindows.first { $0.windowID == wid } ?? cachedWindows[wid]
    }

    // assign window to the active workspace on its screen if not already assigned
    private func assignToScreenWorkspace(_ window: HyprWindow) {
        guard workspaceManager.workspaceFor(window.windowID) == nil else { return }
        if let screen = displayManager.screen(for: window) ?? displayManager.screens.first {
            let ws = workspaceManager.workspaceForScreen(screen)
            workspaceManager.assignWindow(window.windowID, toWorkspace: ws)
        }
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

    private func updatePositionCache() {
        let allWindows = accessibility.getAllWindows()
        tiledPositions.removeAll()
        cachedWindows.removeAll()
        for w in allWindows {
            guard workspaceManager.isWindowVisible(w.windowID) else { continue }
            cachedWindows[w.windowID] = w
            if !floatingWindowIDs.contains(w.windowID), let frame = w.frame {
                tiledPositions[w.windowID] = frame
            }
        }
        updateMenuBarState()

        // keep focus border tracking window position (retile, resize, etc.)
        if let tid = focusBorder.trackedWindowID, let w = cachedWindows[tid], let frame = w.frame {
            focusBorder.updatePosition(frame)
        }
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
        for ws in 1...9 {
            let wsWindows = workspaceManager.windowIDs(onWorkspace: ws)
            if !wsWindows.isDisjoint(with: floatingWindowIDs) {
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
        let currentIDs = Set(allWindows.map { $0.windowID })

        var changed = false

        // check for returning hidden windows
        for w in allWindows {
            if hiddenWindowIDs.contains(w.windowID) {
                hiddenWindowIDs.remove(w.windowID)
                knownWindowIDs.insert(w.windowID)
                windowOwners[w.windowID] = w.ownerPID
                changed = true
                print("[HyprMac] window returned: '\(w.title ?? "?")' (\(w.windowID))")
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
                    print("[HyprMac] auto-float excluded app: '\(w.title ?? "?")'")
                }

                // auto-float on disabled monitors — skip workspace assignment
                if let screen = displayManager.screen(for: w), workspaceManager.isMonitorDisabled(screen) {
                    if !floatingWindowIDs.contains(w.windowID) {
                        floatingWindowIDs.insert(w.windowID)
                        w.isFloating = true
                        print("[HyprMac] auto-float on disabled monitor: '\(w.title ?? "?")'")
                    }
                    changed = true
                    print("[HyprMac] new window (disabled monitor): '\(w.title ?? "?")' (\(w.windowID))")
                    continue
                }

                assignToScreenWorkspace(w)

                changed = true
                print("[HyprMac] new window: '\(w.title ?? "?")' (\(w.windowID))")
            }
        }

        // detect gone windows
        let gone = knownWindowIDs.subtracting(currentIDs)
        var focusedWindowGone = false
        if !gone.isEmpty {
            let runningPIDs = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
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
                        print("[HyprMac] window hidden: \(id)")
                    } else {
                        print("[HyprMac] window hidden (inactive ws): \(id)")
                    }
                } else {
                    // app terminated — full cleanup
                    knownWindowIDs.remove(id)
                    originalFrames.removeValue(forKey: id)
                    floatingWindowIDs.remove(id)
                    windowOwners.removeValue(forKey: id)
                    workspaceManager.removeWindow(id)
                    changed = true
                    print("[HyprMac] window gone: \(id)")
                }
            }
        }

        if changed {
            // animate surrounding windows sliding to fill gaps / make room
            animatedRetile()
        }

        // if the FFM-tracked window disappeared, refocus to whatever tiled window
        // is under the cursor now. without this, focus gets stuck because
        // handleMouseMove only fires on actual mouse movement.
        if focusedWindowGone {
            mouseTracker.refocusUnderCursor()
        }

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
        schedulePoll()
    }

    @objc private func appVisibilityChanged(_ notification: Notification) {
        schedulePoll(delay: 0.3)
    }

    @objc private func screenParametersChanged() {
        print("[HyprMac] screen parameters changed — reinitializing workspaces")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.workspaceManager.initializeMonitors()
            self?.snapshotAndTile()
        }
    }

    @objc private func retileRequested() {
        print("[HyprMac] retile requested")
        snapshotAndTile()
    }
}
