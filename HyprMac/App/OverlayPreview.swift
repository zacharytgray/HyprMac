// Debug-only overlay preview. `--preview-overlays` shows every transient
// overlay in its real panel with sample data, then quits after 90 s. No
// window manager, event tap, AX or tiling, and the config is only read.
// `--glass-fallback` forces the pre-26 blur on macOS 26+, with or without
// the preview. Release builds have neither flag.

import Cocoa

enum OverlayPreview {
    #if DEBUG
    static let isRequested = CommandLine.arguments.contains("--preview-overlays")
    static let forcesGlassFallback = CommandLine.arguments.contains("--glass-fallback")
    #else
    static let isRequested = false
    static let forcesGlassFallback = false
    #endif

    #if DEBUG
    private static var panels: [NSPanel] = []
    private static let overview = WorkspaceOverviewController()
    private static let keybinds = KeybindOverlayController()

    static func run() {
        guard let screen = NSScreen.main else {
            print("HyprMac --preview-overlays: no screen")
            fflush(stdout)
            NSApp.terminate(nil)
            return
        }
        let bounds = screen.visibleFrame
        let list = keybinds.previewPanel()
        let overviewSize = CGSize(width: max(480, bounds.width - list.frame.width), height: list.frame.height)
        let shown = [list, overview.previewOverviewPanel(size: overviewSize)] + overview.previewHUDPanels()
        for (panel, frame) in zip(shown, flow(shown.map(\.frame.size), in: bounds)) {
            panel.setFrame(frame, display: false)
            panel.orderFrontRegardless()
        }
        panels = shown
        print("HyprMac --preview-overlays: showing \(shown.count) panels on \(Int(bounds.width))x\(Int(bounds.height))"
              + (forcesGlassFallback ? " with the pre-26 fallback" : ""))
        fflush(stdout)
        // a little past the third row, so a row sits under a pinned header.
        // after the first layout, or there is nothing to scroll yet
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let scrollView = firstScrollView(in: list.contentView) else { return }
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 3 * OverlayListLayout.rowHeight + 17))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { NSApp.terminate(nil) }
    }
    #endif

    /// Left to right from the top, wrapping when a row is full. Panels that
    /// don't fit below the last row stay inside `bounds` and may overlap.
    static func flow(_ sizes: [CGSize], in bounds: CGRect) -> [CGRect] {
        var frames: [CGRect] = []
        var x = bounds.minX
        var top = bounds.maxY
        var rowHeight: CGFloat = 0
        for size in sizes {
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                top -= rowHeight
                rowHeight = 0
            }
            let y = max(bounds.minY, top - size.height)
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }

    #if DEBUG
    private static func firstScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scrollView = view as? NSScrollView { return scrollView }
        return view.subviews.lazy.compactMap { firstScrollView(in: $0) }.first
    }
    #endif
}
