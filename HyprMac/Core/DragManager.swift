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
        screenAt: (CGPoint) -> NSScreen?,
        workspaceForScreen: (NSScreen) -> Int
    ) -> DetectionResult {

        // check for manual resize first: size changed on any axis
        for w in allWindows {
            guard !floatingWindowIDs.contains(w.windowID),
                  let current = w.frame,
                  let expected = tiledPositions[w.windowID] else { continue }

            let widthDelta = abs(current.width - expected.width)
            let heightDelta = abs(current.height - expected.height)

            if widthDelta > 20 || heightDelta > 20 {
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
                  let expected = tiledPositions[w.windowID] else { continue }

            let dist = abs(current.origin.x - expected.origin.x) + abs(current.origin.y - expected.origin.y)
            let sizeDist = abs(current.width - expected.width) + abs(current.height - expected.height)
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
