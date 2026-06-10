// Action → service routing and the apply-loop reactions that follow a
// discovery diff. Holds the per-Action implementations that resolve a
// focused window, drive the right service entry point, and wire up
// animation glue and rejection feedback.

import Cocoa

/// Routes `Action` cases to the services that handle them and applies the
/// reactions that follow a discovery diff.
///
/// Sits on top of `WorkspaceOrchestrator` and `FloatingWindowController`
/// — those services own their workflows; the dispatcher picks the right
/// entry point per `Action` case and supplies the glue specific to the
/// action path: focused-window resolution, swap-rejection flash, animated
/// swap transitions, etc. `applyChanges` runs the post-discovery
/// reactions: workspace assignment, forgotten-id cleanup, drift moves,
/// retile, refocus, and the focus-invariant safety net.
///
/// What does not live here: workspace switch/move/cycle (in
/// `WorkspaceOrchestrator`), float/cycle/raise (in
/// `FloatingWindowController`), drag-result application (in
/// `DragSwapHandler`).
///
/// Closure handles plumb in WM-side helpers without a service home:
/// `currentFocusedWindow`, `updateFocusBorder`, `updatePositionCache`,
/// `screenUnderCursor`, plus the apply-loop helpers
/// `applyForgottenIDCleanup`, `animatedRetile`, `refocusUnderCursor`, and
/// `isMenuTracking`.
///
/// Threading: main-thread only.
final class ActionDispatcher {

    // hard dependencies
    private let stateCache: WindowStateCache
    private let accessibility: AccessibilityManager
    private let displayManager: DisplayManager
    private let cursorManager: CursorManager
    private let workspaceManager: WorkspaceManager
    private let tilingEngine: TilingEngine
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
        self.focusController = focusController
        self.focusBorder = focusBorder
        self.keybindOverlay = keybindOverlay
        self.appLauncher = appLauncher
        self.workspaceOrchestrator = workspaceOrchestrator
        self.floatingController = floatingController
        self.config = config
    }

    // MARK: - public API

    /// Run the engine/workspace/focus reactions that follow a discovery
    /// diff.
    ///
    /// `WindowDiscoveryService.computeChanges` produces the delta and
    /// already updates its cache half. This method handles everything
    /// downstream: workspace assignment for new windows, cleanup for
    /// forgotten ids, cross-screen drift reassignment, animated retile,
    /// refocus when the FFM-tracked window vanished, the focus-invariant
    /// safety net, and a floater raise pass.
    ///
    /// - Parameter changes: discovery delta.
    /// - Parameter allWindows: the same window snapshot
    ///   `WindowDiscoveryService` consumed; passed through so
    ///   `animatedRetile` and workspace assignment do not re-query AX.
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

        // proactively drop every gone window from its BSP tree. tileAllVisibleSpaces
        // only diffs trees for currently-visible workspaces and bails when an
        // animation is in flight; either case can leave a closed window's node
        // lingering, so the surrounding tiles never expand to fill the gap. doing
        // it here is independent of which workspace was visible at close time and
        // independent of whether the follow-up retile actually runs.
        for id in changes.goneIDs {
            tilingEngine.removeWindowID(id)
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

    /// Route a single `Action` to the service that handles it. Called
    /// from `WindowManager.handleAction` on every hotkey trigger.
    func dispatch(_ action: Action) {
        switch action {
        case .focusDirection(let dir):
            focusInDirection(dir)
        case .swapDirection(let dir):
            swapInDirection(dir)
        case .switchWorkspace(let num):
            workspaceOrchestrator.switchWorkspace(num)
        case .moveToWorkspace(let num):
            workspaceOrchestrator.moveToWorkspace(num)
        case .moveWindowToMonitor(let dir):
            workspaceOrchestrator.moveWindowToMonitor(dir)
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

    // MARK: - apply-loop helpers

    /// Assign a newly-discovered window to a workspace based on where it
    /// physically opened.
    ///
    /// Prefers the window's own screen — that is where macOS placed it —
    /// and falls back to the cursor's screen only when the window has no
    /// usable frame yet. Always overwrites any prior assignment: a
    /// recycled `CGWindowID` could carry a leftover entry pointing at a
    /// workspace the user has not touched in days.
    private func assignNewWindow(_ window: HyprWindow) {
        let physical = displayManager.screen(for: window)
        let cursor = screenUnderCursor()
        let screen = physical ?? cursor
        let frameDesc = window.frame.map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height)))" } ?? "nil"
        let physicalName = physical?.localizedName ?? "nil"
        hyprLog(.notice, .orchestration, "assignNewWindow: '\(window.title ?? "?")' (\(window.windowID)) frame=\(frameDesc) physical=\(physicalName) cursor=\(cursor.localizedName) → ws\(workspaceManager.workspaceForScreen(screen)) on \(screen.localizedName)")
        guard !workspaceManager.isMonitorDisabled(screen) else { return }
        let ws = workspaceManager.workspaceForScreen(screen)
        // overwrite any stale entry — assignWindow handles old-set cleanup
        workspaceManager.assignWindow(window.windowID, toWorkspace: ws)
    }

    /// Re-establish keyboard focus when the border has gone dark but the
    /// cursor's workspace still has a visible window.
    ///
    /// Without this safety net the user can end up with no focus target
    /// after a workspace switch, app close, or window hide — and FFM
    /// alone will not recover, since `handleMouseMove` only fires on
    /// actual mouse motion. Resolution order: AX's reported focused
    /// window if it belongs to this workspace, then any tiled window on
    /// this workspace, then any visible window on this workspace.
    /// No-ops when a menu is tracking (refocusing would dismiss it) or
    /// when the focus border is already showing on a live window.
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

    /// Move keyboard focus to the nearest visible tiled window in
    /// `direction`. Floating windows and hidden-corner windows are
    /// excluded from the candidate set.
    private func focusInDirection(_ direction: Direction) {
        guard let focused = currentFocusedWindow() else { return }
        // only consider windows on visible workspaces — hidden corner windows must be excluded
        let windows = accessibility.getAllWindows().filter {
            workspaceManager.isWindowVisible($0.windowID) && !stateCache.floatingWindowIDs.contains($0.windowID)
        }

        // use BSP-computed intended rects so a crammed (oversized) source
        // window doesn't push its own minX/maxY past a neighbor's far edge
        // and exclude that neighbor from the directional candidate set.
        // stateCache.tiledPositions can't be used here — it stores the
        // *live* AX frame for tiled windows, not the layout-intended rect.
        let intended = tilingEngine.intendedTileRects()
        let frameFor: (HyprWindow) -> CGRect? = { intended[$0.windowID] ?? $0.frame }
        // diag: source rect (intended vs live) + physical screen. see directional-focus bug.
        hyprLog(.debug, .orchestration, "focus \(direction): src '\(focused.title ?? "?")' (\(focused.windowID)) intended=\(intended[focused.windowID].map { "\($0)" } ?? "nil") live=\(focused.frame.map { "\($0)" } ?? "nil") screen=\(displayManager.screen(for: focused)?.localizedName ?? "?")")
        if let target = accessibility.windowInDirection(direction, from: focused, among: windows, frameFor: frameFor) {
            hyprLog(.debug, .orchestration, "focus \(direction): -> '\(target.title ?? "?")' (\(target.windowID)) frameFor=\(frameFor(target).map { "\($0)" } ?? "nil") live=\(target.frame.map { "\($0)" } ?? "nil") screen=\(displayManager.screen(for: target)?.localizedName ?? "?")")
            target.focusWithoutRaise()
            cursorManager.warpToCenter(of: target)
            focusController.recordFocus(target.windowID, reason: "focusInDirection")
            updateFocusBorder(target)
        }
    }

    /// Swap the focused tile with the nearest tiled window in
    /// `direction` on the same `(workspace, screen)` tree.
    ///
    /// Candidates are pre-filtered to the focused window's own screen so
    /// a tied directional pick cannot drift across monitors. Rejected
    /// before any mutation when `canSwapWindows` reports a min-size
    /// violation. With animation on, layout is computed first via
    /// `prepareSwapLayout`, animated from old to new rects, then
    /// committed via `applyComputedLayout`; if the post-readback layout
    /// overflows recorded mins, `applyComputedLayout` reverts and this
    /// path surfaces a `flashError`. With animation off, `swapWindows`
    /// owns its own snapshot/revert.
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

        // intended tile rects — see focusInDirection for rationale.
        let intended = tilingEngine.intendedTileRects()
        let frameFor: (HyprWindow) -> CGRect? = { intended[$0.windowID] ?? $0.frame }
        guard let target = accessibility.windowInDirection(direction, from: focused, among: windows, frameFor: frameFor) else { return }
        guard tilingEngine.canSwapWindows(focused, target, onWorkspace: workspace, screen: screen) else {
            rejectSwap(focused, reason: "swap would violate min-size constraints")
            return
        }

        // swapWindows handles its own snapshot/revert. flashError on false.
        let ok = tilingEngine.swapWindows(focused, target, onWorkspace: workspace, screen: screen)
        if !ok {
            rejectSwap(focused, reason: "swap overflows min-size constraints (post-readback)")
            // the revert retiled — sync the cache, but don't warp the
            // cursor: nothing moved from the user's point of view.
            updatePositionCache()
            return
        }
        cursorManager.warpToCenter(of: focused)
        updatePositionCache()
    }

    /// Beep and flash a red border around `window` to signal a rejected
    /// swap. Exposed publicly so `DragSwapHandler` can route cross-monitor
    /// rejections through the same feedback as direction swaps.
    func rejectSwap(_ window: HyprWindow, reason: String) {
        hyprLog(.debug, .orchestration, "\(reason) — rejected swap")
        NSSound.beep()
        if let frame = window.frame {
            focusBorder.flashError(around: frame, windowID: window.windowID, window: window,
                                   message: "Not enough room to swap here")
        }
    }

    // MARK: - close / menu bar

    /// Click the focused window's close button via AX. Silently no-ops
    /// when the window has no close button (some panels, dialogs).
    private func closeWindow() {
        guard let target = currentFocusedWindow() else { return }
        var closeButton: AnyObject?
        let err = AXUIElementCopyAttributeValue(target.element, kAXCloseButtonAttribute as CFString, &closeButton)
        if err == .success, let button = closeButton, CFGetTypeID(button) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }

    /// Warp the cursor to the menu bar of the screen the cursor is on.
    /// Targets the area just past the Apple menu so the user can navigate
    /// app menus directly. Briefly de-associates the mouse from the
    /// cursor so the warp lands accurately, then re-associates after a
    /// short delay.
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

    /// Cycle through occupied workspaces whose home screen is the cursor's
    /// monitor.
    ///
    /// "Occupied" means at least one window is assigned. Walks the
    /// workspace numbers in `delta` direction (`+1` next, `-1` previous),
    /// wrapping around. Workspaces on other monitors are skipped — the
    /// cycle stays on the current screen.
    private func cycleOccupiedWorkspace(delta: Int) {
        let screen = screenUnderCursor()
        let current = workspaceManager.workspaceForScreen(screen)
        let total = workspaceManager.workspaceCount

        let screenSID = workspaceManager.screenID(for: screen)

        // collect occupied workspaces whose static home is this monitor
        let occupied = Set((1...total).filter { ws in
            guard let home = workspaceManager.homeScreenForWorkspace(ws) else { return false }
            return workspaceManager.screenID(for: home) == screenSID &&
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

    /// Resolve the focused window, its physical screen, and the active
    /// workspace, then hand off to `FloatingWindowController.toggle`.
    private func toggleFloating() {
        guard let focused = currentFocusedWindow(),
              let screen = displayManager.screen(for: focused) ?? displayManager.screens.first else { return }
        let workspace = workspaceManager.workspaceForScreen(screen)
        floatingController.toggle(focused, on: screen, in: workspace)
    }

    /// Toggle the BSP split direction at the focused leaf's parent.
    private func toggleSplit() {
        guard let focused = currentFocusedWindow(),
              let screen = displayManager.screen(for: focused) ?? displayManager.screens.first else { return }
        let workspace = workspaceManager.workspaceForScreen(screen)

        hyprLog(.debug, .orchestration, "toggleSplit on '\(focused.title ?? "?")'")

        tilingEngine.toggleSplit(focused, onWorkspace: workspace, screen: screen)
        updatePositionCache()
    }
}
