import Cocoa

// owns Action → service routing. WindowManager.handleAction shrinks to a one-liner
// that forwards to dispatch(_:); the per-action implementations live here.
//
// per plan §3.2 the dispatcher routes ON TOP of WorkspaceOrchestrator and
// FloatingWindowController — those services own their workflows; the dispatcher
// just picks the right entry point per Action case and supplies any glue
// (focused window resolution, swap-rejection flash, animated swap transitions)
// that's specific to the action path.
//
// what does NOT live here:
//   - workspace switch/move/cycle workflows (WorkspaceOrchestrator)
//   - float/cycle/raise (FloatingWindowController)
//   - drag-result application (DragSwapHandler)
//   - the discovery apply-loop (lifted into applyChanges in Phase 4 step 3b)
//
// closure handles cover WM-side helpers that don't have a service home:
//   currentFocusedWindow, updateFocusBorder, updatePositionCache, screenUnderCursor.
final class ActionDispatcher {

    // hard dependencies
    private let stateCache: WindowStateCache
    private let accessibility: AccessibilityManager
    private let displayManager: DisplayManager
    private let cursorManager: CursorManager
    private let workspaceManager: WorkspaceManager
    private let tilingEngine: TilingEngine
    private let animator: WindowAnimator
    private let focusController: FocusStateController
    private let focusBorder: FocusBorder
    private let keybindOverlay: KeybindOverlayController
    private let appLauncher: AppLauncherManager
    private let workspaceOrchestrator: WorkspaceOrchestrator
    private let floatingController: FloatingWindowController
    private let config: UserConfig

    // closure handles for WM-side helpers
    var currentFocusedWindow: () -> HyprWindow? = { nil }
    var updateFocusBorder: (HyprWindow) -> Void = { _ in }
    var updatePositionCache: () -> Void = {}
    var screenUnderCursor: () -> NSScreen = { NSScreen.main! }

    init(stateCache: WindowStateCache,
         accessibility: AccessibilityManager,
         displayManager: DisplayManager,
         cursorManager: CursorManager,
         workspaceManager: WorkspaceManager,
         tilingEngine: TilingEngine,
         animator: WindowAnimator,
         focusController: FocusStateController,
         focusBorder: FocusBorder,
         keybindOverlay: KeybindOverlayController,
         appLauncher: AppLauncherManager,
         workspaceOrchestrator: WorkspaceOrchestrator,
         floatingController: FloatingWindowController,
         config: UserConfig) {
        self.stateCache = stateCache
        self.accessibility = accessibility
        self.displayManager = displayManager
        self.cursorManager = cursorManager
        self.workspaceManager = workspaceManager
        self.tilingEngine = tilingEngine
        self.animator = animator
        self.focusController = focusController
        self.focusBorder = focusBorder
        self.keybindOverlay = keybindOverlay
        self.appLauncher = appLauncher
        self.workspaceOrchestrator = workspaceOrchestrator
        self.floatingController = floatingController
        self.config = config
    }

    // MARK: - public API

    func dispatch(_ action: Action) {
        switch action {
        case .focusDirection(let dir):
            focusInDirection(dir)
        case .swapDirection(let dir):
            swapInDirection(dir)
        case .switchDesktop(let num):
            workspaceOrchestrator.switchWorkspace(num)
        case .moveToDesktop(let num):
            workspaceOrchestrator.moveToWorkspace(num)
        case .moveWorkspaceToMonitor(let dir):
            workspaceOrchestrator.moveCurrentWorkspaceToMonitor(dir)
        case .toggleFloating:
            toggleFloating()
        case .toggleSplit:
            toggleSplit()
        case .showKeybinds:
            keybindOverlay.toggle(keybinds: config.keybinds)
        case .launchApp(let bundleID):
            appLauncher.launchOrFocus(bundleID: bundleID)
        case .focusMenuBar:
            warpToMenuBar()
        case .focusFloating:
            floatingController.cycleFocus()
        case .closeWindow:
            closeWindow()
        case .cycleWorkspace(let delta):
            cycleOccupiedWorkspace(delta: delta)
        }
    }

    // MARK: - focus / swap

    private func focusInDirection(_ direction: Direction) {
        guard let focused = currentFocusedWindow() else { return }
        // only consider windows on visible workspaces — hidden corner windows must be excluded
        let windows = accessibility.getAllWindows().filter {
            workspaceManager.isWindowVisible($0.windowID) && !stateCache.floatingWindowIDs.contains($0.windowID)
        }

        if let target = accessibility.windowInDirection(direction, from: focused, among: windows) {
            target.focusWithoutRaise()
            cursorManager.warpToCenter(of: target)
            focusController.recordFocus(target.windowID, reason: "focusInDirection")
            updateFocusBorder(target)
        }
    }

    private func swapInDirection(_ direction: Direction) {
        guard let focused = currentFocusedWindow() else { return }
        guard !stateCache.floatingWindowIDs.contains(focused.windowID) else { return }
        guard let screen = displayManager.screen(for: focused) ?? displayManager.screens.first else { return }
        let workspace = workspaceManager.workspaceForScreen(screen)
        let windows = accessibility.getAllWindows().filter {
            workspaceManager.isWindowVisible($0.windowID) && !stateCache.floatingWindowIDs.contains($0.windowID)
        }

        guard let target = accessibility.windowInDirection(direction, from: focused, among: windows) else { return }
        guard tilingEngine.canSwapWindows(focused, target, onWorkspace: workspace, screen: screen) else {
            rejectSwap(focused, reason: "swap would violate min-size constraints")
            return
        }

        if config.animateWindows,
           let focusedFrame = focused.frame,
           let targetFrame = target.frame,
           let layouts = tilingEngine.prepareSwapLayout(focused, target, onWorkspace: workspace, screen: screen) {
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

    // exposed so DragSwapHandler can invoke the same flash on cross-monitor reject paths.
    func rejectSwap(_ window: HyprWindow, reason: String) {
        hyprLog(.debug, .orchestration, "\(reason) — rejected swap")
        NSSound.beep()
        if let frame = window.frame {
            focusBorder.flashError(around: frame, windowID: window.windowID, window: window)
        }
    }

    // MARK: - close / menu bar

    private func closeWindow() {
        guard let target = currentFocusedWindow() else { return }
        var closeButton: AnyObject?
        let err = AXUIElementCopyAttributeValue(target.element, kAXCloseButtonAttribute as CFString, &closeButton)
        if err == .success, let button = closeButton, CFGetTypeID(button) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }

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

    // MARK: - workspace cycle

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
                workspaceOrchestrator.switchWorkspace(candidate)
                return
            }
        }
    }

    // MARK: - floating / split

    // resolves focused window + screen + workspace, then forwards to FloatingWindowController.
    private func toggleFloating() {
        guard let focused = currentFocusedWindow(),
              let screen = displayManager.screen(for: focused) ?? displayManager.screens.first else { return }
        let workspace = workspaceManager.workspaceForScreen(screen)
        floatingController.toggle(focused, on: screen, in: workspace)
    }

    // toggle the BSP split direction at the focused leaf's parent.
    // when animation is on, prepareToggleSplitLayout mutates the tree and returns
    // target frames so we can animate from current → target. once it returns
    // non-nil we're committed — falling through to tilingEngine.toggleSplit()
    // would toggle the tree a second time and revert the user's action.
    private func toggleSplit() {
        guard let focused = currentFocusedWindow(),
              let screen = displayManager.screen(for: focused) ?? displayManager.screens.first else { return }
        let workspace = workspaceManager.workspaceForScreen(screen)

        hyprLog(.debug, .orchestration, "toggleSplit on '\(focused.title ?? "?")'")

        if config.animateWindows {
            // capture current frames before the toggle
            let windows = accessibility.getAllWindows().filter { workspaceManager.isWindowVisible($0.windowID) }
            let currentFrames = Dictionary(uniqueKeysWithValues: windows.compactMap { w -> (CGWindowID, CGRect)? in
                guard let f = w.frame else { return nil }
                return (w.windowID, f)
            })

            if let layouts = tilingEngine.prepareToggleSplitLayout(focused, onWorkspace: workspace, screen: screen) {
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
                } else {
                    // tree was mutated but no frames need to move — apply layout and exit.
                    tilingEngine.applyComputedLayout(onWorkspace: workspace, screen: screen)
                    updatePositionCache()
                }
                return
            }
        }

        // animation disabled, or prepareToggleSplitLayout returned nil (window not in tree)
        tilingEngine.toggleSplit(focused, onWorkspace: workspace, screen: screen)
        updatePositionCache()
    }
}
