import Cocoa

// handles focus-follows-mouse, refocus-under-cursor, and menu bar tracking suppression
class MouseTrackingManager {

    // state
    var lastMouseFocusedID: CGWindowID = 0
    var suppressMouseFocusUntil: Date = .distantPast
    // set by HIToolbox begin/end notifications — true for both menu bar menus
    // and native right-click context menus (NSMenu). other code paths read this
    // to skip focus-stealing operations while a menu is open.
    var menuTracking = false
    var dockIsActive = false

    // throttle mouse-move processing to ~60Hz — the OS can fire hundreds of
    // mouseMoved events per second and each one walks every visible window.
    // with many windows open this became the dominant over-time perf hit.
    private var lastHandleTime: CFAbsoluteTime = 0
    private let handleMinInterval: CFAbsoluteTime = 0.016

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
        guard !menuTracking else { return }
        guard !dockIsActive else { return }
        guard !isAnimating() else { return }
        guard Date() > suppressMouseFocusUntil else { return }

        // throttle: ~60Hz cap. mouseMoved fires hundreds of times per second
        // and the work below scales with window count, so unthrottled it's
        // the dominant cost when many windows are open.
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastHandleTime < handleMinInterval { return }
        lastHandleTime = now

        let mouseNS = NSEvent.mouseLocation
        let cgY = primaryScreenHeight() - mouseNS.y
        let cgPoint = CGPoint(x: mouseNS.x, y: cgY)

        // dead zone: menu bar region (~25px in CG top-left coords)
        if cgY < 25 { return }

        // snapshot closures once per move event
        let floating = floatingWindowIDs()
        let managed = tiledPositions()

        if let topmostID = topmostWindowID(at: cgPoint) {
            if floating.contains(topmostID), isWindowVisible(topmostID) {
                return
            }

            if managed[topmostID] != nil {
                guard topmostID != lastMouseFocusedID else { return }
                guard let target = cachedWindow(topmostID) else { return }
                lastMouseFocusedID = topmostID
                onFocusForFFM(target)
                return
            }

            // an unmanaged normal-layer window is above the tiled window
            // here, such as a popover or autocomplete panel.
            return
        }

        // fast path: cursor still inside the last-focused window's rect → done.
        // O(1) check that short-circuits before walking every floater + tile.
        // huge win during normal mouse movement (cursor stays in one window).
        if lastMouseFocusedID != 0,
           let lastRect = managed[lastMouseFocusedID],
           lastRect.contains(cgPoint) {
            return
        }

        // if cursor is over a visible floating window, don't refocus the tiled window underneath
        for wid in floating {
            guard isWindowVisible(wid),
                  let w = cachedWindow(wid), let frame = w.frame else { continue }
            if frame.contains(cgPoint) { return }
        }

        for (wid, rect) in managed {
            if rect.contains(cgPoint) {
                guard wid != lastMouseFocusedID else { return }

                guard let target = cachedWindow(wid) else { return }
                lastMouseFocusedID = wid
                onFocusForFFM(target)
                return
            }
        }
    }

    // re-derive focus from cursor position after a window disappears.
    // when cursor isn't over any tiled window we *don't* hide the border —
    // WindowManager.ensureFocusInvariant runs after every poll and will pick
    // a fallback so the user never ends up with nothing focused.
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
        // cursor not over any tiled window — clear FFM state but leave the
        // border alone so the invariant check can put it on a sensible target
        lastMouseFocusedID = 0
    }

    // CGWindowListCopyWindowInfo is expensive — cache result with short TTL
    private var topmostCache: (windowID: CGWindowID, time: CFAbsoluteTime, point: CGPoint)?
    private let topmostCacheTTL: CFAbsoluteTime = 0.08

    // front-to-back CG hit-test for the real window under the cursor.
    // returns 0 when no normal visible window is at the point.
    private func topmostWindowID(at point: CGPoint) -> CGWindowID? {
        let now = CFAbsoluteTimeGetCurrent()
        if let cache = topmostCache,
           now - cache.time < topmostCacheTTL,
           abs(point.x - cache.point.x) < 10, abs(point.y - cache.point.y) < 10 {
            return cache.windowID == 0 ? nil : cache.windowID
        }

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // walk front-to-back, find the first window whose bounds contain the point
        for info in windowList {
            if let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == getpid() {
                continue
            }

            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"] else { continue }
            let frame = CGRect(x: x, y: y, width: w, height: h)
            guard frame.contains(point) else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1.0
            guard alpha > 0.01 else { continue }

            let wid = (info[kCGWindowNumber as String] as? Int).map { CGWindowID($0) } ?? 0
            topmostCache = (windowID: wid, time: now, point: point)
            return wid == 0 ? nil : wid
        }

        topmostCache = (windowID: 0, time: now, point: point)
        return nil
    }

    func menuTrackingBegan() {
        menuTracking = true
        // leave the focus border intact — hiding it clears trackedWindowID,
        // which causes ensureFocusInvariant to re-assert focus during menu
        // tracking and dismiss the context menu. the border drawing on top
        // while a menu is open is harmless; menu is at a higher window level.
    }

    func menuTrackingEnded() {
        menuTracking = false
        if let w = cachedWindow(lastMouseFocusedID) {
            onUpdateFocusBorder(w)
        }
    }
}
