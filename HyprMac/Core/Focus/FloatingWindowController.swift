// Floating-window lifecycle: tile/float toggle, cycle, raise-behind, and
// the auto-float predicate. Holds direct references to long-lived services
// and uses closure handles for the WM-side glue (animated retile, focus
// border refresh, position cache).

import Cocoa

enum FloatingAdmissionPolicy {
    enum Reason: String {
        case excludedApp = "excluded app"
        /// a float rule for the app or for windows like this one
        case floatRule = "float rule"
        case fixedSize = "window is not resizable"
        case quickLook = "quick look preview"
    }

    static func reason(isExcluded: Bool, isSizeSettable: Bool?,
                       isQuickLookPanel: Bool = false) -> Reason? {
        reason(rule: isExcluded ? .float(nil) : nil, isSizeSettable: isSizeSettable,
               isQuickLookPanel: isQuickLookPanel)
    }

    /// Why a window floats on admission, or nil when it tiles. A rule
    /// decides before the size check, but a tile rule can't make a window
    /// HyprMac can't resize take a tile: that one still floats.
    static func reason(rule: FloatingRuleVerdict?, isSizeSettable: Bool?,
                       isQuickLookPanel: Bool = false) -> Reason? {
        // a preview always floats: it sizes itself to each file
        if isQuickLookPanel { return .quickLook }
        switch rule {
        case let .float(decider)?:
            return decider == nil ? .excludedApp : .floatRule
        case .tile?, nil:
            if isSizeSettable == false { return .fixedSize }
            return nil
        }
    }

    /// What a rule change does to an open window.
    enum RuleStep: Equatable { case float, tile }

    /// Shown when the user tries to tile a window of an app in Never tile.
    static let neverTileMessage = "App not allowed to tile. Change it in Settings"
    /// Shown when the user tries to tile a window a float rule covers.
    static let floatRuleMessage = "A float rule covers this window. Change it in Settings"

    static func refusalMessage(for verdict: FloatingRuleVerdict) -> String {
        verdict.rule == nil ? neverTileMessage : floatRuleMessage
    }
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

/// What goes off the screen before a floater's Hypr+T attempt. The attempt
/// moves the floater and the tiles around it on the main thread, where
/// nothing can redraw, so every mark drawn on those frames would sit on the
/// old spots until it ends: the floater's outline, the border or brackets
/// on it, and the dim, whose layers follow each tile and carve each
/// floater. A red flash still up from the last refused Hypr+T on the same
/// window goes too: the next press can come before it ends. The scratchpad
/// scrim covers whole screens with no carves, so it stays.
struct TileAttemptChrome: Equatable {
    var outline: Bool
    var border: Bool
    var brackets: Bool
    var dim: Bool
    var errorFlash: Bool = false

    static func clearing(_ id: CGWindowID, borderTrackedID: CGWindowID?, bracketsTrackedID: CGWindowID?,
                         errorFlashID: CGWindowID? = nil, scrimShowing: Bool) -> Self {
        Self(outline: true, border: borderTrackedID == id, brackets: bracketsTrackedID == id,
             dim: !scrimShowing, errorFlash: errorFlashID == id)
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
        case let .keepsFixedSize(fixed):
            return "It keeps its \(fixed.axis.rawValue) at \(Int(fixed.length)). Hypr+T again to try anyway"
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
    /// What a maximized floater goes back to, and the frame it was given.
    private var maximizedFrames: [CGWindowID: (restore: CGRect, full: CGRect)] = [:]
    private let focusController: FocusStateController
    private let focusBorder: FocusBorder
    private let dimmingOverlay: DimmingOverlay

    // closure handles for WM-side helpers used by toggle/cycle/raise.
    var retile: ((@escaping () -> Void) -> Void)?
    var updateFocusBorder: ((HyprWindow) -> Void)?
    var updatePositionCache: (() -> Void)?
    var isMenuTracking: () -> Bool = { false }
    var isScratchpadVisible: () -> Bool = { false }
    // the Never tile list and the float and tile rules, read live so a
    // settings change applies at once
    var excludedBundleIDs: () -> Set<String> = { [] }
    var floatingRules: () -> [FloatingRule] = { [] }
    // rule changes wait out a display transition, as the actions do
    var isDisplayTransitionPending: () -> Bool = { false }
    // a maximize a rule change ended, for the HUD and the menu bar
    var onMaximizeEnded: (NSScreen) -> Void = { _ in }
    /// The rules the open windows were last brought in line with.
    private var appliedRuleBook: FloatingRuleBook?
    /// When Hypr+T last refused a window for a length it keeps, so a second
    /// ask within `tryAnywayWindow` tries for real.
    private var fixedSizeRefusals: [CGWindowID: TimeInterval] = [:]
    static let tryAnywayWindow: TimeInterval = 5

    /// What the user chose by hand for a window: floating or tiled. It beats
    /// every rule, Never tile included, until the window closes.
    private(set) var manualChoices: [CGWindowID: Bool] = [:]
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
    // a floater's marks go before its tile attempt: the pass blocks the
    // main thread while the window tries its slots, and the marks would stay
    // on the old spot until it ends
    var willTryTile: (HyprWindow) -> Void = { _ in }
    // and come back on the frame the attempt left, tiled or floating
    var didTryTile: (HyprWindow) -> Void = { _ in }
    // where the window server draws a window (the window list, not AX, which
    // some apps leave stale), and the write that puts a refused floater back
    var drawnFrame: (HyprWindow) -> CGRect? = { _ in nil }
    var restoreFrame: (HyprWindow, CGRect) -> Void = { _, _ in }

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
        // no rule refuses this: the user asked for this window, and that wins
        // over Never tile and every float rule until the window closes. only
        // a window that can't take a tile fails, below, with the red shake
        guard let retile = retile else { return }

        if wasFloating {
            // floating → tiled: retile so the surrounding windows make room.
            // reassign workspace in case the window was dragged to a different monitor while floating.
            workspaceManager.moveWindow(window.windowID, toWorkspace: workspace)
            // read before anything moves: a rollback leaves a newcomer whose
            // frame hangs off the screen where its slot put it, and a later
            // slot try reads that as the window's original
            let before = drawnFrame(window)
            willTryTile(window)
            retile { [self] in
                stateCache.setFloating(false, window: window)

                switch forceInsert(window, workspace: workspace, screen: screen) {
                case .inserted, .alreadyPresent:
                    noteManualChoice(window.windowID, floating: false)
                    hyprLog(.debug, .floating, "tiling window '\(window.title ?? "?")'")
                case let .failed(reason):
                    // the tree never took it, so it is still a floater. put
                    // both flags back the way they were and say so.
                    floatInPlace(window, reason: "float→tile refused: \(reason)")
                    if let before, Self.moved(from: before, to: drawnFrame(window)) {
                        restoreFrame(window, before)
                    }
                    rejectFloatToTile?(window, reason)
                }
            }
            didTryTile(window)
        } else {
            // tiled → floating: retile so the remaining windows fill the gap.
            focusBorder.hide()
            dimmingOverlay.hideAll()
            retile { [self] in
                stateCache.setFloating(true, window: window)
                noteManualChoice(window.windowID, floating: true)
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

    // MARK: - maximize

    func isMaximized(_ id: CGWindowID) -> Bool { maximizedFrames[id] != nil }

    /// A native tab switch: the shown tab fills the display the hidden one
    /// filled, so it takes the frame to go back to.
    func handOverMaximize(from hiddenID: CGWindowID, to shownID: CGWindowID) {
        guard let frames = maximizedFrames.removeValue(forKey: hiddenID) else { return }
        maximizedFrames[shownID] = frames
    }

    var maximizedIDs: Set<CGWindowID> { Set(maximizedFrames.keys) }

    /// Fill the display with a floater, or put it back where it was. Moved
    /// to another display since, it fills that one instead: the saved frame
    /// belongs to the display it left. Returns whether it's maximized now,
    /// nil when nothing changed.
    func toggleMaximized(_ window: HyprWindow, fullFrame: CGRect, on screen: NSScreen) -> Bool? {
        let current = window.frame
        if let saved = maximizedFrames.removeValue(forKey: window.windowID),
           displayManager.screen(containingMostOf: saved.restore) == screen {
            window.placeFloating(saved.restore, reason: "maximize ended", on: screen, from: current,
                                 displayManager: displayManager)
            return false
        }
        guard let current else { return nil }
        maximizedFrames[window.windowID] = (restore: current, full: fullFrame)
        window.placeFloating(fullFrame, reason: "maximized", on: screen, from: current,
                             displayManager: displayManager)
        return true
    }

    /// Stop treating a floater the user dragged or resized as maximized. It
    /// stays where they put it. Returns the ids that were dropped.
    func forgetMaximizedIfMoved(liveFrame: (CGWindowID) -> CGRect?) -> [CGWindowID] {
        var moved: [CGWindowID] = []
        for (id, frames) in maximizedFrames {
            guard let live = liveFrame(id) else { continue }
            if abs(live.minX - frames.full.minX) > TiledDriftMonitor.positionTolerance
                || abs(live.minY - frames.full.minY) > TiledDriftMonitor.positionTolerance
                || abs(live.width - frames.full.width) > TiledDriftMonitor.sizeTolerance
                || abs(live.height - frames.full.height) > TiledDriftMonitor.sizeTolerance {
                moved.append(id)
            }
        }
        moved.forEach { maximizedFrames.removeValue(forKey: $0) }
        return moved
    }

    func forgetMaximized(_ id: CGWindowID) {
        maximizedFrames.removeValue(forKey: id)
    }

    func forgetAllMaximized() {
        maximizedFrames.removeAll()
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
        // a window known to keep a length no slot holds is refused before
        // anything moves; asking again soon after tries for real, in case
        // the app let go of it
        let now = self.now()
        let askedAgain = fixedSizeRefusals[window.windowID].map { now - $0 <= Self.tryAnywayWindow } ?? false
        fixedSizeRefusals[window.windowID] = nil
        let first = tilingEngine.forceInsertWindow(window, toWorkspace: workspace, on: screen,
                                                   honoringFixedSize: !askedAgain)
        if case .failed(.keepsFixedSize) = first {
            fixedSizeRefusals[window.windowID] = now
            return first
        }
        guard case .failed(.noFittingSlot) = first else { return first }
        guard case .revalidatable = tilingEngine.admissionOutlook(window, onWorkspace: workspace,
                                                                 screen: screen) else { return first }
        hyprLog(.notice, .floating, "float→tile revalidation: \(window.windowID) ws\(workspace)")
        return tilingEngine.forceInsertWindow(window, toWorkspace: workspace, on: screen,
                                              bypassingLearnedMinima: true)
    }

    /// Whether a window read back at `after` is off `before` by more than a
    /// point. An unreadable window counts as moved: the write is harmless.
    static func moved(from before: CGRect, to after: CGRect?) -> Bool {
        guard let after else { return true }
        return abs(after.minX - before.minX) > 1 || abs(after.minY - before.minY) > 1
            || abs(after.width - before.width) > 1 || abs(after.height - before.height) > 1
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

    // MARK: - manual choices

    /// The user floated (`true`) or tiled (`false`) this window directly:
    /// Hypr+T, the rules overlay's one-off, the scratchpad, the dedicated
    /// workspace move. Rules leave it alone from now on.
    func noteManualChoice(_ id: CGWindowID, floating: Bool) {
        if manualChoices[id] != floating {
            hyprLog(.notice, .floating, "manual choice: \(id) \(floating ? "floating" : "tiled") — rules leave it alone")
        }
        manualChoices[id] = floating
    }

    func manualChoice(for id: CGWindowID) -> Bool? { manualChoices[id] }

    /// The window closed: its next life starts without the choice.
    func forgetManualChoice(_ id: CGWindowID) {
        manualChoices.removeValue(forKey: id)
    }

    var ruleBook: FloatingRuleBook {
        FloatingRuleBook(rules: floatingRules(), excludedBundleIDs: excludedBundleIDs())
    }

    /// The rule that floats `window`: its app in Never tile, or a float
    /// rule for the app or for windows like it that no tile rule above it
    /// overrides. nil when no rule floats it.
    func floatRule(for window: HyprWindow) -> FloatingRuleVerdict? {
        // the user tiled it by hand: no rule floats it now
        if manualChoices[window.windowID] == false { return nil }
        guard let verdict = window.floatingVerdict(ruleBook), verdict.floats else { return nil }
        return verdict
    }

    /// Whether a rule keeps `window` floating: Never tile, or a float rule
    /// that covers it. A window-kind tile rule inside a Never tile app
    /// takes that window out.
    func isNeverTile(_ window: HyprWindow) -> Bool {
        floatRule(for: window) != nil
    }

    // MARK: - rule changes

    /// What a change of rules does to one open window, nil for nothing.
    ///
    /// Only a window whose verdict changed moves. It floats when the new
    /// rules float it. It tiles when a tile rule now covers it, or when the
    /// rule that floated it is gone, and only if `canTile` (HyprMac can
    /// resize it and nothing else floats it). A window the user floated by
    /// hand that no rule ever covered is left alone.
    static func ruleChangeStep(before: FloatingRuleVerdict?, after: FloatingRuleVerdict?,
                               isFloating: Bool, canTile: Bool) -> FloatingAdmissionPolicy.RuleStep? {
        guard before != after else { return nil }
        if after?.floats == true { return isFloating ? nil : .float }
        guard isFloating, canTile else { return nil }
        if case .tile? = after { return .tile }
        return before?.floats == true ? .tile : nil
    }

    /// The open windows match the current rules: startup classified them.
    func markRulesApplied() {
        appliedRuleBook = ruleBook
    }

    /// The rules changed: bring the open windows in line, from the rules
    /// they were last applied under. Mid display transition nothing moves
    /// (the trees and screens are in flux, so the actions that move windows
    /// are dropped then too); the caller asks again once it settles, and
    /// the difference is still there to apply.
    /// - Returns: what moved, or nil when it waited.
    @discardableResult
    func rulesChanged(windows: [HyprWindow]) -> (floated: [CGWindowID], tiled: [CGWindowID])? {
        guard !isDisplayTransitionPending() else {
            hyprLog(.notice, .floating, "rule change deferred: display transition pending")
            return nil
        }
        let old = appliedRuleBook ?? ruleBook
        appliedRuleBook = ruleBook
        return applyRuleChange(from: old, windows: windows)
    }

    /// Re-apply the rules to every open window after they changed from
    /// `old`: the menu, an action, Settings, or a config reload. Windows on
    /// visible workspaces move at once, through one retile; ones on hidden
    /// workspaces change state and show up that way when revealed.
    /// Scratchpad members, Quick Look panels and windows on a disabled
    /// monitor keep what they have.
    /// - Returns: the windows it floated and tiled.
    @discardableResult
    func applyRuleChange(from old: FloatingRuleBook, windows: [HyprWindow])
        -> (floated: [CGWindowID], tiled: [CGWindowID]) {
        let new = ruleBook
        guard new != old else { return ([], []) }
        var floated: [HyprWindow] = []
        var tiled: [HyprWindow] = []
        for window in windows {
            let id = window.windowID
            guard stateCache.knownWindowIDs.contains(id), !stateCache.hiddenWindowIDs.contains(id),
                  !window.isQuickLookPanel, manualChoices[id] == nil,
                  let workspace = workspaceManager.workspaceFor(id),
                  workspace != ScratchpadController.workspace,
                  !(displayManager.screen(for: window).map(workspaceManager.isMonitorDisabled) ?? false)
            else { continue }
            let after = window.floatingVerdict(new)
            let step = Self.ruleChangeStep(
                before: window.floatingVerdict(old), after: after,
                isFloating: stateCache.floatingWindowIDs.contains(id),
                canTile: { FloatingAdmissionPolicy.reason(rule: after, isSizeSettable: isWindowSizeSettable(window),
                                                          isQuickLookPanel: false) == nil }())
            switch step {
            case .float?: floated.append(window)
            case .tile?: tiled.append(window)
            case nil: continue
            }
        }
        guard !floated.isEmpty || !tiled.isEmpty else { return ([], []) }
        hyprLog(.notice, .floating, "rule change: floating \(floated.map(\.windowID).sorted())"
                + " tiling \(tiled.map(\.windowID).sorted())")
        // like the actions that rework a window's place (ActionPolicy.endsMaximize)
        for window in floated + tiled { endMaximize(window) }
        let apply = { [self] in
            for window in floated { floatForRule(window) }
            for window in tiled {
                stateCache.setFloating(false, window: window)
                workspaceManager.clearSavedFloatingFrame(for: window.windowID)
            }
        }
        if let retile { retile(apply) } else { apply() }
        return (floated.map(\.windowID), tiled.map(\.windowID))
    }

    /// End a maximize `window` is part of, floating or tiled, before a rule
    /// moves it: a stale maximized frame would otherwise outlive the change.
    private func endMaximize(_ window: HyprWindow) {
        let id = window.windowID
        if isMaximized(id) {
            forgetMaximized(id)
            if let screen = displayManager.screen(for: window) { onMaximizeEnded(screen) }
        }
        if let location = tilingEngine.maximizeLocation(involving: id) {
            tilingEngine.endMaximize(onWorkspace: location.workspace, screen: location.screen)
        }
    }

    /// Float a window a rule now covers. On a visible workspace it goes back
    /// to the frame it had before HyprMac tiled it, when that is on its
    /// screen, else it stays where it is. On a hidden one it is parked in
    /// the corner, so the reveal needs a saved frame: that same frame, or
    /// its size centered on the workspace's home screen.
    private func floatForRule(_ window: HyprWindow) {
        let id = window.windowID
        stateCache.setFloating(true, window: window)
        guard let workspace = workspaceManager.workspaceFor(id) else { return }
        let original = stateCache.originalFrames[id]
        if let screen = workspaceManager.screenForWorkspace(workspace) {
            if let original, original.isSubstantiallyVisible(on: displayManager.cgRect(for: screen)) {
                window.placeFloating(original, reason: "float rule, original frame",
                                     on: screen, displayManager: displayManager)
            }
            return
        }
        guard let home = workspaceManager.homeScreenForWorkspace(workspace) else { return }
        let usable = displayManager.cgRect(for: home)
        if let original, original.isSubstantiallyVisible(on: usable) {
            workspaceManager.setSavedFloatingFrame(original, for: id)
            return
        }
        let size = original?.size ?? window.cachedFrame?.size ?? CGSize(width: 800, height: 600)
        let centered = CGRect(x: usable.midX - size.width / 2, y: usable.midY - size.height / 2,
                              width: size.width, height: size.height)
        workspaceManager.setSavedFloatingFrame(centered.clamped(into: usable), for: id)
    }

    /// `true` when `window` should auto-float on first discovery.
    ///
    /// Excluded apps and windows that explicitly reject AX resize enter as
    /// floaters. An unreadable resize capability is left to verified tiling
    /// and its existing recovery. Disabled-monitor auto-float is separate.
    func shouldAutoFloat(_ window: HyprWindow, excludedBundleIDs: Set<String>,
                         floatingRules: [FloatingRule] = []) -> Bool {
        autoFloatReason(window, excludedBundleIDs: excludedBundleIDs, floatingRules: floatingRules) != nil
    }

    func autoFloatReason(
        _ window: HyprWindow, excludedBundleIDs: Set<String>, floatingRules: [FloatingRule] = []
    ) -> FloatingAdmissionPolicy.Reason? {
        let book = FloatingRuleBook(rules: floatingRules, excludedBundleIDs: excludedBundleIDs)
        // tiled by hand: Retile All keeps it tiled, whatever the rules say.
        // floated by hand it goes back to tiling, as Retile All always did
        let rule = manualChoices[window.windowID] == false ? nil : window.floatingVerdict(book)
        return FloatingAdmissionPolicy.reason(
            rule: rule,
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
