// Corner brackets shown around the focused window while the Hypr key is
// held. Screenshot-tool style: four L-shaped marks at the window corners,
// scale-in on Hypr-down, fade-out on Hypr-up. Always shown regardless of
// the focus-border toggle.

import Cocoa

/// Camera/screenshot-style corner brackets pointing at the focused
/// window's corners. Single borderless `NSPanel` at `.floating` tier
/// hosting four `CAShapeLayer`s — one per corner.
///
/// Lifecycle:
/// ```
/// hidden  --show()-->     visible   (scale-in + fade-in)
/// visible --updatePos()-> visible   (re-stamp paths, no animation)
/// visible --hide()-->     hidden   (fade-out + orderOut)
/// ```
///
/// Threading: main-thread only.
class FocusBrackets {
    private(set) var trackedWindowID: CGWindowID?
    private(set) var isVisible = false

    private var panel: NSPanel?
    private var hostView: NSView?
    // ordered [topLeft, topRight, bottomLeft, bottomRight]
    private var cornerLayers: [CAShapeLayer] = []
    // contrast outline drawn behind each corner. same path, wider stroke,
    // color picked from accent brightness (white outline behind dark
    // accent, black outline behind light accent).
    private var outlineLayers: [CAShapeLayer] = []
    private var trackedFrame: CGRect?

    /// Resolved from config — call before `show()` when the user picks a
    /// new color in settings. Same source as `FocusBorder.accentCGColor`.
    var accentCGColor: CGColor = NSColor.controlAccentColor.cgColor

    /// Primary screen height for CG → NS coordinate flip. Set from
    /// `WindowManager` alongside `FocusBorder.primaryScreenHeight`.
    var primaryScreenHeight: CGFloat = 0

    private enum Tuning {
        // straight leg length on each side of the corner arc.
        static let legLength: CGFloat = 14
        static let strokeWidth: CGFloat = 4.5
        // contrast outline stroke — wider than the accent stroke so it
        // shows ~1.25pt on each side. drawn behind the accent layer.
        static let outlineStrokeWidth: CGFloat = 7
        // inset from window edge — brackets sit *inside* the window
        // padded away from its edge.
        static let inset: CGFloat = 14
        // outward translation each corner starts at during scale-in.
        // brackets snap inward from this offset, mimicking a camera
        // autofocus locking on.
        static let initialOffset: CGFloat = 6
        static let scaleInDurationSec: TimeInterval = 0.10
        static let fadeOutDurationSec: TimeInterval = 0.12
    }

    deinit {
        panel?.orderOut(nil)
    }

    // MARK: - public API

    /// Show brackets around `rect`. Scale-in animation on first appear,
    /// re-stamps in place when already visible on a different window or
    /// frame.
    func show(around rect: CGRect, windowID: CGWindowID) {
        mainThreadOnly()

        let p: NSPanel
        if let existing = panel {
            p = existing
        } else {
            p = makePanel(frame: panelRect(for: rect))
            panel = p
        }

        let isFirstAppear = !isVisible
        let isWindowSwitch = trackedWindowID != nil && trackedWindowID != windowID

        p.setFrame(panelRect(for: rect), display: false)
        layoutHostView(in: p)
        stampCornerPaths()

        // accent color may have changed since last show — update both
        // the colored stroke and the contrast outline behind it.
        let outline = Self.contrastOutlineColor(for: accentCGColor)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in cornerLayers { layer.strokeColor = accentCGColor }
        for layer in outlineLayers { layer.strokeColor = outline }
        CATransaction.commit()

        p.alphaValue = 1.0
        p.orderFront(nil)
        isVisible = true
        trackedWindowID = windowID
        trackedFrame = rect

        if isFirstAppear || isWindowSwitch {
            animateScaleIn()
        }
    }

    /// Re-position brackets to `rect` without animation. Called when the
    /// focused window changes mid-press (e.g. via Hypr+arrow).
    func updatePosition(_ rect: CGRect) {
        mainThreadOnly()
        guard let p = panel, isVisible else { return }
        p.setFrame(panelRect(for: rect), display: false)
        layoutHostView(in: p)
        stampCornerPaths()
        trackedFrame = rect
    }

    /// Fade out and order out. Cheap to call repeatedly — no-op when
    /// already hidden.
    func hide() {
        mainThreadOnly()
        guard isVisible, let p = panel else { return }
        isVisible = false
        trackedWindowID = nil
        trackedFrame = nil

        let captured = p
        let duration = Tuning.fadeOutDurationSec

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            captured.animator().alphaValue = 0
        }, completionHandler: {
            captured.orderOut(nil)
            captured.alphaValue = 1.0
        })
    }

    // MARK: - drawing

    private func stampCornerPaths() {
        guard let host = hostView, let windowID = trackedWindowID else { return }
        let bounds = host.bounds
        let inset = Tuning.inset
        let leg = Tuning.legLength
        // arc curvature matches the host window's own corner radius so
        // each bracket looks like a piece of the window's own corner,
        // floated inward.
        let r = WindowCornerRadius.resolve(for: windowID)
        let W = bounds.width
        let H = bounds.height

        // arc centers chosen so the arc is tangent to the inset edges:
        // top edge at y = H - inset, left edge at x = inset, etc.
        let centers = [
            CGPoint(x: inset + r, y: H - inset - r),       // TL
            CGPoint(x: W - inset - r, y: H - inset - r),   // TR
            CGPoint(x: inset + r, y: inset + r),           // BL
            CGPoint(x: W - inset - r, y: inset + r),       // BR
        ]
        let arcs: [(CGFloat, CGFloat)] = [
            (.pi / 2, .pi),         // TL: top tangent → left tangent
            (0, .pi / 2),           // TR: right tangent → top tangent
            (.pi, 3 * .pi / 2),     // BL: left tangent → bottom tangent
            (3 * .pi / 2, 2 * .pi), // BR: bottom tangent → right tangent
        ]

        ensureCornerLayers(host: host)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<4 {
            let path = makeCornerPath(
                center: centers[i],
                arcRadius: r,
                startAngle: arcs[i].0,
                endAngle: arcs[i].1,
                legLength: leg)
            outlineLayers[i].frame = bounds
            outlineLayers[i].path = path
            cornerLayers[i].frame = bounds
            cornerLayers[i].path = path
        }
        CATransaction.commit()
    }

    /// Build a single corner bracket: a straight leg, a 90° arc, another
    /// straight leg. Arc radius matches the window's corner radius so
    /// the bracket reads as a corner echo. Legs extend tangent to the
    /// arc, along the window's edges (inset by `Tuning.inset`).
    private func makeCornerPath(center: CGPoint,
                                arcRadius: CGFloat,
                                startAngle: CGFloat,
                                endAngle: CGFloat,
                                legLength: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let start = CGPoint(x: center.x + arcRadius * cos(startAngle),
                            y: center.y + arcRadius * sin(startAngle))
        let end = CGPoint(x: center.x + arcRadius * cos(endAngle),
                          y: center.y + arcRadius * sin(endAngle))
        // tangent unit vectors at start (going away from the arc) and
        // end (going away from the arc). for a CCW arc, the before-arc
        // direction at `start` is the radius rotated -90°, and the
        // after-arc direction at `end` is the radius rotated +90°.
        let startTangent = CGPoint(x: sin(startAngle), y: -cos(startAngle))
        let endTangent = CGPoint(x: -sin(endAngle), y: cos(endAngle))

        let leg1 = CGPoint(x: start.x + startTangent.x * legLength,
                           y: start.y + startTangent.y * legLength)
        let leg2 = CGPoint(x: end.x + endTangent.x * legLength,
                           y: end.y + endTangent.y * legLength)

        path.move(to: leg1)
        path.addLine(to: start)
        if arcRadius > 0 {
            path.addArc(center: center, radius: arcRadius,
                        startAngle: startAngle, endAngle: endAngle,
                        clockwise: false)
        }
        path.addLine(to: leg2)
        return path
    }

    private func ensureCornerLayers(host: NSView) {
        guard cornerLayers.isEmpty, let hostLayer = host.layer else { return }
        let outlineColor = Self.contrastOutlineColor(for: accentCGColor)
        for _ in 0..<4 {
            // outline layer first so it sits *behind* the colored stroke.
            let outline = CAShapeLayer()
            outline.fillColor = nil
            outline.strokeColor = outlineColor
            outline.lineWidth = Tuning.outlineStrokeWidth
            outline.lineCap = .round
            outline.lineJoin = .round
            hostLayer.addSublayer(outline)
            outlineLayers.append(outline)

            let layer = CAShapeLayer()
            layer.fillColor = nil
            layer.strokeColor = accentCGColor
            layer.lineWidth = Tuning.strokeWidth
            layer.lineCap = .round
            layer.lineJoin = .round
            hostLayer.addSublayer(layer)
            cornerLayers.append(layer)
        }
    }

    /// Pick a contrasting outline color for `accent`. Dark accents get a
    /// white outline; light accents get a black one. Falls back to black
    /// for colors whose components can't be resolved.
    private static func contrastOutlineColor(for accent: CGColor) -> CGColor {
        guard let ns = NSColor(cgColor: accent)?
                .usingColorSpace(.deviceRGB) else {
            return NSColor.black.cgColor
        }
        // ITU-R BT.601 relative luminance
        let lum = 0.299 * ns.redComponent
                + 0.587 * ns.greenComponent
                + 0.114 * ns.blueComponent
        return (lum < 0.5 ? NSColor.white : NSColor.black).cgColor
    }

    // MARK: - animation

    private func animateScaleIn() {
        guard cornerLayers.count == 4 else { return }
        let off = Tuning.initialOffset
        // direction each corner translates outward from the window center
        // during the initial state — TL: (-,+), TR: (+,+), BL: (-,-), BR: (+,-)
        let offsets: [CGSize] = [
            CGSize(width: -off, height: off),
            CGSize(width: off, height: off),
            CGSize(width: -off, height: -off),
            CGSize(width: off, height: -off),
        ]
        for i in 0..<4 {
            for layer in [outlineLayers[i], cornerLayers[i]] {
                let dx = offsets[i].width
                let dy = offsets[i].height
                let from = CATransform3DMakeTranslation(dx, dy, 0)
                let to = CATransform3DIdentity

                let trans = CABasicAnimation(keyPath: "transform")
                trans.fromValue = NSValue(caTransform3D: from)
                trans.toValue = NSValue(caTransform3D: to)
                trans.duration = Tuning.scaleInDurationSec
                trans.timingFunction = CAMediaTimingFunction(name: .easeOut)
                trans.fillMode = .both
                trans.isRemovedOnCompletion = true

                let opacity = CABasicAnimation(keyPath: "opacity")
                opacity.fromValue = 0
                opacity.toValue = 1
                opacity.duration = Tuning.scaleInDurationSec
                opacity.timingFunction = CAMediaTimingFunction(name: .easeOut)
                opacity.fillMode = .both
                opacity.isRemovedOnCompletion = true

                layer.transform = to
                layer.opacity = 1
                layer.add(trans, forKey: "scaleIn")
                layer.add(opacity, forKey: "fadeIn")
            }
        }
    }

    // MARK: - panel setup

    private func makePanel(frame: NSRect) -> NSPanel {
        let p = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
        p.animationBehavior = .none

        let host = NSView()
        let hosted = CALayer()
        hosted.masksToBounds = false
        host.layer = hosted
        host.wantsLayer = true
        p.contentView?.addSubview(host)
        hostView = host
        layoutHostView(in: p)
        return p
    }

    private func layoutHostView(in panel: NSPanel) {
        guard let host = hostView, let content = panel.contentView else { return }
        host.frame = content.bounds
    }

    /// Panel rect = window rect exactly (no expansion). Brackets are
    /// inset *into* the window via path coordinates, not via panel size.
    private func panelRect(for cgRect: CGRect) -> NSRect {
        let primaryH = primaryScreenHeight
        let nsY = primaryH - cgRect.origin.y - cgRect.height
        return NSRect(x: cgRect.origin.x, y: nsY,
                      width: cgRect.width, height: cgRect.height)
    }
}
