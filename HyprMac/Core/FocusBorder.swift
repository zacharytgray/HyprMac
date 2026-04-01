import Cocoa

// briefly flashes a thin border around a window when it gains focus via keyboard.
// uses our own NSWindow overlay — no AX required, fully in-process.
class FocusBorder {
    private var panel: NSPanel?
    private var fadeWorkItem: DispatchWorkItem?

    func flash(around rect: CGRect) {
        fadeWorkItem?.cancel()

        let inset: CGFloat = -4
        let borderWidth: CGFloat = 2

        // convert CG top-left coords to NS bottom-left
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let nsY = primaryH - rect.origin.y - rect.height
        let nsRect = NSRect(x: rect.origin.x + inset,
                            y: nsY + inset,
                            width: rect.width - inset * 2,
                            height: rect.height - inset * 2)

        let p: NSPanel
        if let existing = panel {
            p = existing
            p.setFrame(nsRect, display: false)
        } else {
            p = NSPanel(contentRect: nsRect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .screenSaver
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary]

            let border = NSView(frame: p.contentView!.bounds)
            border.autoresizingMask = [.width, .height]
            border.wantsLayer = true
            border.layer?.borderColor = NSColor.controlAccentColor.cgColor
            border.layer?.borderWidth = borderWidth
            border.layer?.cornerRadius = 6
            p.contentView?.addSubview(border)

            panel = p
        }

        p.alphaValue = 1.0
        p.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in
            guard let self, let p = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                p.animator().alphaValue = 0
            }, completionHandler: {
                p.orderOut(nil)
            })
        }
        fadeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
