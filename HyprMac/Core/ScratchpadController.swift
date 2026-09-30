// Scratchpad: a quasimodal layer of floating windows, parked off-screen by
// default and summoned on demand. Members live on pseudo-workspace 0 and in
// the floating set. Summoning IS raising — dismissal re-parks, so there is
// never a z-order to defend while the layer is down (the operation macOS
// forbids under SIP is designed out, not worked around).
//
// Two distinct id sets: `members` (assigned to ws 0, possibly parked) and
// `summonedIDs` (actually on screen right now). Every focus/click decision
// consults summonedIDs so a parked member can never be raised while the
// layer is up. The scrim dims every monitor at .normal level; members are
// raised above it at show time (stack recency), so nothing is carved out.
//
// Frame decisions never trust a live AX read taken right after a write —
// Tahoe AX reads lag writes by >1s. Show computes geometry from the saved
// (intended) frame; `lastShownFrames` remembers what we placed so hide can
// re-save it when the live read is still stale.

import Cocoa

final class ScratchpadController {

    enum EntryMode: Equatable { case preserve, tiled, floating }

    static func entryMode(isExistingMember: Bool, tileByDefault: Bool) -> EntryMode {
        if isExistingMember { return .preserve }
        return tileByDefault ? .tiled : .floating
    }

    /// Pseudo-workspace id for scratchpad membership. Outside the regular workspace range, so it
    /// falls out of every switch / home-anchor / cycle path automatically.
    static let workspace = 0
    static let scrimIntensity: CGFloat = 0.45
    /// Fraction of the layer monitor inset on each edge for the tiled
    /// region — tiled members lay out inside this smaller frame so the
    /// scrimmed border stays visible around them. Pushed from
    /// `UserConfig.scratchpadRegionInset` by WindowManager.
    var tiledRegionInset: CGFloat = UserConfigDefaults.scratchpadRegionInset
    /// When true, a window sent to the scratchpad enters the layer's
    /// tiled tree instead of floating (fit permitting). Pushed from
    /// `UserConfig.scratchpadTileByDefault`.
    var tileNewMembers: Bool = UserConfigDefaults.scratchpadTileByDefault
    private let showGraceSec: TimeInterval = 0.75

    /// Why the layer is being dismissed. Focus restore is conditional on
    /// this: only an explicit toggle returns focus to the pre-show window —
    /// on click-outside / Cmd-Tab the user already chose a new target, and
    /// restoring would yank focus away from it.
    enum DismissReason: String {
        case toggle, clickOutside, activationChange, workspaceAction, displayChange
    }

    private let workspaceManager: WorkspaceManager
    private let stateCache: WindowStateCache
    private let accessibility: AccessibilityManager
    private let displayManager: DisplayManager
    private let tilingEngine: TilingEngine
    private let focusController: FocusStateController
    private let focusBorder: FocusBorder
    private let suppressions: SuppressionRegistry

    // wm-local helpers, assigned after construction
    var screenUnderCursor: () -> NSScreen? = { NSScreen.main }
    var currentFocusedWindow: () -> HyprWindow? = { nil }
    var updatePositionCache: () -> Void = {}
    var updateFocusBorder: (HyprWindow) -> Void = { _ in }
    var refocusUnderCursor: () -> Void = {}
    // the app is in Never tile: the layer keeps it floating
    var isNeverTile: (HyprWindow) -> Bool = { _ in false }
    var raiseScrim: () -> Void = {}
    /// Order the scrim panels directly below this window (cross-app window
    /// number). The settle passes use it to tuck the scrim under the
    /// backmost member instead of racing member raises against it.
    var lowerScrimBelow: (CGWindowID) -> Void = { _ in }
    var animatedRetile: ((() -> Void)?, (() -> Void)?) -> Void = { prepare, completion in
        prepare?(); completion?()
    }

    /// Most-recent-first summon order. Pruned lazily against live members.
    private var mruOrder: [CGWindowID] = []
    /// Members currently on screen. Subset of `members` while visible,
    /// empty while hidden.
    private var summonedIDs: Set<CGWindowID> = []
    /// The frame each summoned member was placed at — the intended rect,
    /// immune to stale AX reads.
    private var lastShownFrames: [CGWindowID: CGRect] = [:]
    private var focusBeforeShow: CGWindowID = 0
    /// Activation/click churn from our own show() must not read as
    /// dismiss-worthy while AX is still settling.
    private var shownAt = Date.distantPast
    /// Monitor the layer is currently shown on — the tiled region and
    /// every retile key off this. nil while hidden; fall back to
    /// screenUnderCursor when unset.
    private var shownScreen: NSScreen?

    var isVisible: Bool { workspaceManager.scratchpadVisible }

    /// The layer while it's up: its monitor and the members on screen.
    /// Directional focus, swap, resize and split stay inside it.
    struct Layer {
        let screen: NSScreen
        let members: Set<CGWindowID>
    }

    var visibleLayer: Layer? {
        guard isVisible, let screen = layerScreen() else { return nil }
        return Layer(screen: screen, members: summonedIDs)
    }

    /// The member focus belongs to when it has nowhere better to go: the
    /// most recent summoned member, else any summoned member.
    var focusTarget: HyprWindow? {
        guard isVisible else { return nil }
        let recent = mruOrder.first { summonedIDs.contains($0) && stateCache.cachedWindows[$0] != nil }
        let id = recent ?? summonedIDs.sorted().first { stateCache.cachedWindows[$0] != nil }
        return id.flatMap { stateCache.cachedWindows[$0] }
    }

    /// Put focus back on a member. Anything else would lift a window from
    /// the workspace under the scrim, or hand macOS the choice.
    func refocusMember(reason: String) {
        guard let w = focusTarget else { return }
        hyprLog(.notice, .focus, "scratchpad: focus → member '\(w.title ?? "?")' (\(w.windowID)) reason=\(reason)")
        w.focus()
        focusController.recordFocus(w.windowID, reason: reason)
        updateFocusBorder(w)
        restackLayer()
    }

    /// Hypr+Return and friends for an app that has a member on screen:
    /// focus that member. Activating the app would bring its other windows
    /// forward over the scrim. Returns false when the app has no member up.
    func focusMember(ofBundleID bundleID: String) -> Bool {
        guard isVisible else { return false }
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map(\.processIdentifier))
        let owners = stateCache.windowOwners
        let owned = { (id: CGWindowID) in owners[id].map(pids.contains) ?? false }
        let id = mruOrder.first { summonedIDs.contains($0) && owned($0) }
            ?? summonedIDs.sorted().first(where: owned)
        guard let id, let w = stateCache.cachedWindows[id] else { return false }
        w.focus()
        noteFocus(id)
        focusController.recordFocus(id, reason: "scratchpad-launch-focus")
        updateFocusBorder(w)
        restackLayer()
        return true
    }

    /// A window a member app opened while the layer is up (Cmd-N) joins the
    /// layer, as it would join the focused workspace. Same entry rule as a
    /// send: tiled when tile-by-default is on and it fits, else floating.
    /// Returns false when the window stays with the ordinary admission.
    func admitNewWindow(_ window: HyprWindow) -> Bool {
        guard isVisible, !window.isQuickLookPanel, memberPIDs.contains(window.ownerPID),
              !contains(window.windowID) else { return false }
        let id = window.windowID
        workspaceManager.assignWindow(id, toWorkspace: Self.workspace)
        summonedIDs.insert(id)
        let autoFloated = stateCache.floatingWindowIDs.contains(id)
        if tileNewMembers && !autoFloated {
            saveFreeFormFrame(window, fallback: window.frame)
            window.isFloating = false
            if !tileIntoVisibleLayer(window) {
                stateCache.floatingWindowIDs.insert(id)
                window.isFloating = true
                hyprLog(.notice, .lifecycle, "scratchpad: no slot for new '\(window.title ?? "?")' (\(id)) — floating")
            }
        } else {
            stateCache.floatingWindowIDs.insert(id)
            window.isFloating = true
        }
        if !isTiled(id), let frame = window.frame {
            lastShownFrames[id] = frame
        }
        window.raise()
        noteFocus(id)
        focusController.recordFocus(id, reason: "scratchpad-new-window")
        updateFocusBorder(window)
        restackLayer()
        hyprLog(.notice, .lifecycle, "scratchpad: new window '\(window.title ?? "?")' (\(id)) joined the layer")
        return true
    }

    /// Discovery saw members close, minimize or come back. A gone member
    /// leaves the layer and the rest re-lay to fill its slot; focus moves to
    /// another member when it was the focused one. A returning member rejoins
    /// the layer while it's up, and goes back to its park spot while it's
    /// down.
    func noteDiscovery(goneIDs: Set<CGWindowID>, returned: [HyprWindow]) {
        let returning = returned.filter { contains($0.windowID) }
        if !isVisible {
            if let parkScreen = displayManager.screens.first {
                for w in returning { workspaceManager.hideInCorner(w, on: parkScreen) }
            }
            return
        }
        let goneMembers = summonedIDs.intersection(goneIDs)
        let back = returning.filter { !summonedIDs.contains($0.windowID) }
        guard !goneMembers.isEmpty || !back.isEmpty else { return }

        let focusedGone = goneMembers.contains(focusController.lastFocusedID)
            || goneMembers.contains(focusBorder.trackedWindowID ?? 0)
        summonedIDs.subtract(goneMembers)
        for id in goneMembers { lastShownFrames.removeValue(forKey: id) }

        let screen = layerScreen()
        for w in back {
            summonedIDs.insert(w.windowID)
            if !isTiled(w.windowID), let screen {
                let base = workspaceManager.savedFloatingFrame(for: w.windowID) ?? w.frame ?? .zero
                if base != .zero {
                    lastShownFrames[w.windowID] = w.placeFloating(
                        carriedRect(base, to: displayManager.cgRect(for: screen)),
                        reason: "scratchpad return", on: screen, displayManager: displayManager)
                }
            }
            w.raise()
        }

        if summonedIDs.isEmpty {
            // every member closed: nothing left to show
            workspaceManager.scratchpadVisible = false
            lastShownFrames = [:]
            shownScreen = nil
            updatePositionCache()
            refocusUnderCursor()
            hyprLog(.notice, .lifecycle, "scratchpad: last member closed — layer dropped")
            return
        }
        retileLayer()
        if focusedGone { refocusMember(reason: "scratchpad-member-closed") } else { restackLayer() }
        updatePositionCache()
        hyprLog(.notice, .lifecycle, "scratchpad: members gone=\(goneMembers.sorted()) back=\(back.map(\.windowID).sorted()) — layer re-laid")
    }
    var members: Set<CGWindowID> { workspaceManager.windowIDs(onWorkspace: Self.workspace) }
    func contains(_ id: CGWindowID) -> Bool {
        workspaceManager.workspaceFor(id) == Self.workspace
    }
    func isSummoned(_ id: CGWindowID) -> Bool { summonedIDs.contains(id) }
    func ownsPID(_ pid: pid_t) -> Bool {
        stateCache.windowOwners.contains { $0.value == pid && contains($0.key) }
    }
    /// A member is tiled when it's on ws 0 and NOT in the floating set —
    /// no separate membership set, tiled-ness is derived state.
    private func isTiled(_ id: CGWindowID) -> Bool {
        contains(id) && !stateCache.floatingWindowIDs.contains(id)
    }

    init(workspaceManager: WorkspaceManager,
         stateCache: WindowStateCache,
         accessibility: AccessibilityManager,
         displayManager: DisplayManager,
         tilingEngine: TilingEngine,
         focusController: FocusStateController,
         focusBorder: FocusBorder,
         suppressions: SuppressionRegistry) {
        self.workspaceManager = workspaceManager
        self.stateCache = stateCache
        self.accessibility = accessibility
        self.displayManager = displayManager
        self.tilingEngine = tilingEngine
        self.focusController = focusController
        self.focusBorder = focusBorder
        self.suppressions = suppressions
    }

    // MARK: - toggle / show / hide

    func toggle() {
        if isVisible { hide(reason: .toggle) } else { show() }
    }

    func show(focusing preferredID: CGWindowID? = nil) {
        if isVisible {
            if let preferredID, let w = stateCache.cachedWindows[preferredID] {
                w.focus()
                noteFocus(preferredID)
                focusController.recordFocus(preferredID, reason: "scratchpad-refocus")
            }
            return
        }
        let ids = members
        guard !ids.isEmpty else {
            NSSound.beep()
            hyprLog(.notice, .lifecycle, "scratchpad toggle: empty — nothing to show")
            return
        }
        suppressions.suppress("workspace-transition", for: 1.5)
        suppressions.suppress("activation-switch", for: 0.5)
        suppressions.suppress("mouse-focus", for: 0.15)
        focusBeforeShow = focusController.lastFocusedID
        shownAt = Date()
        workspaceManager.scratchpadVisible = true

        // ordering is load-bearing: within the normal level, stacking is
        // recency, so the scrim must be above the tiles before the members
        // are raised above the scrim. fine that summonedIDs isn't populated
        // yet — the scrim no longer needs member rects.
        raiseScrim()

        var windowsByID: [CGWindowID: HyprWindow] = [:]
        for w in accessibility.getAllWindows() where ids.contains(w.windowID) {
            windowsByID[w.windowID] = w
        }
        // minimized / app-hidden members are absent from AX — they stay
        // parked members but don't join the summoned set
        summonedIDs = Set(windowsByID.keys)
        mruOrder = mruOrder.filter { windowsByID[$0] != nil }
        for id in windowsByID.keys.sorted() where !mruOrder.contains(id) { mruOrder.append(id) }
        if let preferredID, mruOrder.contains(preferredID) { noteFocus(preferredID) }

        // the monitor the layer lives on for this show. tiled region and
        // retiles key off this; captured now so a later cursor move doesn't
        // move the region out from under the tree.
        let targetScreen = screenUnderCursor() ?? displayManager.screens.first
        shownScreen = targetScreen
        let targetRect = targetScreen.map { displayManager.cgRect(for: $0) }

        // tile the tiled members first — the engine's setFrames ARE the unpark.
        // done before the floating raise loop so the region rects are fresh.
        // rejects (no fitting slot — layer tree full or window min-size too
        // big for the region) fall back to floating members BEFORE the
        // floating placement loop below, which then places them from their
        // saved free-form frame.
        let tiledRegionRect = targetScreen.map { tiledRegion(on: $0) }
        if let targetScreen, let tiledRegionRect {
            let tiledMembers = summonedIDs.filter { isTiled($0) }.compactMap { windowsByID[$0] }
            if !tiledMembers.isEmpty {
                let rejects = tilingEngine.tileScratchpad(tiledMembers, screen: targetScreen, in: tiledRegionRect)
                for w in rejects {
                    stateCache.floatingWindowIDs.insert(w.windowID)
                    w.isFloating = true
                    hyprLog(.notice, .lifecycle, "scratchpad show: no slot for '\(w.title ?? "?")' (\(w.windowID)) — falls back to floating")
                }
            }
        }

        // place FLOATING members from the saved (intended) frame, not a live AX
        // read — reads lag the park write. tiled members skip setFrame (the
        // tile pass already placed them). unpark + raise back-to-front so the
        // MRU head lands on top; raise every summoned member either way.
        for id in mruOrder.reversed() {
            guard let w = windowsByID[id] else { continue }
            if !isTiled(id) {
                let base = workspaceManager.savedFloatingFrame(for: id) ?? w.frame ?? .zero
                workspaceManager.clearSavedFloatingFrame(for: id)
                if base != .zero {
                    let carried = targetRect.map { carriedRect(base, to: $0) } ?? base
                    lastShownFrames[id] = w.placeFloating(carried, reason: "scratchpad show",
                                                          on: targetScreen,
                                                          displayManager: displayManager)
                }
            }
            w.raise()
        }

        // bare AXRaise can't lift a background app's window above another
        // app's tiles on Tahoe — only app activation reorders across apps
        // (which is why Hypr+F used to rescue buried members one at a time).
        // activate every non-head member app back-to-front; head.focus()
        // below activates the head's app last so the MRU head ends frontmost.
        let headPID = mruOrder.first.flatMap { windowsByID[$0]?.ownerPID }
        var activatedPIDs = Set<pid_t>()
        for id in mruOrder.reversed() {
            guard let w = windowsByID[id] else { continue }
            let pid = w.ownerPID
            guard pid != headPID, !activatedPIDs.contains(pid) else { continue }
            activatedPIDs.insert(pid)
            // activation brings the app's main window forward. make that the
            // member, not one of the app's windows on the workspace behind
            w.makeMain()
            suppressions.expectActivation(of: pid)
            NSRunningApplication(processIdentifier: pid)?
                .activate(options: [.activateIgnoringOtherApps])
        }

        // record the engine's intended region rects for the summoned tiled
        // members — handleMouseDown containment and eject geometry read
        // lastShownFrames.
        if let targetScreen, let tiledRegionRect {
            let intended = tilingEngine.scratchpadTileRects(screen: targetScreen, in: tiledRegionRect)
            for id in summonedIDs where isTiled(id) {
                if let r = intended[id] { lastShownFrames[id] = r }
            }
        }

        if let headID = mruOrder.first, let head = windowsByID[headID] {
            head.focus()
            focusController.recordFocus(headID, reason: "scratchpad-show")
            updateFocusBorder(head)
        }
        updatePositionCache()
        hyprLog(.notice, .lifecycle, "scratchpad shown (\(summonedIDs.count) windows)")

        // settle passes: activations land async, and orderFrontRegardless'd
        // scrim panels can beat even an activation reorder. repeatedly tuck
        // the scrim directly below the backmost member until the stack
        // converges — idempotent, own windows only, no activation churn.
        // the first pass lands right after head.focus() re-asserts (50 ms),
        // so a member left under the previously active app is lifted at once
        for delay in [0.07, 0.15, 0.45, 0.9] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.settleScrimBelowMembers()
            }
        }
    }

    func hide(reason: DismissReason) {
        guard isVisible else { return }
        suppressions.suppress("workspace-transition", for: 1.5)
        let ids = members
        let parkScreen = displayManager.screens.first
        for w in accessibility.getAllWindows() where ids.contains(w.windowID) {
            savePlacementAndPark(w, parkScreen: parkScreen)
        }
        workspaceManager.scratchpadVisible = false
        summonedIDs = []
        lastShownFrames = [:]
        shownScreen = nil
        updatePositionCache()
        if reason == .toggle, focusBeforeShow != 0,
           let prev = stateCache.cachedWindows[focusBeforeShow] {
            prev.focusWithoutRaise()
            focusController.recordFocus(focusBeforeShow, reason: "scratchpad-dismiss")
            updateFocusBorder(prev)
        }
        focusBeforeShow = 0
        hyprLog(.notice, .lifecycle, "scratchpad hidden (\(reason.rawValue))")
    }

    /// Save the live frame when trustworthy, fall back to the frame we
    /// placed at show time when the AX read is still stale (the off-screen
    /// guard in saveFloatingFrame rejects park-corner reads), then park.
    private func savePlacementAndPark(_ w: HyprWindow, parkScreen: NSScreen?) {
        let id = w.windowID
        // tiled member: the tile slot is transient — its savedFloatingFrame
        // still holds the pre-tile free-form frame for toggle-back, so DON'T
        // overwrite it with the slot rect. re-show re-tiles from the ws-0 tree,
        // not from savedFloatingFrame. just park it.
        if !isTiled(id) {
            workspaceManager.saveFloatingFrame(w)
            if workspaceManager.savedFloatingFrame(for: id) == nil,
               let intended = lastShownFrames[id] {
                workspaceManager.setSavedFloatingFrame(intended, for: id)
            }
        }
        if let parkScreen { workspaceManager.hideInCorner(w, on: parkScreen) }
    }

    // MARK: - send / eject

    /// Hypr+Shift+S. Symmetric toggle: sends the focused window into the
    /// scratchpad, or — on a window that's already summoned — takes it back
    /// out into tiling. Shift+S and Shift+N are the only exits; Hypr+T
    /// never removes membership. The scratchpad is a place windows go and
    /// return from, not a hold pen.
    func sendFocusedWindow() {
        guard let focused = currentFocusedWindow() else {
            NSSound.beep()
            return
        }
        let id = focused.windowID
        // a preview always floats and never joins the layer's tree
        guard !focused.isQuickLookPanel else {
            NSSound.beep()
            return
        }
        if isSummoned(id) {
            _ = ejectFocusedWindow()
            return
        }
        let entryMode = Self.entryMode(isExistingMember: contains(id),
                                       tileByDefault: tileNewMembers && !isNeverTile(focused))
        if entryMode == .preserve {
            // parked member (layer hidden, or minimized through a show) —
            // already where it belongs
            NSSound.beep()
            return
        }
        let frameBeforeSend = focused.frame
        let wasFloating = stateCache.floatingWindowIDs.contains(id)
        let sourceScreen = displayManager.screen(for: focused) ?? screenUnderCursor()
        let sourceWs = sourceScreen.flatMap { screen -> Int? in
            workspaceManager.isMonitorDisabled(screen) ? nil : workspaceManager.workspaceForScreen(screen)
        }
        animatedRetile({ [weak self] in
            guard let self else { return }
            if !wasFloating, let ws = sourceWs {
                tilingEngine.removeWindow(focused, fromWorkspace: ws)
            }
            workspaceManager.assignWindow(id, toWorkspace: Self.workspace)
            if entryMode == .tiled {
                // tile-by-default: the member enters the layer tree. save
                // the pre-send frame first — it's the restore target for a
                // later tiled→floating toggle (and the placement fallback
                // if the tile is rejected).
                saveFreeFormFrame(focused, fallback: frameBeforeSend)
                stateCache.floatingWindowIDs.remove(id)
                focused.isFloating = false
                if isVisible {
                    summonedIDs.insert(id)
                    if !tileIntoVisibleLayer(focused) {
                        // no fitting slot — stays a floating member
                        stateCache.floatingWindowIDs.insert(id)
                        focused.isFloating = true
                        if let f = frameBeforeSend { lastShownFrames[id] = f }
                        hyprLog(.notice, .lifecycle, "scratchpad send: no slot for '\(focused.title ?? "?")' (\(id)) — floating instead")
                    }
                } else if let screen = displayManager.screens.first {
                    // parked as a tiled member; the next show() tiles it
                    workspaceManager.hideInCorner(focused, on: screen)
                }
            } else {
                stateCache.floatingWindowIDs.insert(id)
                focused.isFloating = true
                if isVisible {
                    summonedIDs.insert(id)
                    if let f = frameBeforeSend { lastShownFrames[id] = f }
                } else {
                    saveFreeFormFrame(focused, fallback: frameBeforeSend)
                    if let screen = displayManager.screens.first {
                        workspaceManager.hideInCorner(focused, on: screen)
                    }
                }
            }
            noteFocus(id)
        }, { [weak self] in
            guard let self else { return }
            if isVisible {
                focused.raise()
                focusController.recordFocus(id, reason: "scratchpad-send")
            } else {
                if let frameBeforeSend {
                    focusBorder.flashInfo(message: "→ scratchpad", around: frameBeforeSend,
                                          windowID: id)
                }
                refocusUnderCursor()
            }
            updatePositionCache()
        })
        hyprLog(.notice, .lifecycle, "sent '\(focused.title ?? "?")' (\(id)) to scratchpad")
    }

    /// Overflow buffer: adopt a window that failed to fit its workspace's
    /// BSP tree as a FLOATING scratchpad member. Unlike sendFocusedWindow
    /// this never steals focus or MRU head — it's not a user-summon, the
    /// window just spilled here. `preferredFrame` is the pre-tile original
    /// frame the fit-failure site wants restored; falls back to the live
    /// frame. No updatePositionCache — onAutoFloat fires mid-tile-pass, the
    /// caller's post-pass refresh covers it.
    func adopt(_ window: HyprWindow, preferredFrame: CGRect? = nil) {
        let id = window.windowID
        guard !contains(id) else { return }
        let frameBefore = window.frame

        stateCache.floatingWindowIDs.insert(id)
        window.isFloating = true
        workspaceManager.assignWindow(id, toWorkspace: Self.workspace)

        // saved frame for a later summon: prefer the pre-tile original, then
        // the live frame. use the unconditional setter when saveFloatingFrame
        // refuses (off-screen guard) so the frame is never lost.
        if let preferredFrame {
            workspaceManager.setSavedFloatingFrame(preferredFrame, for: id)
        } else {
            workspaceManager.saveFloatingFrame(window)
            if workspaceManager.savedFloatingFrame(for: id) == nil, let f = frameBefore {
                workspaceManager.setSavedFloatingFrame(f, for: id)
            }
        }

        if isVisible {
            summonedIDs.insert(id)
            if let f = frameBefore { lastShownFrames[id] = f }
            window.raise()
        } else {
            if let screen = displayManager.screens.first {
                workspaceManager.hideInCorner(window, on: screen)
            }
            if let f = frameBefore {
                focusBorder.flashInfo(message: "→ scratchpad", around: f, windowID: id)
            }
        }

        // appended at END — not a user summon, don't steal the MRU head.
        if !mruOrder.contains(id) { mruOrder.append(id) }
        hyprLog(.notice, .lifecycle, "scratchpad: adopted overflow '\(window.title ?? "?")' (\(id))")
    }

    /// Leave the scratchpad for good — dismiss the layer and tile the
    /// focused member into the workspace visible on the monitor it sits
    /// on. The exit behind Hypr+Shift+S, and the first step of a
    /// move-to-workspace out of the scratchpad. Returns false when the
    /// focused window isn't an ejectable summoned member.
    func ejectFocusedWindow() -> Bool {
        guard isVisible,
              let focused = currentFocusedWindow(),
              isSummoned(focused.windowID) else { return false }
        let id = focused.windowID
        let rect = lastShownFrames[id] ?? focused.frame
        let screen = rect.flatMap { displayManager.screen(at: CGPoint(x: $0.midX, y: $0.midY)) }
            ?? screenUnderCursor()
        guard let screen, !workspaceManager.isMonitorDisabled(screen) else { return false }
        let targetWs = workspaceManager.workspaceForScreen(screen)

        // tiled member: pull it out of the ws-0 tree before reassigning, else
        // a ghost node lingers in the layer tree after the eject.
        if isTiled(id) {
            tilingEngine.removeWindow(focused, fromWorkspace: Self.workspace)
        }

        // a floating member of a never-tile app leaves the layer floating
        let staysFloating = isNeverTile(focused)

        // drop membership first so hide() parks only the remaining members
        summonedIDs.remove(id)
        mruOrder.removeAll { $0 == id }
        lastShownFrames.removeValue(forKey: id)
        workspaceManager.clearSavedFloatingFrame(for: id)
        workspaceManager.assignWindow(id, toWorkspace: targetWs)
        hide(reason: .workspaceAction)

        animatedRetile({ [weak self] in
            guard let self, !staysFloating else { return }
            stateCache.floatingWindowIDs.remove(id)
            focused.isFloating = false
        }, { [weak self] in
            guard let self else { return }
            focused.focusWithoutRaise()
            focusController.recordFocus(id, reason: "scratchpad-eject")
            updateFocusBorder(focused)
            updatePositionCache()
        })
        hyprLog(.notice, .lifecycle, "scratchpad: ejected '\(focused.title ?? "?")' (\(id)) → ws\(targetWs)")
        return true
    }

    /// Hypr+T on a summoned member: toggle it between floating and
    /// tiled-within-the-layer. Membership is untouched either way — the
    /// member stays on ws 0. Returns true when the focused window was a
    /// summoned member and the toggle was handled (including a rejected
    /// float→tile, which flashes rather than changing state).
    func toggleTilingOfFocusedMember() -> Bool {
        guard isVisible,
              let focused = currentFocusedWindow(),
              isSummoned(focused.windowID) else { return false }
        let id = focused.windowID
        guard let screen = layerScreen() else { return false }

        if isTiled(id) {
            // tiled → floating: pull it out of the ws-0 tree, restore the
            // pre-tile free-form frame, then close the gap left behind.
            tilingEngine.removeWindow(focused, fromWorkspace: Self.workspace)
            stateCache.floatingWindowIDs.insert(id)
            focused.isFloating = true
            let full = displayManager.cgRect(for: screen)
            let base = workspaceManager.savedFloatingFrame(for: id) ?? focused.frame ?? .zero
            if base != .zero {
                lastShownFrames[id] = focused.placeFloating(carriedRect(base, to: full),
                                                            reason: "scratchpad untile",
                                                            on: screen,
                                                            displayManager: displayManager)
            }
            retileLayer()
            focused.raise()
            focused.focus()
            focusController.recordFocus(id, reason: "scratchpad-untile")
            updateFocusBorder(focused)
            noteFocus(id)
            updatePositionCache()
            hyprLog(.notice, .lifecycle, "scratchpad: untiled '\(focused.title ?? "?")' (\(id)) → floating")
            return true
        }

        if isNeverTile(focused) {
            if let f = focused.frame {
                focusBorder.flashError(around: f, windowID: id, window: focused,
                                       message: FloatingAdmissionPolicy.neverTileMessage)
            } else {
                NSSound.beep()
            }
            hyprLog(.notice, .lifecycle, "scratchpad: tile refused for never-tile app '\(focused.title ?? "?")' (\(id))")
            return true
        }

        // floating → tiled. save the current free-form frame first so the
        // reverse toggle restores it (belt-and-suspenders: fall back to the
        // live frame when the off-screen guard in saveFloatingFrame refuses).
        saveFreeFormFrame(focused, fallback: focused.frame)
        stateCache.floatingWindowIDs.remove(id)
        focused.isFloating = false

        if !tileIntoVisibleLayer(focused) {
            // layer tree is full — revert to floating and flash. deliberately
            // no onAutoFloat: a scratchpad reject must never route into adopt.
            stateCache.floatingWindowIDs.insert(id)
            focused.isFloating = true
            if let f = focused.frame {
                focusBorder.flashError(around: f, windowID: id, window: focused)
            } else {
                NSSound.beep()
            }
            hyprLog(.notice, .lifecycle, "scratchpad: tile rejected (layer full) for '\(focused.title ?? "?")' (\(id)) — stays floating")
            return true
        }
        focused.focus()
        focusController.recordFocus(id, reason: "scratchpad-tile")
        updateFocusBorder(focused)
        noteFocus(id)
        updatePositionCache()
        hyprLog(.notice, .lifecycle, "scratchpad: tiled '\(focused.title ?? "?")' (\(id)) into layer")
        return true
    }

    /// Hypr+Shift+T while the layer is up: rotate focus across the summoned
    /// members only (stable id order — MRU is not reshuffled by cycling).
    func cycleSummoned() {
        guard isVisible else { return }
        let order = summonedIDs.sorted().filter { stateCache.cachedWindows[$0] != nil }
        guard !order.isEmpty else { return }
        let idx = order.firstIndex(of: focusController.lastFocusedID)
            .map { ($0 + 1) % order.count } ?? 0
        guard let w = stateCache.cachedWindows[order[idx]] else { return }
        w.focus()
        focusController.recordFocus(order[idx], reason: "scratchpad-cycle")
        updateFocusBorder(w)
    }

    // MARK: - dismissal triggers (wired from WindowManager)

    /// Global left-mouse-down while visible: a click inside a summoned
    /// member keeps the layer (and bumps MRU); anything else dismisses in
    /// the same runloop tick so the click lands on the tile it was aimed
    /// at. Containment is judged against the placed frame as well as the
    /// live read — right after show() the live read still lags.
    func handleMouseDown(atCG point: CGPoint, synthetic: Bool) {
        guard isVisible else { return }
        // HyprMac's own clicks (hover focus) are never the user leaving.
        // a real click outside is, even during the show grace: the scrim
        // lets it through, and the window it lands on would take focus
        // with the layer still up
        guard !synthetic else { return }
        for id in summonedIDs {
            if let f = stateCache.cachedWindows[id]?.frame, f.contains(point) {
                noteFocus(id)
                return
            }
            if let f = lastShownFrames[id], f.contains(point) {
                noteFocus(id)
                return
            }
        }
        hide(reason: .clickOutside)
    }

    /// App activation while visible. Member apps and our own process keep
    /// the layer; anything else past the show-grace window dismisses it
    /// (Cmd-Tab, Dock click).
    func noteAppActivation(pid: pid_t, bundleID: String?) {
        guard isVisible else { return }
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        guard bundleID != "com.apple.dock" else { return }
        guard !ownsPID(pid) else {
            // a member app came forward, possibly with one of its windows
            // from the workspace behind
            restackLayer()
            return
        }
        guard Date().timeIntervalSince(shownAt) > showGraceSec else { return }
        hide(reason: .activationChange)
    }

    /// Discovery forgot this id (app died). Called after WorkspaceManager
    /// dropped the assignment, so `members` already excludes it.
    func forget(_ id: CGWindowID) {
        let wasSummoned = summonedIDs.contains(id)
        mruOrder.removeAll { $0 == id }
        summonedIDs.remove(id)
        lastShownFrames.removeValue(forKey: id)
        // sweep the id from the ws-0 tree in case it was a tiled member. safe
        // and idempotent — a no-op when WindowManager's gone-path already
        // removed it (which it does via removeWindowID on goneIDs).
        tilingEngine.removeWindowID(id)
        if isVisible && summonedIDs.isEmpty {
            workspaceManager.scratchpadVisible = false
            lastShownFrames = [:]
            shownScreen = nil
            updatePositionCache()
            refocusUnderCursor()
            hyprLog(.notice, .lifecycle, "scratchpad: last summoned member gone — layer dropped")
        } else if isVisible && wasSummoned {
            // a tiled member may have died — close the gap in the layer tree.
            retileLayer()
            // the focused member closed: focus the next member before macOS
            // promotes the app's next window, which may sit under the scrim
            if focusController.lastFocusedID == id || focusBorder.trackedWindowID == id {
                refocusMember(reason: "scratchpad-member-gone")
            }
            updatePositionCache()
        }
    }

    func noteFocus(_ id: CGWindowID) {
        guard contains(id) else { return }
        mruOrder.removeAll { $0 == id }
        mruOrder.insert(id, at: 0)
    }

    // MARK: - helpers

    /// Find the backmost summoned member in the live level-0 z-order and
    /// order the scrim panels directly below it: members lit above the
    /// scrim, tiles dimmed below — regardless of who won the raise races.
    private func settleScrimBelowMembers() {
        guard isVisible, !summonedIDs.isEmpty else { return }
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var backmost: CGWindowID?
        // managed windows of a regular workspace seen so far, front to back.
        // one that overlaps a member further down is on top of it, and the
        // scrim, tucked under the backmost member, would leave it lit there
        var above: [(id: CGWindowID, bounds: CGRect)] = []
        var covered: [CGWindowID: [CGWindowID]] = [:]
        for w in info {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init),
                  pid != ownPID else { continue }
            let bounds = (w[kCGWindowBounds as String] as? NSDictionary)
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            // front→back list: the last summoned id seen is the backmost
            if summonedIDs.contains(id) {
                backmost = id
                let over = above.filter { $0.bounds.intersects(bounds) }.map(\.id)
                if !over.isEmpty { covered[id] = over }
            } else if let ws = workspaceManager.workspaceFor(id), ws != Self.workspace {
                // unmanaged windows (a member app's settings panel, system
                // panels) are left where they are
                above.append((id, bounds))
            }
        }
        if !covered.isEmpty {
            let desc = covered.keys.sorted().map { "\($0) under \(covered[$0] ?? [])" }.joined(separator: ", ")
            hyprLog(.notice, .lifecycle, "scratchpad: \(desc) — raising members")
            raiseMembers()
            enforceFocus()
        }
        if let backmost { lowerScrimBelow(backmost) }
    }

    /// Raise every member back to front: tiled under floating, the most
    /// recent last within each. AXRaise only reorders another app's windows
    /// for the frontmost app, so while a non-member app is frontmost (the
    /// window under the cursor when the layer came up, say) the head's app
    /// is activated first. A member only its app's main window came forward
    /// with stays under that app until then.
    private func raiseMembers() {
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           !memberPIDs.contains(front) {
            focusTarget?.focus()
        }
        let ordered = mruOrder.reversed().filter { summonedIDs.contains($0) }
        for id in ordered.filter({ isTiled($0) }) + ordered.filter({ !isTiled($0) }) {
            stateCache.cachedWindows[id]?.raise()
        }
    }

    /// Keystrokes belong to a member while the layer is up. An app can move
    /// focus on its own to one of its windows on the workspace behind
    /// (Cmd-`, a Dock click, a promoted window); pull it back to a member.
    /// Unmanaged windows (menus, panels, settings) are left alone.
    func enforceFocus() {
        guard isVisible, Date().timeIntervalSince(shownAt) > showGraceSec,
              let focused = accessibility.getFocusedWindow(),
              !summonedIDs.contains(focused.windowID),
              let ws = workspaceManager.workspaceFor(focused.windowID), ws != Self.workspace else { return }
        hyprLog(.notice, .focus, "scratchpad: focus escaped to '\(focused.title ?? "?")' (\(focused.windowID)) on ws\(ws)")
        refocusMember(reason: "scratchpad-focus-escaped")
    }

    /// Owners of the members on screen.
    private var memberPIDs: Set<pid_t> {
        Set(summonedIDs.compactMap { stateCache.windowOwners[$0] })
    }

    /// Re-run the stacking settle a few times. Activations and raises land
    /// asynchronously, so one pass can run before the reorder it answers.
    func restackLayer() {
        for delay in [0.05, 0.3, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.settleScrimBelowMembers()
            }
        }
    }

    /// The monitor the tiled region and layer retiles key off. Prefers the
    /// screen captured at show time; falls back to the cursor's screen.
    private func layerScreen() -> NSScreen? {
        shownScreen ?? screenUnderCursor() ?? displayManager.screens.first
    }

    /// Inset layout rect for the tiled region on `screen`. The clamp
    /// guards a hand-edited config — an inset ≥ 0.5 would invert the rect.
    private func tiledRegion(on screen: NSScreen) -> CGRect {
        let full = displayManager.cgRect(for: screen)
        let inset = min(max(tiledRegionInset, 0), 0.4)
        return full.insetBy(dx: full.width * inset,
                            dy: full.height * inset)
    }

    /// Persist the window's free-form frame for a later summon/untile:
    /// prefer the live AX read (saveFloatingFrame's off-screen guard
    /// rejects park slivers), fall back to `fallback` when it refuses.
    private func saveFreeFormFrame(_ w: HyprWindow, fallback: CGRect?) {
        workspaceManager.saveFloatingFrame(w)
        if workspaceManager.savedFloatingFrame(for: w.windowID) == nil, let f = fallback {
            workspaceManager.setSavedFloatingFrame(f, for: w.windowID)
        }
    }

    /// Insert an already-non-floating summoned member into the visible
    /// layer's tree, re-lay the region, and refresh intended rects for
    /// every tiled member. Returns false when the tree has no fitting
    /// slot — the caller reverts the member to floating. Deliberately
    /// never routes through onAutoFloat (see tileScratchpad).
    private func tileIntoVisibleLayer(_ window: HyprWindow) -> Bool {
        guard let screen = layerScreen() else { return false }
        let region = tiledRegion(on: screen)
        var tiledMembers = summonedIDs.filter { isTiled($0) }.compactMap { stateCache.cachedWindows[$0] }
        if !tiledMembers.contains(where: { $0.windowID == window.windowID }) {
            tiledMembers.append(window)
        }
        let rejects = tilingEngine.tileScratchpad(tiledMembers, screen: screen, in: region)
        if rejects.contains(where: { $0.windowID == window.windowID }) { return false }
        let intended = tilingEngine.scratchpadTileRects(screen: screen, in: region)
        for m in summonedIDs where isTiled(m) {
            if let r = intended[m] { lastShownFrames[m] = r }
        }
        return true
    }

    /// Live re-layout after a region-inset change from Settings. No-op
    /// while hidden — the next show() reads the new inset.
    func relayoutVisibleLayer() {
        guard isVisible else { return }
        retileLayer()
        updatePositionCache()
    }

    /// Re-run the layer's ws-0 tree against its current tiled members and
    /// refresh `lastShownFrames` for the summoned tiled ids from the
    /// engine's intended rects. No-op when the layer isn't visible.
    private func retileLayer() {
        guard isVisible, let screen = layerScreen() else { return }
        let region = tiledRegion(on: screen)
        let tiledMembers: [HyprWindow] = summonedIDs
            .filter { isTiled($0) }
            .compactMap { stateCache.cachedWindows[$0] }
        tilingEngine.tileScratchpad(tiledMembers, screen: screen, in: region)
        syncTiledFrames()
    }

    /// Re-read the tiled members' slots after the engine re-laid the layer
    /// (a retile, swap, resize or split toggle). Click containment and the
    /// eject read `lastShownFrames`.
    func syncTiledFrames() {
        guard isVisible, let screen = layerScreen() else { return }
        let rects = tilingEngine.scratchpadTileRects(screen: screen, in: tiledRegion(on: screen))
        for id in summonedIDs where isTiled(id) {
            if let r = rects[id] { lastShownFrames[id] = r }
        }
    }

    /// Pure carry math on the intended rect: keep it when it already sits
    /// substantially on the target screen, otherwise clamp it in with size
    /// preserved (same semantics as the orchestrator's floater carry).
    private func carriedRect(_ base: CGRect, to target: CGRect) -> CGRect {
        if base.isSubstantiallyVisible(on: target, threshold: 0.5) { return base }
        let width = min(base.width, target.width)
        let height = min(base.height, target.height)
        let x = max(target.minX, min(base.origin.x, target.maxX - width))
        let y = max(target.minY, min(base.origin.y, target.maxY - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
