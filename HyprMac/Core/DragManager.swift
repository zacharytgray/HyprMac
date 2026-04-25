import Cocoa

// detects drag-swap and manual resize gestures on tiled windows
class DragManager {

    struct ResizeResult {
        let window: HyprWindow
        let newFrame: CGRect
        let screen: NSScreen
        let workspace: Int
    }

    struct DragSwapResult {
        let dragged: HyprWindow
        let target: HyprWindow
        let sourceScreen: NSScreen?
        let targetScreen: NSScreen?
        let crossMonitor: Bool
    }

    struct DragToEmptyResult {
        let dragged: HyprWindow
        let targetScreen: NSScreen
    }

    enum DetectionResult {
        case resize(ResizeResult)
        case swap(DragSwapResult)
        case dragToEmpty(DragToEmptyResult)
        case snapBack
        case none
    }

    // dependencies
    var floatingWindowIDs: Set<CGWindowID> = []
    var tiledPositions: [CGWindowID: CGRect] = [:]

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
