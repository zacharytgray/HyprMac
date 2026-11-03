// Which window the user means right now, and the repair a bare Hypr press runs
// when focus has gone stale. A swap makes the router report "superseded", so
// `recordFocus` stays before `tiledFocusRouter.focus`.

import Cocoa

final class FocusResolver {
    private let displayManager: DisplayManager
    private let workspaceManager: WorkspaceManager
    private let stateCache: WindowStateCache
    private let accessibility: AccessibilityManager
    private let focusController: FocusStateController
    private let focusBorder: FocusBorder
    private let scratchpad: ScratchpadController
    private let suppressions: SuppressionRegistry
    private let tiledFocusRouter: TiledFocusRouter

    var updateFocusBorder: (HyprWindow) -> Void = { _ in }

    init(displayManager: DisplayManager,
         workspaceManager: WorkspaceManager,
         stateCache: WindowStateCache,
         accessibility: AccessibilityManager,
         focusController: FocusStateController,
         focusBorder: FocusBorder,
         scratchpad: ScratchpadController,
         suppressions: SuppressionRegistry,
         tiledFocusRouter: TiledFocusRouter) {
        self.displayManager = displayManager
        self.workspaceManager = workspaceManager
        self.stateCache = stateCache
        self.accessibility = accessibility
        self.focusController = focusController
        self.focusBorder = focusBorder
        self.scratchpad = scratchpad
        self.suppressions = suppressions
        self.tiledFocusRouter = tiledFocusRouter
    }

    /// Return the window the user actually intends to control.
    ///
    /// AX's `kAXFocusedWindowAttribute` lags or diverges from reality for
    /// multi-window apps (Finder, Teams); `focusWithoutRaise` — used by FFM
    /// and `Hypr+Arrow` — does not reliably update it. The internal focus
    /// tracker is the source of truth: it's updated on every focus action
    /// and on manual clicks, so it stays in sync with what the user
    /// actually pointed at last.
    ///
    /// Resolution order: `focusBorder.trackedWindowID` → `lastFocusedID`
    /// → AX's reported focused window → `nil`. Each candidate must be
    /// selectable in the cursor's current workspace.
    func currentFocusedWindow() -> HyprWindow? {
        let screen = displayManager.screenUnderCursor()
        let workspace = workspaceManager.workspaceForScreen(screen)
        let wsWindows = workspaceManager.windowIDs(onWorkspace: workspace)
        let bid = focusBorder.trackedWindowID ?? 0
        let lid = focusController.lastFocusedID

        let resolved = FocusResolution.resolve(
            borderID: focusBorder.trackedWindowID,
            lastFocusedID: lid,
            isSelectable: { isSelectableInCurrentContext($0, workspaceWindows: wsWindows) },
            cachedWindow: { stateCache.cachedWindows[$0] },
            axFocused: { accessibility.getFocusedWindow() },
            // nothing focused inside the layer: act on its most recent member
            scratchpadMember: { scratchpad.focusTarget })
        guard let resolved else {
            hyprLog(.debug, .focus, "currentFocused → nil ws=\(workspace) screen=\(screen.localizedName) (border=\(bid) last=\(lid))")
            return nil
        }
        let id = resolved.window.windowID
        switch resolved.source {
        case .border:
            hyprLog(.debug, .focus, "currentFocused → border=\(id) ws=\(workspace) screen=\(screen.localizedName) (border=\(bid) last=\(lid))")
        case .lastFocused:
            hyprLog(.debug, .focus, "currentFocused → last=\(id) ws=\(workspace) screen=\(screen.localizedName) (border=\(bid) last=\(lid))")
        case .accessibility:
            hyprLog(.debug, .focus, "currentFocused → ax=\(id) ws=\(workspace) screen=\(screen.localizedName) (border=\(bid) last=\(lid))")
        case .scratchpadMember:
            hyprLog(.debug, .focus, "currentFocused → scratchpad member=\(id) (border=\(bid) last=\(lid))")
        }
        return resolved.window
    }

    /// `true` when `id` may take focus now. While the scratchpad is up only
    /// its summoned members do; the workspace under the scrim is out.
    func isInteractive(_ id: CGWindowID) -> Bool {
        scratchpad.isVisible ? scratchpad.isSummoned(id) : workspaceManager.isWindowVisible(id)
    }

    /// See `FocusResolution.isSelectable`.
    private func isSelectableInCurrentContext(_ windowID: CGWindowID, workspaceWindows: Set<CGWindowID>) -> Bool {
        FocusResolution.isSelectable(windowID,
                                     scratchpadVisible: scratchpad.isVisible,
                                     isSummoned: { scratchpad.isSummoned($0) },
                                     workspaceWindows: workspaceWindows,
                                     floatingWindowIDs: stateCache.floatingWindowIDs,
                                     isWindowVisible: { workspaceManager.isWindowVisible($0) })
    }

    func visibleFloatingWindows() -> [HyprWindow] {
        stateCache.floatingWindowIDs.compactMap { id in
            guard isInteractive(id) else { return nil }
            return stateCache.cachedWindows[id]
        }
    }

    /// Re-establish a coherent focus on bare Hypr keydown.
    ///
    /// The visible focus border is the primary source of truth for intent,
    /// as long as the bordered window belongs to the cursor's workspace.
    /// A front app that changed wins first: its focused window is adopted.
    /// When that fails, fallbacks are tried in priority order: the last
    /// recorded focus, floating window under the cursor (drawn on top),
    /// tiled window under the cursor, AX's reported focused window, and
    /// finally the nearest tiled window's center. Each candidate must be
    /// selectable in the cursor's current workspace context.
    func ensureFocus() {
        suppressions.suppress(.mouseFocus, for: SuppressionDelay.mouseFocus)

        // scratchpad is quasimodal: focus belongs to a summoned member. the
        // resolver below is scoped to the cursor's *background* workspace
        // (screenUnderCursor never maps to ws 0), so letting it run would
        // focus — and front — a tile under the cursor, dismissing the layer.
        // just re-assert the current member and stop.
        if scratchpad.isVisible {
            let current = focusBorder.trackedWindowID ?? focusController.lastFocusedID
            if scratchpad.isSummoned(current), let w = stateCache.cachedWindows[current] {
                w.focusWithoutRaise()
                updateFocusBorder(w)
            } else {
                scratchpad.refocusMember(reason: "ensureFocus-scratchpad")
            }
            return
        }

        let screen = displayManager.screenUnderCursor()
        let workspace = workspaceManager.workspaceForScreen(screen)
        let wsWindows = workspaceManager.windowIDs(onWorkspace: workspace)

        // the user switched apps behind our back: Cmd-Tab, a Dock click, an
        // app that opened its own window. the app in front wins over what
        // we remember, when its focused window is a valid target here.
        // within one app AX focus is not trusted (multi-window apps lag
        // and diverge), so only a change of app counts. a bare Hypr press
        // used to activate the remembered window and yank focus back
        if let front = NSWorkspace.shared.frontmostApplication,
           let remembered = stateCache.cachedWindows[focusBorder.trackedWindowID ?? focusController.lastFocusedID],
           front.processIdentifier != remembered.ownerPID,
           let focused = accessibility.getFocusedWindow(),
           focused.ownerPID == front.processIdentifier,
           isSelectableInCurrentContext(focused.windowID, workspaceWindows: wsWindows) {
            hyprLog(.notice, .focus, "ensureFocus: front app changed to \(focused.windowID) — adopting it")
            focusController.recordFocus(focused.windowID, reason: "ensureFocus-frontApp")
            updateFocusBorder(focused)
            return
        }

        if let tid = focusBorder.trackedWindowID,
           isSelectableInCurrentContext(tid, workspaceWindows: wsWindows),
           let w = stateCache.cachedWindows[tid] {
            focusController.recordFocus(tid, reason: "ensureFocus-trackedID")
            tiledFocusRouter.focus(w, reason: "ensureFocus", fallback: .activate)
            updateFocusBorder(w)
            return
        }

        if focusController.lastFocusedID != 0,
           isSelectableInCurrentContext(focusController.lastFocusedID, workspaceWindows: wsWindows),
           let w = stateCache.cachedWindows[focusController.lastFocusedID] {
            tiledFocusRouter.focus(w, reason: "ensureFocus", fallback: .activate)
            updateFocusBorder(w)
            return
        }

        // convert mouse to CG coords
        let cgPoint = displayManager.flippedY(NSEvent.mouseLocation)

        // floating windows are visually above tiled windows
        for wid in stateCache.floatingWindowIDs where wsWindows.contains(wid) {
            guard let w = stateCache.cachedWindows[wid], let frame = w.frame else { continue }
            if frame.contains(cgPoint) {
                w.focusWithoutRaise()
                focusController.recordFocus(wid, reason: "ensureFocus-floating")
                updateFocusBorder(w)
                return
            }
        }

        // tiled window under cursor
        for (wid, rect) in stateCache.tiledPositions {
            if wsWindows.contains(wid), rect.contains(cgPoint),
               let w = stateCache.cachedWindows[wid] {
                focusController.recordFocus(wid, reason: "ensureFocus-tiled")
                tiledFocusRouter.focus(w, reason: "ensureFocus", fallback: .activate)
                updateFocusBorder(w)
                return
            }
        }

        // whatever AX says is focused, if it is on this workspace
        if let focused = accessibility.getFocusedWindow(),
           isSelectableInCurrentContext(focused.windowID, workspaceWindows: wsWindows) {
            focusController.recordFocus(focused.windowID, reason: "ensureFocus-ax")
            updateFocusBorder(focused)
            return
        }

        // deterministic fallback: nearest tiled window center on this workspace
        let fallback = stateCache.tiledPositions
            .filter { wsWindows.contains($0.key) }
            .min { lhs, rhs in
                let lhsCenter = CGPoint(x: lhs.value.midX, y: lhs.value.midY)
                let rhsCenter = CGPoint(x: rhs.value.midX, y: rhs.value.midY)
                return distanceSquared(lhsCenter, cgPoint) < distanceSquared(rhsCenter, cgPoint)
            }
        if let (wid, _) = fallback, let w = stateCache.cachedWindows[wid] {
            focusController.recordFocus(wid, reason: "ensureFocus-fallback")
            tiledFocusRouter.focus(w, reason: "ensureFocus", fallback: .activate)
            updateFocusBorder(w)
        }
    }

    private func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }
}
