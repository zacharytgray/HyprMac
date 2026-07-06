// Persistent focus indicator around the active window, plus outline-only
// borders around every visible floating window. Implemented as borderless
// `NSPanel`s at `.floating` tier with `CALayer` masking for occlusion.

import Cocoa

/// Visual focus indicator: a tinted outline around the focused window
/// and a thinner outline around each visible floating window.
///
/// State machine on the focused-window panel:
/// ```
/// hidden  --show()-->        active   (tint fill + border)
/// active  --settle()-->      settled  (outline only, no fill)
/// any     --hide()-->        hidden   (fade out + orderOut + nil-out)
/// any     --flashError()-->  active   (red shake; hides itself afterward)
/// ```
///
/// Floating-window panels are keyed by `CGWindowID` and managed
/// independently via `updateFloatingBorders` / `hideFloatingBorders`.
///
/// Lifecycle invariants: every public mutation cancels in-flight work
/// (`settleWork`, `shakeTimer`) before reassigning; `hide` nils the
/// focused panel and its glow view synchronously so the next `show`
/// builds a fresh panel rather than reusing one that is mid-fade;
/// `deinit` guarantees cleanup of every owned panel and timer.
///
/// Threading: main-thread only. Public methods assert via
/// `mainThreadOnly()`.
class FocusBorder {
    private(set) var trackedWindowID: CGWindowID?

    private var panel: NSPanel?
    private var glowView: NSView?
    private var floatingPanels: [CGWindowID: BorderPanel] = [:]
    private var settleWork: DispatchWorkItem?
    private var shakeTimer: DispatchSourceTimer?
    private var state: State = .hidden
    // pill shown centered in the error panel explaining a rejection.
    private var messageBanner: NSView?

    // remembered CG frames — used by applyOcclusion to translate occluder
    // CG rects into glow-local NS coords. kept in sync with panel positions.
    private var trackedWindowFrame: CGRect?
    private var floaterFrames: [CGWindowID: CGRect] = [:]

    private enum State { case active, settled, hidden }
    private struct BorderPanel {
        let panel: NSPanel
        let glowView: NSView
    }

    /// Tunables. Empirical timings (settle delay, shake step) and
    /// stroke widths. Per-window corner radius is resolved via
    /// `WindowCornerRadius` rather than a single static value, so the
    /// border arcs concentrically with whatever radius the underlying
    /// app actually renders.
    private enum Tuning {
        static let settleDelaySec: TimeInterval = 0.5
        static let settleAnimationDurationSec: TimeInterval = 0.3
        // fast enough to feel instant, slow enough to register visually.
        // applied on transitions from hidden → active (workspace switch,
        // app un-hide, fresh focus), on focus changes between windows, and
        // when a floater's border first appears.
        static let showAnimationDurationSec: TimeInterval = 0.22
        static let hideAnimationDurationSec: TimeInterval = 0.28
        static let floatingShowAnimationDurationSec: TimeInterval = 0.22
        static let floatingHideAnimationDurationSec: TimeInterval = 0.28
        static let shakeStepDurationSec: TimeInterval = 0.04
        static let shakeOffsets: [CGFloat] = [10, -10, 7, -7, 3, -3, 0]
        static let shakeFadeDelaySec: TimeInterval = 0.15
        static let activeBorderWidth: CGFloat = 2
        static let settledBorderWidth: CGFloat = 1.5
        static let floatingBorderWidth: CGFloat = 1.5
        static let errorBorderWidth: CGFloat = 2.5
        static let activeFillAlpha: CGFloat = 0.08
        static let errorFillAlpha: CGFloat = 0.12
    }

    // resolved from config — call updateColor() when config changes
    var accentCGColor: CGColor = NSColor.controlAccentColor.cgColor

    /// Shared fade duration used by `show`, `hide`, the floating-border
    /// counterparts, and the `flashError` follow-up. Settle (the
    /// active-tint → outline transition) and shake keep their own
    /// constants in `Tuning` — those are timing-of-interaction values,
    /// not chrome appearance. Set by `WindowManager` from
    /// `config.chromeFadeDurationSec`.
    var fadeDurationSec: TimeInterval = Tuning.showAnimationDurationSec

    deinit {
        // tests and future ownership swaps may drop a FocusBorder mid-life;
        // ensure we don't leak NSPanels or live timers in those cases.
        settleWork?.cancel()
        shakeTimer?.cancel()
        panel?.orderOut(nil)
        for (_, border) in floatingPanels { border.panel.orderOut(nil) }
    }

    // MARK: - public API

    /// Show the focused-window border around `rect` and start the
    /// transition to the settled (outline-only) state after
    /// `settleDelaySec`. Cancels any in-flight settle or shake before
    /// re-asserting — without this, a pending shake or settle would
    /// stomp the new frame moments after `show` returns.
    func show(around rect: CGRect, windowID: CGWindowID) {
        mainThreadOnly()
        // idempotent re-show: already painted on this window at this frame
        // and the state machine has progressed past .hidden — nothing to do.
        // without this, every redundant updateFocusBorder call (post-click
        // refocus, raiseBehind, app-activated polls) would re-fire the
        // active-tint → settle cycle and the user sees the window "light up
        // again" on each click.
        if state != .hidden, trackedWindowID == windowID,
           let f = trackedWindowFrame,
           abs(f.minX - rect.minX) < 1, abs(f.minY - rect.minY) < 1,
           abs(f.width - rect.width) < 1, abs(f.height - rect.height) < 1 {
            return
        }
        // cancel any in-flight transition (settle, shake) before re-asserting.
        // without this, a pending shake or settle can mutate the panel after
        // show() returns and undo the new frame/state.
        settleWork?.cancel()
        shakeTimer?.cancel()
        shakeTimer = nil
        // drop a leftover error pill if show() reuses a panel mid-flash
        removeMessageBanner()

        // fade in on fresh appearance (panel orderedOut/nil'd, state hidden)
        // AND on window-to-window switches — both feel jarring if snapped.
        // Same-window repositioning (tile resize/move) keeps snap so the
        // border tracks live geometry without animation lag.
        let isFreshAppearance = (panel == nil) || (state == .hidden)
        let isWindowSwitch = (trackedWindowID != nil) && (trackedWindowID != windowID)
        let shouldFadeIn = isFreshAppearance || isWindowSwitch

        let expansion = Tuning.activeBorderWidth / 2
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

        // active state: tint fill + border, centered on window edge
        if let layer = glowView?.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.borderColor = accentCGColor
            layer.borderWidth = Tuning.activeBorderWidth
            layer.cornerRadius = windowRadius + expansion
            layer.backgroundColor = accentCGColor.copy(alpha: Tuning.activeFillAlpha)
            CATransaction.commit()
        }

        p.alphaValue = 1.0
        p.orderFront(nil)
        if let glow = glowView {
            if shouldFadeIn {
                fadeViewAlpha(glow, from: 0, to: 1, duration: fadeDurationSec)
            } else {
                glow.alphaValue = 1.0
            }
        }
        state = .active
        trackedWindowID = windowID
        trackedWindowFrame = rect

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
        let expansion = Tuning.activeBorderWidth / 2
        let nsRect = panelRect(for: rect, expansion: expansion)
        p.setFrame(nsRect, display: false)
        positionGlowView(in: p)
        trackedWindowFrame = rect
    }

    /// Sync the floating-border panels to `frames`. Creates panels for
    /// new ids, repositions existing ones, and orders out any panel
    /// whose id is not present in the input — so a single call brings
    /// the floating-border set into agreement with the current
    /// floating-window set.
    func updateFloatingBorders(_ frames: [CGWindowID: CGRect], color: CGColor) {
        mainThreadOnly()
        let visibleIDs = Set(frames.keys)
        let staleIDs = floatingPanels.keys.filter { !visibleIDs.contains($0) }
        for windowID in staleIDs { hideFloatingBorder(for: windowID) }

        floaterFrames = frames
        let expansion = Tuning.floatingBorderWidth / 2
        for (windowID, frame) in frames {
            let nsRect = panelRect(for: frame, expansion: expansion)
            let windowRadius = WindowCornerRadius.resolve(for: windowID)
            let border: BorderPanel
            let isNewPanel: Bool
            if let existing = floatingPanels[windowID] {
                border = existing
                border.panel.setFrame(nsRect, display: false)
                positionGlowView(border.glowView, in: border.panel)
                isNewPanel = false
            } else {
                border = makeFloatingPanel(frame: nsRect)
                floatingPanels[windowID] = border
                isNewPanel = true
            }

            if let layer = border.glowView.layer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.borderColor = color
                layer.borderWidth = Tuning.floatingBorderWidth
                layer.cornerRadius = windowRadius + expansion
                layer.backgroundColor = CGColor.clear
                CATransaction.commit()
            }

            border.panel.alphaValue = 1.0
            border.panel.orderFront(nil)
            if isNewPanel {
                fadeViewAlpha(border.glowView, from: 0, to: 1,
                              duration: fadeDurationSec)
            } else {
                border.glowView.alphaValue = 1.0
            }
        }
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
    /// that is mid-fade. Cancels any pending settle or shake work.
    func hide() {
        mainThreadOnly()
        settleWork?.cancel()
        shakeTimer?.cancel()
        shakeTimer = nil
        trackedWindowID = nil
        trackedWindowFrame = nil
        removeMessageBanner()
        guard let p = panel, state != .hidden else { return }
        state = .hidden

        // detach panel + glowView synchronously so a subsequent show()
        // builds a fresh panel rather than reusing the one we're fading out.
        // the captured `p` keeps the old panel alive through the animation.
        let glowLayer = glowView?.layer
        panel = nil
        glowView = nil

        fadeOutAndOrderOut(p, layer: glowLayer, duration: fadeDurationSec)
    }

    /// Flash a red border around `rect` and shake the window
    /// horizontally to signal a rejected operation (e.g. swap that
    /// would violate min-size constraints, move to a full workspace).
    /// The border auto-hides after the shake completes.
    ///
    /// - Parameter window: when supplied, the actual window oscillates
    ///   along with the overlay panel; without it, only the overlay
    ///   shakes.
    /// - Parameter message: short reason shown as a pill centered in the
    ///   flashed window — e.g. "Not enough room to swap".
    func flashError(around rect: CGRect, windowID: CGWindowID, window: HyprWindow? = nil, message: String? = nil) {
        mainThreadOnly()
        settleWork?.cancel()
        shakeTimer?.cancel()

        let expansion = Tuning.errorBorderWidth / 2
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
        trackedWindowID = windowID
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

        // shake: oscillate both the overlay panel and the actual window
        let panelBaseX = nsRect.origin.x
        let windowBaseX = rect.origin.x
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
                window?.position = CGPoint(x: windowBaseX + offset, y: rect.origin.y)
                step += 1
            } else {
                self.shakeTimer?.cancel()
                self.shakeTimer = nil
                // restore window to exact original position
                window?.position = CGPoint(x: windowBaseX, y: rect.origin.y)
                // fade out after shake
                DispatchQueue.main.asyncAfter(deadline: .now() + Tuning.shakeFadeDelaySec) { [weak self] in
                    self?.hide()
                }
            }
        }
        timer.resume()
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
        if let frame = trackedWindowFrame, let glow = glowView {
            applyMask(to: glow, windowCGRect: frame,
                      expansion: Tuning.activeBorderWidth / 2,
                      occluders: focusedOccluders)
        }
        for (wid, border) in floatingPanels {
            guard let frame = floaterFrames[wid] else { continue }
            let occluders = floaterOccluders[wid] ?? []
            applyMask(to: border.glowView, windowCGRect: frame,
                      expansion: Tuning.floatingBorderWidth / 2,
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
            pieces = pieces.flatMap { subtract(occLocal, from: $0) }
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
    // mirrors DimmingOverlay.subtract — same algorithm, kept local to avoid
    // crossing the FocusBorder/DimmingOverlay file boundary for a 25-line helper.
    private func subtract(_ hole: NSRect, from rect: NSRect) -> [NSRect] {
        guard rect.intersects(hole) else { return [rect] }
        let clipped = rect.intersection(hole)
        if clipped == rect { return [] }
        var pieces: [NSRect] = []
        if rect.maxY > clipped.maxY {
            pieces.append(NSRect(x: rect.minX, y: clipped.maxY,
                                 width: rect.width, height: rect.maxY - clipped.maxY))
        }
        if clipped.minY > rect.minY {
            pieces.append(NSRect(x: rect.minX, y: rect.minY,
                                 width: rect.width, height: clipped.minY - rect.minY))
        }
        if clipped.minX > rect.minX {
            pieces.append(NSRect(x: rect.minX, y: clipped.minY,
                                 width: clipped.minX - rect.minX, height: clipped.height))
        }
        if rect.maxX > clipped.maxX {
            pieces.append(NSRect(x: clipped.maxX, y: clipped.minY,
                                 width: rect.maxX - clipped.maxX, height: clipped.height))
        }
        return pieces
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
        positionGlowView(glow, in: p)
        return BorderPanel(panel: p, glowView: glow)
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
        panel.orderFrontRegardless()
        fadeViewAlpha(content, from: 0, to: 1, duration: 0.12)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [self] in
            fadeOutAndOrderOut(panel, layer: nil, duration: 0.3)
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
        let p = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        // Phase 5b: .floating tier guarantees borders render above the dim
        // panel — which sits at .floating - 1 in normal mode and .normal in
        // scrim mode — and above all .normal-level app windows. previously
        // .normal + order(.above, relativeTo: windowID), which became
        // undefined when the focused window closed.
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
        return p
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

    // MARK: - fade helpers

    /// Animate an NSView's `alphaValue`. Goes through NSAnimationContext +
    /// the view's animator proxy — the documented, reliable path for
    /// layer-backed NSViews. CALayer.opacity directly doesn't work here
    /// because AppKit re-syncs the layer's properties from the view on
    /// each draw cycle and overwrites the in-flight animation.
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
