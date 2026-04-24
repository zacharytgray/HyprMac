import Cocoa

// dims non-focused tiled windows by drawing a shape mask per screen.
// one NSPanel per screen sits at .floating level covering the whole screen;
// a CAShapeLayer inside fills *only* the rects of non-focused tiled windows.
// focused window and floating windows render bright because the path skips them.
//
// deterministic — doesn't depend on relative z-order of other apps' windows.
// that's why v1 (order relative to focused window) was flaky: macOS reshuffles
// the global z-stack constantly on app activation, window open/close, etc.
class DimmingOverlay {

    private class DimView: NSView {
        let shape = CAShapeLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(shape)
            shape.frame = bounds
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            shape.frame = bounds
        }
    }

    private var panels: [String: (panel: NSPanel, view: DimView)] = [:]
    private var visible = false

    var intensity: CGFloat = 0.2
    var enabled: Bool = false
    var primaryScreenHeight: CGFloat = 0

    func update(focusedID: CGWindowID, tiledRects: [CGWindowID: CGRect], screens: [NSScreen]) {
        guard enabled, focusedID != 0 else { hideAll(); return }
        visible = true

        let fill = NSColor.black.withAlphaComponent(intensity).cgColor

        for screen in screens {
            let entry = ensurePanel(for: screen)
            let screenNS = screen.frame
            if entry.panel.frame != screenNS {
                entry.panel.setFrame(screenNS, display: false)
            }

            // build path in panel-local coords — fill rects of non-focused tiles
            // that land on this screen, clipped against the focused rect so
            // the dim doesn't bleed onto the focused window where slots
            // physically overlap (apps with min-size constraints expanding
            // past their allocated rect).
            let focusedLocal: NSRect? = tiledRects[focusedID].flatMap {
                localRect(cgRect: $0, screenNS: screenNS)
            }

            let path = CGMutablePath()
            for (wid, cgRect) in tiledRects where wid != focusedID {
                guard let local = localRect(cgRect: cgRect, screenNS: screenNS) else { continue }
                for piece in subtract(focusedLocal, from: local) {
                    path.addRect(piece)
                }
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            entry.view.shape.fillRule = .nonZero
            entry.view.shape.path = path
            entry.view.shape.fillColor = fill
            CATransaction.commit()

            if !entry.panel.isVisible {
                entry.panel.alphaValue = 1
                entry.panel.orderFrontRegardless()
            }
        }
    }

    func hideAll() {
        guard visible else { return }
        visible = false
        for (_, entry) in panels {
            entry.panel.orderOut(nil)
        }
    }

    func setIntensity(_ value: CGFloat) {
        intensity = max(0, min(1, value))
    }

    // rect subtraction: returns up to 4 rects representing `rect` minus `hole`.
    // if hole is nil or doesn't intersect rect, returns [rect] unchanged.
    // produces top/bottom/left/right strips around the hole (any strip that
    // collapses to zero area is skipped).
    private func subtract(_ hole: NSRect?, from rect: NSRect) -> [NSRect] {
        guard let hole, rect.intersects(hole) else { return [rect] }
        let clipped = rect.intersection(hole)
        if clipped == rect { return [] } // rect fully inside hole
        var pieces: [NSRect] = []
        // top strip (above hole)
        if rect.maxY > clipped.maxY {
            pieces.append(NSRect(x: rect.minX, y: clipped.maxY,
                                 width: rect.width, height: rect.maxY - clipped.maxY))
        }
        // bottom strip (below hole)
        if clipped.minY > rect.minY {
            pieces.append(NSRect(x: rect.minX, y: rect.minY,
                                 width: rect.width, height: clipped.minY - rect.minY))
        }
        // left strip (beside hole, between top/bottom strips)
        if clipped.minX > rect.minX {
            pieces.append(NSRect(x: rect.minX, y: clipped.minY,
                                 width: clipped.minX - rect.minX, height: clipped.height))
        }
        // right strip
        if rect.maxX > clipped.maxX {
            pieces.append(NSRect(x: clipped.maxX, y: clipped.minY,
                                 width: rect.maxX - clipped.maxX, height: clipped.height))
        }
        return pieces
    }

    // convert top-left CG rect to panel-local NS rect, clipped to the screen.
    // returns nil if the rect doesn't intersect this screen.
    private func localRect(cgRect: CGRect, screenNS: NSRect) -> NSRect? {
        let nsY = primaryScreenHeight - cgRect.origin.y - cgRect.height
        let nsRect = NSRect(x: cgRect.origin.x, y: nsY, width: cgRect.width, height: cgRect.height)
        let clipped = nsRect.intersection(screenNS)
        guard !clipped.isEmpty else { return nil }
        return NSRect(x: clipped.origin.x - screenNS.origin.x,
                      y: clipped.origin.y - screenNS.origin.y,
                      width: clipped.width,
                      height: clipped.height)
    }

    private func ensurePanel(for screen: NSScreen) -> (panel: NSPanel, view: DimView) {
        let key = screen.localizedName
        if let existing = panels[key] { return existing }

        let p = NSPanel(contentRect: screen.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let view = DimView(frame: p.contentView!.bounds)
        view.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(view)

        let entry = (panel: p, view: view)
        panels[key] = entry
        return entry
    }
}
