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
    // additional closures used by applyChanges (Phase 4 step 3b)
    var applyForgottenIDCleanup: (CGWindowID) -> Void = { _ in }
    var animatedRetile: ([HyprWindow]) -> Void = { _ in }
    var refocusUnderCursor: () -> Void = {}
    var isMenuTracking: () -> Bool = { false }

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

    // apply a discovery delta to the live state. WindowDiscoveryService produces
    // the delta and updates its cache half; this method runs the engine/workspace/
    // focus reactions for everything else.
    //
    // per plan §3.2 (post-Phase-4 data flow), this is the path:
    //   PollingScheduler.coalesce → WM.pollWindowChanges → discovery.computeChanges
    //     → ActionDispatcher.applyChanges → animator/workspace/focus reactions.
    //
    // allWindows is the same snapshot WindowDiscoveryService consumed; we re-pass
    // it here so animatedRetile + workspace assignment don't re-fetch from AX.
    func applyChanges(_ changes: WindowChanges, allWindows: [HyprWindow]) {
        // workspace assignment for new windows that didn't auto-float onto a
        // disabled monitor. assigning by physical screen — cursor-based was
        // unreliable under multi-monitor + display-reconfig churn.
        for w in changes.newWindows where !changes.newOnDisabledMonitor.contains(w.windowID) {
            assignNewWindow(w)
        }

        // engine/workspace/focus cleanup for ids the service forgot.
        for id in changes.fullyForgottenIDs {
            applyForgottenIDCleanup(id)
        }

        // apply cross-screen drift reassignments.
        for drift in changes.screenDrift {
            workspaceManager.moveWindow(drift.windowID, toWorkspace: drift.toWorkspace)
        }

        if changes.needsRetile {
            // animate surrounding windows sliding to fill gaps / make room.
            animatedRetile(allWindows)
        }

        // if the FFM-tracked window disappeared, refocus to whatever tiled window
        // is under the cursor now. without this, focus gets stuck because
        // handleMouseMove only fires on actual mouse movement.
        if changes.focusedWindowGone {
            refocusUnderCursor()
        }

        // catch-all: ensure something on the active workspace has focus + border.
        ensureFocusInvariant()

        // periodically re-raise floating windows so they don't get stuck behind
        // full-screen tiled windows (no activation event to trigger raise).
        if !stateCache.floatingWindowIDs.isEmpty {
            floatingController.raiseBehind()
        }
    }

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

    // MARK: - apply-loop helpers (Phase 4 step 3b)

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

    // if the focus border is hidden but the cursor's screen's workspace has any
    // visible window, focus one. prevents getting stuck with no focus target —
    // the user shouldn't have to click a window to get keyboard focus back.
    private func ensureFocusInvariant() {
        guard config.showFocusBorder else { return }
        // don't steal focus from a native menu that's currently tracking —
        // SLPSPostEventRecordTo + panel reordering both dismiss menus
        guard !isMenuTracking() else { return }
        // border is already showing on a live window — nothing to do
        if let tid = focusBorder.trackedWindowID, stateCache.cachedWindows[tid] != nil {
            return
        }
        let screen = screenUnderCursor()
        guard !workspaceManager.isMonitorDisabled(screen) else { return }
        let workspace = workspaceManager.workspaceForScreen(screen)
        let wsWindows = workspaceManager.windowIDs(onWorkspace: workspace)
            .subtracting(stateCache.hiddenWindowIDs)
        guard !wsWindows.isEmpty else { return }

        // prefer whatever AX says is focused if it's on this workspace
        if let focused = accessibility.getFocusedWindow(),
           wsWindows.contains(focused.windowID) {
            focusController.recordFocus(focused.windowID, reason: "ensureInvariant-ax")
            updateFocusBorder(focused)
            return
        }
        // any tiled window on this workspace
        for (wid, _) in stateCache.tiledPositions where wsWindows.contains(wid) {
            if let w = stateCache.cachedWindows[wid] {
                w.focusWithoutRaise()
                focusController.recordFocus(wid, reason: "ensureInvariant-tiled")
                updateFocusBorder(w)
                return
            }
        }
        // fall back to any visible window on this workspace (floating, etc.)
        for wid in wsWindows {
            if let w = stateCache.cachedWindows[wid] {
                w.focusWithoutRaise()
                focusController.recordFocus(wid, reason: "ensureInvariant-fallback")
                updateFocusBorder(w)
                return
            }
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
        // restrict swap candidates to focused's (workspace, screen) tree.
        // canSwapWindows already requires both windows in the same tree, so
        // a cross-monitor candidate would be rejected anyway — but having
        // the picker pre-filter means it can't drift into a cross-monitor
        // pick when same-monitor candidates are tied (e.g., a full-width
        // source with two adjacent windows directly below).
        let windows = accessibility.getAllWindows().filter {
            workspaceManager.isWindowVisible($0.windowID)
                && !stateCache.floatingWindowIDs.contains($0.windowID)
                && displayManager.screen(for: $0) == screen
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
                guard let self = self else { return }
                // snap final state with two-pass min-size resolution. returns
                // false if the post-readback layout overflows recorded mins
                // — applyComputedLayout has already reverted to the pre-swap
                // tree state and retiled. surface as flashError so the user
                // sees the rejection rather than a silent revert.
                let ok = self.tilingEngine.applyComputedLayout(onWorkspace: workspace, screen: screen)
                if !ok {
                    self.rejectSwap(focused, reason: "swap overflows min-size constraints (post-readback)")
                }
                self.cursorManager.warpToCenter(of: focused)
                self.updatePositionCache()
            }
        } else {
            // swapWindows handles its own snapshot/revert. flashError on false.
            let ok = tilingEngine.swapWindows(focused, target, onWorkspace: workspace, screen: screen)
            if !ok {
                rejectSwap(focused, reason: "swap overflows min-size constraints (post-readback)")
            }
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
