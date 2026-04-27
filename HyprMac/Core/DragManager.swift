// Heuristics for classifying mouse-driven drags on tiled windows. Pure
// classification — `DragSwapHandler` applies whatever this returns.

import Cocoa

/// Detects manual resize, swap, drag-to-empty-desktop, and snap-back
/// gestures on tiled windows.
///
/// Compares mouse-down frames against post-mouse-up frames and decides
/// what the user did. Output is one of `DetectionResult`'s cases; the
/// caller (`DragSwapHandler`) applies the side effects.
class DragManager {

    /// Classification: window was resized in place. `newFrame` is the
    /// post-drag frame; `screen` and `workspace` locate the BSP tree.
    struct ResizeResult {
        let window: HyprWindow
        let newFrame: CGRect
        let screen: NSScreen
        let workspace: Int
    }

    /// Classification: window was dragged onto another tiled window's
    /// slot. `crossMonitor` distinguishes the same-tree path from the
    /// cross-screen path.
    struct DragSwapResult {
        let dragged: HyprWindow
        let target: HyprWindow
        let sourceScreen: NSScreen?
        let targetScreen: NSScreen?
        let crossMonitor: Bool
    }

    /// Classification: window was dragged onto an empty workspace on a
    /// different monitor.
    struct DragToEmptyResult {
        let dragged: HyprWindow
        let targetScreen: NSScreen
    }

    /// One of the five drag classifications; `none` means nothing
    /// actionable happened.
    enum DetectionResult {
        case resize(ResizeResult)
        case swap(DragSwapResult)
        case dragToEmpty(DragToEmptyResult)
        case snapBack
        case none
    }

    /// Snapshot of currently-floating window IDs at detect time.
    /// Caller-supplied so this class does not depend on `WindowStateCache`.
    var floatingWindowIDs: Set<CGWindowID> = []

    /// Snapshot of expected tiled rects at detect time. Used to compare
    /// against post-drag positions.
    var tiledPositions: [CGWindowID: CGRect] = [:]

    /// Classify whatever happened between `startFrames` (mouseDown) and
    /// the current AX frames in `allWindows` (post-mouseUp).
    ///
    /// - Parameter cachedWindows: cache lookup so the result can carry
    ///   `HyprWindow` references that survive the AX round trip.
    /// - Parameter screenAt: cursor-position → screen lookup, supplied
    ///   by `DisplayManager` via closure.
    /// - Parameter workspaceForScreen: screen → workspace lookup, also
    ///   supplied via closure.
    func detect(
        allWindows: [HyprWindow],
        cachedWindows: [CGWindowID: HyprWindow],
        startFrames: [CGWindowID: CGRect],
        screenAt: (CGPoint) -> NSScreen?,
        workspaceForScreen: (NSScreen) -> Int
    ) -> DetectionResult {

        // check for manual resize first: size changed on any axis
        for w in allWindows {
            guard !floatingWindowIDs.contains(w.windowID),
                  let current = w.frame,
                  let start = startFrames[w.windowID],
                  let expected = tiledPositions[w.windowID] else { continue }

            let widthDelta = abs(current.width - start.width)
            let heightDelta = abs(current.height - start.height)

            if widthDelta > 20 || heightDelta > 20 {
                // app min-size overflow is not a user resize; accepting it here
                // persists bogus split ratios and corrupts the BSP layout.
                if let observed = w.observedMinSize,
                   abs(current.width - observed.width) < 10,
                   abs(current.height - observed.height) < 10 {
                    continue
                }

                guard let screen = screenAt(CGPoint(x: expected.midX, y: expected.midY)) else { continue }
                let workspace = workspaceForScreen(screen)
                return .resize(ResizeResult(window: w, newFrame: current, screen: screen, workspace: workspace))
            }
        }

        // drag-swap: position changed but size stayed roughly the same
        var draggedWindow: HyprWindow?
        for w in allWindows {
            guard !floatingWindowIDs.contains(w.windowID),
                  let current = w.frame,
                  let start = startFrames[w.windowID] else { continue }

            let dist = abs(current.origin.x - start.origin.x) + abs(current.origin.y - start.origin.y)
            let sizeDist = abs(current.width - start.width) + abs(current.height - start.height)
            if dist > 50 && sizeDist < 40 {
                draggedWindow = w
                break
            }
        }

        guard let dragged = draggedWindow, let dragCenter = dragged.center else { return .none }

        guard let expectedRect = tiledPositions[dragged.windowID] else { return .none }
        let expectedCenter = CGPoint(x: expectedRect.midX, y: expectedRect.midY)
        let sourceScreen = screenAt(expectedCenter)
        let targetScreen = screenAt(dragCenter)
        let crossMonitor = (sourceScreen != targetScreen)

        // find swap target
        var swapTarget: HyprWindow?
        for (wid, rect) in tiledPositions {
            guard wid != dragged.windowID else { continue }
            if rect.contains(dragCenter) {
                swapTarget = allWindows.first { $0.windowID == wid } ?? cachedWindows[wid]
                break
            }
        }

        if let target = swapTarget {
            return .swap(DragSwapResult(
                dragged: dragged, target: target,
                sourceScreen: sourceScreen, targetScreen: targetScreen,
                crossMonitor: crossMonitor
            ))
        }

        if crossMonitor {
            let targetHasWindows = tiledPositions.contains { (wid, rect) in
                guard wid != dragged.windowID else { return false }
                let center = CGPoint(x: rect.midX, y: rect.midY)
                return screenAt(center) == targetScreen
            }

            if !targetHasWindows, let ts = targetScreen {
                return .dragToEmpty(DragToEmptyResult(dragged: dragged, targetScreen: ts))
            }
        }

        return .snapBack
    }
}
