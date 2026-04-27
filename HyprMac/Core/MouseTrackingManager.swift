// Focus-follows-mouse plus menu-bar-tracking suppression and
// refocus-under-cursor recovery. Throttled to ~60 Hz with a short-TTL
// topmost-window cache so the global mouseMoved handler stays cheap.

import Cocoa

/// Mouse-driven focus controller for focus-follows-mouse (FFM).
///
/// `handleMouseMove` fires on every `NSMouseMoved` event, so the hot
/// path is built around early exits. The eligibility check
/// (`isFFMEligible`) gates on the FFM toggle, mouse button state, menu
/// tracking, dock activation, animation in flight, and the
/// `mouse-focus` suppression key. After eligibility, a 60 Hz throttle
/// caps resolve work, and a topmost-window cache (TTL +
/// spatial-tolerance) avoids redundant `CGWindowListCopyWindowInfo`
/// queries when the cursor jitters.
///
/// `refocusUnderCursor` is a separate path used when the previously
/// focused window vanishes mid-flight — it re-derives focus from the
/// current cursor position without going through the FFM gates.
///
/// Threading: main-thread only.
class MouseTrackingManager {

    /// Tunables. Empirical: throttle measured on M1 Air with ~30
    /// visible windows; raising past ~24 ms produces visible focus lag
    /// during fast cursor sweeps, lowering below ~16 ms wastes work on
    /// no-op resolves between display frames.
    private enum Tuning {
        // 60Hz cap on FFM resolve work. raising = slower focus, lowering =
        // wasted CG window-list queries between display frames.
        static let throttleInterval: CFAbsoluteTime = 0.016
        // dedupe burst of NSMouseMoved events on a single frame; short
        // enough that windows reshuffling under a stationary cursor still
        // re-resolve within ~80ms.
        static let topmostCacheTTL: CFAbsoluteTime = 0.08
        // cursor jitter within this radius reuses the cached hit-test result
        // without re-querying CGWindowListCopyWindowInfo.
        static let topmostCacheSpatialTolerance: CGFloat = 10
        // menu bar dead zone in CG (top-left) coords. focus changes inside
        // this band would compete with menu-bar interaction.
        static let menuBarDeadZonePx: CGFloat = 25
    }

    // state
    // set by HIToolbox begin/end notifications — true for both menu bar menus
    // and native right-click context menus (NSMenu). other code paths read this
    // to skip focus-stealing operations while a menu is open.
    var menuTracking = false
    var dockIsActive = false

    private var lastHandleTime: CFAbsoluteTime = 0

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
    // routed to SuppressionRegistry["mouse-focus"] by WindowManager
    var isMouseFocusSuppressed: () -> Bool = { false }
    // routed to FocusStateController by WindowManager (canonical "last focused" id)
    var lastFocusedID: () -> CGWindowID = { 0 }
    var recordFocus: (CGWindowID, String) -> Void = { _, _ in }

    private struct FocusTarget {
        let windowID: CGWindowID
        let window: HyprWindow
        let reason: String
    }

    /// Entry point for FFM. Called from the global `NSMouseMoved`
    /// monitor on every event; gates and throttles before doing real
    /// work, then resolves a focus target and applies it.
    func handleMouseMove() {
        mainThreadOnly()
        guard isFFMEligible() else { return }

        // throttle: cap the resolve rate. note this records lastHandleTime
        // even when we end up bailing on the dead-zone check below — that
        // matches the prior behavior, where any pass through the eligibility
        // gate consumes the throttle window.
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastHandleTime < Tuning.throttleInterval { return }
        lastHandleTime = now

        let mouseNS = NSEvent.mouseLocation
        let cgY = primaryScreenHeight() - mouseNS.y
        let cgPoint = CGPoint(x: mouseNS.x, y: cgY)

        if isInMenuBarDeadZone(cgPoint) { return }

        guard let target = determineFocusTarget(at: cgPoint) else { return }
        recordFocus(target.windowID, target.reason)
        onFocusForFFM(target.window)
    }

    /// `true` when FFM should react to the current mouse event.
    ///
    /// Each guard exists for a specific reason: `isMouseButtonDown`
    /// skips drags (`DragManager` owns those), `menuTracking` and
    /// `dockIsActive` skip transient OS UI that would race with focus
    /// changes, `isAnimating` skips during `WindowAnimator` transitions
    /// where visual frames do not match AX positions, and
    /// `isMouseFocusSuppressed` honors the post-action quiet window
    /// owned by `SuppressionRegistry["mouse-focus"]`.
    private func isFFMEligible() -> Bool {
        guard isFocusFollowsMouseEnabled() else { return false }
        guard !isMouseButtonDown() else { return false }
        guard !menuTracking else { return false }
        guard !dockIsActive else { return false }
        guard !isAnimating() else { return false }
        guard !isMouseFocusSuppressed() else { return false }
        return true
    }

    /// `true` when `cgPoint` is in the menu-bar dead zone — focus
    /// changes that fired here would compete with menu interaction.
    private func isInMenuBarDeadZone(_ cgPoint: CGPoint) -> Bool {
        cgPoint.y < Tuning.menuBarDeadZonePx
    }

    /// Resolve which window should receive focus for `cgPoint`, or `nil`
    /// when no change is appropriate.
    ///
    /// Returns `nil` for the common no-change cases: cursor over a
    /// floater (leave focus alone), cursor over the already-focused
    /// tile, cursor over an unmanaged normal-layer overlay (popover,
    /// autocomplete panel), or no managed window at all.
    private func determineFocusTarget(at cgPoint: CGPoint) -> FocusTarget? {
        // snapshot closures once per move event
        let floating = floatingWindowIDs()
        let managed = tiledPositions()

        if let topmostID = topmostWindowID(at: cgPoint) {
            // cursor is over a visible floater — leave focus alone
            if floating.contains(topmostID), isWindowVisible(topmostID) {
                return nil
            }

            if managed[topmostID] != nil {
                guard topmostID != lastFocusedID() else { return nil }
                guard let target = cachedWindow(topmostID) else { return nil }
                return FocusTarget(windowID: topmostID, window: target, reason: "ffm-topmost")
            }

            // an unmanaged normal-layer window is above the tiled window
            // here, such as a popover or autocomplete panel.
            return nil
        }

        // fast path: cursor still inside the last-focused window's rect.
        // O(1) check that short-circuits before walking every floater + tile.
        // huge win during normal mouse movement (cursor stays in one window).
        let lastID = lastFocusedID()
        if lastID != 0,
           let lastRect = managed[lastID],
           lastRect.contains(cgPoint) {
            return nil
        }

        // CG topmost returned nothing but a floater may still cover the
        // point at the AX-frame level (e.g. transparent regions where CG
        // hit-test passes through). don't refocus the tile underneath.
        for wid in floating {
            guard isWindowVisible(wid),
                  let w = cachedWindow(wid), let frame = w.frame else { continue }
            if frame.contains(cgPoint) { return nil }
        }

        for (wid, rect) in managed {
            if rect.contains(cgPoint) {
                guard wid != lastFocusedID() else { return nil }
                guard let target = cachedWindow(wid) else { return nil }
                return FocusTarget(windowID: wid, window: target, reason: "ffm-managed")
            }
        }
        return nil
    }

    /// Re-derive focus from the current cursor position after a window
    /// vanishes mid-flight.
    ///
    /// Bypasses the FFM eligibility gates — this is invoked from
    /// `ActionDispatcher.applyChanges` when `focusedWindowGone` fires.
    /// When the cursor is not over any tiled window the border is left
    /// alone so `ensureFocusInvariant` can pick a fallback target on
    /// the next pass.
    func refocusUnderCursor() {
        mainThreadOnly()
        let mouseNS = NSEvent.mouseLocation
        let cgY = primaryScreenHeight() - mouseNS.y
        let cgPoint = CGPoint(x: mouseNS.x, y: cgY)

        for (wid, rect) in tiledPositions() {
            if rect.contains(cgPoint), let target = cachedWindow(wid) {
                recordFocus(wid, "refocus-under-cursor")
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
        recordFocus(0, "refocus-under-cursor-clear")
    }

    /// Short-TTL cache of the most recent topmost-window result.
    /// `CGWindowListCopyWindowInfo` is expensive enough to dominate the
    /// FFM hot path without this.
    private var topmostCache: (windowID: CGWindowID, time: CFAbsoluteTime, point: CGPoint)?

    /// Front-to-back CG hit-test for the real window under `point`.
    /// Skips this process's own windows (the focus border, dim panel,
    /// settings/welcome) and any layer ≠ 0. Returns `nil` when no
    /// normal-layer visible window covers the point.
    private func topmostWindowID(at point: CGPoint) -> CGWindowID? {
        let now = CFAbsoluteTimeGetCurrent()
        if let cache = topmostCache,
           now - cache.time < Tuning.topmostCacheTTL,
           abs(point.x - cache.point.x) < Tuning.topmostCacheSpatialTolerance,
           abs(point.y - cache.point.y) < Tuning.topmostCacheSpatialTolerance {
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

    /// Called when a menu (app menu or right-click context menu) opens.
    /// Sets the suppression flag so FFM stops reacting; deliberately
    /// leaves the focus border intact, since hiding it would clear
    /// `trackedWindowID` and cause `ensureFocusInvariant` to re-assert
    /// focus and dismiss the menu. The border drawing on top while the
    /// menu is open is harmless — the menu is at a higher window level.
    func menuTrackingBegan() {
        mainThreadOnly()
        menuTracking = true
    }

    /// Called when the menu closes. Refreshes the focus border on the
    /// last-focused window so its rect tracks any motion that happened
    /// during the menu's lifetime.
    func menuTrackingEnded() {
        mainThreadOnly()
        menuTracking = false
        if let w = cachedWindow(lastFocusedID()) {
            onUpdateFocusBorder(w)
        }
    }
}
