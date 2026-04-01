import Cocoa

class WindowManager {
    let accessibility = AccessibilityManager()
    let hotkeyManager = HotkeyManager()
    let spaceManager = SpaceManager()
    let displayManager = DisplayManager()
    let cursorManager = CursorManager()
    let appLauncher = AppLauncherManager()
    let config: UserConfig

    private(set) var tilingEngine: TilingEngine!

    // tracks known window IDs so we can detect new/closed ones
    private var knownWindowIDs: Set<CGWindowID> = []

    // stores original frames before tiling (for float toggle restore)
    private var originalFrames: [CGWindowID: CGRect] = [:]

    // tracks which windows are floating (persists across HyprWindow recreation)
    private var floatingWindowIDs: Set<CGWindowID> = []

    // track which PID owns each window (for close vs hide detection)
    private var windowOwners: [CGWindowID: pid_t] = [:]

    // windows that disappeared but app is still running (minimized/hidden)
    // preserves originalFrames and floatingWindowIDs for when they return
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

    // suppress focus-follows-mouse briefly after keyboard actions
    private var suppressMouseFocusUntil: Date = .distantPast

    init(config: UserConfig) {
        self.config = config
        self.tilingEngine = TilingEngine(displayManager: displayManager)

        hotkeyManager.onAction = { [weak self] action in
            self?.suppressMouseFocusUntil = Date().addingTimeInterval(0.3)
            self?.handleAction(action)
        }

        // auto-float windows that exceed max tiling depth
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
            self?.snapshotAndTile()
        }

        // poll for window changes every 1s
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollWindowChanges()
        }

        // mouse tracking for focus-follows-mouse and drag-swap
        startMouseTracking()

        // workspace observers
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

        NotificationCenter.default.addObserver(
            self, selector: #selector(retileRequested),
            name: .hyprMacRetile, object: nil
        )

        print("[HyprMac] started")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        stopMouseTracking()
        hotkeyManager.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        print("[HyprMac] stopped")
    }

    func restart() {
        stop()
        start()
    }

    // MARK: - mouse tracking

    private func startMouseTracking() {
        // focus follows mouse
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.handleMouseMove()
        }

        // drag detection
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

    // focus the window under the cursor
    private func handleMouseMove() {
        guard !mouseButtonDown else { return }
        guard Date() > suppressMouseFocusUntil else { return }

        let mouseNS = NSEvent.mouseLocation
        let cgY = displayManager.primaryScreenHeight - mouseNS.y
        let cgPoint = CGPoint(x: mouseNS.x, y: cgY)

        // find which tiled window the cursor is over
        for (wid, rect) in tiledPositions {
            if rect.contains(cgPoint) {
                guard wid != lastMouseFocusedID else { return }
                lastMouseFocusedID = wid

                // use cached HyprWindow to avoid expensive getAllWindows call
                if let target = cachedWindows[wid] {
                    target.focus()
                }
                return
            }
        }
    }

    // detect drag-drop and swap windows
    private func handleMouseUp() {
        // small delay for the window position to settle after drop
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.detectDragSwap()
        }
    }

    private func detectDragSwap() {
        let allWindows = accessibility.getAllWindows()

        // find a window that moved from its expected tiled position
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

        // find the window whose tiled slot the dragged window landed on
        var swapTarget: HyprWindow?
        for (wid, rect) in tiledPositions {
            guard wid != dragged.windowID else { continue }
            if rect.contains(dragCenter) {
                swapTarget = allWindows.first { $0.windowID == wid }
                                ?? cachedWindows[wid]
                break
            }
        }

        if let target = swapTarget {
            if crossMonitor {
                // cross-monitor swap: directly swap refs in both BSP trees
                // each window takes the other's exact slot
                print("[HyprMac] cross-monitor swap: '\(dragged.title ?? "?")' ↔ '\(target.title ?? "?")'")
                tilingEngine.crossSwapWindows(dragged, target)
            } else {
                // same-monitor swap
                if let spaceID = spaceManager.spaceForWindow(dragged.windowID) {
                    print("[HyprMac] drag swap: '\(dragged.title ?? "?")' ↔ '\(target.title ?? "?")'")
                    tilingEngine.swapWindows(dragged, target, onSpace: spaceID)
                }
            }
            updatePositionCache()
            return
        }

        // no swap target found
        if crossMonitor {
            // check if target monitor is completely empty — allow move
            let targetHasWindows = tiledPositions.contains { (wid, rect) in
                guard wid != dragged.windowID else { return false }
                let center = CGPoint(x: rect.midX, y: rect.midY)
                return displayManager.screen(at: center) == targetScreen
            }

            if !targetHasWindows {
                print("[HyprMac] cross-monitor move to empty desktop")
                if let screen = targetScreen {
                    let r = displayManager.cgRect(for: screen)
                    // use resize-move-resize to cross screen boundary
                    dragged.setFrame(CGRect(
                        x: r.midX - r.width / 4,
                        y: r.midY - r.height / 4,
                        width: r.width / 2,
                        height: r.height / 2
                    ))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.tileAllVisibleSpaces()
                }
                return
            }
        }

        // snap back
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
            switchToMonitor(num)
        case .moveToDesktop(let num):
            moveToMonitor(num)
        case .toggleFloating:
            toggleFloating()
        case .toggleSplit:
            toggleSplit()
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
            cursorManager.warpToCenter(of: target)
            lastMouseFocusedID = target.windowID
        }
    }

    // MARK: - swap

    private func swapInDirection(_ direction: Direction) {
        guard let focused = accessibility.getFocusedWindow() else { return }
        guard let spaceID = spaceManager.spaceForWindow(focused.windowID) else { return }
        let windows = accessibility.getAllWindows()

        guard let target = accessibility.windowInDirection(direction, from: focused, among: windows) else { return }

        tilingEngine.swapWindows(focused, target, onSpace: spaceID)
        cursorManager.warpToCenter(of: focused)
        updatePositionCache()
    }

    // MARK: - monitor switching/moving

    private func switchToMonitor(_ number: Int) {
        let screens = displayManager.screens
        guard number >= 1 && number <= screens.count else {
            print("[HyprMac] monitor \(number) doesn't exist (have \(screens.count))")
            return
        }

        let screen = screens[number - 1]
        let rect = displayManager.cgRect(for: screen)
        let center = CGPoint(x: rect.midX, y: rect.midY)

        let allWindows = accessibility.getAllWindows()
        var bestWindow: HyprWindow?
        var bestDist = CGFloat.infinity
        for w in allWindows {
            guard let wc = w.center else { continue }
            if let ws = displayManager.screen(at: wc), ws == screen {
                let dist = hypot(wc.x - center.x, wc.y - center.y)
                if dist < bestDist {
                    bestDist = dist
                    bestWindow = w
                }
            }
        }

        if let target = bestWindow {
            print("[HyprMac] switchToMonitor \(number): focusing '\(target.title ?? "?")'")
            target.focus()
            cursorManager.warpToCenter(of: target)
            lastMouseFocusedID = target.windowID
        } else {
            print("[HyprMac] switchToMonitor \(number): no windows, warping cursor")
            CGWarpMouseCursorPosition(center)
        }
    }

    private func moveToMonitor(_ number: Int) {
        let screens = displayManager.screens
        guard number >= 1 && number <= screens.count else {
            print("[HyprMac] monitor \(number) doesn't exist (have \(screens.count))")
            return
        }

        guard let focused = accessibility.getFocusedWindow() else { return }

        let targetScreen = screens[number - 1]
        let targetRect = displayManager.cgRect(for: targetScreen)

        // read position fresh — don't trust cached state
        guard let currentPos = focused.position else {
            print("[HyprMac] moveToMonitor: can't read window position")
            return
        }

        // check if already on target screen by raw coordinate comparison
        if targetRect.contains(CGPoint(x: currentPos.x + 50, y: currentPos.y + 50)) {
            print("[HyprMac] window already on monitor \(number)")
            return
        }

        // check if target screen has room before moving
        let targetSpaces = spaceManager.allCurrentSpaceIDs()
        let targetSpaceID = targetSpaces.count >= number ? targetSpaces[number - 1] : targetSpaces.first
        if let sid = targetSpaceID, !tilingEngine.canFitWindow(onSpace: sid, screen: targetScreen) {
            print("[HyprMac] moveToMonitor \(number): target screen full, aborting move")
            return
        }

        print("[HyprMac] moveToMonitor \(number): '\(focused.title ?? "?")' from (\(Int(currentPos.x)),\(Int(currentPos.y))) → screen \(Int(targetRect.origin.x)),\(Int(targetRect.origin.y))")

        // pure AX approach — resize-move-resize to cross the screen boundary
        // no CGS space API (doesn't work for cross-display moves)
        // macOS auto-reassigns the window to the target display's space when it physically moves there
        let halfW = targetRect.width / 2
        let halfH = targetRect.height / 2
        focused.setFrame(CGRect(
            x: targetRect.midX - halfW / 2,
            y: targetRect.midY - halfH / 2,
            width: halfW,
            height: halfH
        ))

        // retile after the move settles
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.tileAllVisibleSpaces()
        }
    }

    // MARK: - split toggle

    private func toggleSplit() {
        guard let focused = accessibility.getFocusedWindow(),
              let spaceID = spaceManager.spaceForWindow(focused.windowID) else { return }

        print("[HyprMac] toggleSplit on '\(focused.title ?? "?")'")
        tilingEngine.toggleSplit(focused, onSpace: spaceID)
        updatePositionCache()
    }

    // MARK: - floating

    private func toggleFloating() {
        guard let focused = accessibility.getFocusedWindow(),
              let spaceID = spaceManager.spaceForWindow(focused.windowID) else { return }

        let wasFloating = floatingWindowIDs.contains(focused.windowID)

        if wasFloating {
            floatingWindowIDs.remove(focused.windowID)
            focused.isFloating = false

            // force-insert: evict another window if tree is full
            if let evicted = tilingEngine.forceInsertWindow(focused, toSpace: spaceID) {
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
            tilingEngine.removeWindow(focused, fromSpace: spaceID)

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
            if let frame = w.frame {
                if originalFrames[w.windowID] == nil {
                    originalFrames[w.windowID] = frame
                }
            }
            knownWindowIDs.insert(w.windowID)
            windowOwners[w.windowID] = w.ownerPID
        }
        tileAllVisibleSpaces()
    }

    func tileAllVisibleSpaces() {
        let currentSpaces = spaceManager.allCurrentSpaceIDs()
        let allWindows = accessibility.getAllWindows()

        for w in allWindows {
            if floatingWindowIDs.contains(w.windowID) {
                w.isFloating = true
            }
        }

        for spaceID in currentSpaces {
            var spaceWindows: [HyprWindow] = []
            for window in allWindows {
                if let windowSpace = spaceManager.spaceForWindow(window.windowID),
                   windowSpace == spaceID {
                    spaceWindows.append(window)
                }
            }
            print("[HyprMac] retile: space=\(spaceID), \(spaceWindows.count) windows")
            tilingEngine.tileWindows(spaceWindows, onSpace: spaceID)
        }

        updatePositionCache()
    }

    func tileCurrentSpace() {
        guard let spaceID = spaceManager.currentSpaceID() else {
            print("[HyprMac] retile: no current space ID")
            return
        }
        let allWindows = accessibility.getAllWindows()

        var spaceWindows: [HyprWindow] = []
        for window in allWindows {
            if let windowSpace = spaceManager.spaceForWindow(window.windowID),
               windowSpace == spaceID {
                spaceWindows.append(window)
            }
        }

        print("[HyprMac] retile: space=\(spaceID), \(spaceWindows.count) windows on this space")
        tilingEngine.tileWindows(spaceWindows, onSpace: spaceID)
        updatePositionCache()
    }

    // refresh the cached positions and window refs after any tiling operation
    private func updatePositionCache() {
        let allWindows = accessibility.getAllWindows()
        tiledPositions.removeAll()
        cachedWindows.removeAll()
        for w in allWindows {
            cachedWindows[w.windowID] = w
            // only track tiled (non-floating) windows for mouse focus and drag detection
            if !floatingWindowIDs.contains(w.windowID), let frame = w.frame {
                tiledPositions[w.windowID] = frame
            }
        }
    }

    // poll for window changes
    private func pollWindowChanges() {
        let allWindows = accessibility.getAllWindows()
        let currentIDs = Set(allWindows.map { $0.windowID })

        var changed = false

        // check for returning hidden windows (un-minimized / un-hidden)
        for w in allWindows {
            if hiddenWindowIDs.contains(w.windowID) {
                hiddenWindowIDs.remove(w.windowID)
                knownWindowIDs.insert(w.windowID)
                windowOwners[w.windowID] = w.ownerPID
                changed = true
                print("[HyprMac] window returned: '\(w.title ?? "?")' (\(w.windowID))")
            }
        }

        // detect genuinely new windows
        for w in allWindows {
            if !knownWindowIDs.contains(w.windowID) {
                if let frame = w.frame {
                    originalFrames[w.windowID] = frame
                }
                knownWindowIDs.insert(w.windowID)
                windowOwners[w.windowID] = w.ownerPID
                changed = true
                print("[HyprMac] new window: '\(w.title ?? "?")' (\(w.windowID))")
            }
        }

        // detect gone windows — distinguish close from hide
        let gone = knownWindowIDs.subtracting(currentIDs)
        if !gone.isEmpty {
            let runningPIDs = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
            for id in gone {
                knownWindowIDs.remove(id)
                tiledPositions.removeValue(forKey: id)
                cachedWindows.removeValue(forKey: id)

                if let pid = windowOwners[id], runningPIDs.contains(pid) {
                    // app still running — window is probably minimized/hidden
                    // preserve originalFrames and floatingWindowIDs for return
                    hiddenWindowIDs.insert(id)
                    print("[HyprMac] window hidden: \(id)")
                } else {
                    // app terminated — full cleanup
                    originalFrames.removeValue(forKey: id)
                    floatingWindowIDs.remove(id)
                    windowOwners.removeValue(forKey: id)
                    print("[HyprMac] window gone: \(id)")
                }
            }
            changed = true
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

    @objc private func retileRequested() {
        print("[HyprMac] retile requested")
        snapshotAndTile()
    }
}
