// Scratchpad: a quasimodal layer of floating windows, parked off-screen by
// default and summoned on demand. Members live on pseudo-workspace 0 and in
// the floating set. Summoning IS raising — dismissal re-parks, so there is
// never a z-order to defend while the layer is down (the operation macOS
// forbids under SIP is designed out, not worked around).
//
// Two distinct id sets: `members` (assigned to ws 0, possibly parked) and
// `summonedIDs` (actually on screen right now). Every focus/carve/click
// decision consults summonedIDs so a parked member can never be raised or
// carved while the layer is up.
//
// Frame decisions never trust a live AX read taken right after a write —
// Tahoe AX reads lag writes by >1s. Show computes geometry from the saved
// (intended) frame; `lastShownFrames` remembers what we placed so hide can
// re-save it when the live read is still stale.

import Cocoa

final class ScratchpadController {

    /// Pseudo-workspace id for scratchpad membership. Outside 1...9, so it
    /// falls out of every switch / home-anchor / cycle path automatically.
    static let workspace = 0
    static let scrimIntensity: CGFloat = 0.45
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

    var isVisible: Bool { workspaceManager.scratchpadVisible }
    var members: Set<CGWindowID> { workspaceManager.windowIDs(onWorkspace: Self.workspace) }
    func contains(_ id: CGWindowID) -> Bool {
        workspaceManager.workspaceFor(id) == Self.workspace
    }
    func isSummoned(_ id: CGWindowID) -> Bool { summonedIDs.contains(id) }
    func ownsPID(_ pid: pid_t) -> Bool {
        stateCache.windowOwners.contains { $0.value == pid && contains($0.key) }
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

        // place from the saved (intended) frame, not a live AX read — reads
        // lag the park write. unpark + raise back-to-front so the MRU head
        // lands on top.
        let targetRect = (screenUnderCursor() ?? displayManager.screens.first)
            .map { displayManager.cgRect(for: $0) }
        for id in mruOrder.reversed() {
            guard let w = windowsByID[id] else { continue }
            let base = workspaceManager.savedFloatingFrame(for: id) ?? w.frame ?? .zero
            workspaceManager.clearSavedFloatingFrame(for: id)
            if base != .zero {
                let placed = targetRect.map { carriedRect(base, to: $0) } ?? base
                w.setFrame(placed)
                lastShownFrames[id] = placed
            }
            w.raise()
        }
        if let headID = mruOrder.first, let head = windowsByID[headID] {
            head.focus()
            focusController.recordFocus(headID, reason: "scratchpad-show")
            updateFocusBorder(head)
        }
        updatePositionCache()
        hyprLog(.notice, .lifecycle, "scratchpad shown (\(summonedIDs.count) windows)")
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
        workspaceManager.saveFloatingFrame(w)
        if workspaceManager.savedFloatingFrame(for: id) == nil,
           let intended = lastShownFrames[id] {
            workspaceManager.setSavedFloatingFrame(intended, for: id)
        }
        if let parkScreen { workspaceManager.hideInCorner(w, on: parkScreen) }
    }

    // MARK: - send / eject

    /// Hypr+Shift+S. Symmetric toggle: sends the focused window into the
    /// scratchpad, or — on a window that's already summoned — takes it back
    /// out into tiling (same exit as Hypr+Shift+T). The scratchpad is a
    /// place windows go and return from, not a hold pen.
    func sendFocusedWindow() {
        guard let focused = currentFocusedWindow() else {
            NSSound.beep()
            return
        }
        let id = focused.windowID
        if isSummoned(id) {
            _ = ejectFocusedWindow()
            return
        }
        if contains(id) {
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
            stateCache.floatingWindowIDs.insert(id)
            focused.isFloating = true
            workspaceManager.assignWindow(id, toWorkspace: Self.workspace)
            if isVisible {
                summonedIDs.insert(id)
                if let f = frameBeforeSend { lastShownFrames[id] = f }
            } else {
                workspaceManager.saveFloatingFrame(focused)
                if workspaceManager.savedFloatingFrame(for: id) == nil, let f = frameBeforeSend {
                    workspaceManager.setSavedFloatingFrame(f, for: id)
                }
                if let screen = displayManager.screens.first {
                    workspaceManager.hideInCorner(focused, on: screen)
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

    /// Leave the scratchpad for good — dismiss the layer and tile the
    /// focused member into the workspace visible on the monitor it sits
    /// on. The shared exit for Hypr+Shift+T and Hypr+Shift+S, and the
    /// first step of a move-to-workspace out of the scratchpad. Returns
    /// false when the focused window isn't an ejectable summoned member.
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

        // drop membership first so hide() parks only the remaining members
        summonedIDs.remove(id)
        mruOrder.removeAll { $0 == id }
        lastShownFrames.removeValue(forKey: id)
        workspaceManager.clearSavedFloatingFrame(for: id)
        workspaceManager.assignWindow(id, toWorkspace: targetWs)
        hide(reason: .workspaceAction)

        animatedRetile({ [weak self] in
            guard let self else { return }
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

    /// Hypr+F while the layer is up: rotate focus across the summoned
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
    func handleMouseDown(atCG point: CGPoint) {
        guard isVisible else { return }
        guard Date().timeIntervalSince(shownAt) > showGraceSec else { return }
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
        guard !ownsPID(pid) else { return }
        guard Date().timeIntervalSince(shownAt) > showGraceSec else { return }
        hide(reason: .activationChange)
    }

    /// Discovery forgot this id (app died). Called after WorkspaceManager
    /// dropped the assignment, so `members` already excludes it.
    func forget(_ id: CGWindowID) {
        mruOrder.removeAll { $0 == id }
        summonedIDs.remove(id)
        lastShownFrames.removeValue(forKey: id)
        if isVisible && summonedIDs.isEmpty {
            workspaceManager.scratchpadVisible = false
            lastShownFrames = [:]
            updatePositionCache()
            refocusUnderCursor()
            hyprLog(.notice, .lifecycle, "scratchpad: last summoned member gone — layer dropped")
        }
    }

    func noteFocus(_ id: CGWindowID) {
        guard contains(id) else { return }
        mruOrder.removeAll { $0 == id }
        mruOrder.insert(id, at: 0)
    }

    // MARK: - helpers

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
