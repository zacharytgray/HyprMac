// Persistent focus indicator around the active window, plus outline-only
// borders around every visible floating window. Implemented as borderless
// `NSPanel`s at `.floating` tier with `CALayer` masking for occlusion.

import Cocoa

/// What marks each visible floating window. Any focus indicator outlines
/// it, in Corners mode too; None draws nothing.
enum FloaterMarkStyle: Equatable {
    case outline, none

    static func resolve(showFocusBorder: Bool, bracketStyle: FocusBracketStyle) -> Self {
        showFocusBorder || bracketStyle != .off ? .outline : .none
    }
}

/// Where a floater's outline and its glow sit in the floater panel.
///
/// The panel reaches `glowRoom` past the outline on every side so the
/// glow's blur is not clipped. The outline itself stays where it always
/// was: centered on the window edge.
enum FloaterOutlineGeometry {
    /// room past the outline for a blur of `glowRadius`
    static func glowRoom(glowRadius: CGFloat) -> CGFloat {
        (glowRadius * 3).rounded(.up)
    }

    /// how far the panel reaches past the window on each side
    static func panelExpansion(borderWidth: CGFloat, glowRadius: CGFloat) -> CGFloat {
        borderWidth / 2 + glowRoom(glowRadius: glowRadius)
    }

    /// the outline layer's frame in the panel's content bounds
    static func outlineFrame(inPanelBounds bounds: CGRect, glowRadius: CGFloat) -> CGRect {
        let room = glowRoom(glowRadius: glowRadius)
        return bounds.insetBy(dx: room, dy: room)
    }

    /// The ring a `CALayer` border paints: `borderWidth` inside `bounds`,
    /// outer corners at `cornerRadius`. Filled nonzero, as `shadowPath` is.
    static func ringPath(in bounds: CGRect, cornerRadius: CGFloat, borderWidth: CGFloat) -> CGPath {
        let center = bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
        guard center.width > 0, center.height > 0, borderWidth > 0 else { return CGMutablePath() }
        // CGPath asserts when a corner exceeds half the width or height
        let r = max(0, min(cornerRadius - borderWidth / 2, center.width / 2, center.height / 2))
        let line = CGPath(roundedRect: center, cornerWidth: r, cornerHeight: r, transform: nil)
        return line.copy(strokingWithWidth: borderWidth, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
    }
}

struct FocusBorderFeedbackLifecycle {
    private(set) var isActive = false

    var permitsPersistentShow: Bool { !isActive }

    func persistentTrackedID(_ renderedWindowID: CGWindowID?) -> CGWindowID? {
        isActive ? nil : renderedWindowID
    }

    mutating func begin() { isActive = true }

    mutating func finish() -> Bool {
        guard isActive else { return false }
        isActive = false
        return true
    }

    mutating func cancel() { isActive = false }
}

/// Visual focus indicator: a tinted outline around the focused window
/// and a thinner outline around each visible floating window.
///
/// State machine on the focused-window panel:
/// ```
/// hidden  --show()-->        active   (tint fill + border; no fill when
///                                      `flashesOnFocus` is off)
/// active  --settle()-->      settled  (outline only, no fill)
/// any     --hide()-->        hidden   (fade out + orderOut + nil-out)
/// any     --flashError()-->  active   (red shake; hides itself afterward)
/// ```
///
/// Floating-window panels are keyed by `CGWindowID` and managed
/// independently via `updateFloatingBorders` / `hideFloatingBorders`.
///
/// Lifecycle invariants: explicit teardown cancels in-flight work;
/// persistent `show` calls defer to bounded error feedback; `hide` nils the
/// focused panel and its glow view synchronously so the next `show`
/// builds a fresh panel rather than reusing one that is mid-fade;
/// `deinit` guarantees cleanup of every owned panel and timer.
///
/// Threading: main-thread only. Public methods assert via
/// `mainThreadOnly()`.
class FocusBorder {
    private var renderedWindowID: CGWindowID?
    var trackedWindowID: CGWindowID? {
        errorFeedback.persistentTrackedID(renderedWindowID)
    }

    /// Global persistent-chrome policy pushed from `UserConfig.showFocusBorder`.
    /// One-shot rejection feedback remains available when chrome is disabled.
    var isEnabled = true {
        didSet {
            guard !isEnabled else { return }
            disableImmediately()
        }
    }

    /// Whether `show` tints the window while the border is active, pushed
    /// from `UserConfig.focusBorderFlash`. Off keeps the border and its
    /// settle but drops the fill. A change repaints an active border at once,
    /// either way. Error feedback keeps its red fill.
    var flashesOnFocus = true {
        didSet {
            guard flashesOnFocus != oldValue, state == .active, !errorFeedback.isActive else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glowView?.layer?.backgroundColor = Self.activeFill(for: accentCGColor, flashesOnFocus: flashesOnFocus)
            CATransaction.commit()
        }
    }

    /// The active-state fill for `color`: a faint tint, or clear when the
    /// focus flash is off. Pure, so the rule is testable without panels.
    static func activeFill(for color: CGColor, flashesOnFocus: Bool) -> CGColor {
        flashesOnFocus ? color.copy(alpha: Tuning.activeFillAlpha) ?? CGColor.clear : CGColor.clear
    }

    private var panel: NSPanel?
    private var glowView: NSView?
    private var floatingPanels: [CGWindowID: BorderPanel] = [:]
    private var settleWork: DispatchWorkItem?
    private var shakeTimer: DispatchSourceTimer?
    private var state: State = .hidden
    // pill shown centered in the error panel explaining a rejection.
    private var messageBanner: NSView?
    private var infoPanels: [NSPanel] = []
    private let observedPanels = NSHashTable<NSPanel>.weakObjects()
    private var renderGeneration = 0
    private var restoreShakenWindow: (() -> Void)?
    var onShakeRestore: () -> Void = {}
    var onErrorFeedbackFinished: () -> Void = {}
    var onErrorFeedbackFinishedToken: (Int) -> Void = { _ in }
    private var errorFeedback = FocusBorderFeedbackLifecycle()
    private var errorFeedbackWindowID: CGWindowID?
    var isErrorFeedbackActive: Bool { errorFeedback.isActive }

    var visibleOwnedPanelCount: Int { observedPanels.allObjects.filter(\.isVisible).count }
    static func errorFeedbackCanRender(isEnabled _: Bool) -> Bool { true }

    // remembered CG frames — used by applyOcclusion to translate occluder
    // CG rects into glow-local NS coords. kept in sync with panel positions.
    private var trackedWindowFrame: CGRect?
    /// Where the focused border sits now, CG coordinates. nil while hidden.
    var frame: CGRect? { state == .hidden ? nil : trackedWindowFrame }
    // set while the outline travels to a teleported window's new frame.
    // occluders that arrive meanwhile wait for the landing
    private var glideTarget: CGRect?
    private var glideOccluders: [CGRect] = []
    private var floaterFrames: [CGWindowID: CGRect] = [:]
    // the dragged floater's live frame. it wins over the lagging frame a
    // refresh reads, and the floater is in front of everything while it moves
    private var floaterDrag: (id: CGWindowID, frame: CGRect)?

    private enum State { case active, settled, hidden }
    // a floater's glowView fills the panel and carries the fade and the
    // occlusion mask. its outline sublayer draws the stroke and the glow.
    private struct BorderPanel {
        let panel: NSPanel
        let glowView: NSView
        let outline: CALayer
    }

    /// Whether the floater panels draw. Pushed from config by `WindowManager`
    /// next to `isEnabled`. Floaters draw even with `isEnabled` off, since
    /// that flag is the focused-window border toggle and Corners mode
    /// turns it off.
    private(set) var floaterMarks: FloaterMarkStyle = .outline

    /// Tunables. Empirical timings (settle delay, shake step) and
    /// stroke widths. Corner radius comes from `WindowCornerRadius`, one
    /// global value.
    private enum Tuning {
        static let settleDelaySec: TimeInterval = 0.5
        static let settleAnimationDurationSec: TimeInterval = 0.3
        // fast enough to feel instant, slow enough to register visually.
        // applied on transitions from hidden → active (workspace switch,
        // app un-hide, fresh focus), on focus changes between windows, and
        // when a floater's border first appears.
        static let showAnimationDurationSec: TimeInterval = 0.22
        static let shakeStepDurationSec: TimeInterval = 0.04
        static let shakeOffsets: [CGFloat] = [10, -10, 7, -7, 3, -3, 0]
        // hold the message after the shake stops
        static let errorMessageHoldSec: TimeInterval = 1.15
        static let activeBorderWidth: CGFloat = 2
        static let settledBorderWidth: CGFloat = 1.5
        static let floatingBorderWidth: CGFloat = 1.5
        // the faint glow around a floater outline, in the outline's color
        static let floatingGlowRadius: CGFloat = 3
        static let floatingGlowOpacity: Float = 0.45
        static let errorBorderWidth: CGFloat = 2.5
        static let activeFillAlpha: CGFloat = 0.08
        static let errorFillAlpha: CGFloat = 0.12
    }

    /// How far a floater panel reaches past its window on each side: half
    /// the stroke, plus room for the glow.
    static let floaterPanelExpansion = FloaterOutlineGeometry.panelExpansion(
        borderWidth: Tuning.floatingBorderWidth, glowRadius: Tuning.floatingGlowRadius)

    // The settled border keeps the active panel geometry, while an error
    // flash uses its wider stroke. Refreshes must preserve whichever
    // expansion was used when the focused border was last stamped.
    private var focusedCornerRadiusExpansion = Tuning.activeBorderWidth / 2

    // resolved from config, repainted by refreshAppearance
    var accentCGColor: CGColor = NSColor.controlAccentColor.cgColor

    /// Shared fade duration used by `show`, `hide`, the floating-border
    /// counterparts, and the `flashError` follow-up. Settle (the
    /// active-tint → outline transition) and shake keep their own
    /// constants in `Tuning` — those are timing-of-interaction values,
    /// not chrome appearance. Set by `WindowManager` from
    /// `config.chromeFadeDurationSec`.
    var fadeDurationSec: TimeInterval = Tuning.showAnimationDurationSec

    /// Repaint existing persistent chrome without changing geometry or
    /// restarting its animations. Active rejection feedback keeps its red.
    func refreshAppearance(focusColor: CGColor, floatingColor: CGColor) {
        mainThreadOnly()
        guard !errorFeedback.isActive else { return }
        let focusedColor = renderedWindowID.map { floaterFrames[$0] != nil } == true
            ? floatingColor : focusColor
        accentCGColor = focusedColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let layer = glowView?.layer {
            layer.borderColor = focusedColor
            layer.backgroundColor = state == .active
                ? Self.activeFill(for: focusedColor, flashesOnFocus: flashesOnFocus)
                : CGColor.clear
        }
        for (_, border) in floatingPanels {
            border.outline.borderColor = floatingColor
            border.outline.shadowColor = floatingColor
        }
        CATransaction.commit()
    }

    deinit {
        // tests and future ownership swaps may drop a FocusBorder mid-life;
        // ensure we don't leak NSPanels or live timers in those cases.
        settleWork?.cancel()
        cancelActiveShake()
        panel?.orderOut(nil)
        for (_, border) in floatingPanels { border.panel.orderOut(nil) }
    }

    // MARK: - public API

    /// Show the focused-window border around `rect` and start the
    /// transition to the settled (outline-only) state after
    /// `settleDelaySec`. Cancels any in-flight settle before re-asserting.
    /// An active error flash keeps ownership until its bounded interval ends.
    /// With `glide`, a window switch travels from the old window instead
    /// of fading in.
    func show(around rect: CGRect, windowID: CGWindowID, glide: TimeInterval? = nil) {
        mainThreadOnly()
        guard isEnabled else { return }
        // Focus can change while a rejected drag is still reporting its
        // result. Keep the one-shot red panel intact; the owner re-resolves
        // current focus when the bounded feedback interval finishes.
        guard errorFeedback.permitsPersistentShow else { return }
        if isGliding(to: rect, windowID: windowID) { return }
        cancelGlide()
        // idempotent re-show: already painted on this window at this frame
        // and the state machine has progressed past .hidden — nothing to do.
        // without this, every redundant updateFocusBorder call (post-click
        // refocus, raiseBehind, app-activated polls) would re-fire the
        // active-tint → settle cycle and the user sees the window "light up
        // again" on each click.
        if state != .hidden, renderedWindowID == windowID,
           let f = trackedWindowFrame,
           abs(f.minX - rect.minX) < 1, abs(f.minY - rect.minY) < 1,
           abs(f.width - rect.width) < 1, abs(f.height - rect.height) < 1 {
            return
        }
        renderGeneration += 1
        // cancel any in-flight transition before re-asserting. Active error
        // feedback returned above and keeps ownership of the panel.
        settleWork?.cancel()
        cancelActiveShake()
        // drop a leftover error pill if show() reuses a panel mid-flash
        removeMessageBanner()

        // fade in on fresh appearance (panel orderedOut/nil'd, state hidden)
        // AND on window-to-window switches — both feel jarring if snapped.
        // Same-window repositioning (tile resize/move) keeps snap so the
        // border tracks live geometry without animation lag.
        let isFreshAppearance = (panel == nil) || (state == .hidden)
        let isWindowSwitch = (renderedWindowID != nil) && (renderedWindowID != windowID)
        let shouldFadeIn = isFreshAppearance || isWindowSwitch
        let glideFrom = glide != nil && !isFreshAppearance && isWindowSwitch ? trackedWindowFrame : nil

        let expansion = Tuning.activeBorderWidth / 2
        focusedCornerRadiusExpansion = expansion
        let nsRect = panelRect(for: rect, expansion: expansion)
        let windowRadius = WindowCornerRadius.resolve(for: windowID)

        let p: NSPanel
        if let existing = panel {
            p = existing
            if glideFrom == nil {
                p.setFrame(nsRect, display: false)
                positionGlowView(in: p)
            }
        } else {
            p = makePanel(frame: nsRect)
            panel = p
        }

        // active state: tint fill (unless the focus flash is off) + border,
        // centered on window edge
        if let layer = glowView?.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.borderColor = accentCGColor
            layer.borderWidth = Tuning.activeBorderWidth
            layer.cornerRadius = windowRadius + expansion
            layer.backgroundColor = Self.activeFill(for: accentCGColor, flashesOnFocus: flashesOnFocus)
            CATransaction.commit()
        }

        p.alphaValue = 1.0
        p.orderFront(nil)
        if let glow = glowView {
            if shouldFadeIn, glideFrom == nil {
                fadeViewAlpha(glow, from: 0, to: 1, duration: fadeDurationSec)
            } else {
                glow.layer?.removeAnimation(forKey: "fade")
                glow.layer?.opacity = 1
                glow.alphaValue = 1.0
            }
        }
        state = .active
        renderedWindowID = windowID
        trackedWindowFrame = rect
        if let glideFrom, let glide, !self.glide(from: glideFrom, to: rect, duration: glide) {
            p.setFrame(nsRect, display: false)
            positionGlowView(in: p)
        }

        // schedule transition to settled (outline only)
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Tuning.settleDelaySec, execute: work)
    }

    /// Reposition the focused-window border to `rect` without changing
    /// state. Called on tile/resize/move so the border tracks the
    /// window without re-running the show transition.
    func updatePosition(_ rect: CGRect) {
        mainThreadOnly()
        guard let p = panel, state != .hidden, trackedWindowID != nil else { return }
        if isGliding(to: rect, windowID: renderedWindowID) { return }
        cancelGlide()
        let expansion = Tuning.activeBorderWidth / 2
        let nsRect = panelRect(for: rect, expansion: expansion)
        p.setFrame(nsRect, display: false)
        positionGlowView(in: p)
        trackedWindowFrame = rect
    }

    /// Re-stamp the configured curvature without replaying show animations.
    func refreshCornerRadius() {
        mainThreadOnly()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let windowID = errorFeedbackWindowID ?? renderedWindowID, let layer = glowView?.layer {
            layer.cornerRadius = WindowCornerRadius.resolve(for: windowID)
                + focusedCornerRadiusExpansion
        }
        for (windowID, border) in floatingPanels {
            stampOutlineShape(border.outline, cornerRadius: WindowCornerRadius.resolve(for: windowID)
                + Tuning.floatingBorderWidth / 2)
        }
        CATransaction.commit()
    }

    /// Switch whether the floater panels draw. `.none` fades them out now.
    func setFloaterMarks(_ style: FloaterMarkStyle) {
        mainThreadOnly()
        floaterMarks = style
        if style == .none { hideFloatingBorders() }
    }

    /// Synchronous snapshot for tests: the outline width of the floater
    /// panel for `windowID`, or nil when it has none.
    func currentFloaterOutlineWidth(for windowID: CGWindowID) -> CGFloat? {
        floatingPanels[windowID]?.outline.borderWidth
    }

    /// Synchronous snapshot for tests: the floater outline's frame in its
    /// panel, its corner radius, and its glow.
    func currentFloaterOutline(for windowID: CGWindowID)
        -> (panel: NSRect, outline: CGRect, cornerRadius: CGFloat,
            glowRadius: CGFloat, glowOpacity: Float, glowColor: CGColor?, glowPath: CGPath?)? {
        guard let border = floatingPanels[windowID] else { return nil }
        let o = border.outline
        return (border.panel.frame, o.frame, o.cornerRadius, o.shadowRadius, o.shadowOpacity,
                o.shadowColor, o.shadowPath)
    }

    /// Synchronous style snapshot used by regression tests and diagnostics.
    func currentFocusedBorderCornerRadius() -> CGFloat? {
        glowView?.layer?.cornerRadius
    }

    /// Sync the floating-border panels to `frames`. Creates panels for
    /// new ids, repositions existing ones, and orders out any panel
    /// whose id is not present in the input — so a single call brings
    /// the floating-border set into agreement with the current
    /// floating-window set.
    func updateFloatingBorders(_ incoming: [CGWindowID: CGRect], color: CGColor) {
        mainThreadOnly()
        guard floaterMarks == .outline else { return }
        var frames = incoming
        if let drag = floaterDrag, frames[drag.id] != nil { frames[drag.id] = drag.frame }
        let visibleIDs = Set(frames.keys)
        let staleIDs = floatingPanels.keys.filter { !visibleIDs.contains($0) }
        for windowID in staleIDs { hideFloatingBorder(for: windowID) }

        floaterFrames = frames
        let expansion = Tuning.floatingBorderWidth / 2
        for (windowID, frame) in frames {
            let nsRect = panelRect(for: frame, expansion: Self.floaterPanelExpansion)
            let windowRadius = WindowCornerRadius.resolve(for: windowID)
            let border: BorderPanel
            if let existing = floatingPanels[windowID] {
                border = existing
                border.panel.setFrame(nsRect, display: false)
                positionFloaterViews(border)
            } else {
                border = makeFloatingPanel(frame: nsRect)
                floatingPanels[windowID] = border
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let outline = border.outline
            outline.borderColor = color
            outline.borderWidth = Tuning.floatingBorderWidth
            outline.backgroundColor = CGColor.clear
            outline.shadowColor = color
            outline.shadowOpacity = Tuning.floatingGlowOpacity
            outline.shadowRadius = Tuning.floatingGlowRadius
            outline.shadowOffset = .zero
            stampOutlineShape(outline, cornerRadius: windowRadius + expansion)
            CATransaction.commit()

            // no fade in: a window that just floated, or came back with a
            // workspace, is marked the moment it shows
            border.panel.alphaValue = 1.0
            border.glowView.alphaValue = 1.0
            border.panel.orderFront(nil)
        }
    }

    /// Move `windowID`'s outline to `frame` (CG) while the user drags the
    /// window. Geometry only: no fade, no ordering. The dragged floater is
    /// in front of everything, so its occlusion mask goes until the drag ends.
    func followFloaterDrag(_ windowID: CGWindowID, to frame: CGRect) {
        mainThreadOnly()
        floaterDrag = (windowID, frame)
        guard let border = floatingPanels[windowID] else { return }
        floaterFrames[windowID] = frame
        border.panel.setFrame(panelRect(for: frame, expansion: Self.floaterPanelExpansion), display: false)
        positionFloaterViews(border)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.glowView.layer?.mask = nil
        CATransaction.commit()
    }

    /// The drag ended. The refresh after the drop puts the outline on the
    /// settled frame and masks it again.
    func endFloaterDrag() {
        mainThreadOnly()
        floaterDrag = nil
    }

    /// The live drag frame the outline follows, nil when no drag is on. For tests.
    var currentFloaterDrag: (id: CGWindowID, frame: CGRect)? { floaterDrag }

    /// The floater panel's root layer, which carries the fade and the mask. For tests.
    func currentFloaterGlowLayer(for windowID: CGWindowID) -> CALayer? {
        floatingPanels[windowID]?.glowView.layer
    }

    /// Order out every floating-border panel with a fade and drop the cache.
    /// Captured panel references keep the windows alive through the animation
    /// while the dict is cleared synchronously so a subsequent
    /// `updateFloatingBorders` builds fresh panels.
    func hideFloatingBorders() {
        mainThreadOnly()
        let toFade = Array(floatingPanels.values)
        floatingPanels.removeAll()
        floaterFrames.removeAll()
        for border in toFade { fadeOutAndOrderOut(border.panel, layer: border.glowView.layer, duration: fadeDurationSec) }
    }

    /// Order out and forget the floating-border panel for `windowID`,
    /// with a fade. No-op when the id is unknown.
    func hideFloatingBorder(for windowID: CGWindowID) {
        mainThreadOnly()
        guard let border = floatingPanels.removeValue(forKey: windowID) else { return }
        floaterFrames.removeValue(forKey: windowID)
        fadeOutAndOrderOut(border.panel, layer: border.glowView.layer, duration: fadeDurationSec)
    }

    /// Order out `windowID`'s floater panel now, with no fade. A fade
    /// runs only once the main thread is free; before a layout pass that
    /// blocks it, the outline would sit on the old spot for the whole pass.
    func dropFloatingBorder(for windowID: CGWindowID) {
        mainThreadOnly()
        guard let border = floatingPanels.removeValue(forKey: windowID) else { return }
        floaterFrames.removeValue(forKey: windowID)
        border.panel.orderOut(nil)
    }

    /// Move `windowID`'s outline to `frame` (CG), geometry only, when the
    /// window moved: the window list's frame after the app said so. Its
    /// occlusion mask was cut for the old frame, so it goes until the settle
    /// refresh cuts a new one. A dragged floater keeps the newer frame for
    /// the drag too.
    func followFloater(_ windowID: CGWindowID, to frame: CGRect) {
        mainThreadOnly()
        guard let border = floatingPanels[windowID], floaterFrames[windowID] != frame else { return }
        if floaterDrag?.id == windowID { floaterDrag = (windowID, frame) }
        floaterFrames[windowID] = frame
        border.panel.setFrame(panelRect(for: frame, expansion: Self.floaterPanelExpansion), display: false)
        positionFloaterViews(border)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.glowView.layer?.mask = nil
        CATransaction.commit()
    }

    /// Where `windowID`'s floater outline sits now (CG), nil without one.
    func floaterOutlineFrame(_ windowID: CGWindowID) -> CGRect? {
        floatingPanels[windowID] == nil ? nil : floaterFrames[windowID]
    }

    /// Transition the focused-window panel from `active` (filled) to
    /// `settled` (outline only). Called automatically by the timer
    /// scheduled in `show`; safe to call manually as well.
    func settle() {
        mainThreadOnly()
        guard state == .active, let layer = glowView?.layer else { return }
        state = .settled

        // animate to outline-only
        CATransaction.begin()
        CATransaction.setAnimationDuration(Tuning.settleAnimationDurationSec)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        layer.backgroundColor = CGColor.clear
        layer.borderWidth = Tuning.settledBorderWidth
        CATransaction.commit()
    }

    /// Hide the focused-window border with a fade-out, then order out
    /// the panel.
    ///
    /// Detaches `panel` and `glowView` synchronously — the captured
    /// reference keeps the old panel alive through the animation, while
    /// the next `show` builds a fresh panel rather than reusing the one
    /// that is mid-fade. Cancels any pending settle or shake work. Without
    /// `fade` the panel goes at once, for a pass about to block the main
    /// thread, where a fade would only start once the pass ends.
    func hide(fade: Bool = true) {
        mainThreadOnly()
        if errorFeedback.isActive {
            hyprLog(.notice, .border, "error feedback cancel: wid=\(errorFeedbackWindowID ?? 0)")
        }
        settleWork?.cancel()
        cancelActiveShake()
        cancelGlide()
        errorFeedback.cancel()
        errorFeedbackWindowID = nil
        renderedWindowID = nil
        trackedWindowFrame = nil
        focusedCornerRadiusExpansion = Tuning.activeBorderWidth / 2
        removeMessageBanner()
        guard let p = panel, state != .hidden else { return }
        state = .hidden

        // detach panel + glowView synchronously so a subsequent show()
        // builds a fresh panel rather than reusing the one we're fading out.
        // the captured `p` keeps the old panel alive through the animation.
        let glowLayer = glowView?.layer
        panel = nil
        glowView = nil

        guard fade else { p.orderOut(nil); return }
        fadeOutAndOrderOut(p, layer: glowLayer, duration: fadeDurationSec)
    }

    /// Hide persistent focus chrome without interrupting one-shot rejection
    /// feedback. Used by ordinary focus refreshes when persistent borders are
    /// disabled or no managed window is under the cursor.
    func hidePersistentBorder() {
        mainThreadOnly()
        guard errorFeedback.permitsPersistentShow else { return }
        hide()
    }

    func beginErrorFeedback(windowID: CGWindowID) {
        errorFeedback.begin()
        errorFeedbackWindowID = windowID
        hyprLog(.notice, .border, "error feedback begin: wid=\(windowID)")
    }

    /// Flash a red border around `rect` and shake the overlay
    /// horizontally to signal a rejected operation (e.g. swap that
    /// would violate min-size constraints, move to a full workspace).
    /// The border auto-hides after the shake completes.
    ///
    /// Error feedback never moves the actual window, because verified
    /// geometry must remain unchanged after a rejection or restoration.
    ///
    /// - Parameter windowID: the flashed window; its corner radius shapes
    ///   the border.
    /// - Parameter message: short reason shown as a pill centered in the
    ///   flashed window — e.g. "Not enough room to swap".
    @discardableResult
    func flashError(around rect: CGRect, windowID: CGWindowID,
                    message: String? = nil) -> Int? {
        guard Self.errorFeedbackCanRender(isEnabled: isEnabled) else { return nil }
        mainThreadOnly()
        renderGeneration += 1
        let generation = renderGeneration
        settleWork?.cancel()
        cancelActiveShake()
        beginErrorFeedback(windowID: windowID)

        let expansion = Tuning.errorBorderWidth / 2
        focusedCornerRadiusExpansion = expansion
        let nsRect = panelRect(for: rect, expansion: expansion)
        let windowRadius = WindowCornerRadius.resolve(for: windowID)
        let p: NSPanel
        if let existing = panel {
            p = existing
            p.setFrame(nsRect, display: false)
            positionGlowView(in: p)
        } else {
            p = makePanel(frame: nsRect)
            panel = p
        }

        let red = NSColor.systemRed.cgColor
        if let layer = glowView?.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.borderColor = red
            layer.borderWidth = Tuning.errorBorderWidth
            layer.cornerRadius = windowRadius + expansion
            layer.backgroundColor = red.copy(alpha: Tuning.errorFillAlpha)
            CATransaction.commit()
        }

        p.alphaValue = 1.0
        p.orderFront(nil)
        state = .active
        renderedWindowID = windowID
        trackedWindowFrame = rect

        // reason pill, centered over the flashed window
        removeMessageBanner()
        if let message, let content = p.contentView {
            let banner = makeMessageBanner(message)
            var f = banner.frame
            f.origin.x = (content.bounds.width - f.width) / 2
            f.origin.y = (content.bounds.height - f.height) / 2
            banner.frame = f
            banner.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            content.addSubview(banner)
            messageBanner = banner
        }

        // shake only the overlay; moving the AX window would invalidate the
        // verified frame that the rejected transaction just restored.
        let panelBaseX = nsRect.origin.x
        restoreShakenWindow = { [weak self] in self?.onShakeRestore() }
        let offsets = Tuning.shakeOffsets
        let stepDuration = Tuning.shakeStepDurationSec
        var step = 0

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(Int(stepDuration * 1000)))
        shakeTimer = timer

        timer.setEventHandler { [weak self] in
            guard let self, let p = self.panel else { return }
            if step < offsets.count {
                let offset = offsets[step]
                var frame = p.frame
                frame.origin.x = panelBaseX + offset
                p.setFrame(frame, display: false)
                step += 1
            } else {
                self.cancelActiveShake()
                // leave the message still before fading out
                DispatchQueue.main.asyncAfter(deadline: .now() + Tuning.errorMessageHoldSec) { [weak self] in
                    guard let self, self.renderGeneration == generation else { return }
                    guard self.errorFeedback.finish() else { return }
                    let finishedID = self.errorFeedbackWindowID ?? 0
                    self.errorFeedbackWindowID = nil
                    hyprLog(.notice, .border, "error feedback end: wid=\(finishedID)")
                    self.hide()
                    self.onErrorFeedbackFinishedToken(generation)
                    self.onErrorFeedbackFinished()
                }
            }
        }
        timer.resume()
        return generation
    }

    @discardableResult
    func cancelErrorFeedback(token: Int) -> Bool {
        guard errorFeedback.isActive, renderGeneration == token else { return false }
        hide()
        return true
    }

    // MARK: - occlusion masking

    /// Apply `CALayer` masks so each border's portion that overlaps a
    /// higher-z tracked window is hidden.
    ///
    /// Both focus and floating borders sit at `.floating` tier — OS
    /// layering cannot resolve which border should appear when a floater
    /// is behind a focused tile, or vice versa. The caller computes
    /// occluder rects from `CGWindowListCopyWindowInfo` z-order; this
    /// method translates each occluder into glow-local NS coords and
    /// builds a mask path that excludes them.
    ///
    /// - Parameter focusedOccluders: rects of higher-z windows
    ///   overlapping the focused border.
    /// - Parameter floaterOccluders: per-window occluder rects for
    ///   floating borders.
    func applyOcclusion(focusedOccluders: [CGRect], floaterOccluders: [CGWindowID: [CGRect]]) {
        mainThreadOnly()
        if glideTarget != nil {
            glideOccluders = focusedOccluders
        } else if let frame = trackedWindowFrame, let glow = glowView {
            applyMask(to: glow, windowCGRect: frame,
                      expansion: Tuning.activeBorderWidth / 2,
                      occluders: focusedOccluders)
        }
        for (wid, border) in floatingPanels {
            guard let frame = floaterFrames[wid] else { continue }
            // the dragged floater is in front; the occluders came from a stale list
            let occluders = wid == floaterDrag?.id ? [] : floaterOccluders[wid] ?? []
            applyMask(to: border.glowView, windowCGRect: frame,
                      expansion: Self.floaterPanelExpansion,
                      occluders: occluders)
        }
    }

    private func applyMask(to glow: NSView, windowCGRect: CGRect, expansion: CGFloat, occluders: [CGRect]) {
        guard let layer = glow.layer else { return }
        if occluders.isEmpty {
            layer.mask = nil
            return
        }

        // visible region in glow-local NS coords (lower-left origin).
        // glow.bounds is the panel's content rect — `expansion` larger
        // than the window on every side. translate each occluder from
        // CG (top-down, screen origin) into glow-local NS:
        //   x_local = occCG.minX - (windowCG.minX - expansion)
        //   y_local = (windowCG.maxY + expansion) - occCG.maxY
        var pieces: [NSRect] = [layer.bounds]
        for occCG in occluders {
            let occLocal = NSRect(
                x: occCG.origin.x - (windowCGRect.origin.x - expansion),
                y: (windowCGRect.maxY + expansion) - occCG.maxY,
                width: occCG.width,
                height: occCG.height)
            pieces = pieces.flatMap { WindowStacking.subtract(occLocal, from: $0) }
        }

        let path = CGMutablePath()
        for piece in pieces { path.addRect(piece) }

        let mask = CAShapeLayer()
        mask.frame = layer.bounds
        mask.path = path
        mask.fillColor = NSColor.white.cgColor
        // disable implicit animations — mask updates can flicker otherwise
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.mask = mask
        CATransaction.commit()
    }

    // returns up to 4 strips representing `rect` minus `hole`.
    // MARK: - teleport glide

    /// Travel the outline from `old` to `new`, CG coordinates, while the
    /// window itself snaps. The panel covers both frames for the trip and
    /// shrinks back to the window when it lands. Same screen only.
    @discardableResult
    func glide(from old: CGRect, to new: CGRect, duration: TimeInterval) -> Bool {
        mainThreadOnly()
        guard let p = panel, let glow = glowView, let layer = glow.layer, state != .hidden,
              renderedWindowID != nil, !errorFeedback.isActive else { return false }
        let e = Tuning.activeBorderWidth / 2
        let union = old.union(new)
        p.setFrame(panelRect(for: union, expansion: e), display: false)
        // a window's border rect inside the union panel, NS (y up)
        func local(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX - union.minX, y: union.maxY - r.maxY,
                   width: r.width + 2 * e, height: r.height + 2 * e)
        }
        let from = local(old), to = local(new)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.mask = nil
        glow.frame = to
        CATransaction.commit()
        trackedWindowFrame = new
        glideTarget = new
        glideOccluders = []

        let anchor = layer.anchorPoint
        func position(_ r: CGRect) -> CGPoint {
            CGPoint(x: r.minX + anchor.x * r.width, y: r.minY + anchor.y * r.height)
        }
        let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: position(from))
        move.toValue = NSValue(point: position(to))
        let size = CABasicAnimation(keyPath: "bounds.size")
        size.fromValue = NSValue(size: from.size)
        size.toValue = NSValue(size: to.size)
        let group = CAAnimationGroup()
        group.animations = [move, size]
        group.duration = duration
        group.timingFunction = timing
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.finishGlide(at: new) }
        layer.add(group, forKey: "glide")
        CATransaction.commit()
        return true
    }

    private func isGliding(to rect: CGRect, windowID: CGWindowID?) -> Bool {
        guard let glideTarget, state != .hidden, windowID == renderedWindowID else { return false }
        return TeleportPlanner.travel(glideTarget, rect) < TeleportPlanner.minimumTravel
    }

    private func cancelGlide() {
        guard glideTarget != nil else { return }
        glideTarget = nil
        glowView?.layer?.removeAnimation(forKey: "glide")
        if let p = panel, let rect = trackedWindowFrame {
            p.setFrame(panelRect(for: rect, expansion: Tuning.activeBorderWidth / 2), display: false)
            positionGlowView(in: p)
        }
    }

    // back to a panel the size of the window, so the rest of the class
    // can keep assuming the glow fills the panel
    private func finishGlide(at rect: CGRect) {
        guard let glideTarget, glideTarget.equalTo(rect), state != .hidden,
              let p = panel, let glow = glowView else { return }
        self.glideTarget = nil
        let e = Tuning.activeBorderWidth / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        p.setFrame(panelRect(for: rect, expansion: e), display: false)
        positionGlowView(in: p)
        CATransaction.commit()
        if !glideOccluders.isEmpty {
            applyMask(to: glow, windowCGRect: rect, expansion: e, occluders: glideOccluders)
            glideOccluders = []
        }
    }

    // MARK: - panel setup

    private func makePanel(frame: NSRect) -> NSPanel {
        let p = makeBasePanel(frame: frame)
        let glow = makeGlowView()
        p.contentView?.addSubview(glow)
        glowView = glow
        positionGlowView(in: p)

        return p
    }

    private func makeFloatingPanel(frame: NSRect) -> BorderPanel {
        let p = makeBasePanel(frame: frame)
        let glow = makeGlowView()
        p.contentView?.addSubview(glow)
        // the glow is a shadow, so the stroke's layer must not clip. the
        // root still clips, and the panel has room for the blur
        let outline = CALayer()
        outline.masksToBounds = false
        glow.layer?.addSublayer(outline)
        let border = BorderPanel(panel: p, glowView: glow, outline: outline)
        positionFloaterViews(border)
        return border
    }

    /// Layer-hosting glow view. We assign the CALayer BEFORE `wantsLayer`
    /// so AppKit treats this as a layer-hosting view (we own the layer)
    /// rather than layer-backed (AppKit re-syncs view→layer each draw).
    /// In layer-hosting mode `CABasicAnimation` on opacity actually paints
    /// the in-between frames instead of being instantly overridden.
    private func makeGlowView() -> NSView {
        let glow = NSView()
        let hosted = CALayer()
        hosted.masksToBounds = true
        glow.layer = hosted
        glow.wantsLayer = true
        return glow
    }

    // MARK: - error message banner

    private func removeMessageBanner() {
        messageBanner?.removeFromSuperview()
        messageBanner = nil
    }

    /// One-shot neutral flash: accent-stroked outline plus a message pill
    /// at `rect` (CG coords). Independent of the border state machine —
    /// safe to fire while the border tracks another window. No shake.
    func flashInfo(message: String, around rect: CGRect, windowID: CGWindowID = 0) {
        mainThreadOnly()
        guard isEnabled else { return }
        let frame = panelRect(for: rect, expansion: 0)
        let panel = makeBasePanel(frame: frame)
        panel.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        if let layer = content.layer {
            layer.borderColor = accentCGColor
            layer.borderWidth = 2.0
            layer.cornerRadius = WindowCornerRadius.resolve(for: windowID)
        }
        let pill = makeMessageBanner(message)
        pill.setFrameOrigin(NSPoint(x: (frame.width - pill.frame.width) / 2,
                                    y: (frame.height - pill.frame.height) / 2))
        content.addSubview(pill)
        panel.contentView?.addSubview(content)
        infoPanels.append(panel)
        panel.orderFrontRegardless()
        fadeViewAlpha(content, from: 0, to: 1, duration: 0.12)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self, weak panel] in
            guard let self, let panel else { return }
            fadeOutAndOrderOut(panel, layer: nil, duration: 0.3)
            infoPanels.removeAll { $0 === panel }
        }
    }

    /// Dark rounded pill holding a centered white reason string. Sized to
    /// fit the text plus padding; positioned by the caller.
    private func makeMessageBanner(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.sizeToFit()

        let padX: CGFloat = 14, padY: CGFloat = 8
        let pill = NSView(frame: NSRect(x: 0, y: 0,
                                        width: label.frame.width + padX * 2,
                                        height: label.frame.height + padY * 2))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        pill.layer?.cornerRadius = 10
        label.frame = NSRect(x: padX, y: padY,
                             width: label.frame.width, height: label.frame.height)
        pill.addSubview(label)
        return pill
    }

    private func makeBasePanel(frame: NSRect) -> NSPanel {
        let p = ClickThroughPanel(contentRect: frame,
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        p.isFloatingPanel = true
        // .floating keeps borders above the dim panel (.floating - 1, or
        // .normal in scrim mode) and above all .normal-level app windows.
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
        // Critical: the default `.utilityWindow` behavior applies a system
        // fade on orderFront/orderOut that *replaces* explicit alpha
        // animations on our content. With `.none`, our CABasicAnimation
        // on the glow layer's opacity is what the user actually sees.
        p.animationBehavior = .none
        observedPanels.add(p)
        return p
    }

    private func disableImmediately() {
        mainThreadOnly()
        renderGeneration += 1
        settleWork?.cancel()
        settleWork = nil
        cancelActiveShake()
        errorFeedback.cancel()
        errorFeedbackWindowID = nil
        for owned in observedPanels.allObjects {
            owned.contentView?.subviews.forEach { $0.layer?.removeAllAnimations() }
            owned.orderOut(nil)
        }
        panel = nil
        glowView = nil
        floatingPanels.removeAll()
        floaterFrames.removeAll()
        floaterDrag = nil
        infoPanels.removeAll()
        renderedWindowID = nil
        trackedWindowFrame = nil
        state = .hidden
        focusedCornerRadiusExpansion = Tuning.activeBorderWidth / 2
        removeMessageBanner()
    }

    private func cancelActiveShake() {
        shakeTimer?.cancel()
        shakeTimer = nil
        let restore = restoreShakenWindow
        restoreShakenWindow = nil
        restore?()
    }

    private func positionGlowView(in panel: NSPanel) {
        guard let glow = glowView else { return }
        positionGlowView(glow, in: panel)
    }

    private func positionGlowView(_ glow: NSView, in panel: NSPanel) {
        guard let content = panel.contentView else { return }
        // glow fills the entire panel; the panel itself is sized
        // slightly larger than the window so the stroke (drawn inset
        // from glow's outer edge) lands centered on the window edge.
        glow.frame = content.bounds
    }

    /// Fill the floater panel with its glow view and inset the outline by
    /// the glow room, so the stroke stays centered on the window edge.
    private func positionFloaterViews(_ border: BorderPanel) {
        positionGlowView(border.glowView, in: border.panel)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.outline.frame = FloaterOutlineGeometry.outlineFrame(
            inPanelBounds: border.glowView.bounds, glowRadius: Tuning.floatingGlowRadius)
        stampOutlineShape(border.outline, cornerRadius: border.outline.cornerRadius)
        CATransaction.commit()
    }

    /// Corner radius plus the glow's explicit path: the stroke's own ring,
    /// so the shadow never has to read the layer's contents.
    private func stampOutlineShape(_ outline: CALayer, cornerRadius: CGFloat) {
        outline.cornerRadius = cornerRadius
        outline.shadowPath = FloaterOutlineGeometry.ringPath(
            in: outline.bounds, cornerRadius: cornerRadius, borderWidth: Tuning.floatingBorderWidth)
    }

    // MARK: - fade helpers

    /// Animate the view's layer opacity with a `CABasicAnimation`. The glow
    /// view is layer-hosting (see `makeGlowView`), so AppKit does not
    /// overwrite the layer.
    /// Panel-level (`NSWindow.alphaValue`) animations also no-op on these
    /// borderless `.floating` non-activating panels for reasons not fully
    /// understood — animating the contentView is what actually paints.
    private func fadeViewAlpha(_ view: NSView, from: CGFloat, to: CGFloat, duration: TimeInterval) {
        guard let layer = view.layer else { view.alphaValue = to; return }
        layer.removeAnimation(forKey: "fade")
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = Float(from)
        anim.toValue = Float(to)
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        anim.fillMode = .both
        anim.isRemovedOnCompletion = true
        layer.opacity = Float(to)
        layer.add(anim, forKey: "fade")
    }

    /// Fade the glow view to 0, then orderOut the panel. Captured panel
    /// keeps the window alive through the animation.
    private func fadeOutAndOrderOut(_ p: NSPanel, layer: CALayer?,
                                    duration: TimeInterval) {
        guard let glowLayer = (p.contentView?.subviews.first?.layer) else {
            p.orderOut(nil); return
        }
        let fromOpacity = glowLayer.opacity
        glowLayer.removeAnimation(forKey: "fade")
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = fromOpacity
        anim.toValue = 0
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { p.orderOut(nil) }
        glowLayer.opacity = 0
        glowLayer.add(anim, forKey: "fade")
        CATransaction.commit()
    }

    // MARK: - coordinate conversion

    var primaryScreenHeight: CGFloat = 0

    /// Panel rect expanded outward from `cgRect` by `expansion` on each
    /// side. Pass `strokeWidth/2` to land the stroke's centerline on
    /// the window edge.
    private func panelRect(for cgRect: CGRect, expansion: CGFloat) -> NSRect {
        let primaryH = primaryScreenHeight
        let nsY = primaryH - cgRect.origin.y - cgRect.height
        return NSRect(x: cgRect.origin.x - expansion,
                      y: nsY - expansion,
                      width: cgRect.width + expansion * 2,
                      height: cgRect.height + expansion * 2)
    }
}
