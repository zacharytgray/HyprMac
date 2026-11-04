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

    /// Shown when the user tries to tile a window of an app in Never tile.
    static let neverTileMessage = "App not allowed to tile. Change it in Settings"
}

/// Every frame HyprMac writes to a floating window goes through here: the
/// workspace reveal, the carry to another screen, the float toggle, the
/// focus cycle, the scratchpad, the overflow float and the stop restore.
///
/// A floater dragged onto the ultrawide once grew far past the screen and
/// off its edge, and the notice log could not say whether HyprMac wrote
/// that frame. So each write logs its reason, both frames, both screens and
/// both backing scales, and none may leave the destination's usable frame:
/// a frame too big is shrunk to fit, one hanging off an edge is moved in.
/// Parking in the hide corner is a position-only write and does not come
/// through here.
enum FloatingFramePlacement {
    struct Plan: Equatable {
        /// the frame the caller asked for
        let requested: CGRect
        /// what is written: `requested` clamped into `usable`
        let target: CGRect
        let source: NSScreen?
        let destination: NSScreen?
        let usable: CGRect?
        var clamped: Bool { target != requested }
    }

    /// Where `frame` lands and what gets written. `screen` names the
    /// destination when the caller knows it; otherwise it is the screen
    /// holding most of `frame`.
    static func plan(_ frame: CGRect, from current: CGRect?, on screen: NSScreen?,
                     displayManager: DisplayManager) -> Plan {
        let destination = screen ?? displayManager.screen(containingMostOf: frame)
        let source = current.flatMap { displayManager.screen(containingMostOf: $0) }
        guard let destination else {
            return Plan(requested: frame, target: frame, source: source, destination: nil, usable: nil)
        }
        let usable = displayManager.cgRect(for: destination)
        return Plan(requested: frame, target: frame.clamped(into: usable), source: source,
                    destination: destination, usable: usable)
    }

    static func logLine(windowID: CGWindowID, reason: String, from current: CGRect?,
                        plan: Plan) -> String {
        var line = "floating frame write: wid=\(windowID) reason=\(reason)"
            + " from=\(current.map(describe) ?? "unread") on \(describe(plan.source))"
            + " to=\(describe(plan.target)) on \(describe(plan.destination))"
        if plan.clamped, let usable = plan.usable {
            line += " clamped from \(describe(plan.requested)) into usable \(describe(usable))"
        }
        return line
    }

    static func describe(_ screen: NSScreen?) -> String {
        guard let screen else { return "no screen" }
        return "'\(screen.localizedName)' @\(String(format: "%g", Double(screen.backingScaleFactor)))x"
    }

    static func describe(_ rect: CGRect) -> String {
        String(format: "(%g, %g, %g, %g)", Double(rect.minX), Double(rect.minY),
               Double(rect.width), Double(rect.height))
    }
}

extension HyprWindow {
    /// Write `frame` to this floating window through `FloatingFramePlacement`:
    /// clamped into the destination's usable frame, with a notice line.
    /// `current` is the frame the caller already read, if it has one.
    /// - Returns: the frame written.
    @discardableResult
    func placeFloating(_ frame: CGRect, reason: String, on screen: NSScreen? = nil,
                       from current: CGRect? = nil,
                       displayManager: DisplayManager) -> CGRect {
        let before = current ?? self.frame
        let plan = FloatingFramePlacement.plan(frame, from: before, on: screen,
                                               displayManager: displayManager)
        hyprLog(.notice, .floating, FloatingFramePlacement.logLine(
            windowID: windowID, reason: reason, from: before, plan: plan))
        setFrame(plan.target)
        return plan.target
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
/// floater covered (macOS 27 ignores a cross-app AXRaise) cools the pair
/// down, and so does a burst of plain raises for one pair.
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
    // a raise that fronted the floater's app normally works, and while a pair
    // rests the floater stays buried, so a miss gets another try soon
    var frontedIneffectiveCooldown: TimeInterval = 1
    // misses in a row: each doubles the rest, and past this many nothing retries
    // until the next click. an app that never comes up must not take the front
    // from whoever is typing once a second, forever
    var frontedRetryLimit = 3
    private var frontedMisses: [Pair: Int] = [:]
    static let frontedIneffectiveReason = "ineffective after fronting"
    var burstCooldown: TimeInterval = 10
    var burstLimit = 4
    var burstWindow: TimeInterval = 5

    private var attempts: [Pair: [TimeInterval]] = [:]
    private var cooldowns: [Pair: (until: TimeInterval, reason: String)] = [:]
    /// Decide one pair. A `.raise` counts as an attempt.
    mutating func decide(_ pair: Pair, now: TimeInterval) -> Decision {
        prune(now)
        if let cooldown = cooldowns[pair] {
            return .coolingDown(reason: cooldown.reason, remaining: cooldown.until - now)
        }
        let recent = attempts[pair, default: []]
        if recent.count >= burstLimit {
            return startCooldown(pair, reason: "burst", for: burstCooldown, now: now)
        }
        attempts[pair] = recent + [now]
        return .raise
    }

    mutating func noteIneffective(_ pair: Pair, now: TimeInterval, fronted: Bool = false) {
        if fronted {
            let misses = frontedMisses[pair, default: 0] + 1
            frontedMisses[pair] = misses
            cooldowns[pair] = (now + frontedIneffectiveCooldown * pow(2, Double(misses - 1)),
                               Self.frontedIneffectiveReason)
        } else {
            cooldowns[pair] = (now + ineffectiveCooldown, "ineffective")
        }
        attempts[pair] = nil
    }

    /// Whether a fronted miss should try again by itself.
    func retriesAfterMiss(_ pair: Pair) -> Bool {
        frontedMisses[pair, default: 0] < frontedRetryLimit
    }

    mutating func noteFrontedRaiseLanded(_ pair: Pair) {
        frontedMisses[pair] = nil
    }

    /// Clear a cooldown set for a raise that couldn't work (a plain AXRaise
    /// across apps), so a raise that fronts the app gets its chance. A miss
    /// after fronting stays.
    mutating func clearUnfrontedCooldown(_ pair: Pair) {
        guard let reason = cooldowns[pair]?.reason, reason != Self.frontedIneffectiveReason else { return }
        cooldowns[pair] = nil
    }

    /// The pair's running cooldown, if any. Asking counts as no attempt:
    /// the fronted path is bounded by its hand-off instead.
    mutating func cooldown(_ pair: Pair, now: TimeInterval) -> (reason: String, remaining: TimeInterval)? {
        prune(now)
        return cooldowns[pair].map { ($0.reason, $0.until - now) }
    }

    private mutating func startCooldown(_ pair: Pair, reason: String, for duration: TimeInterval,
                                        now: TimeInterval) -> Decision {
        cooldowns[pair] = (now + duration, reason)
        attempts[pair] = nil
        return .cooldownStarted(reason: reason, duration: duration)
    }

    private mutating func prune(_ now: TimeInterval) {
        cooldowns = cooldowns.filter { $0.value.until > now }
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
/// lifts floaters that ended up behind unfocused tiled windows;
/// `shouldAutoFloat` wraps `FloatingAdmissionPolicy` for startup and Retile All. Discovery asks
/// the policy directly.
///
/// What does not live here: workspace assignment for new floaters
/// (`ActionDispatcher`), and per-window focus
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
    var retile: ((@escaping () -> Void) -> Void)?
    var updateFocusBorder: ((HyprWindow) -> Void)?
    var updatePositionCache: (() -> Void)?
    var isMenuTracking: () -> Bool = { false }
    var isScratchpadVisible: () -> Bool = { false }
    // the Never tile list, read live so a settings change applies at once
    var excludedBundleIDs: () -> Set<String> = { [] }
    var windowListForZOrder: () -> [[String: Any]]? = {
        CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]]
    }
    var performRaise: (HyprWindow) -> AXError = {
        AXUIElementPerformAction($0.element, kAXRaiseAction as CFString)
    }
    // macOS 27 ignores AXRaise on a window of an app behind the front one, so
    // a cross-app raise fronts the floater's app first. this does not lift
    // anything by itself: the AXRaise after it does
    var frontApp: (HyprWindow) -> Void = { $0.makeFrontAndKeyWithoutRaise() }
    // keys go to the front app, so fronting the floater's app while someone types
    // puts their words in the floater
    var secondsSinceLastKey: () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }
    // fronting another app mid press would break the drag or selection under way
    var isMouseDown: () -> Bool = { NSEvent.pressedMouseButtons != 0 }
    var scheduleAfter: (TimeInterval, @escaping () -> Void) -> Void = { delay, body in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
    }
    // back on top and key. runs in the same turn as the floater's raise, so the
    // floater doesn't show over a tile it was already behind
    var restoreFocusLifting: (HyprWindow) -> Void = { $0.focus() }
    var windowFrameForZOrder: (HyprWindow) -> CGRect? = { $0.frame }
    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    // the frontmost app's open popup in a list. WindowManager points this at
    // the mouse tracker so every guard ignores the same long-lived windows.
    var findPopup: ([StackedWindow], pid_t?) -> StackedWindow? = { windows, front in
        WindowStacking.openPopup(in: windows, frontmostPID: front, ownPID: getpid())
    }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var throttle = RaiseBehindThrottle()
    // the stack may have changed: redraw floater cutouts and outlines
    var onRestack: () -> Void = {}
    var isWindowSizeSettable: (HyprWindow) -> Bool? = { $0.isSizeSettable }
    // red flash on a float→tile the tree or the screen refused.
    var rejectFloatToTile: ((HyprWindow, TilingEngine.ForceInsertFailure) -> Void)?

    // same-stack-frame reentrancy guard for raiseBehind. paired with defer.
    // not a SuppressionRegistry key: not a time gate.
    private var isRaising = false

    // time for the raise to land before checking the stack and the front app
    static let verifyDelay: TimeInterval = 0.05
    // gap between mouse-up and the check after a click. the app has lifted the
    // clicked tile by then
    static let clickRaiseDelay: TimeInterval = 0.04
    // an app can take longer than verifyDelay to come up after fronting. seen
    // live: Granola missed the first check, the pair then rested for 30 s, and
    // every click in that time left it buried
    static let frontedRecheckDelay: TimeInterval = 0.06
    static let frontedRechecks = 3
    // how long a fronted raise owns the front app: the rechecks and the hand-back.
    // a second one inside this would hand focus to the wrong app
    static let frontedRaiseBusy: TimeInterval = 0.4
    static let typingQuietWindow: TimeInterval = 0.25
    private var frontedRaiseBusyUntil: TimeInterval = 0
    private var raiseRetryPending = false
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
    /// A Quick Look preview is refused with the red shake and stays
    /// floating. On disabled monitors the call is a no-op — everything
    /// floats there by definition. The change runs inside `retile`,
    /// which retiles the surrounding tiles.
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
                focusBorder.flashError(around: frame, windowID: window.windowID,
                                       message: "Quick Look previews stay floating")
            }
            return
        }
        if wasFloating && isNeverTile(window) {
            // the user put this app in Never tile. say so, and where to change it
            hyprLog(.notice, .floating, "float→tile refused: \(window.windowID) belongs to a never-tile app")
            if let frame = window.frame ?? stateCache.cachedWindows[window.windowID]?.frame {
                focusBorder.flashError(around: frame, windowID: window.windowID,
                                       message: FloatingAdmissionPolicy.neverTileMessage)
            }
            return
        }
        guard let retile = retile else { return }

        if wasFloating {
            // floating → tiled: retile so the surrounding windows make room.
            // reassign workspace in case the window was dragged to a different monitor while floating.
            workspaceManager.moveWindow(window.windowID, toWorkspace: workspace)
            retile { [self] in
                stateCache.setFloating(false, window: window)

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
            // tiled → floating: retile so the remaining windows fill the gap.
            focusBorder.hide()
            dimmingOverlay.hideAll()
            retile { [self] in
                stateCache.setFloating(true, window: window)
                tilingEngine.removeWindow(window, fromWorkspace: workspace)

                let screenRect = displayManager.cgRect(for: screen)
                if let original = stateCache.originalFrames[window.windowID],
                   original.isSubstantiallyVisible(on: screenRect) {
                    window.placeFloating(original, reason: "float toggle, original frame",
                                         on: screen, displayManager: displayManager)
                } else if let current = window.frame {
                    let centeredOrigin = CGPoint(
                        x: screenRect.midX - current.width / 2,
                        y: screenRect.midY - current.height / 2
                    )
                    window.placeFloating(CGRect(origin: centeredOrigin, size: current.size),
                                         reason: "float toggle, centered (no usable original)",
                                         on: screen, from: current, displayManager: displayManager)
                } else {
                    // unreadable frame: move only. there is no
                    // real size to write or clamp
                    let size = window.size ?? CGSize(width: 800, height: 600)
                    window.position = CGPoint(x: screenRect.midX - size.width / 2,
                                              y: screenRect.midY - size.height / 2)
                    hyprLog(.notice, .floating, "floating frame write: wid=\(window.windowID)"
                            + " reason=float toggle, centered, position only (frame unreadable)")
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
        stateCache.setFloating(true, window: window)
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
        suppressions.suppress(.mouseFocus, for: SuppressionDelay.mouseFocus)
        suppressions.suppress(.activationSwitch, for: SuppressionDelay.activationSwitch)

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
                let sz = frame.size
                target.placeFloating(CGRect(x: screenRect.midX - sz.width / 2,
                                            y: screenRect.midY - sz.height / 2,
                                            width: sz.width, height: sz.height),
                                     reason: "focus cycle, off-screen floater",
                                     on: screen, from: frame, displayManager: displayManager)
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

    /// Lift floating windows that an unfocused tile covers back above it.
    ///
    /// The rule: a floater may be behind the focused tile or another floater,
    /// and nothing else. A click lifts the clicked tile natively and nothing
    /// fights that. Raising above every tile after each click flickered on every
    /// click, and made the floater's app take the keyboard for a moment.
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
    /// focused tile only when the raise moved the front app away from it,
    /// and it goes back through `restoreFocusLifting`.
    ///
    /// A floater of another app is raised by fronting that app first, since
    /// macOS 27 ignores the plain AXRaise. That happens only when the focused
    /// tile's app is in front, so the restore can undo it, and never during a
    /// mouse press. With anything else in front it stays a plain raise, which
    /// can't take focus from an app HyprMac doesn't manage.
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
        // a floater may sit behind the focused tile. only other tiles count
        let focusedTile = focusedTiledPID == nil ? nil : previousFocusID
        // safari can reorder a floating sibling when focus returns to its tile
        let candidates = coveredFloaters(in: windows, ignoringTile: focusedTile).filter { pair in
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

        let frontsApp = focusedTiledPID != nil && frontBefore == focusedTiledPID
        // a click's mouse-up runs this check again
        if frontsApp, isMouseDown() { return }
        if frontsApp, deferFrontedRaise() { return }

        let now = self.now()
        var pairs: [RaiseBehindThrottle.Pair] = []
        for pair in candidates {
            // a fronted raise runs at most once per hand-off, its misses back
            // off, and an app that re-buries the floater gets marked. a burst
            // limit on top left the floater buried after rapid clicks
            if frontsApp {
                throttle.clearUnfrontedCooldown(pair)
                if let cooldown = throttle.cooldown(pair, now: now),
                   cooldown.reason == RaiseBehindThrottle.frontedIneffectiveReason {
                    hyprLog(.debug, .floating, "raise behind cooling: pair=\(pair) reason=\(cooldown.reason) "
                            + "\(String(format: "%.1f", cooldown.remaining))s left")
                } else {
                    pairs.append(pair)
                }
                continue
            }
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
        if frontsApp { frontedRaiseBusyUntil = now + Self.frontedRaiseBusy }

        suppressions.suppress(.activationSwitch, for: SuppressionDelay.activationSwitch)
        suppressions.suppress(.mouseFocus, for: SuppressionDelay.mouseFocus)

        hyprLog(.notice, .floating, "raise behind: wids=\(pairs.map(\.floater)) under=\(pairs.map(\.tile)) "
                + "focus=\(previousFocusID) front=\(frontBefore.map(String.init) ?? "nil")")
        for pair in pairs {
            guard let w = stateCache.cachedWindows[pair.floater] else { continue }
            // an app that activates itself on a raise is HyprMac's doing
            suppressions.expectActivation(of: w.ownerPID)
            if frontsApp, w.ownerPID != frontBefore { frontApp(w) }
            let rc = performRaise(w)
            if rc != .success {
                hyprLog(.notice, .floating, "raise behind failed: wid=\(pair.floater) rc=\(rc.rawValue)")
            }
        }
        // focused window, floater, then the rest
        if frontsApp, let previousWindow { restoreFocusLifting(previousWindow) }

        scheduleAfter(Self.verifyDelay) { [weak self] in
            self?.finishRaise(pairs, frontBefore: frontBefore, frontsApp: frontsApp,
                              rechecks: frontsApp ? Self.frontedRechecks : 0,
                              previousFocusID: previousFocusID,
                              previousFocusGeneration: previousFocusGeneration,
                              previousWindow: previousWindow)
        }
    }

    /// Check what the raise did, cool down pairs it could not lift, and
    /// give focus back to the tile only if the raise took it away.
    private func finishRaise(_ pairs: [RaiseBehindThrottle.Pair], frontBefore: pid_t?,
                             frontsApp: Bool, rechecks: Int,
                             previousFocusID: CGWindowID, previousFocusGeneration: UInt64,
                             previousWindow: HyprWindow?) {
        let windows = windowListForZOrder().map(WindowStacking.decode)
        let now = self.now()
        if let windows {
            let focusedTile = previousWindow.flatMap {
                stateCache.floatingWindowIDs.contains($0.windowID) ? nil : previousFocusID
            }
            let stillCovered = Dictionary(coveredFloaters(in: windows, ignoringTile: focusedTile).map { ($0.floater, $0.tile) },
                                          uniquingKeysWith: { first, _ in first })
            if rechecks > 0, pairs.contains(where: { stillCovered[$0.floater] != nil }) {
                scheduleAfter(Self.frontedRecheckDelay) { [weak self] in
                    self?.finishRaise(pairs, frontBefore: frontBefore, frontsApp: frontsApp,
                                      rechecks: rechecks - 1, previousFocusID: previousFocusID,
                                      previousFocusGeneration: previousFocusGeneration,
                                      previousWindow: previousWindow)
                }
                return
            }
            for pair in pairs {
                guard let tile = stillCovered[pair.floater] else {
                    throttle.noteFrontedRaiseLanded(pair)
                    continue
                }
                throttle.noteIneffective(pair, now: now, fronted: frontsApp)
                if frontsApp { retryAfterMiss(pair, now: now) }
                hyprLog(.notice, .floating, "raise behind ineffective: wid=\(pair.floater) still under \(tile) "
                        + "— cooldown \(Int(frontsApp ? throttle.frontedIneffectiveCooldown : throttle.ineffectiveCooldown))s")
            }
        }
        onRestack()

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
        // a fronted raise always ends here, so this isn't the loop. hovering
        // between two tiles would otherwise cool the pair for longer each time.
        // an app that re-buries the floater is caught by tileAppLiftsOnFocus,
        // and the burst limit bounds what gets through before that
        restoreFocusLifting(prev)
        updateFocusBorder?(prev)
    }

    /// Put back on top any floater a tile other than `target` covers, right before
    /// `target` takes focus.
    ///
    /// Order is the point. Raising the floater before the target lifts means it
    /// goes straight from over the old tile to under the new one, and never shows
    /// over the window taking focus. Skipped work is picked up by `raiseBehind`
    /// after the activation.
    func raiseFloatersBeforeFocus(_ target: HyprWindow) {
        guard !stateCache.floatingWindowIDs.contains(target.windowID),
              !isScratchpadVisible(), !isMenuTracking(), !isMouseDown(),
              stateCache.floatingWindowIDs.contains(where: workspaceManager.isWindowVisible),
              let windows = windowListForZOrder().map(WindowStacking.decode) else { return }
        let pairs = coveredFloaters(in: windows, ignoringTile: target.windowID).filter {
            stateCache.cachedWindows[$0.floater]?.ownerPID != target.ownerPID
        }
        guard !pairs.isEmpty, findPopup(windows, frontmostPID()) == nil, !deferFrontedRaise() else { return }
        frontedRaiseBusyUntil = now() + Self.frontedRaiseBusy
        suppressions.suppress(.activationSwitch, for: SuppressionDelay.activationSwitch)
        hyprLog(.notice, .floating, "raise before focus: wids=\(pairs.map(\.floater)) "
                + "under=\(pairs.map(\.tile)) focus=\(target.windowID)")
        for pair in pairs {
            guard let w = stateCache.cachedWindows[pair.floater] else { continue }
            suppressions.expectActivation(of: w.ownerPID)
            frontApp(w)
            let rc = performRaise(w)
            if rc != .success {
                hyprLog(.notice, .floating, "raise before focus failed: wid=\(pair.floater) rc=\(rc.rawValue)")
            }
        }
    }

    /// Put a tile that just took focus above any floater still over it. Its app
    /// was fronted by the focus, so the AXRaise lands. An app can take a moment to
    /// come to the front, so it checks again once if focus hasn't moved on.
    func liftOverFloaters(_ target: HyprWindow, retrying: Bool = true) {
        guard !stateCache.floatingWindowIDs.contains(target.windowID),
              !isScratchpadVisible(), !isMenuTracking(),
              focusController.lastFocusedID == target.windowID else { return }
        let floaters = stateCache.floatingWindowIDs.filter(workspaceManager.isWindowVisible)
        guard !floaters.isEmpty, let windows = windowListForZOrder().map(WindowStacking.decode),
              findPopup(windows, frontmostPID()) == nil else { return }
        let targetFrame = windows.first { $0.windowID == target.windowID }?.bounds
        let over = WindowStacking.floaters(above: target.windowID, among: floaters, in: windows).filter { floater in
            guard let targetFrame, let frame = floater.bounds else { return true }
            return WindowStacking.overlaps(targetFrame, frame)
        }
        guard !over.isEmpty else { return }
        let rc = performRaise(target)
        if rc != .success {
            hyprLog(.notice, .floating, "lift over floaters failed: wid=\(target.windowID) rc=\(rc.rawValue)")
        }
        if retrying {
            scheduleAfter(Self.frontedRecheckDelay) { [weak self] in
                self?.liftOverFloaters(target, retrying: false)
            }
        }
    }

    /// Whether a raise that fronts another app has to wait, and if so, try
    /// again when it can. Rapid clicks, a focus still settling and typing all
    /// wait, and the floater comes back up once they stop.
    private func deferFrontedRaise() -> Bool {
        let remaining = frontedRaiseBusyUntil - now()
        if remaining > 0 {
            retryRaiseBehind(after: remaining + 0.02)
            return true
        }
        if secondsSinceLastKey() < Self.typingQuietWindow {
            retryRaiseBehind(after: Self.typingQuietWindow)
            return true
        }
        return false
    }

    private func retryAfterMiss(_ pair: RaiseBehindThrottle.Pair, now: TimeInterval) {
        guard throttle.retriesAfterMiss(pair),
              let rest = throttle.cooldown(pair, now: now)?.remaining else { return }
        retryRaiseBehind(after: rest + 0.05)
    }

    private func retryRaiseBehind(after delay: TimeInterval) {
        guard !raiseRetryPending else { return }
        raiseRetryPending = true
        scheduleAfter(delay) { [weak self] in
            self?.raiseRetryPending = false
            self?.raiseBehind()
        }
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

    /// Whether `window` belongs to an app in the Never tile list.
    func isNeverTile(_ window: HyprWindow) -> Bool {
        guard let bundleID = window.bundleID
                ?? NSRunningApplication(processIdentifier: window.ownerPID)?.bundleIdentifier else { return false }
        return excludedBundleIDs().contains(bundleID)
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

    /// Floaters that a tile covers, paired with the frontmost tile that
    /// covers each one, read from the window list's z-order.
    ///
    /// Covered means the tile is stacked above the floater and the two
    /// overlap. A floater behind a tile it does not touch looks fine and
    /// is left alone. Frames come from the window list, or from AX and
    /// `tiledPositions` when the list has none.
    func coveredFloaters(in windows: [StackedWindow],
                         floatingWindowIDs: Set<CGWindowID>? = nil,
                         tiledPositions: [CGWindowID: CGRect]? = nil,
                         ignoringTile: CGWindowID? = nil) -> [RaiseBehindThrottle.Pair] {
        let floaters = (floatingWindowIDs ?? stateCache.floatingWindowIDs)
            .filter { workspaceManager.isWindowVisible($0) }
        guard !floaters.isEmpty else { return [] }
        let tiles = tiledPositions ?? stateCache.tiledPositions

        var pairs: [RaiseBehindThrottle.Pair] = []
        for (index, entry) in windows.enumerated()
        where floaters.contains(entry.windowID) && WindowStacking.isFloaterLayer(entry.layer) {
            guard let frame = entry.bounds
                    ?? stateCache.cachedWindows[entry.windowID].flatMap(windowFrameForZOrder) else { continue }
            let cover = windows[..<index].first { above in
                guard above.windowID != ignoringTile, above.layer == 0,
                      let rect = above.bounds ?? tiles[above.windowID],
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
