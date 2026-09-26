// Floating-window lifecycle: tile/float toggle, cycle, raise-behind, and
// the auto-float predicate. Holds direct references to long-lived services
// and uses closure handles for the WM-side glue (animated retile, focus
// border refresh, position cache).

import Cocoa

enum FloatingAdmissionPolicy {
    enum Reason: String {
        case excludedApp = "excluded app"
        case fixedSize = "window is not resizable"
    }

    static func reason(isExcluded: Bool, isSizeSettable: Bool?) -> Reason? {
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

/// Bounds `raiseBehind` so it cannot fight the window server or its own
/// focus restore.
///
/// Keyed by the floater and the tile covering it. A raise that left the
/// floater covered (Tahoe often refuses a cross-app AXRaise) cools the pair
/// down. So does a raise that follows our own restore within `echoWindow`,
/// which is the raise → restore → activation → raise loop, and a burst of
/// raises for one pair from any cause.
struct RaiseBehindThrottle {
    struct Pair: Hashable, CustomStringConvertible {
        let floater: CGWindowID
        let tile: CGWindowID
        var description: String { "\(floater)/\(tile)" }
    }

    enum Decision: Equatable {
        case raise
        case cooldownStarted(reason: String, duration: TimeInterval)
        case coolingDown(reason: String, remaining: TimeInterval)
    }

    var ineffectiveCooldown: TimeInterval = 30
    var loopCooldown: TimeInterval = 15
    var burstCooldown: TimeInterval = 10
    var burstLimit = 4
    var burstWindow: TimeInterval = 5
    var echoWindow: TimeInterval = 1

    private var attempts: [Pair: [TimeInterval]] = [:]
    private var cooldowns: [Pair: (until: TimeInterval, reason: String)] = [:]
    private var restores: [Pair: TimeInterval] = [:]

    /// Decide one pair. A `.raise` counts as an attempt.
    mutating func decide(_ pair: Pair, now: TimeInterval) -> Decision {
        prune(now)
        if let cooldown = cooldowns[pair] {
            return .coolingDown(reason: cooldown.reason, remaining: cooldown.until - now)
        }
        if restores[pair] != nil {
            return startCooldown(pair, reason: "loop", for: loopCooldown, now: now)
        }
        let recent = attempts[pair, default: []]
        if recent.count >= burstLimit {
            return startCooldown(pair, reason: "burst", for: burstCooldown, now: now)
        }
        attempts[pair] = recent + [now]
        return .raise
    }

    mutating func noteIneffective(_ pair: Pair, now: TimeInterval) {
        cooldowns[pair] = (now + ineffectiveCooldown, "ineffective")
        attempts[pair] = nil
        restores[pair] = nil
    }

    mutating func noteRestore(_ pairs: [Pair], now: TimeInterval) {
        for pair in pairs { restores[pair] = now }
    }

    private mutating func startCooldown(_ pair: Pair, reason: String, for duration: TimeInterval,
                                        now: TimeInterval) -> Decision {
        cooldowns[pair] = (now + duration, reason)
        attempts[pair] = nil
        restores[pair] = nil
        return .cooldownStarted(reason: reason, duration: duration)
    }

    private mutating func prune(_ now: TimeInterval) {
        cooldowns = cooldowns.filter { $0.value.until > now }
        restores = restores.filter { now - $0.value < echoWindow }
        attempts = attempts.compactMapValues { times in
            let kept = times.filter { now - $0 < burstWindow }
            return kept.isEmpty ? nil : kept
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
    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    // the frontmost app's open popup in a list. WindowManager points this at
    // the mouse tracker so every guard ignores the same long-lived windows.
    var findPopup: ([StackedWindow], pid_t?) -> StackedWindow? = { windows, front in
        WindowStacking.openPopup(in: windows, frontmostPID: front, ownPID: getpid())
    }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var throttle = RaiseBehindThrottle()
    var isWindowSizeSettable: (HyprWindow) -> Bool? = { $0.isSizeSettable }
    // red flash on a float→tile the tree or the screen refused.
    var rejectFloatToTile: ((HyprWindow, TilingEngine.ForceInsertFailure) -> Void)?

    // same-stack-frame reentrancy guard for raiseBehind. paired with defer.
    // moved here from WindowManager (per §5.5 — not a SuppressionRegistry key).
    private var isRaising = false

    // time for the raise to land before checking the stack and the front app
    static let verifyDelay: TimeInterval = 0.05
    // a raise deferred by an open popup tries again this often, this many times
    static let popupRetryDelay: TimeInterval = 0.5
    static let popupRetryLimit = 20
    private var popupRetryPending = false
    private var popupRetries = 0
    private var lastDeferredPopupID: CGWindowID = 0

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

    /// Lift floating windows that a tile covers back above it.
    ///
    /// Runs after app activation and after each discovery pass. It stays
    /// out of the way of the user:
    /// - it does nothing while a menu tracks, the scratchpad is up, or the
    ///   frontmost app has a popup-level window open (a raise or a focus
    ///   restore would dismiss it). An open popup defers the raise and
    ///   retries shortly after.
    /// - floating siblings of the focused tile's app are left alone, because
    ///   restoring focus in that app can put the tile back above them.
    /// - `throttle` cools a floater/tile pair down after a raise that did not
    ///   lift the floater, after a raise that follows our own restore, and
    ///   after a burst.
    ///
    /// A moment after raising it checks the stack. Focus goes back to the
    /// focused tile only when the raise moved the front app away from it
    /// (some apps activate themselves when raised), and it goes back
    /// through `restoreFocusWithoutRaise`, which does not lift the tile.
    func raiseBehind() {
        guard !isRaising else { return }
        // scratchpad is quasimodal: it owns the level-0 stack (scrim below,
        // members raised above) and the post-raise focus restore would
        // pull focus onto a background tiled window and dismiss the layer.
        guard !isScratchpadVisible() else { return }
        // skip while a native menu is tracking — the focus restore
        // synthesizes key-focus events that dismiss context menus.
        guard !isMenuTracking() else { return }
        guard stateCache.floatingWindowIDs.contains(where: workspaceManager.isWindowVisible) else { return }
        isRaising = true
        defer { isRaising = false }

        guard let windows = windowListForZOrder().map(WindowStacking.decode) else { return }
        let previousFocusID = focusController.lastFocusedID
        let previousFocusGeneration = focusController.generation
        let previousWindow = stateCache.cachedWindows[previousFocusID]
        let focusedTiledPID = previousWindow.flatMap {
            stateCache.floatingWindowIDs.contains($0.windowID) ? nil : $0.ownerPID
        }
        // safari can reorder a floating sibling when focus returns to its tile
        let candidates = coveredFloaters(in: windows).filter { pair in
            guard let floater = stateCache.cachedWindows[pair.floater] else { return false }
            guard let focusedTiledPID else { return true }
            return floater.ownerPID != focusedTiledPID
        }
        guard !candidates.isEmpty else { return }

        let frontBefore = frontmostPID()
        if let popup = findPopup(windows, frontBefore) {
            deferForPopup(popup)
            return
        }
        popupRetries = 0
        lastDeferredPopupID = 0

        let now = self.now()
        var pairs: [RaiseBehindThrottle.Pair] = []
        for pair in candidates {
            switch throttle.decide(pair, now: now) {
            case .raise:
                pairs.append(pair)
            case let .cooldownStarted(reason, duration):
                hyprLog(.notice, .floating, "raise behind cooldown: pair=\(pair) reason=\(reason) for \(Int(duration))s")
            case let .coolingDown(reason, remaining):
                hyprLog(.debug, .floating, "raise behind cooling: pair=\(pair) reason=\(reason) \(String(format: "%.1f", remaining))s left")
            }
        }
        guard !pairs.isEmpty else { return }

        suppressions.suppress("activation-switch", for: 0.5)
        suppressions.suppress("mouse-focus", for: 0.15)

        hyprLog(.notice, .floating, "raise behind: wids=\(pairs.map(\.floater)) under=\(pairs.map(\.tile)) "
                + "focus=\(previousFocusID) front=\(frontBefore.map(String.init) ?? "nil")")
        for pair in pairs {
            guard let w = stateCache.cachedWindows[pair.floater] else { continue }
            let rc = performRaise(w)
            if rc != .success {
                hyprLog(.notice, .floating, "raise behind failed: wid=\(pair.floater) rc=\(rc.rawValue)")
            }
        }

        scheduleAfter(Self.verifyDelay) { [weak self] in
            self?.finishRaise(pairs, frontBefore: frontBefore, previousFocusID: previousFocusID,
                              previousFocusGeneration: previousFocusGeneration,
                              previousWindow: previousWindow)
        }
    }

    /// Check what the raise did, cool down pairs it could not lift, and
    /// give focus back to the tile only if the raise took it away.
    private func finishRaise(_ pairs: [RaiseBehindThrottle.Pair], frontBefore: pid_t?,
                             previousFocusID: CGWindowID, previousFocusGeneration: UInt64,
                             previousWindow: HyprWindow?) {
        let windows = windowListForZOrder().map(WindowStacking.decode)
        let now = self.now()
        if let windows {
            let stillCovered = Dictionary(coveredFloaters(in: windows).map { ($0.floater, $0.tile) },
                                          uniquingKeysWith: { first, _ in first })
            for pair in pairs {
                guard let tile = stillCovered[pair.floater] else { continue }
                throttle.noteIneffective(pair, now: now)
                hyprLog(.notice, .floating, "raise behind ineffective: wid=\(pair.floater) still under \(tile) "
                        + "— cooldown \(Int(throttle.ineffectiveCooldown))s")
            }
        }

        guard let prev = previousWindow, !stateCache.floatingWindowIDs.contains(prev.windowID) else { return }
        let frontAfter = frontmostPID()
        guard frontBefore == prev.ownerPID, frontAfter != frontBefore else {
            hyprLog(.notice, .floating, "raise behind kept focus: wid=\(previousFocusID) "
                    + "front=\(frontAfter.map(String.init) ?? "nil")")
            return
        }
        guard focusController.lastFocusedID == previousFocusID,
              focusController.generation == previousFocusGeneration,
              stateCache.knownWindowIDs.contains(previousFocusID),
              !stateCache.hiddenWindowIDs.contains(previousFocusID),
              workspaceManager.workspaceFor(previousFocusID) != nil,
              workspaceManager.isWindowVisible(previousFocusID),
              !isMenuTracking(), !isScratchpadVisible() else { return }
        // without a list there is no way to rule out an open menu
        guard let windows else { return }
        if let popup = findPopup(windows, frontAfter) {
            hyprLog(.notice, .floating, "raise behind restore skipped: popup wid=\(popup.windowID) layer=\(popup.layer)")
            return
        }
        hyprLog(.notice, .floating, "raise behind restore: wid=\(previousFocusID) "
                + "(front moved \(frontBefore.map(String.init) ?? "nil") → \(frontAfter.map(String.init) ?? "nil"))")
        throttle.noteRestore(pairs, now: now)
        restoreFocusWithoutRaise(prev)
        updateFocusBorder?(prev)
    }

    /// An open popup blocks the raise. Say so once per popup and try again
    /// shortly, a bounded number of times, so the floater comes back up
    /// after the menu closes.
    private func deferForPopup(_ popup: StackedWindow) {
        if popup.windowID != lastDeferredPopupID {
            lastDeferredPopupID = popup.windowID
            hyprLog(.notice, .floating, "raise behind deferred: popup wid=\(popup.windowID) "
                    + "pid=\(popup.ownerPID) layer=\(popup.layer)")
        }
        guard !popupRetryPending, popupRetries < Self.popupRetryLimit else { return }
        popupRetryPending = true
        popupRetries += 1
        scheduleAfter(Self.popupRetryDelay) { [weak self] in
            self?.popupRetryPending = false
            self?.raiseBehind()
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
            isSizeSettable: isWindowSizeSettable(window)
        )
    }

    // MARK: - z-order helper (used by raiseBehind + cross-checks)

    /// Floaters that a tile covers, paired with the frontmost tile that
    /// covers each one, read from the window list's z-order.
    ///
    /// Covered means the tile is stacked above the floater and the two
    /// overlap. A floater behind a tile it does not touch looks fine and
    /// is left alone. Frames come from the window list, or from AX and
    /// `tiledPositions` when the list has none.
    func coveredFloaters(in windows: [StackedWindow],
                         floatingWindowIDs: Set<CGWindowID>? = nil,
                         tiledPositions: [CGWindowID: CGRect]? = nil) -> [RaiseBehindThrottle.Pair] {
        let floaters = (floatingWindowIDs ?? stateCache.floatingWindowIDs)
            .filter { workspaceManager.isWindowVisible($0) }
        guard !floaters.isEmpty else { return [] }
        let tiles = tiledPositions ?? stateCache.tiledPositions

        var pairs: [RaiseBehindThrottle.Pair] = []
        for (index, entry) in windows.enumerated()
        where floaters.contains(entry.windowID) && entry.layer == 0 {
            guard let frame = entry.bounds
                    ?? stateCache.cachedWindows[entry.windowID].flatMap(windowFrameForZOrder) else { continue }
            let cover = windows[..<index].first { above in
                guard above.layer == 0, let rect = above.bounds ?? tiles[above.windowID],
                      tiles[above.windowID] != nil else { return false }
                return WindowStacking.overlaps(rect, frame)
            }
            if let cover {
                pairs.append(RaiseBehindThrottle.Pair(floater: entry.windowID, tile: cover.windowID))
            }
        }
        return pairs
    }

    /// Visible floaters a tile covers, read from the current window list.
    /// Empty when the list is unavailable: without z-order there is no
    /// evidence anything is covered.
    func floatingWindowsBehindTiled(
        floatingWindowIDs: Set<CGWindowID>,
        tiledPositions: [CGWindowID: CGRect]
    ) -> [CGWindowID] {
        guard let windows = windowListForZOrder().map(WindowStacking.decode) else { return [] }
        return coveredFloaters(in: windows, floatingWindowIDs: floatingWindowIDs,
                               tiledPositions: tiledPositions).map(\.floater)
    }

}
