// Dims non-focused tiled windows by drawing a per-screen shape mask. One
// NSPanel per screen at `.floating - 1`; a CAShapeLayer inside fills only
// the rects of non-focused tiled windows, leaving floaters and the
// focused tile bright.

import Cocoa

/// Dim overlay for non-focused tiled windows.
///
/// One panel per active display, sized to that display's frame, with a
/// `CAShapeLayer` whose path covers every non-focused tiled rect.
/// Focused and floating windows render bright because the path skips
/// them. The approach is deterministic: it does not rely on the relative
/// z-order of other apps' windows, which macOS reshuffles on every
/// activation, window open, or close.
///
/// Panels live at `NSWindow.Level.floating - 1` so they sit above
/// `.normal` app windows but below the focus borders (which sit at
/// `.floating`). Internal storage keys by `CGDirectDisplayID` — that ID
/// is OS-stable and unique even when two physical monitors share a
/// localized name. User-facing per-monitor config still keys by
/// `NSScreen.localizedName`.
///
/// Threading: main-thread only.
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

    // per-display panel + last inputs for path memoization. boxed in a class so
    // we can update lastInputs in place without round-tripping the dict.
    private final class PanelEntry {
        let panel: NSPanel
        let view: DimView
        var lastInputs: Inputs?

        struct Inputs: Equatable {
            let focusedID: CGWindowID
            let tiledRects: [CGWindowID: CGRect]
            let floatingRects: [CGWindowID: CGRect]
            let screenFrame: NSRect
            let intensity: CGFloat
        }

        init(panel: NSPanel, view: DimView) {
            self.panel = panel
            self.view = view
        }
    }

    private var panels: [CGDirectDisplayID: PanelEntry] = [:]
    private var visible = false

    var intensity: CGFloat = 0.2
    var enabled: Bool = false
    var primaryScreenHeight: CGFloat = 0

    deinit {
        for (_, entry) in panels { entry.panel.orderOut(nil) }
    }

    /// Rebuild the dim shape from the current focus + window set.
    ///
    /// Per-display: ensure a panel exists, prune any stale displays
    /// since the last call, then rebuild the dim path from non-focused
    /// tile rects with the focused tile and every visible floater
    /// subtracted out. Inputs are memoized — when nothing changed since
    /// the last call, the O(tiled × floating) path build is skipped.
    ///
    /// - Parameter focusedID: the bright window. `0` (or `enabled ==
    ///   false`) hides every panel.
    /// - Parameter tiledRects: every visible tile keyed by id.
    /// - Parameter floatingRects: every visible floating window keyed by
    ///   id; subtracted from the dim path so floaters render bright.
    /// - Parameter screens: enabled `NSScreen`s.
    func update(
        focusedID: CGWindowID,
        tiledRects: [CGWindowID: CGRect],
        floatingRects: [CGWindowID: CGRect],
        screens: [NSScreen]
    ) {
        mainThreadOnly()
        guard enabled, focusedID != 0 else { hideAll(); return }
        visible = true

        // prune entries for displays that have been unplugged. otherwise the
        // panels dict accumulates orphaned NSPanels across monitor reconfigs.
        let currentDisplayIDs = Set(screens.compactMap { $0.displayID })
        let stale = panels.keys.filter { !currentDisplayIDs.contains($0) }
        for id in stale {
            panels[id]?.panel.orderOut(nil)
            panels.removeValue(forKey: id)
        }

        let fill = NSColor.black.withAlphaComponent(intensity).cgColor

        for screen in screens {
            let entry = ensurePanel(for: screen)
            let screenNS = screen.frame
            if entry.panel.frame != screenNS {
                entry.panel.setFrame(screenNS, display: false)
            }

            // memo: skip path rebuild when inputs are byte-equal to the prior
            // call. the path computation is O(tiled * floating); update() runs
            // after every poll/focus/retile so unchanged frames are common.
            let inputs = PanelEntry.Inputs(
                focusedID: focusedID,
                tiledRects: tiledRects,
                floatingRects: floatingRects,
                screenFrame: screenNS,
                intensity: intensity
            )
            let inputsUnchanged = entry.lastInputs == inputs

            if !inputsUnchanged {
                // build path in panel-local coords — fill rects of non-focused
                // tiles that land on this screen, clipped against the focused
                // rect so the dim doesn't bleed onto the focused window where
                // slots physically overlap (apps with min-size constraints
                // expanding past their allocated rect).
                let focusedLocal: NSRect? = tiledRects[focusedID].flatMap {
                    localRect(cgRect: $0, screenNS: screenNS)
                }
                let floatingLocals = floatingRects.values.compactMap {
                    localRect(cgRect: $0, screenNS: screenNS)
                }

                let path = CGMutablePath()
                for (wid, cgRect) in tiledRects where wid != focusedID {
                    guard let local = localRect(cgRect: cgRect, screenNS: screenNS) else { continue }
                    var pieces = subtract(focusedLocal, from: local)
                    for floater in floatingLocals {
                        pieces = pieces.flatMap { subtract(floater, from: $0) }
                    }
                    for piece in pieces {
                        path.addRect(piece)
                    }
                }

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                entry.view.shape.fillRule = .nonZero
                entry.view.shape.path = path
                entry.view.shape.fillColor = fill
                CATransaction.commit()

                entry.lastInputs = inputs
            }

            if !entry.panel.isVisible {
                entry.panel.alphaValue = 1
                entry.panel.orderFrontRegardless()
            }
        }
    }

    /// Order out every dim panel. Idempotent.
    func hideAll() {
        mainThreadOnly()
        guard visible else { return }
        visible = false
        for (_, entry) in panels {
            entry.panel.orderOut(nil)
        }
    }

    /// Clamp `value` into `0...1` and apply it as the dim alpha.
    /// Inputs outside the range are clamped silently.
    func setIntensity(_ value: CGFloat) {
        mainThreadOnly()
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

    private func ensurePanel(for screen: NSScreen) -> PanelEntry {
        let key = screen.displayID
        if let existing = panels[key] { return existing }

        let p = NSPanel(contentRect: screen.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        // Phase 5b: pin one tier below FocusBorder panels (.floating). this
        // keeps the dim layer above all .normal-level app windows (fixing the
        // ccfa26f regression where the panel could be pushed behind other
        // apps' tiled windows) while still letting FocusBorder render above
        // it without orderFront-recency fights. .floating - 1 is integer 2
        // — above .normal (0) and below .floating (3).
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let view = DimView(frame: p.contentView!.bounds)
        view.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(view)

        let entry = PanelEntry(panel: p, view: view)
        panels[key] = entry
        return entry
    }
}

private extension NSScreen {
    // CGDirectDisplayID — stable across plug/unplug for the same physical
    // display, unlike localizedName which can collide across identical models.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
