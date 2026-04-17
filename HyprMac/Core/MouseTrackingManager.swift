import Cocoa

// handles focus-follows-mouse, refocus-under-cursor, and menu bar tracking suppression
class MouseTrackingManager {

    // state
    var lastMouseFocusedID: CGWindowID = 0
    var suppressMouseFocusUntil: Date = .distantPast
    var menuBarTracking = false
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
        guard !menuBarTracking else { return }
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

                // check if an unmanaged window (emoji picker, autocomplete, etc.) is above this point
                if unmanagedWindowAtPoint(cgPoint, managed: managed, floating: floating) { return }

                lastMouseFocusedID = wid
                if let target = cachedWindow(wid) {
                    onFocusForFFM(target)
                }
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
    private var unmanagedCache: (result: Bool, time: CFAbsoluteTime, point: CGPoint)?
    private let unmanagedCacheTTL: CFAbsoluteTime = 0.15  // 150ms

    // check if an unmanaged window (emoji picker, popup, autocomplete) is the topmost at this point
    private func unmanagedWindowAtPoint(_ point: CGPoint, managed: [CGWindowID: CGRect], floating: Set<CGWindowID>) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if let cache = unmanagedCache,
           now - cache.time < unmanagedCacheTTL,
           abs(point.x - cache.point.x) < 10, abs(point.y - cache.point.y) < 10 {
            return cache.result
        }

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        // walk front-to-back, find the first window whose bounds contain the point
        var result = false
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
                result = false // it's one of ours, FFM is fine
            } else {
                result = true // unmanaged window on top, suppress FFM
            }
            break
        }

        unmanagedCache = (result: result, time: now, point: point)
        return result
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
