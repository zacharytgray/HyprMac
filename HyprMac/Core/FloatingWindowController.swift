// Floating-window lifecycle: tile/float toggle, cycle, raise-behind, and
// the auto-float predicate. Holds direct references to long-lived services
// and uses closure handles for the WM-side glue (animated retile, focus
// border refresh, position cache).

import Cocoa

/// Owner of floating-window behavior.
///
/// Public surface: `toggle` flips a window between tiled and floating;
/// `cycleFocus` rotates focus across visible floaters; `raiseBehind`
/// lifts floaters that ended up behind tiled windows; `shouldAutoFloat`
/// is the single predicate used by snapshot and discovery to decide
/// whether a freshly-seen window enters tiling.
///
/// What does not live here: the `onAutoFloat` callback wiring on
/// `TilingEngine` (stays in `WindowManager` init), workspace assignment
/// for new floaters (`WindowDiscoveryService`), and per-window focus
/// border refresh (the focus border itself plus `WindowManager`'s
/// `updateFocusBorder`).
///
/// Reentrancy: `raiseBehind` guards itself with a same-stack-frame
/// `Bool` + `defer`. This is not a date-gated suppression — see
/// `SuppressionRegistry`.
///
/// Threading: main-thread only.
final class FloatingWindowController {

    private let stateCache: WindowStateCache
    private let suppressions: SuppressionRegistry
    private let workspaceManager: WorkspaceManager
    private let tilingEngine: TilingEngine
    private let displayManager: DisplayManager
    private let accessibility: AccessibilityManager
    private let cursorManager: CursorManager
    private let focusController: FocusStateController
    private let focusBorder: FocusBorder
    private let dimmingOverlay: DimmingOverlay

    // closure handles for WM-side helpers used by toggle/cycle/raise.
    var animatedRetile: ((@escaping () -> Void) -> Void)?
    var updateFocusBorder: ((HyprWindow) -> Void)?
    var updatePositionCache: (() -> Void)?
    var isMenuTracking: () -> Bool = { false }

    // same-stack-frame reentrancy guard for raiseBehind. paired with defer.
    // moved here from WindowManager (per §5.5 — not a SuppressionRegistry key).
    private var isRaising = false

    init(stateCache: WindowStateCache,
         suppressions: SuppressionRegistry,
         workspaceManager: WorkspaceManager,
         tilingEngine: TilingEngine,
         displayManager: DisplayManager,
         accessibility: AccessibilityManager,
         cursorManager: CursorManager,
         focusController: FocusStateController,
         focusBorder: FocusBorder,
         dimmingOverlay: DimmingOverlay) {
        self.stateCache = stateCache
        self.suppressions = suppressions
        self.workspaceManager = workspaceManager
        self.tilingEngine = tilingEngine
        self.displayManager = displayManager
        self.accessibility = accessibility
        self.cursorManager = cursorManager
        self.focusController = focusController
        self.focusBorder = focusBorder
        self.dimmingOverlay = dimmingOverlay
    }

    // MARK: - public API

    /// Flip `window` between tiled and floating.
    ///
    /// Tiled → floating: the window leaves the BSP tree and pops back to
    /// its `originalFrame` (when on-screen) or to a screen-centered
    /// fallback. Floating → tiled: the window enters the BSP tree at the
    /// best-fit slot; if the tree is full, an existing tile is evicted
    /// to floating to make room.
    ///
    /// On disabled monitors the call is a no-op — everything floats
    /// there by definition. The actual retile is wrapped in
    /// `animatedRetile` so the surrounding tiles slide instead of
    /// snapping.
    func toggle(_ window: HyprWindow, on screen: NSScreen, in workspace: Int) {
        if workspaceManager.isMonitorDisabled(screen) {
            hyprLog(.debug, .floating, "toggle: monitor disabled, no tiling available")
            return
        }

        let wasFloating = stateCache.floatingWindowIDs.contains(window.windowID)
        guard let animatedRetile = animatedRetile else { return }

        if wasFloating {
            // floating → tiled: animate surrounding windows making room.
            // reassign workspace in case the window was dragged to a different monitor while floating.
            workspaceManager.moveWindow(window.windowID, toWorkspace: workspace)
            animatedRetile { [self] in
                stateCache.floatingWindowIDs.remove(window.windowID)
                window.isFloating = false

                if let evicted = tilingEngine.forceInsertWindow(window, toWorkspace: workspace, on: screen) {
                    evicted.isFloating = true
                    stateCache.floatingWindowIDs.insert(evicted.windowID)
                    let screenRect = displayManager.cgRect(for: screen)
                    if let original = stateCache.originalFrames[evicted.windowID],
                       isFrameVisible(original, on: screenRect) {
                        evicted.setFrame(original)
                    } else {
                        let sz = evicted.size ?? CGSize(width: 800, height: 600)
                        evicted.position = CGPoint(x: screenRect.midX - sz.width / 2,
                                                   y: screenRect.midY - sz.height / 2)
                    }
                    hyprLog(.debug, .floating, "tiling '\(window.title ?? "?")' — bumped '\(evicted.title ?? "?")' to floating")
                } else {
                    hyprLog(.debug, .floating, "tiling window '\(window.title ?? "?")'")
                }
            }
        } else {
            // tiled → floating: animate remaining windows filling the gap.
            focusBorder.hide()
            dimmingOverlay.hideAll()
            animatedRetile { [self] in
                stateCache.floatingWindowIDs.insert(window.windowID)
                window.isFloating = true
                tilingEngine.removeWindow(window, fromWorkspace: workspace)

                let screenRect = displayManager.cgRect(for: screen)
                if let original = stateCache.originalFrames[window.windowID],
                   isFrameVisible(original, on: screenRect) {
                    window.position = original.origin
                    window.size = original.size
                    hyprLog(.debug, .floating, "floated window '\(window.title ?? "?")' → restored \(original)")
                } else {
                    let currentSize = window.size ?? CGSize(width: 800, height: 600)
                    let centeredOrigin = CGPoint(
                        x: screenRect.midX - currentSize.width / 2,
                        y: screenRect.midY - currentSize.height / 2
                    )
                    window.position = centeredOrigin
                    hyprLog(.debug, .floating, "floated window '\(window.title ?? "?")' → centered on screen (bad original frame)")
                }
            }
        }
    }

    /// Cycle focus through visible floating windows in id order, raising
    /// each in turn.
    ///
    /// Suppresses FFM and activation-switch briefly so the focus change
    /// is not undone by mouse motion or activation churn. Off-screen
    /// floaters are recentered onto the primary screen before being
    /// focused, so a floater hidden across a disconnected monitor still
    /// becomes reachable.
    func cycleFocus() {
        suppressions.suppress("mouse-focus", for: 0.3)
        suppressions.suppress("activation-switch", for: 0.5)

        let visibleFloaters = stateCache.floatingWindowIDs.sorted().compactMap { wid -> HyprWindow? in
            guard workspaceManager.isWindowVisible(wid) else { return nil }
            return stateCache.cachedWindows[wid] ?? accessibility.getAllWindows().first { $0.windowID == wid }
        }
        guard !visibleFloaters.isEmpty else {
            hyprLog(.debug, .floating, "no visible floating windows")
            return
        }

        let focused = accessibility.getFocusedWindow()
        var target = visibleFloaters[0]
        if let focused = focused,
           let idx = visibleFloaters.firstIndex(where: { $0.windowID == focused.windowID }) {
            target = visibleFloaters[(idx + 1) % visibleFloaters.count]
        }

        // bring offscreen floaters to center of nearest screen
        if let frame = target.frame {
            let onScreen = displayManager.screens.contains { screen in
                isFrameVisible(frame, on: displayManager.cgRect(for: screen))
            }
            if !onScreen {
                let screen = displayManager.screens.first ?? NSScreen.main!
                let screenRect = displayManager.cgRect(for: screen)
                let sz = target.size ?? CGSize(width: 800, height: 600)
                target.position = CGPoint(x: screenRect.midX - sz.width / 2,
                                          y: screenRect.midY - sz.height / 2)
                hyprLog(.debug, .floating, "brought offscreen floater '\(target.title ?? "?")' to center")
            }
        }

        hyprLog(.debug, .floating, "focused floating window '\(target.title ?? "?")' (\(visibleFloaters.count) total)")

        target.focus()
        cursorManager.warpToCenter(of: target)
        focusController.recordFocus(target.windowID, reason: "cycleFocus")
        target.isFloating = true
        stateCache.cachedWindows[target.windowID] = target
        updateFocusBorder?(target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.updatePositionCache?()
        }
    }

    /// Lift any floating windows that ended up behind tiled windows on
    /// their screen.
    ///
    /// Honors the same-stack reentrancy guard so app-activation churn
    /// does not retrigger the raise mid-flight, and skips entirely while
    /// a native menu is tracking — the post-raise focus restore would
    /// dismiss the menu. After raising, focus is restored to the
    /// previously focused tiled window via `focusWithoutRaise` so the
    /// raise itself does not hijack keyboard focus.
    func raiseBehind() {
        guard !isRaising else { return }
        // skip while a native menu is tracking — the post-raise focusWithoutRaise below
        // synthesizes key-focus events that dismiss context menus.
        guard !isMenuTracking() else { return }
        isRaising = true
        defer { isRaising = false }

        let toRaise = floatingWindowsBehindTiled(
            floatingWindowIDs: stateCache.floatingWindowIDs,
            tiledPositions: stateCache.tiledPositions
        )
        guard !toRaise.isEmpty else { return }

        let previousFocusID = focusController.lastFocusedID
        let previousWindow = stateCache.cachedWindows[previousFocusID]

        suppressions.suppress("activation-switch", for: 0.5)
        suppressions.suppress("mouse-focus", for: 0.15)

        for wid in toRaise {
            guard let w = stateCache.cachedWindows[wid] else { continue }
            AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        }

        // immediately restore focus to the tiled window the user was interacting with.
        // prevents the raise from stealing focus and triggering an FFM cascade.
        if let prev = previousWindow, !stateCache.floatingWindowIDs.contains(prev.windowID) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                prev.focusWithoutRaise()
                self?.updateFocusBorder?(prev)
            }
        }
    }

    /// `true` when `window` should auto-float on first discovery.
    ///
    /// Single source for the "excluded bundle ID" check shared between
    /// `snapshotAndTile` and `WindowDiscoveryService`. Disabled-monitor
    /// auto-float is a separate decision with separate logic.
    func shouldAutoFloat(_ window: HyprWindow, excludedBundleIDs: Set<String>) -> Bool {
        guard let bundleID = NSRunningApplication(processIdentifier: window.ownerPID)?.bundleIdentifier else {
            return false
        }
        return excludedBundleIDs.contains(bundleID)
    }

    // MARK: - z-order helper (used by raiseBehind + cross-checks)

    /// Floaters currently sitting behind the frontmost tiled window on
    /// their own screen, computed from
    /// `CGWindowListCopyWindowInfo` z-order.
    ///
    /// Per-screen comparison: a floater on monitor A whose z-index is
    /// greater (deeper) than the frontmost tiled window on monitor A is
    /// flagged. Without z-order info, every visible floater is returned
    /// (safe default — `raiseBehind` will lift everything).
    func floatingWindowsBehindTiled(
        floatingWindowIDs: Set<CGWindowID>,
        tiledPositions: [CGWindowID: CGRect]
    ) -> [CGWindowID] {
        let visibleFloaters = floatingWindowIDs.filter { workspaceManager.isWindowVisible($0) }
        guard !visibleFloaters.isEmpty else { return [] }

        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return Array(visibleFloaters)
        }

        // build z-index map: lower index = closer to front
        var zIndex: [CGWindowID: Int] = [:]
        for (i, info) in infoList.enumerated() {
            if let wid = info[kCGWindowNumber as String] as? CGWindowID {
                zIndex[wid] = i
            }
        }

        // find frontmost tiled window z-index per screen
        var frontTiledZ: [Int: Int] = [:]
        for (wid, rect) in tiledPositions {
            guard let z = zIndex[wid],
                  let screen = displayManager.screen(at: CGPoint(x: rect.midX, y: rect.midY)) else { continue }
            let sid = workspaceManager.screenID(for: screen)
            if frontTiledZ[sid].map({ z < $0 }) ?? true {
                frontTiledZ[sid] = z
            }
        }

        // floater needs raising if it's behind frontmost tiled on its screen
        var needsRaise: [CGWindowID] = []
        for wid in visibleFloaters {
            guard let fz = zIndex[wid],
                  let w = stateCache.cachedWindows[wid], let frame = w.frame else { continue }
            let screen = displayManager.screen(at: CGPoint(x: frame.midX, y: frame.midY))
            let sid = screen.map { workspaceManager.screenID(for: $0) } ?? -1
            if let tz = frontTiledZ[sid], fz > tz {
                needsRaise.append(wid)
            }
        }
        return needsRaise
    }

    // MARK: - private helpers

    /// `true` when at least 25 % of `frame` overlaps `screenRect`.
    /// Matches the duplicate in `WindowManager` and
    /// `WindowDiscoveryService`; tracked as an extraction candidate but
    /// kept inline until a third caller appears.
    private func isFrameVisible(_ frame: CGRect, on screenRect: CGRect) -> Bool {
        let overlap = frame.intersection(screenRect)
        guard !overlap.isNull else { return false }
        let overlapArea = overlap.width * overlap.height
        let frameArea = frame.width * frame.height
        guard frameArea > 0 else { return false }
        return overlapArea / frameArea > 0.25
    }
}
