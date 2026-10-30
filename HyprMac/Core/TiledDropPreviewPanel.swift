// Translucent highlight of where a tiled drag will land. One borderless,
// click-through panel at the floating tier, like the focus border's.

import Cocoa

final class TiledDropPreviewPanel {
    private enum Tuning {
        static let fillAlpha: CGFloat = 0.16
        static let borderAlpha: CGFloat = 0.85
        static let borderWidth: CGFloat = 2
    }

    /// cached primary height for the CG → NS flip. set by the owner
    var primaryScreenHeight: CGFloat = 0
    var accentColor: NSColor = .hyprCyan
    var cornerRadius: CGFloat = 10

    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Show the highlight over `cgRect`, global CG coordinates.
    func show(_ cgRect: CGRect) {
        mainThreadOnly()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // CG top-left origin to NS bottom-left, against the primary screen.
        // a screen left of or above the primary has negative coordinates in
        // both, and the one formula covers it
        let frame = NSRect(x: cgRect.minX, y: primaryScreenHeight - cgRect.maxY,
                           width: cgRect.width, height: cgRect.height)
        panel.setFrame(frame, display: false)
        if let layer = panel.contentView?.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.backgroundColor = accentColor.withAlphaComponent(Tuning.fillAlpha).cgColor
            layer.borderColor = accentColor.withAlphaComponent(Tuning.borderAlpha).cgColor
            layer.borderWidth = Tuning.borderWidth
            layer.cornerRadius = cornerRadius
            CATransaction.commit()
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        mainThreadOnly()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = ClickThroughPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        // above ordinary windows, below menus, with the focus border
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        panel.contentView = view
        return panel
    }

    deinit {
        panel?.orderOut(nil)
    }
}
