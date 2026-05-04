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
        static let hideAnimationDurationSec: TimeInterval = 0.15
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
        // cancel any in-flight transition (settle, shake) before re-asserting.
        // without this, a pending shake or settle can mutate the panel after
        // show() returns and undo the new frame/state.
        settleWork?.cancel()
        shakeTimer?.cancel()
        shakeTimer = nil

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
            if let existing = floatingPanels[windowID] {
                border = existing
                border.panel.setFrame(nsRect, display: false)
                positionGlowView(border.glowView, in: border.panel)
            } else {
                border = makeFloatingPanel(frame: nsRect)
                floatingPanels[windowID] = border
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
        }
    }

    /// Order out every floating-border panel and drop the cache.
    func hideFloatingBorders() {
        mainThreadOnly()
        for (_, border) in floatingPanels {
            border.panel.orderOut(nil)
        }
        floatingPanels.removeAll()
        floaterFrames.removeAll()
    }

    /// Order out and forget the floating-border panel for `windowID`.
    /// No-op when the id is unknown.
    func hideFloatingBorder(for windowID: CGWindowID) {
        mainThreadOnly()
        guard let border = floatingPanels.removeValue(forKey: windowID) else { return }
        border.panel.orderOut(nil)
        floaterFrames.removeValue(forKey: windowID)
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
        guard let p = panel, state != .hidden else { return }
        state = .hidden

        // detach panel + glowView synchronously so a subsequent show()
        // builds a fresh panel rather than reusing the one we're fading out.
        // the captured `p` keeps the old panel alive through the animation.
        panel = nil
        glowView = nil

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Tuning.hideAnimationDurationSec
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }

    /// Flash a red border around `rect` and shake the window
    /// horizontally to signal a rejected operation (e.g. swap that
    /// would violate min-size constraints, move to a full workspace).
    /// The border auto-hides after the shake completes.
    ///
    /// - Parameter window: when supplied, the actual window oscillates
    ///   along with the overlay panel; without it, only the overlay
    ///   shakes.
    func flashError(around rect: CGRect, windowID: CGWindowID, window: HyprWindow? = nil) {
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
        let glow = NSView()
        glow.wantsLayer = true
        glow.layer?.masksToBounds = true
        p.contentView?.addSubview(glow)
        glowView = glow
        positionGlowView(in: p)

        return p
    }

    private func makeFloatingPanel(frame: NSRect) -> BorderPanel {
        let p = makeBasePanel(frame: frame)
        let glow = NSView()
        glow.wantsLayer = true
        glow.layer?.masksToBounds = true
        p.contentView?.addSubview(glow)
        positionGlowView(glow, in: p)
        return BorderPanel(panel: p, glowView: glow)
    }

    private func makeBasePanel(frame: NSRect) -> NSPanel {
        let p = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        // Phase 5b: .floating tier guarantees borders sit above the dim panel
        // (one tier below at .floating - 1) and above all .normal-level app
        // windows. previously .normal + order(.above, relativeTo: windowID),
        // which became undefined when the focused window closed.
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
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
