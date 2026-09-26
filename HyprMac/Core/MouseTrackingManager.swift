// Focus-follows-mouse plus menu and popup suppression and
// refocus-under-cursor recovery. Throttled at the configured hover rate
// with a short-TTL window-list cache so the global mouseMoved handler stays cheap.

import Cocoa

/// Mouse-driven focus controller for focus-follows-mouse (FFM).
///
/// `handleMouseMove` fires on every `NSMouseMoved` event, so the hot
/// path is built around early exits. The eligibility check
/// (`isFFMEligible`) gates on the FFM toggle, mouse button state, menu
/// tracking, dock activation, animation in flight, and the
/// `mouse-focus` suppression key. After eligibility, a configurable throttle
/// caps resolve work, and a short-TTL window-list cache avoids a
/// `CGWindowListCopyWindowInfo` query on every event.
///
/// A popup-level window of the frontmost app (an open menu, including
/// Chrome's bookmark folders) pauses hover focus everywhere, and a raised
/// window of the frontmost app under the cursor is never hit-tested
/// through. Either would otherwise focus the window below and close it.
///
/// `refocusUnderCursor` is a separate path used when the previously
/// focused window vanishes mid-flight — it re-derives focus from the
/// current cursor position without going through the FFM gates.
///
/// Threading: main-thread only.
class MouseTrackingManager {

    /// Tunables for the fallback throttle and the menu bar dead zone.
    private enum Tuning {
        // used until WindowManager injects the saved hover response rate
        static let throttleInterval: CFAbsoluteTime = 0.008
        // menu bar dead zone in CG (top-left) coords. focus changes inside
        // this band would compete with menu-bar interaction.
        static let menuBarDeadZonePx: CGFloat = 25
    }

    // window-list cache age. dedupes bursts of NSMouseMoved events; short
    // enough that windows reshuffling under a stationary cursor still
    // re-resolve within ~80ms.
    static let windowListMaxAge: CFAbsoluteTime = 0.08
    // a menu-level window open this long is part of the app, not a menu.
    // stop treating it as a popup so one odd app cannot freeze FFM or the
    // other popup guards.
    static let popupPauseLimit: CFAbsoluteTime = 30

    // state
    // set by HIToolbox begin/end notifications — true for both menu bar menus
    // and native right-click context menus (NSMenu). other code paths read this
    // to skip focus-stealing operations while a menu is open.
    var menuTracking = false
    var dockIsActive = false

    private var lastHandleTime: CFAbsoluteTime = 0
    // last time menuTrackingBegan was called. used by the watchdog to clear
    // a stuck menuTracking flag — Tahoe sometimes drops the end notification,
    // which would otherwise kill FFM until the next begin/end cycle.
    private var menuTrackingStart: CFAbsoluteTime = 0
    // hard ceiling on how long menuTracking can stay true without an explicit
    // end notification. real menus get dismissed by mouseDown anyway, so this
    // is just a safety net for the dropped-notification case.
    private static let menuTrackingMaxAge: CFAbsoluteTime = 5.0

    // dependencies injected by WindowManager
    var isFocusFollowsMouseEnabled: () -> Bool = { false }
    var isMouseButtonDown: () -> Bool = { false }
    var primaryScreenHeight: () -> CGFloat = { 0 }
    var mouseLocationNS: () -> CGPoint = { NSEvent.mouseLocation }
    var now: () -> CFAbsoluteTime = { CFAbsoluteTimeGetCurrent() }
    // test seam: replaces the window-list hit test (and its popup check)
    var resolveTopmostWindowID: ((CGPoint) -> CGWindowID?)?
    // front-to-back on-screen windows. read through the TTL cache below.
    var readWindowList: () -> [StackedWindow]? = { WindowStacking.onScreen() }
    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var ownPID: pid_t = getpid()
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
    // true while the scratchpad layer is up — FFM must not reach through the
    // scrim to hover-focus a background tile (would dismiss the quasimodal layer)
    var isScratchpadVisible: () -> Bool = { false }
    // minimum spacing between eligible checks. skipped events are not replayed.
    // WindowManager derives this from the user-configured response rate.
    var hoverThrottleInterval: () -> CFAbsoluteTime = { Tuning.throttleInterval }
    // routed to FocusStateController by WindowManager (canonical "last focused" id)
    var lastFocusedID: () -> CGWindowID = { 0 }
    var recordFocus: (CGWindowID, String) -> Void = { _, _ in }

    private struct FocusTarget {
        let windowID: CGWindowID
        let window: HyprWindow
        let reason: String
    }

    // the popup that last paused hover focus, so the pause logs once
    private var pausedByPopupID: CGWindowID = 0
    // when each open popup was first seen, and which ones outlived the limit
    private var popupFirstSeen: [CGWindowID: CFAbsoluteTime] = [:]
    private var ignoredStalePopupIDs: Set<CGWindowID> = []

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
        let currentTime = now()
        if currentTime - lastHandleTime < hoverThrottleInterval() { return }
        lastHandleTime = currentTime

        let mouseNS = mouseLocationNS()
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
    /// changes, and `isMouseFocusSuppressed` honors the post-action quiet window
    /// owned by `SuppressionRegistry["mouse-focus"]`.
    private func isFFMEligible() -> Bool {
        guard isFocusFollowsMouseEnabled() else { return false }
        // scratchpad quasimodality freezes focus to summoned members; hovering
        // the scrimmed background must not steal focus to a tile beneath it.
        if isScratchpadVisible() { hyprLog(.debug, .mouse, "ffm-bail: scratchpad visible"); return false }
        if isMouseButtonDown() { hyprLog(.debug, .mouse, "ffm-bail: mouseButtonDown"); return false }
        if menuTracking {
            // watchdog: HIToolbox sometimes drops endMenuTrackingNotification on
            // Tahoe, leaving menuTracking latched and FFM dead until the next
            // menu cycle. force-clear after the max age so a dropped notification
            // doesn't permanently kill hover focus.
            let age = now() - menuTrackingStart
            if age > Self.menuTrackingMaxAge {
                hyprLog(.notice, .mouse, "menuTracking stuck for \(String(format: "%.1f", age))s — force-clearing")
                menuTracking = false
            } else {
                hyprLog(.debug, .mouse, "ffm-bail: menuTracking (age=\(String(format: "%.1f", age))s)")
                return false
            }
        }
        if dockIsActive { hyprLog(.debug, .mouse, "ffm-bail: dockIsActive"); return false }
        if isMouseFocusSuppressed() { hyprLog(.debug, .mouse, "ffm-bail: mouse-focus suppressed"); return false }
        return true
    }

    /// `true` when `cgPoint` is in the menu-bar dead zone — focus
    /// changes that fired here would compete with menu interaction.
    ///
    /// The dead zone is anchored to the cursor's local screen, not the
    /// primary screen. Without this, a monitor stacked above the primary
    /// produces `cgY < 0` everywhere and FFM is dead across its full
    /// height — the bug from the multi-monitor FFM investigation.
    private func isInMenuBarDeadZone(_ cgPoint: CGPoint) -> Bool {
        guard let screen = screenAt(cgPoint) else {
            // fall back to the old primary-anchored check
            return cgPoint.y < Tuning.menuBarDeadZonePx
        }
        // screen.frame is in NS (bottom-left). its top edge in CG (top-left) is
        // primaryH - (origin.y + height).
        let screenTopCG = primaryScreenHeight() - (screen.frame.origin.y + screen.frame.height)
        return cgPoint.y - screenTopCG < Tuning.menuBarDeadZonePx
    }

    /// Resolve which window should receive focus for `cgPoint`, or `nil`
    /// when no change is appropriate.
    ///
    /// Returns `nil` for the common no-change cases: cursor over the already-focused
    /// window, cursor over an unmanaged normal-layer overlay (popover,
    /// autocomplete panel), an open popup of the frontmost app anywhere on
    /// screen, a raised panel of the frontmost app under the cursor, or no
    /// managed window at all.
    private func determineFocusTarget(at cgPoint: CGPoint) -> FocusTarget? {
        // snapshot closures once per move event
        let floating = floatingWindowIDs()
        let managed = tiledPositions()

        let hit = hover(at: cgPoint)
        switch hit {
        case .blocked(let raised):
            // over an open menu or a panel of the frontmost app. the window
            // below is not the target, and focusing it would close the menu.
            hyprLog(.debug, .mouse, "ffm-bail: over raised window \(raised.windowID) layer=\(raised.layer)")
            return nil
        case .window(let topmostID):
            // focus the physical floater, including a sibling of the current tile
            if floating.contains(topmostID), isWindowVisible(topmostID) {
                guard topmostID != lastFocusedID(), let target = cachedWindow(topmostID) else { return nil }
                return FocusTarget(windowID: topmostID, window: target, reason: "ffm-topmost-floating")
            }

            if managed[topmostID] != nil {
                guard topmostID != lastFocusedID() else { return nil }
                guard let target = cachedWindow(topmostID) else {
                    hyprLog(.debug, .mouse, "ffm-bail: topmost \(topmostID) in managed but cachedWindow nil")
                    return nil
                }
                return FocusTarget(windowID: topmostID, window: target, reason: "ffm-topmost")
            }

            // an unmanaged normal-layer window is above the tiled window
            // here, such as a popover or autocomplete panel.
            hyprLog(.debug, .mouse, "ffm-bail: topmost \(topmostID) not in managed (managed.count=\(managed.count), cached=\(cachedWindow(topmostID) != nil), floating=\(floating.contains(topmostID)))")
            return nil
        case .none:
            break
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
        // the synthetic click in focusForFFM would close an open menu
        if let popup = openPopup(maxAge: 0) {
            hyprLog(.notice, .mouse, "refocus under cursor skipped: popup wid=\(popup.windowID) "
                    + "pid=\(popup.ownerPID) layer=\(popup.layer)")
            return
        }
        let mouseNS = mouseLocationNS()
        let cgY = primaryScreenHeight() - mouseNS.y
        let cgPoint = CGPoint(x: mouseNS.x, y: cgY)

        // already-focused fast path: cursor is still over the last-focused
        // tile and that tile still exists — no refocus needed. without this,
        // every click inside the focused window would re-fire the synthetic
        // click and re-show the focus border (visible "re-highlight" flash).
        // matches the same guard determineFocusTarget uses on the live FFM
        // path. when the previously-focused window is gone, tiledPositions
        // won't contain its ID, the guard falls through, and a fallback is
        // picked below.
        let lastID = lastFocusedID()
        if lastID != 0, let lastRect = tiledPositions()[lastID], lastRect.contains(cgPoint) {
            return
        }

        // bail if cursor is over a visible floater — refocusing the tile below
        // would pull the tile above the floater (the synthetic click in
        // focusForFFM raises the clicked window's app). matches the same guard
        // determineFocusTarget uses on the live FFM path.
        for wid in floatingWindowIDs() where isWindowVisible(wid) {
            if let f = cachedWindow(wid)?.frame, f.contains(cgPoint) { return }
        }

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

    /// Short-TTL cache of the window list. `CGWindowListCopyWindowInfo` is
    /// expensive enough to dominate the FFM hot path without this. Mouse
    /// presses invalidate it, since a click is what opens a menu.
    private var windowListCache: (windows: [StackedWindow], time: CFAbsoluteTime)?

    func invalidateWindowListCache() {
        windowListCache = nil
    }

    /// On-screen windows, front to back, no older than `maxAge`.
    func stackedWindows(maxAge: CFAbsoluteTime = MouseTrackingManager.windowListMaxAge) -> [StackedWindow]? {
        let now = now()
        if let cache = windowListCache, now - cache.time < maxAge {
            return cache.windows
        }
        guard let windows = readWindowList() else { return nil }
        windowListCache = (windows, now)
        return windows
    }

    /// The frontmost app's open popup-level window, if any.
    func openPopup(maxAge: CFAbsoluteTime = MouseTrackingManager.windowListMaxAge) -> StackedWindow? {
        guard let windows = stackedWindows(maxAge: maxAge) else { return nil }
        return livePopup(in: windows, frontmostPID: frontmostPID())
    }

    /// The frontmost app's open popup in `windows`, skipping any that has
    /// been open longer than `popupPauseLimit`. Every popup guard asks
    /// through here, so they agree on what counts.
    func livePopup(in windows: [StackedWindow], frontmostPID front: pid_t?) -> StackedWindow? {
        let popups = WindowStacking.openPopups(in: windows, frontmostPID: front, ownPID: ownPID)
        let time = now()
        let ids = Set(popups.map(\.windowID))
        popupFirstSeen = popupFirstSeen.filter { ids.contains($0.key) }
        ignoredStalePopupIDs.formIntersection(ids)
        for popup in popups {
            let firstSeen = popupFirstSeen[popup.windowID] ?? time
            popupFirstSeen[popup.windowID] = firstSeen
            if time - firstSeen < Self.popupPauseLimit { return popup }
            if ignoredStalePopupIDs.insert(popup.windowID).inserted {
                hyprLog(.notice, .mouse, "ignoring popup \(popup.windowID) pid=\(popup.ownerPID) "
                        + "layer=\(popup.layer): open \(Int(Self.popupPauseLimit))s, treated as part of the app")
            }
        }
        return nil
    }

    /// Pointer hit test at `point` (CG coordinates) against the cached list.
    func hitTest(at point: CGPoint, maxAge: CFAbsoluteTime = MouseTrackingManager.windowListMaxAge) -> WindowStacking.Hit {
        guard let windows = stackedWindows(maxAge: maxAge) else { return .none }
        return WindowStacking.hitTest(point, in: windows, frontmostPID: frontmostPID(), ownPID: ownPID,
                                      managedFloaters: floatingWindowIDs())
    }

    /// What hover focus should see at `point`. An open popup of the
    /// frontmost app blocks every point, not just the ones it covers:
    /// the menu stays open while the pointer wanders, as it does natively.
    private func hover(at point: CGPoint) -> WindowStacking.Hit {
        if let resolve = resolveTopmostWindowID {
            return resolve(point).map { .window($0) } ?? .none
        }
        guard let windows = stackedWindows() else { return .none }
        let front = frontmostPID()
        if let popup = livePopup(in: windows, frontmostPID: front) {
            if popup.windowID != pausedByPopupID {
                pausedByPopupID = popup.windowID
                hyprLog(.notice, .mouse, "ffm paused: popup wid=\(popup.windowID) pid=\(popup.ownerPID) "
                        + "layer=\(popup.layer) bounds=\(popup.bounds.map { "\($0)" } ?? "nil")")
            }
            return .blocked(popup)
        }
        if pausedByPopupID != 0 {
            hyprLog(.notice, .mouse, "ffm resumed: popup \(pausedByPopupID) gone")
            pausedByPopupID = 0
        }
        return WindowStacking.hitTest(point, in: windows, frontmostPID: front, ownPID: ownPID,
                                      managedFloaters: floatingWindowIDs())
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
        menuTrackingStart = now()
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
