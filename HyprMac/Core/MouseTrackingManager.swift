import Cocoa

// handles focus-follows-mouse, refocus-under-cursor, and menu bar tracking suppression
class MouseTrackingManager {

    // state
    var lastMouseFocusedID: CGWindowID = 0
    var suppressMouseFocusUntil: Date = .distantPast
    var menuBarTracking = false
    var dockIsActive = false

    // dependencies injected by WindowManager
    var isFocusFollowsMouseEnabled: () -> Bool = { false }
    var isMouseButtonDown: () -> Bool = { false }
    var isAnimating: () -> Bool = { false }
    var primaryScreenHeight: () -> CGFloat = { 0 }
    var screenAt: (CGPoint) -> NSScreen? = { _ in nil }
    var floatingWindowIDs: () -> Set<CGWindowID> = { [] }
    var isWindowVisible: (CGWindowID) -> Bool = { _ in false }
    var cachedWindow: (CGWindowID) -> HyprWindow? = { _ in nil }
    var tiledPositions: () -> [CGWindowID: CGRect] = { [:] }
    var onFocusForFFM: (HyprWindow) -> Void = { _ in }
    var onUpdateFocusBorder: (HyprWindow) -> Void = { _ in }
    var onHideFocusBorder: () -> Void = {}

    func handleMouseMove() {
        guard isFocusFollowsMouseEnabled() else { return }
        guard !isMouseButtonDown() else { return }
        guard !menuBarTracking else { return }
        guard !dockIsActive else { return }
        guard !isAnimating() else { return }
        guard Date() > suppressMouseFocusUntil else { return }

        let mouseNS = NSEvent.mouseLocation
        let cgY = primaryScreenHeight() - mouseNS.y
        let cgPoint = CGPoint(x: mouseNS.x, y: cgY)

        // dead zone: menu bar region (~25px in CG top-left coords)
        if cgY < 25 { return }

        // if cursor is over a visible floating window, don't refocus the tiled window underneath
        for wid in floatingWindowIDs() {
            guard isWindowVisible(wid),
                  let w = cachedWindow(wid), let frame = w.frame else { continue }
            if frame.contains(cgPoint) { return }
        }

        for (wid, rect) in tiledPositions() {
            if rect.contains(cgPoint) {
                guard wid != lastMouseFocusedID else { return }

                // check if an unmanaged window (emoji picker, autocomplete, etc.) is above this point
                if unmanagedWindowAtPoint(cgPoint) { return }

                lastMouseFocusedID = wid
                if let target = cachedWindow(wid) {
                    onFocusForFFM(target)
                }
                return
            }
        }
    }

    // re-derive focus from cursor position after a window disappears
    func refocusUnderCursor() {
        let mouseNS = NSEvent.mouseLocation
        let cgY = primaryScreenHeight() - mouseNS.y
        let cgPoint = CGPoint(x: mouseNS.x, y: cgY)

        for (wid, rect) in tiledPositions() {
            if rect.contains(cgPoint), let target = cachedWindow(wid) {
                lastMouseFocusedID = wid
                if isFocusFollowsMouseEnabled() {
                    onFocusForFFM(target)
                } else {
                    onUpdateFocusBorder(target)
                }
                return
            }
        }
        // cursor not over any tiled window
        lastMouseFocusedID = 0
        onHideFocusBorder()
    }

    // check if an unmanaged window (emoji picker, popup, autocomplete) is the topmost at this point
    private func unmanagedWindowAtPoint(_ point: CGPoint) -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let managed = tiledPositions()
        let floating = floatingWindowIDs()

        // walk front-to-back, find the first window whose bounds contain the point
        for info in windowList {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"] else { continue }
            let frame = CGRect(x: x, y: y, width: w, height: h)
            guard frame.contains(point) else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }

            // found the topmost normal-layer window at this point
            let wid = (info[kCGWindowNumber as String] as? Int).map { CGWindowID($0) } ?? 0
            if managed[wid] != nil || floating.contains(wid) {
                return false // it's one of ours, FFM is fine
            }
            return true // unmanaged window on top, suppress FFM
        }
        return false
    }

    func menuTrackingBegan() {
        menuBarTracking = true
        onHideFocusBorder()
    }

    func menuTrackingEnded() {
        menuBarTracking = false
        if let w = cachedWindow(lastMouseFocusedID) {
            onUpdateFocusBorder(w)
        }
    }
}
