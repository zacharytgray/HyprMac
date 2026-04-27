// Applies the result of `DragManager.detect` to the tiling engine and
// workspace state: tree mutation, cross-monitor workspace reassignment,
// animation, position-cache refresh. The classification heuristics live
// in `DragManager`; this handler runs the side effects.

import Cocoa

/// Side effects for drag classifications.
///
/// Public surface is a single `handleMouseUp` entry called from the
/// global mouseUp monitor. After a 0.1 s settle (empirical: gives macOS
/// time to commit the final dragged frame before AX queries it), the
/// handler asks `DragManager` to classify and applies the result —
/// resize, same-monitor swap, cross-monitor swap, drag-to-empty-desktop,
/// or snap-back.
///
/// Cross-monitor swap registers `cross-swap-in-flight` on
/// `SuppressionRegistry` for ~0.8 s. `PollingScheduler` honors that key,
/// so neither the 1 Hz timer nor notification-driven schedules fire
/// during `crossSwapWindows`'s two synchronous retile passes — without
/// this, polls land mid-mutation and produce inconsistent visible state.
///
/// Threading: main-thread only.
final class DragSwapHandler {

    private let stateCache: WindowStateCache
    private let dragManager: DragManager
    private let accessibility: AccessibilityManager
    private let displayManager: DisplayManager
    private let workspaceManager: WorkspaceManager
    private let tilingEngine: TilingEngine
    private let animator: WindowAnimator
    private let config: UserConfig
    private let suppressions: SuppressionRegistry

    // closure handles for WM-side helpers
    var updatePositionCache: (([HyprWindow]?) -> Void)?
    var rejectSwap: ((HyprWindow, String) -> Void)?
    var tileAllVisibleSpaces: (([HyprWindow]?) -> Void)?

    /// Empirical bound on the wall-clock cost of
    /// `TilingEngine.crossSwapWindows`: two back-to-back retile passes,
    /// each containing up to ~360 ms of `Thread.sleep` readback. 0.8 s
    /// gives headroom for slow apps and post-swap settling.
    private static let crossSwapSuppressionSec: TimeInterval = 0.8

    /// `SuppressionRegistry` key honored by `PollingScheduler`. Holds
    /// timer and notification polls off for the duration of a
    /// cross-monitor drag-swap.
    private static let crossSwapKey = "cross-swap-in-flight"

    init(stateCache: WindowStateCache,
         dragManager: DragManager,
         accessibility: AccessibilityManager,
         displayManager: DisplayManager,
         workspaceManager: WorkspaceManager,
         tilingEngine: TilingEngine,
         animator: WindowAnimator,
         config: UserConfig,
         suppressions: SuppressionRegistry) {
        self.stateCache = stateCache
        self.dragManager = dragManager
        self.accessibility = accessibility
        self.displayManager = displayManager
        self.workspaceManager = workspaceManager
        self.tilingEngine = tilingEngine
        self.animator = animator
        self.config = config
        self.suppressions = suppressions
    }

    /// Entry point invoked by `WindowManager`'s mouseUp monitor.
    /// Schedules a 0.1 s settle then runs detect-and-apply on the main
    /// thread.
    func handleMouseUp(startFrames: [CGWindowID: CGRect]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.applyDragResult(startFrames: startFrames)
        }
    }

    // MARK: - private

    /// Classify the drag and dispatch to the matching effect.
    ///
    /// Skipped when an animation is in flight (animator-parked frames
    /// would mis-classify) or when the focused window is floating —
    /// floating windows nudging adjacent tiles otherwise produce false
    /// snap-back retiles that disrupt the layout.
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

    /// Apply a drag-classified swap.
    ///
    /// Cross-monitor: register `cross-swap-in-flight`, reassign both
    /// windows to the matching workspaces, then call
    /// `crossSwapWindows`. Same-monitor: check `canSwapWindows` first
    /// (rejection beeps + flashes via `rejectSwap`), then either animate
    /// from old to new rects via `prepareSwapLayout` /
    /// `applyComputedLayout` or fall through to the synchronous
    /// `swapWindows`.
    private func applySwap(_ s: DragManager.DragSwapResult, allWindows: [HyprWindow]) {
        if s.crossMonitor {
            hyprLog(.debug, .drag, "cross-monitor swap: '\(s.dragged.title ?? "?")' ↔ '\(s.target.title ?? "?")'")
            guard tilingEngine.canCrossSwapWindows(s.dragged, s.target) else {
                rejectSwap?(s.dragged, "cross-monitor swap would violate min-size constraints")
                updatePositionCache?(allWindows)
                return
            }

            // hold polling off for the duration of the swap. crossSwapWindows runs
            // two synchronous retile passes back-to-back; without this guard, the
            // 1Hz timer or NSWorkspace notifications can fire mid-swap and observe
            // the windows in an inconsistent state.
            suppressions.suppress(Self.crossSwapKey, for: Self.crossSwapSuppressionSec)
            var srcWs: Int?
            var tgtWs: Int?
            if let srcScreen = s.sourceScreen, let tgtScreen = s.targetScreen {
                srcWs = workspaceManager.workspaceForScreen(srcScreen)
                tgtWs = workspaceManager.workspaceForScreen(tgtScreen)
                if let srcWs, let tgtWs {
                    workspaceManager.moveWindow(s.dragged.windowID, toWorkspace: tgtWs)
                    workspaceManager.moveWindow(s.target.windowID, toWorkspace: srcWs)
                }
            }
            let ok = tilingEngine.crossSwapWindows(s.dragged, s.target)
            if !ok {
                if let srcWs, let tgtWs {
                    workspaceManager.moveWindow(s.dragged.windowID, toWorkspace: srcWs)
                    workspaceManager.moveWindow(s.target.windowID, toWorkspace: tgtWs)
                }
                rejectSwap?(s.dragged, "cross-monitor swap overflows min-size constraints (post-readback)")
                tileAllVisibleSpaces?(allWindows)
                return
            }
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
                guard let self else { return }
                let ok = self.tilingEngine.applyComputedLayout(onWorkspace: workspace, screen: screen)
                if !ok {
                    self.rejectSwap?(s.dragged, "drag swap overflows min-size constraints (post-readback)")
                }
                self.updatePositionCache?(nil)
            }
        } else {
            let ok = tilingEngine.swapWindows(s.dragged, s.target, onWorkspace: workspace, screen: screen)
            if !ok {
                rejectSwap?(s.dragged, "drag swap overflows min-size constraints (post-readback)")
            }
            updatePositionCache?(allWindows)
        }
    }
}
