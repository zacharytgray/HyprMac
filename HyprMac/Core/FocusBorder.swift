import Cocoa

// persistent focus indicator around the active window. two states:
// - active (traversal): accent-colored tint overlay + border
// - settled: outline border only, no fill
class FocusBorder {
    private(set) var trackedWindowID: CGWindowID?

    private var panel: NSPanel?
    private var glowView: NSView?
    private var settleWork: DispatchWorkItem?
    private var state: State = .hidden

    private enum State { case active, settled, hidden }

    private let margin: CGFloat = 6
    private let borderRadius: CGFloat = 10
    private let settleDelay: TimeInterval = 0.5

    // resolved from config — call updateColor() when config changes
    var accentCGColor: CGColor = NSColor.controlAccentColor.cgColor

    // MARK: - public API

    func show(around rect: CGRect, windowID: CGWindowID) {
        settleWork?.cancel()

        let nsRect = panelRect(for: rect)

        let p: NSPanel
        if let existing = panel {
            p = existing
            p.setFrame(nsRect, display: false)
            positionGlowView(in: p)
        } else {
            p = makePanel(frame: nsRect)
            panel = p
        }

        // active state: tint fill + border
        if let layer = glowView?.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.borderColor = accentCGColor
            layer.borderWidth = 2
            layer.cornerRadius = borderRadius
            layer.backgroundColor = accentCGColor.copy(alpha: 0.08)
            CATransaction.commit()
        }

        p.alphaValue = 1.0
        orderAboveWindow(p, windowID: windowID)
        state = .active
        trackedWindowID = windowID

        // schedule transition to settled (outline only)
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
    }

    func updatePosition(_ rect: CGRect) {
        guard let p = panel, state != .hidden, let wid = trackedWindowID else { return }
        let nsRect = panelRect(for: rect)
        p.setFrame(nsRect, display: false)
        positionGlowView(in: p)
        // re-order after reposition to maintain z-order relative to focused window
        orderAboveWindow(p, windowID: wid)
    }

    func settle() {
        guard state == .active, let layer = glowView?.layer else { return }
        state = .settled

        // animate to outline-only
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        layer.backgroundColor = CGColor.clear
        layer.borderWidth = 1.5
        CATransaction.commit()
    }

    func hide() {
        settleWork?.cancel()
        trackedWindowID = nil
        guard let p = panel, state != .hidden else { return }
        state = .hidden

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }

    // MARK: - panel setup

    // place panel just above the focused window in z-order.
    // floating windows raised above the focused window stay on top.
    private func orderAboveWindow(_ p: NSPanel, windowID: CGWindowID) {
        p.order(.above, relativeTo: Int(windowID))
    }

    private func makePanel(frame: NSRect) -> NSPanel {
        let p = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .normal
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let glow = NSView()
        glow.wantsLayer = true
        glow.layer?.masksToBounds = true
        p.contentView?.addSubview(glow)
        glowView = glow
        positionGlowView(in: p)

        return p
    }

    private func positionGlowView(in panel: NSPanel) {
        guard let content = panel.contentView, let glow = glowView else { return }
        let bounds = content.bounds
        glow.frame = NSRect(x: margin, y: margin,
                            width: bounds.width - margin * 2,
                            height: bounds.height - margin * 2)
    }

    // MARK: - coordinate conversion

    private func panelRect(for cgRect: CGRect) -> NSRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let nsY = primaryH - cgRect.origin.y - cgRect.height
        return NSRect(x: cgRect.origin.x - margin,
                      y: nsY - margin,
                      width: cgRect.width + margin * 2,
                      height: cgRect.height + margin * 2)
    }
}
