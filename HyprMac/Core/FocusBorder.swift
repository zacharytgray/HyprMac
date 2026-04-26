import Cocoa

// persistent focus indicator around the active window. two states:
// - active (traversal): accent-colored tint overlay + border
// - settled: outline border only, no fill
// floating windows also get persistent outline-only panels keyed by window id
class FocusBorder {
    private(set) var trackedWindowID: CGWindowID?

    private var panel: NSPanel?
    private var glowView: NSView?
    private var floatingPanels: [CGWindowID: BorderPanel] = [:]
    private var settleWork: DispatchWorkItem?
    private var shakeTimer: DispatchSourceTimer?
    private var state: State = .hidden

    private enum State { case active, settled, hidden }
    private struct BorderPanel {
        let panel: NSPanel
        let glowView: NSView
    }

    private let margin: CGFloat = 6
    // match OS window corner radius. Tahoe (macOS 26) uses noticeably rounder
    // corners than Sequoia (15); using Sequoia's radius on Tahoe leaves visible
    // gaps at the corners where the border arcs tighter than the window.
    private let borderRadius: CGFloat = {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
            return 12
        }
        return 10
    }()
    private let settleDelay: TimeInterval = 0.5

    // resolved from config — call updateColor() when config changes
    var accentCGColor: CGColor = NSColor.controlAccentColor.cgColor

    // MARK: - public API

    func show(around rect: CGRect, windowID: CGWindowID) {
        mainThreadOnly()
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
        mainThreadOnly()
        guard let p = panel, state != .hidden, let wid = trackedWindowID else { return }
        let nsRect = panelRect(for: rect)
        p.setFrame(nsRect, display: false)
        positionGlowView(in: p)
        // re-order after reposition to maintain z-order relative to focused window
        orderAboveWindow(p, windowID: wid)
    }

    func updateFloatingBorders(_ frames: [CGWindowID: CGRect], color: CGColor) {
        mainThreadOnly()
        let visibleIDs = Set(frames.keys)
        let staleIDs = floatingPanels.keys.filter { !visibleIDs.contains($0) }
        for windowID in staleIDs { hideFloatingBorder(for: windowID) }

        for (windowID, frame) in frames {
            let nsRect = panelRect(for: frame)
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
                layer.borderWidth = 1.5
                layer.cornerRadius = borderRadius
                layer.backgroundColor = CGColor.clear
                CATransaction.commit()
            }

            border.panel.alphaValue = 1.0
            orderAboveWindow(border.panel, windowID: windowID)
        }
    }

    func hideFloatingBorders() {
        mainThreadOnly()
        for (_, border) in floatingPanels {
            border.panel.orderOut(nil)
        }
        floatingPanels.removeAll()
    }

    func hideFloatingBorder(for windowID: CGWindowID) {
        mainThreadOnly()
        guard let border = floatingPanels.removeValue(forKey: windowID) else { return }
        border.panel.orderOut(nil)
    }

    func settle() {
        mainThreadOnly()
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
        mainThreadOnly()
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

    // brief red flash + shake to indicate a rejected operation
    func flashError(around rect: CGRect, windowID: CGWindowID, window: HyprWindow? = nil) {
        mainThreadOnly()
        settleWork?.cancel()
        shakeTimer?.cancel()

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

        let red = NSColor.systemRed.cgColor
        if let layer = glowView?.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.borderColor = red
            layer.borderWidth = 2.5
            layer.cornerRadius = borderRadius
            layer.backgroundColor = red.copy(alpha: 0.12)
            CATransaction.commit()
        }

        p.alphaValue = 1.0
        orderAboveWindow(p, windowID: windowID)
        state = .active
        trackedWindowID = windowID

        // shake: oscillate both the overlay panel and the actual window
        let panelBaseX = nsRect.origin.x
        let windowBaseX = rect.origin.x
        let offsets: [CGFloat] = [10, -10, 7, -7, 3, -3, 0]
        let stepDuration: TimeInterval = 0.04
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.hide()
                }
            }
        }
        timer.resume()
    }

    // MARK: - panel setup

    // place panel just above the focused window in z-order.
    // floating windows raised above the focused window stay on top.
    private func orderAboveWindow(_ p: NSPanel, windowID: CGWindowID) {
        p.order(.above, relativeTo: Int(windowID))
    }

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
        p.level = .normal
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
        let bounds = content.bounds
        glow.frame = NSRect(x: margin, y: margin,
                            width: bounds.width - margin * 2,
                            height: bounds.height - margin * 2)
    }

    // MARK: - coordinate conversion

    var primaryScreenHeight: CGFloat = 0

    private func panelRect(for cgRect: CGRect) -> NSRect {
        let primaryH = primaryScreenHeight
        let nsY = primaryH - cgRect.origin.y - cgRect.height
        return NSRect(x: cgRect.origin.x - margin,
                      y: nsY - margin,
                      width: cgRect.width + margin * 2,
                      height: cgRect.height + margin * 2)
    }
}
