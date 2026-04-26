import Cocoa

// applies the result of DragManager.detect to the tiling engine and workspace.
// drag classification (resize vs swap vs snap-back vs cross-monitor move) lives
// in DragManager; this handler owns the side effects: tree mutation, cross-monitor
// workspace reassignment, animation, position-cache refresh.
//
// what does NOT live here:
//   - drag classification heuristics (DragManager)
//   - mouse-monitor wiring or mouseDown frame capture (WindowManager — mouse-tracking
//     plumbing is separate from drag-result application)
//   - rejectSwap (WindowManager — also used by keyboard swap, passed as closure)
//
// main-thread is a precondition. the 0.1s settle delay is an empirical timing
// from the original implementation: gives macOS enough time to commit the final
// dragged frame before AX queries it.
final class DragSwapHandler {

    private let stateCache: WindowStateCache
    private let dragManager: DragManager
    private let accessibility: AccessibilityManager
    private let displayManager: DisplayManager
    private let workspaceManager: WorkspaceManager
    private let tilingEngine: TilingEngine
    private let animator: WindowAnimator
    private let config: UserConfig

    // closure handles for WM-side helpers
    var updatePositionCache: (([HyprWindow]?) -> Void)?
    var rejectSwap: ((HyprWindow, String) -> Void)?
    var tileAllVisibleSpaces: (([HyprWindow]?) -> Void)?

    init(stateCache: WindowStateCache,
         dragManager: DragManager,
         accessibility: AccessibilityManager,
         displayManager: DisplayManager,
         workspaceManager: WorkspaceManager,
         tilingEngine: TilingEngine,
         animator: WindowAnimator,
         config: UserConfig) {
        self.stateCache = stateCache
        self.dragManager = dragManager
        self.accessibility = accessibility
        self.displayManager = displayManager
        self.workspaceManager = workspaceManager
        self.tilingEngine = tilingEngine
        self.animator = animator
        self.config = config
    }

    // entry point: called from WindowManager's mouseUp handler.
    // schedules the 0.1s settle then runs detect-and-apply on main.
    func handleMouseUp(startFrames: [CGWindowID: CGRect]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.applyDragResult(startFrames: startFrames)
        }
    }

    // MARK: - private

    private func applyDragResult(startFrames: [CGWindowID: CGRect]) {
        guard !animator.isAnimating else { return }

        // skip drag detection if the user was dragging a floating window —
        // floating windows can nudge tiled windows slightly, causing false
        // snapBack retiles that disrupt the layout.
        if let focused = accessibility.getFocusedWindow(),
           stateCache.floatingWindowIDs.contains(focused.windowID) {
            return
        }

        let allWindows = accessibility.getAllWindows()

        dragManager.floatingWindowIDs = stateCache.floatingWindowIDs
        dragManager.tiledPositions = stateCache.tiledPositions

        let result = dragManager.detect(
            allWindows: allWindows,
            cachedWindows: stateCache.cachedWindows,
            startFrames: startFrames,
            screenAt: { [weak self] pt in self?.displayManager.screen(at: pt) },
            workspaceForScreen: { [weak self] s in self?.workspaceManager.workspaceForScreen(s) ?? 1 }
        )

        switch result {
        case .resize(let r):
            hyprLog(.debug, .drag, "manual resize detected: '\(r.window.title ?? "?")'")
            tilingEngine.applyResize(r.window, newFrame: r.newFrame, onWorkspace: r.workspace, screen: r.screen)
            updatePositionCache?(allWindows)

        case .swap(let s):
            applySwap(s, allWindows: allWindows)

        case .dragToEmpty(let d):
            hyprLog(.debug, .drag, "cross-monitor move to empty desktop")
            let r = displayManager.cgRect(for: d.targetScreen)
            d.dragged.setFrame(CGRect(
                x: r.midX - r.width / 4,
                y: r.midY - r.height / 4,
                width: r.width / 2,
                height: r.height / 2
            ))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.tileAllVisibleSpaces?(nil)
            }

        case .snapBack:
            hyprLog(.debug, .drag, "drag snap-back")
            tileAllVisibleSpaces?(allWindows)

        case .none:
            break
        }
    }

    private func applySwap(_ s: DragManager.DragSwapResult, allWindows: [HyprWindow]) {
        if s.crossMonitor {
            hyprLog(.debug, .drag, "cross-monitor swap: '\(s.dragged.title ?? "?")' ↔ '\(s.target.title ?? "?")'")
            if let srcScreen = s.sourceScreen, let tgtScreen = s.targetScreen {
                let srcWs = workspaceManager.workspaceForScreen(srcScreen)
                let tgtWs = workspaceManager.workspaceForScreen(tgtScreen)
                workspaceManager.moveWindow(s.dragged.windowID, toWorkspace: tgtWs)
                workspaceManager.moveWindow(s.target.windowID, toWorkspace: srcWs)
            }
            tilingEngine.crossSwapWindows(s.dragged, s.target)
            updatePositionCache?(allWindows)
            return
        }

        guard let screen = s.sourceScreen else { return }
        let workspace = workspaceManager.workspaceForScreen(screen)
        hyprLog(.debug, .drag, "drag swap: '\(s.dragged.title ?? "?")' ↔ '\(s.target.title ?? "?")'")

        guard tilingEngine.canSwapWindows(s.dragged, s.target, onWorkspace: workspace, screen: screen) else {
            rejectSwap?(s.dragged, "drag swap would violate min-size constraints")
            updatePositionCache?(allWindows)
            return
        }

        if config.animateWindows,
           let draggedFrame = s.dragged.frame,
           let targetFrame = s.target.frame,
           let layouts = tilingEngine.prepareSwapLayout(s.dragged, s.target, onWorkspace: workspace, screen: screen) {
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
                self?.updatePositionCache?(nil)
            }
        } else {
            tilingEngine.swapWindows(s.dragged, s.target, onWorkspace: workspace, screen: screen)
            updatePositionCache?(allWindows)
        }
    }
}
