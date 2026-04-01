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
    private var lastMouseFocusedID: CGWindowID = 0

    // dwell delay — mouse must hover briefly before FFM triggers
    private var pendingFocusID: CGWindowID = 0
    private var pendingFocusTime: Date = .distantPast
    private let focusFollowsMouseDelay: TimeInterval = 0.05

    // suppress FFM while interacting with a floating window or menu bar
    private var floatingWindowActive = false
    private var menuBarTracking = false

    // suppress focus-follows-mouse briefly after keyboard actions
    private var suppressMouseFocusUntil: Date = .distantPast

    // live config reload
    private var configObserver: AnyCancellable?

    init(config: UserConfig) {
        self.config = config
        self.workspaceManager = WorkspaceManager(displayManager: displayManager)
        self.tilingEngine = TilingEngine(displayManager: displayManager)

        hotkeyManager.onAction = { [weak self] action in
            self?.suppressMouseFocusUntil = Date().addingTimeInterval(0.3)
            self?.handleAction(action)
        }

        tilingEngine.onAutoFloat = { [weak self] window in
            guard let self = self else { return }
            window.isFloating = true
            self.floatingWindowIDs.insert(window.windowID)
            if let original = self.originalFrames[window.windowID] {
                window.setFrame(original)
            }
            print("[HyprMac] auto-floated '\(window.title ?? "?")' — screen full (max \(self.tilingEngine.maxDepth) splits)")
        }
    }

    func start() {
        guard config.enabled else {
            print("[HyprMac] disabled in config")
            return
        }

        tilingEngine.gapSize = config.gapSize
        tilingEngine.outerPadding = config.outerPadding
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
        configObserver = config.$keybinds.sink { [weak self] newBinds in
            guard let self = self else { return }
            self.hotkeyManager.updateKeybinds(newBinds)
            print("[HyprMac] keybinds reloaded (\(newBinds.count) binds)")
        }

        print("[HyprMac] started")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        stopMouseTracking()
        hotkeyManager.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        print("[HyprMac] stopped")
    }

    @objc private func menuTrackingBegan(_ note: Notification) {
        menuBarTracking = true
    }

    @objc private func menuTrackingEnded(_ note: Notification) {
        menuBarTracking = false
    }

    func restart() {
        stop()
        start()
    }

    // MARK: - mouse tracking

    private func startMouseTracking() {
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.handleMouseMove()
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

    private func handleMouseMove() {
        guard config.focusFollowsMouse else { return }
        guard !mouseButtonDown else { return }
        guard !floatingWindowActive else { return }
        guard !menuBarTracking else { return }
        guard Date() > suppressMouseFocusUntil else { return }

        let mouseNS = NSEvent.mouseLocation
        let cgY = displayManager.primaryScreenHeight - mouseNS.y
        let cgPoint = CGPoint(x: mouseNS.x, y: cgY)

        // dead zone: menu bar region (~25px in CG top-left coords)
        if cgY < 25 {
            pendingFocusID = 0
            return
        }

        for (wid, rect) in tiledPositions {
            if rect.contains(cgPoint) {
                guard wid != lastMouseFocusedID else { return }

                if wid != pendingFocusID {
                    // mouse entered new window — start dwell timer
                    pendingFocusID = wid
                    pendingFocusTime = Date()
                    return
                }

                // same pending window — check dwell time
                guard Date().timeIntervalSince(pendingFocusTime) >= focusFollowsMouseDelay else {
                    return
                }

                // dwell met — focus
                lastMouseFocusedID = wid
                pendingFocusID = 0
                if let target = cachedWindows[wid] {
                    target.focus()
                }
                return
            }
        }

        // mouse not over any tiled window — reset pending
        pendingFocusID = 0
    }

    private func handleMouseUp() {
        // re-raise floating windows after click/drag — delayed to beat focus() 50ms re-raise
        if floatingWindowActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self = self, self.floatingWindowActive else { return }
                for wid in self.floatingWindowIDs {
                    guard self.workspaceManager.isWindowVisible(wid),
                          let w = self.cachedWindows[wid] else { continue }
                    AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.detectDragSwap()
        }
    }

    private func detectDragSwap() {
        let allWindows = accessibility.getAllWindows()

        var draggedWindow: HyprWindow?
        for w in allWindows {
            guard !floatingWindowIDs.contains(w.windowID),
                  let current = w.frame,
                  let expected = tiledPositions[w.windowID] else { continue }

            let dist = abs(current.origin.x - expected.origin.x) + abs(current.origin.y - expected.origin.y)
            if dist > 50 {
                draggedWindow = w
                break
            }
        }

        guard let dragged = draggedWindow, let dragCenter = dragged.center else { return }

        let expectedRect = tiledPositions[dragged.windowID]!
        let expectedCenter = CGPoint(x: expectedRect.midX, y: expectedRect.midY)
        let sourceScreen = displayManager.screen(at: expectedCenter)
        let targetScreen = displayManager.screen(at: dragCenter)
        let crossMonitor = (sourceScreen != targetScreen)

        var swapTarget: HyprWindow?
        for (wid, rect) in tiledPositions {
            guard wid != dragged.windowID else { continue }
            if rect.contains(dragCenter) {
                swapTarget = allWindows.first { $0.windowID == wid } ?? cachedWindows[wid]
                break
            }
        }

        if let target = swapTarget {
            if crossMonitor {
                print("[HyprMac] cross-monitor swap: '\(dragged.title ?? "?")' ↔ '\(target.title ?? "?")'")
                tilingEngine.crossSwapWindows(dragged, target)
            } else {
                if let screen = sourceScreen {
                    let workspace = workspaceManager.workspaceForScreen(screen)
                    print("[HyprMac] drag swap: '\(dragged.title ?? "?")' ↔ '\(target.title ?? "?")'")
                    tilingEngine.swapWindows(dragged, target, onWorkspace: workspace, screen: screen)
                }
            }
            updatePositionCache()
            return
        }

        if crossMonitor {
            let targetHasWindows = tiledPositions.contains { (wid, rect) in
                guard wid != dragged.windowID else { return false }
                let center = CGPoint(x: rect.midX, y: rect.midY)
                return displayManager.screen(at: center) == targetScreen
            }

            if !targetHasWindows, let targetScreen = targetScreen {
                print("[HyprMac] cross-monitor move to empty desktop")
                let r = displayManager.cgRect(for: targetScreen)
                dragged.setFrame(CGRect(
                    x: r.midX - r.width / 4,
                    y: r.midY - r.height / 4,
                    width: r.width / 2,
                    height: r.height / 2
                ))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.tileAllVisibleSpaces()
                }
                return
            }
        }

        print("[HyprMac] drag snap-back")
        tileAllVisibleSpaces()
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
        }
    }

    // MARK: - focus

    private func focusInDirection(_ direction: Direction) {
        guard let focused = accessibility.getFocusedWindow() else { return }
        let windows = accessibility.getAllWindows()

        if let target = accessibility.windowInDirection(direction, from: focused, among: windows) {
            target.focus()
            floatingWindowActive = false
            cursorManager.warpToCenter(of: target)
            lastMouseFocusedID = target.windowID
        }
    }

    // MARK: - swap

    private func swapInDirection(_ direction: Direction) {
        guard let focused = accessibility.getFocusedWindow() else { return }
        guard let screen = displayManager.screen(for: focused) ?? displayManager.screens.first else { return }
        let workspace = workspaceManager.workspaceForScreen(screen)
        let windows = accessibility.getAllWindows()

        guard let target = accessibility.windowInDirection(direction, from: focused, among: windows) else { return }

        tilingEngine.swapWindows(focused, target, onWorkspace: workspace, screen: screen)
        cursorManager.warpToCenter(of: focused)
        updatePositionCache()
    }

    // MARK: - workspace switching

    // always use cursor position to determine which screen the user is on.
    // focused window can be stale (e.g. after switching to an empty workspace,
    // the focused window still belongs to the previous screen).
    private func screenUnderCursor() -> NSScreen {
        let mouseNS = NSEvent.mouseLocation
        let cgY = displayManager.primaryScreenHeight - mouseNS.y
        return displayManager.screen(at: CGPoint(x: mouseNS.x, y: cgY))
            ?? displayManager.screens.first!
    }

    private func switchWorkspace(_ number: Int) {
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
                lastMouseFocusedID = best.windowID
            } else {
                let rect = displayManager.cgRect(for: result.screen)
                CGWarpMouseCursorPosition(CGPoint(x: rect.midX, y: rect.midY))
            }
            return
        }

        // hide windows from old workspace
        for wid in result.toHide {
            if let w = allWindows.first(where: { $0.windowID == wid }) ?? cachedWindows[wid] {
                if floatingWindowIDs.contains(wid) {
                    workspaceManager.saveFloatingFrame(w)
                }
                workspaceManager.hideInCorner(w, on: result.screen)
            }
        }

        // unhide floating windows on new workspace
        for wid in result.toShow {
            if floatingWindowIDs.contains(wid),
               let w = allWindows.first(where: { $0.windowID == wid }) ?? cachedWindows[wid] {
                workspaceManager.restoreFloatingFrame(w)
            }
        }

        // retile — visible-only filter applies in tileAllVisibleSpaces
        tileAllVisibleSpaces()

        // focus best tiled window on the new workspace, or warp cursor
        let newWorkspaceWindows = allWindows.filter {
            result.toShow.contains($0.windowID) && !floatingWindowIDs.contains($0.windowID)
        }
        if let best = newWorkspaceWindows.first {
            best.focus()
            cursorManager.warpToCenter(of: best)
            lastMouseFocusedID = best.windowID
        } else {
            let rect = displayManager.cgRect(for: result.screen)
            CGWarpMouseCursorPosition(CGPoint(x: rect.midX, y: rect.midY))
        }

        NotificationCenter.default.post(name: .hyprMacWorkspaceChanged, object: nil)
    }

    private func moveToWorkspace(_ number: Int) {
        guard let focused = accessibility.getFocusedWindow() else { return }
        guard let screen = displayManager.screen(for: focused) ?? displayManager.screens.first else { return }
        let currentWorkspace = workspaceManager.workspaceForScreen(screen)

        if number == currentWorkspace {
            print("[HyprMac] window already on workspace \(number)")
            return
        }

        let isFloating = floatingWindowIDs.contains(focused.windowID)

        // remove from current workspace's tiling tree
        if !isFloating {
            tilingEngine.removeWindow(focused, fromWorkspace: currentWorkspace)
        }

        // reassign globally
        workspaceManager.moveWindow(focused.windowID, toWorkspace: number)

        // hide the window — target workspace may not be visible
        if isFloating {
            workspaceManager.saveFloatingFrame(focused)
        }
        workspaceManager.hideInCorner(focused, on: screen)

        tileAllVisibleSpaces()
        NotificationCenter.default.post(name: .hyprMacWorkspaceChanged, object: nil)
    }

    // MARK: - move workspace to adjacent monitor

    private func moveCurrentWorkspaceToMonitor(_ direction: Direction) {
        let currentScreen = screenUnderCursor()

        // find adjacent monitor in the given direction
        let screens = displayManager.screens.sorted { $0.frame.origin.x < $1.frame.origin.x }
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
            if let w = allWindows.first(where: { $0.windowID == wid }) ?? cachedWindows[wid] {
                if floatingWindowIDs.contains(wid) { workspaceManager.saveFloatingFrame(w) }
                workspaceManager.hideInCorner(w, on: targetScreen)
            }
        }

        // target's old workspace windows: need to be hidden (displaced, no longer visible)
        let displacedWindows = workspaceManager.windowIDs(onWorkspace: result.targetOldWs)
        if !workspaceManager.isWorkspaceVisible(result.targetOldWs) {
            for wid in displacedWindows {
                if let w = allWindows.first(where: { $0.windowID == wid }) ?? cachedWindows[wid] {
                    if floatingWindowIDs.contains(wid) { workspaceManager.saveFloatingFrame(w) }
                    workspaceManager.hideInCorner(w, on: targetScreen)
                }
            }
        }

        // fallback workspace windows: need to appear on source screen
        let fallbackWindows = workspaceManager.windowIDs(onWorkspace: result.fallbackWs)
        for wid in fallbackWindows where floatingWindowIDs.contains(wid) {
            if let w = allWindows.first(where: { $0.windowID == wid }) ?? cachedWindows[wid] {
                workspaceManager.restoreFloatingFrame(w)
            }
        }

        tileAllVisibleSpaces()

        // restore floating windows on moved workspace (now on target screen)
        for wid in movedWindows where floatingWindowIDs.contains(wid) {
            if let w = allWindows.first(where: { $0.windowID == wid }) ?? cachedWindows[wid] {
                workspaceManager.restoreFloatingFrame(w)
            }
        }

        NotificationCenter.default.post(name: .hyprMacWorkspaceChanged, object: nil)
    }

    // MARK: - keybind overlay

    private var keybindPanel: NSPanel?

    private func showKeybindOverlay() {
        // toggle off if already showing
        if let panel = keybindPanel {
            panel.close()
            keybindPanel = nil
            return
        }

        let binds = config.keybinds
        var lines: [(String, String)] = []  // (shortcut, description)

        for bind in binds {
            var mods: [String] = []
            if bind.modifiers.contains(.hypr) { mods.append("Caps") }
            if bind.modifiers.contains(.shift) { mods.append("Shift") }
            if bind.modifiers.contains(.control) { mods.append("Ctrl") }
            if bind.modifiers.contains(.option) { mods.append("Opt") }
            if bind.modifiers.contains(.command) { mods.append("Cmd") }

            let keyName = bind.keyCodeName
            let shortcut = (mods + [keyName]).joined(separator: " + ")
            let desc = bind.actionDescription
            lines.append((shortcut, desc))
        }

        // build the overlay
        guard let screen = NSScreen.main else { return }
        let padding: CGFloat = 24
        let lineHeight: CGFloat = 22
        let headerHeight: CGFloat = 36
        let contentHeight = headerHeight + CGFloat(lines.count) * lineHeight + padding * 2
        let panelWidth: CGFloat = 400
        let panelHeight = min(contentHeight, screen.visibleFrame.height * 0.8)

        let panelX = screen.frame.midX - panelWidth / 2
        let panelY = screen.frame.midY - panelHeight / 2
        let frame = NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight)

        let panel = NSPanel(contentRect: frame,
                            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
                            backing: .buffered, defer: false)
        panel.title = "HyprMac Keybinds"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight - 28))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: panelWidth - 20, height: 0))
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: padding, height: padding)

        let attrStr = NSMutableAttributedString()
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor
        ]
        let shortcutAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.systemBlue
        ]
        let descAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        attrStr.append(NSAttributedString(string: "Keybinds\n\n", attributes: headerAttrs))

        for (shortcut, desc) in lines {
            attrStr.append(NSAttributedString(string: shortcut, attributes: shortcutAttrs))
            attrStr.append(NSAttributedString(string: "  →  ", attributes: descAttrs))
            attrStr.append(NSAttributedString(string: desc + "\n", attributes: descAttrs))
        }

        textView.textStorage?.setAttributedString(attrStr)
        textView.sizeToFit()

        scroll.documentView = textView
        panel.contentView = scroll

        panel.makeKeyAndOrderFront(nil)
        keybindPanel = panel
    }

    // MARK: - split toggle

    private func toggleSplit() {
        guard let focused = accessibility.getFocusedWindow(),
              let screen = displayManager.screen(for: focused) ?? displayManager.screens.first else { return }
        let workspace = workspaceManager.workspaceForScreen(screen)

        print("[HyprMac] toggleSplit on '\(focused.title ?? "?")'")
        tilingEngine.toggleSplit(focused, onWorkspace: workspace, screen: screen)
        updatePositionCache()
    }

    // MARK: - floating

    private func toggleFloating() {
        guard let focused = accessibility.getFocusedWindow(),
              let screen = displayManager.screen(for: focused) ?? displayManager.screens.first else { return }
        let workspace = workspaceManager.workspaceForScreen(screen)

        let wasFloating = floatingWindowIDs.contains(focused.windowID)

        if wasFloating {
            floatingWindowIDs.remove(focused.windowID)
            focused.isFloating = false
            floatingWindowActive = false

            if let evicted = tilingEngine.forceInsertWindow(focused, toWorkspace: workspace, on: screen) {
                evicted.isFloating = true
                floatingWindowIDs.insert(evicted.windowID)
                if let original = originalFrames[evicted.windowID] {
                    evicted.setFrame(original)
                }
                print("[HyprMac] tiling '\(focused.title ?? "?")' — bumped '\(evicted.title ?? "?")' to floating")
            } else {
                print("[HyprMac] tiling window '\(focused.title ?? "?")'")
            }

            tileAllVisibleSpaces()
        } else {
            floatingWindowIDs.insert(focused.windowID)
            focused.isFloating = true
            floatingWindowActive = true
            tilingEngine.removeWindow(focused, fromWorkspace: workspace)

            if let original = originalFrames[focused.windowID] {
                focused.position = original.origin
                focused.size = original.size
                print("[HyprMac] floated window '\(focused.title ?? "?")' → restored \(original)")
            } else {
                print("[HyprMac] floated window '\(focused.title ?? "?")' (no saved frame)")
            }

            tileAllVisibleSpaces()
        }
    }

    // MARK: - tiling

    func snapshotAndTile() {
        let allWindows = accessibility.getAllWindows()
        for w in allWindows {
            if let frame = w.frame, originalFrames[w.windowID] == nil {
                originalFrames[w.windowID] = frame
            }
            knownWindowIDs.insert(w.windowID)
            windowOwners[w.windowID] = w.ownerPID

            // assign to workspace of the monitor it's physically on
            if workspaceManager.workspaceFor(w.windowID) == nil {
                if let screen = displayManager.screen(for: w) ?? displayManager.screens.first {
                    let ws = workspaceManager.workspaceForScreen(screen)
                    workspaceManager.assignWindow(w.windowID, toWorkspace: ws)
                }
            }
        }
        tileAllVisibleSpaces()
    }

    func tileAllVisibleSpaces() {
        let allWindows = accessibility.getAllWindows()

        for w in allWindows {
            if floatingWindowIDs.contains(w.windowID) {
                w.isFloating = true
            }
        }

        // for each monitor, tile the windows that belong to its active workspace
        for screen in displayManager.screens {
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
    }

    // MARK: - poll

    private func pollWindowChanges() {
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
                    originalFrames[w.windowID] = frame
                }
                knownWindowIDs.insert(w.windowID)
                windowOwners[w.windowID] = w.ownerPID

                // assign to active workspace on the window's screen
                if workspaceManager.workspaceFor(w.windowID) == nil {
                    if let screen = displayManager.screen(for: w) ?? displayManager.screens.first {
                        let ws = workspaceManager.workspaceForScreen(screen)
                        workspaceManager.assignWindow(w.windowID, toWorkspace: ws)
                    }
                }

                changed = true
                print("[HyprMac] new window: '\(w.title ?? "?")' (\(w.windowID))")
            }
        }

        // detect gone windows
        let gone = knownWindowIDs.subtracting(currentIDs)
        if !gone.isEmpty {
            let runningPIDs = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
            for id in gone {
                tiledPositions.removeValue(forKey: id)
                cachedWindows.removeValue(forKey: id)

                if let pid = windowOwners[id], runningPIDs.contains(pid) {
                    if workspaceManager.isWindowVisible(id) {
                        // window was on a visible workspace → genuinely minimized/hidden
                        knownWindowIDs.remove(id)
                        hiddenWindowIDs.insert(id)
                        changed = true
                        print("[HyprMac] window hidden: \(id)")
                    }
                    // on inactive workspace → absence is expected, keep tracking it
                    // don't remove from knownWindowIDs or it'll be "rediscovered" as new
                    // and reassigned to the wrong workspace
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
            tileAllVisibleSpaces()
        }
    }

    // MARK: - observers

    @objc private func appDidActivate(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.pollWindowChanges()
        }
    }

    @objc private func appDidLaunch(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pollWindowChanges()
        }
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.pollWindowChanges()
        }
    }

    @objc private func appVisibilityChanged(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pollWindowChanges()
        }
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
