import Cocoa

// persistent focus indicator around the active window.
//
// state machine:
//   hidden  --show()-->  active   (tint fill + border, ~settleDelay)
//   active  --settle()-> settled  (outline only, no fill)
//   any     --hide()-->  hidden   (fade out + orderOut + nil-out)
//   any     --flashError()--> active (red shake; hides itself when done)
//
// floating windows also get persistent outline-only panels keyed by window id
// (managed via updateFloatingBorders / hideFloatingBorder(s)).
//
// lifecycle: every public mutation cancels in-flight work (settleWork,
// shakeTimer) before reassigning. hide() nils the panel + glowView so a
// long-lived FocusBorder doesn't accumulate orphaned panels across
// app/workspace transitions. deinit guarantees cleanup if the FocusBorder
// itself is dropped (currently it isn't — WindowManager owns it for the
// lifetime of the app — but the contract holds for tests + future swaps).
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

    // tunables. origin: empirical (settleDelay, shake timing) and OS-imposed
    // (corner radius needs to track the actual window corner radius per macOS
    // version or the border arcs tighter and leaves visible gaps at corners).
    private enum Tuning {
        static let margin: CGFloat = 6
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
        // Tahoe (macOS 26) uses noticeably rounder window corners than
        // Sequoia (15); using Sequoia's radius on Tahoe leaves visible
        // gaps where the border arcs tighter than the window.
        static let macOSSequoiaCornerRadius: CGFloat = 10
        static let macOSTahoeCornerRadius: CGFloat = 12
    }

    private let borderRadius: CGFloat = {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
            return Tuning.macOSTahoeCornerRadius
        }
        return Tuning.macOSSequoiaCornerRadius
    }()

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

    func show(around rect: CGRect, windowID: CGWindowID) {
        mainThreadOnly()
        // cancel any in-flight transition (settle, shake) before re-asserting.
        // without this, a pending shake or settle can mutate the panel after
        // show() returns and undo the new frame/state.
        settleWork?.cancel()
        shakeTimer?.cancel()
        shakeTimer = nil

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
            layer.borderWidth = Tuning.activeBorderWidth
            layer.cornerRadius = borderRadius
            layer.backgroundColor = accentCGColor.copy(alpha: Tuning.activeFillAlpha)
            CATransaction.commit()
        }

        p.alphaValue = 1.0
        p.orderFront(nil)
        state = .active
        trackedWindowID = windowID

        // schedule transition to settled (outline only)
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Tuning.settleDelaySec, execute: work)
    }

    func updatePosition(_ rect: CGRect) {
        mainThreadOnly()
        guard let p = panel, state != .hidden, trackedWindowID != nil else { return }
        let nsRect = panelRect(for: rect)
        p.setFrame(nsRect, display: false)
        positionGlowView(in: p)
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
                layer.borderWidth = Tuning.floatingBorderWidth
                layer.cornerRadius = borderRadius
                layer.backgroundColor = CGColor.clear
                CATransaction.commit()
            }

            border.panel.alphaValue = 1.0
            border.panel.orderFront(nil)
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
        CATransaction.setAnimationDuration(Tuning.settleAnimationDurationSec)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        layer.backgroundColor = CGColor.clear
        layer.borderWidth = Tuning.settledBorderWidth
        CATransaction.commit()
    }

    func hide() {
        mainThreadOnly()
        settleWork?.cancel()
        shakeTimer?.cancel()
        shakeTimer = nil
        trackedWindowID = nil
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
            layer.borderWidth = Tuning.errorBorderWidth
            layer.cornerRadius = borderRadius
            layer.backgroundColor = red.copy(alpha: Tuning.errorFillAlpha)
            CATransaction.commit()
        }

        p.alphaValue = 1.0
        p.orderFront(nil)
        state = .active
        trackedWindowID = windowID

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
        let bounds = content.bounds
        glow.frame = NSRect(x: Tuning.margin, y: Tuning.margin,
                            width: bounds.width - Tuning.margin * 2,
                            height: bounds.height - Tuning.margin * 2)
    }

    // MARK: - coordinate conversion

    var primaryScreenHeight: CGFloat = 0

    private func panelRect(for cgRect: CGRect) -> NSRect {
        let primaryH = primaryScreenHeight
        let nsY = primaryH - cgRect.origin.y - cgRect.height
        return NSRect(x: cgRect.origin.x - Tuning.margin,
                      y: nsY - Tuning.margin,
                      width: cgRect.width + Tuning.margin * 2,
                      height: cgRect.height + Tuning.margin * 2)
    }
}
