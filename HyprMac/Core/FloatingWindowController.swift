// Floating-window lifecycle: tile/float toggle, cycle, raise-behind, and
// the auto-float predicate. Holds direct references to long-lived services
// and uses closure handles for the WM-side glue (animated retile, focus
// border refresh, position cache).

import Cocoa

enum FloatingAdmissionPolicy {
    enum Reason: String {
        case excludedApp = "excluded app"
        case fixedSize = "window is not resizable"
        case quickLook = "quick look preview"
    }

    static func reason(isExcluded: Bool, isSizeSettable: Bool?,
                       isQuickLookPanel: Bool = false) -> Reason? {
        // a preview always floats: it sizes itself to each file
        if isQuickLookPanel { return .quickLook }
        if isExcluded { return .excludedApp }
        if isSizeSettable == false { return .fixedSize }
        return nil
    }
}

struct FloatToTileRejectionMessage {
    static func text(for failure: TilingEngine.ForceInsertFailure) -> String {
        switch failure {
        case .noFittingSlot:
            return "No room to tile this window"
        case .layoutRejected(.geometryMismatch):
            return "This window did not accept the tile size"
        case .layoutRejected:
            return "Could not apply the tiled layout"
        }
    }
}

/// Owner of floating-window behavior.
///
/// Public surface: `toggle` flips a window between tiled and floating;
/// `cycleFocus` rotates focus across visible floaters; `raiseBehind`
/// lifts floaters that ended up behind tiled windows; `shouldAutoFloat`
/// is the single predicate used by snapshot and discovery to decide
/// whether a freshly-seen window enters tiling.
///
/// What does not live here: workspace assignment for new floaters
/// (`WindowDiscoveryService`), and per-window focus
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
    var isScratchpadVisible: () -> Bool = { false }
    var windowListForZOrder: () -> [[String: Any]]? = {
        CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]]
    }
    var performRaise: (HyprWindow) -> AXError = {
        AXUIElementPerformAction($0.element, kAXRaiseAction as CFString)
    }
    var scheduleAfter: (TimeInterval, @escaping () -> Void) -> Void = { delay, body in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
    }
    var restoreFocusWithoutRaise: (HyprWindow) -> Void = { $0.focusWithoutRaise() }
    var windowFrameForZOrder: (HyprWindow) -> CGRect? = { $0.frame }
    var isWindowSizeSettable: (HyprWindow) -> Bool? = { $0.isSizeSettable }
    // red flash on a float→tile the tree or the screen refused.
    var rejectFloatToTile: ((HyprWindow, TilingEngine.ForceInsertFailure) -> Void)?

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
    /// best-fit slot; if the tree is full, the window stays floating.
    ///
    /// A Quick Look preview is refused with the red shake and stays
    /// floating. On disabled monitors the call is a no-op — everything
    /// floats there by definition. The actual retile is wrapped in
    /// `animatedRetile` so the surrounding tiles slide instead of
    /// snapping.
    func toggle(_ window: HyprWindow, on screen: NSScreen, in workspace: Int) {
        if workspaceManager.isMonitorDisabled(screen) {
            hyprLog(.debug, .floating, "toggle: monitor disabled, no tiling available")
            return
        }

        let wasFloating = stateCache.floatingWindowIDs.contains(window.windowID)
        if wasFloating && window.isQuickLookPanel {
            // a preview never enters a tree. say so instead of doing nothing.
            hyprLog(.notice, .floating, "float→tile refused: \(window.windowID) is a quick look preview")
            if let frame = window.frame ?? stateCache.cachedWindows[window.windowID]?.frame {
                focusBorder.flashError(around: frame, windowID: window.windowID, window: window,
                                       message: "Quick Look previews stay floating")
            }
            return
        }
        guard let animatedRetile = animatedRetile else { return }

        if wasFloating {
            // floating → tiled: animate surrounding windows making room.
            // reassign workspace in case the window was dragged to a different monitor while floating.
            workspaceManager.moveWindow(window.windowID, toWorkspace: workspace)
            animatedRetile { [self] in
                stateCache.floatingWindowIDs.remove(window.windowID)
                window.isFloating = false

                switch forceInsert(window, workspace: workspace, screen: screen) {
                case .inserted, .alreadyPresent:
                    hyprLog(.debug, .floating, "tiling window '\(window.title ?? "?")'")
                case let .failed(reason):
                    // the tree never took it, so it is still a floater. put
                    // both flags back the way they were and say so.
                    floatInPlace(window, reason: "float→tile refused: \(reason)")
                    rejectFloatToTile?(window, reason)
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
                   original.isSubstantiallyVisible(on: screenRect) {
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

    /// The float→tile insertion, with one explicit revalidation behind it.
    ///
    /// When the tree refuses the window and the fit check says learned bounds
    /// are the only thing in the way, the user's toggle buys exactly one more
    /// attempt with those bounds set aside. Structure still decides: a tree
    /// that is out of depth, or a slot too small whatever the memory says,
    /// refuses both times. There is no second bypass and nothing is rearmed —
    /// the next toggle is a new request.
    ///
    private func forceInsert(_ window: HyprWindow, workspace: Int,
                             screen: NSScreen) -> TilingEngine.ForceInsertResult {
        let first = tilingEngine.forceInsertWindow(window, toWorkspace: workspace, on: screen)
        guard case .failed(.noFittingSlot) = first else { return first }
        guard case .revalidatable = tilingEngine.admissionOutlook(window, onWorkspace: workspace,
                                                                 screen: screen) else { return first }
        hyprLog(.notice, .floating, "float→tile revalidation: \(window.windowID) ws\(workspace)")
        return tilingEngine.forceInsertWindow(window, toWorkspace: workspace, on: screen,
                                              bypassingLearnedMinima: true)
    }

    /// Leave `window` floating exactly where it is.
    ///
    /// Both flags move together — the controller's set and the window's own
    /// — because half a float is what makes a window tiled to one subsystem
    /// and floating to the next. No frame is written: the window is already
    /// somewhere the user can see, and that is the whole point of the
    /// fallback. Focus is left alone.
    func floatInPlace(_ window: HyprWindow, reason: String) {
        stateCache.floatingWindowIDs.insert(window.windowID)
        window.isFloating = true
        stateCache.cachedWindows[window.windowID] = window
        hyprLog(.notice, .floating, "float in place: \(window.windowID) (\(reason))")
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
        suppressions.suppress("mouse-focus", for: 0.15)
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
                frame.isSubstantiallyVisible(on: displayManager.cgRect(for: screen))
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
        // scratchpad is quasimodal: it owns the level-0 stack (scrim below,
        // members raised above) and the post-raise focusWithoutRaise would
        // pull focus onto a background tiled window and dismiss the layer.
        guard !isScratchpadVisible() else { return }
        // skip while a native menu is tracking — the post-raise focusWithoutRaise below
        // synthesizes key-focus events that dismiss context menus.
        guard !isMenuTracking() else { return }
        isRaising = true
        defer { isRaising = false }

        let behind = floatingWindowsBehindTiled(
            floatingWindowIDs: stateCache.floatingWindowIDs,
            tiledPositions: stateCache.tiledPositions
        )
        let previousFocusID = focusController.lastFocusedID
        let previousFocusGeneration = focusController.generation
        let previousWindow = stateCache.cachedWindows[previousFocusID]
        let focusedTiledPID = previousWindow.flatMap {
            stateCache.floatingWindowIDs.contains($0.windowID) ? nil : $0.ownerPID
        }
        // safari can reorder a floating sibling when focus returns to its tile
        let toRaise = behind.filter { wid in
            guard let focusedTiledPID else { return true }
            return stateCache.cachedWindows[wid]?.ownerPID != focusedTiledPID
        }
        guard !toRaise.isEmpty else { return }

        suppressions.suppress("activation-switch", for: 0.5)
        suppressions.suppress("mouse-focus", for: 0.15)

        hyprLog(.notice, .floating, "raise behind: wids=\(toRaise.sorted()) focus=\(previousFocusID)")
        for wid in toRaise {
            guard let w = stateCache.cachedWindows[wid] else { continue }
            let rc = performRaise(w)
            if rc != .success {
                hyprLog(.notice, .floating, "raise behind failed: wid=\(wid) rc=\(rc.rawValue)")
            }
        }

        // immediately restore focus to the tiled window the user was interacting with.
        // prevents the raise from stealing focus and triggering an FFM cascade.
        if let prev = previousWindow, !stateCache.floatingWindowIDs.contains(prev.windowID) {
            scheduleAfter(0.02) { [weak self] in
                guard let self,
                      self.focusController.lastFocusedID == previousFocusID,
                      self.focusController.generation == previousFocusGeneration,
                      self.stateCache.knownWindowIDs.contains(previousFocusID),
                      !self.stateCache.hiddenWindowIDs.contains(previousFocusID),
                      self.workspaceManager.workspaceFor(previousFocusID) != nil,
                      self.workspaceManager.isWindowVisible(previousFocusID),
                      !self.stateCache.floatingWindowIDs.contains(previousFocusID),
                      !self.isMenuTracking(), !self.isScratchpadVisible() else { return }
                hyprLog(.notice, .floating, "raise behind restore: wid=\(previousFocusID)")
                self.restoreFocusWithoutRaise(prev)
                self.updateFocusBorder?(prev)
            }
        }
    }

    /// `true` when `window` should auto-float on first discovery.
    ///
    /// Excluded apps and windows that explicitly reject AX resize enter as
    /// floaters. An unreadable resize capability is left to verified tiling
    /// and its existing recovery. Disabled-monitor auto-float is separate.
    func shouldAutoFloat(_ window: HyprWindow, excludedBundleIDs: Set<String>) -> Bool {
        autoFloatReason(window, excludedBundleIDs: excludedBundleIDs) != nil
    }

    func autoFloatReason(
        _ window: HyprWindow, excludedBundleIDs: Set<String>
    ) -> FloatingAdmissionPolicy.Reason? {
        let bundleID = NSRunningApplication(processIdentifier: window.ownerPID)?.bundleIdentifier
        return FloatingAdmissionPolicy.reason(
            isExcluded: bundleID.map(excludedBundleIDs.contains) ?? false,
            isSizeSettable: isWindowSizeSettable(window),
            isQuickLookPanel: window.isQuickLookPanel
        )
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

        guard let infoList = windowListForZOrder() else {
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
                  let w = stateCache.cachedWindows[wid], let frame = windowFrameForZOrder(w) else { continue }
            let screen = displayManager.screen(at: CGPoint(x: frame.midX, y: frame.midY))
            let sid = screen.map { workspaceManager.screenID(for: $0) } ?? -1
            if let tz = frontTiledZ[sid], fz > tz {
                needsRaise.append(wid)
            }
        }
        return needsRaise
    }

}
