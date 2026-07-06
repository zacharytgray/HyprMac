// Dims non-focused tiled windows by drawing one CAShapeLayer per window.
// Each layer covers exactly one tile rect and animates its own opacity:
// 1 when the window is dimmed, 0 when it's the focused tile. Focus
// traversal animates layers in lockstep — the window being left fades
// in (dim appears), the window being entered fades out (dim disappears).

import Cocoa

/// Per-window dim overlay.
///
/// One `NSPanel` per active display, pinned one tier below the focus
/// border. Inside each panel a layer-hosting container holds one
/// `CAShapeLayer` per visible tiled window; that layer renders the dim
/// over exactly that window's rect. The layer's `opacity` is the only
/// thing that's ever animated — geometry updates (window moves,
/// resizes, focus-region carve-outs, floater carve-outs) re-stamp the
/// path inside `setDisableActions(true)` and are instant. Opacity
/// changes (window becoming focused or unfocused, dim turning on or
/// off) animate over `fadeDurationSec` with `easeInEaseOut`.
///
/// State per window:
/// ```
/// new window appears  → layer created at opacity 0, animates to target
/// focus moves A → B   → A: 0 → 1   B: 1 → 0   (parallel)
/// window moves        → path updates instantly, opacity untouched
/// window disappears   → animate 1 → 0, then remove from superlayer
/// dim disabled        → every layer animates → 0, panel orderOuts
/// dim re-enabled      → orderFront, every non-focused layer 0 → 1
/// ```
///
/// Threading: main-thread only.
class DimmingOverlay {

    /// One panel + a container view + one shape layer per tracked window.
    private final class PanelEntry {
        let panel: NSPanel
        let container: NSView
        var windowLayers: [CGWindowID: CAShapeLayer] = [:]
        // last value passed to animateOpacity; the diff against this is
        // what gates whether a focus change actually fires an animation.
        var lastTargets: [CGWindowID: Float] = [:]

        init(panel: NSPanel, container: NSView) {
            self.panel = panel
            self.container = container
        }
    }

    private var panels: [CGDirectDisplayID: PanelEntry] = [:]
    private var visible = false

    // last update() inputs, cached so setDragOverride can re-stamp paths
    // without the caller recomputing the whole world every mouse-dragged.
    private var lastFocusedID: CGWindowID = 0
    private var lastTiledRects: [CGWindowID: CGRect] = [:]
    private var lastFloatingRects: [CGWindowID: CGRect] = [:]
    private var lastScreens: [NSScreen] = []
    // single live floater rect during a drag. merged over lastFloatingRects
    // inside update() so a mid-drag full update doesn't stomp it, and
    // re-stamped path-only by setDragOverride at mouse-drag rate.
    private var dragOverride: (id: CGWindowID, rect: CGRect)?
    // bumped on each hideAll; the deferred orderOut closure captures the
    // token at schedule time and aborts if `update()` re-enabled the panel
    // before the fade-out wall-clock window expired.
    private var hideEpoch: UInt64 = 0

    var intensity: CGFloat = 0.2
    var enabled: Bool = false
    var primaryScreenHeight: CGFloat = 0

    // when set, replaces the pure-black fill (used by the scratchpad scrim to
    // layer a faint magenta tint over the black). nil = normal focus-dim black.
    // the caller pre-blends tint over black at the target alpha and passes one
    // opaque-alpha color here; intensity is then ignored for the fill.
    var fillOverride: NSColor?

    // panel window level. .floating - 1 (=2) for the normal focus dim, sits
    // above all normal windows so carve-outs keep floaters bright. .normal
    // for the scratchpad scrim, where the quasimodal-frozen stack lets the
    // members be raised above it (stack recency, no carve-outs).
    var panelLevel: NSWindow.Level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)

    /// Fade duration for opacity transitions (focus traversal AND
    /// enable/disable). `easeInEaseOut` (set in `animateOpacity`) spreads
    /// the alpha ramp evenly so the small-delta dim reads as a fade
    /// rather than a step — `.easeOut` packs the change into the first
    /// ~30% of the duration and reads as a snap on a screen-spanning
    /// low-alpha overlay. Set by `WindowManager` from
    /// `config.chromeFadeDurationSec`.
    var fadeDurationSec: TimeInterval = 0.22

    deinit {
        for (_, entry) in panels { entry.panel.orderOut(nil) }
    }

    /// Rebuild per-window state from the current focus + window set.
    ///
    /// - Parameter focusedID: the bright window. `0` (or `enabled ==
    ///   false`) fades every panel out and orderOuts.
    /// - Parameter tiledRects: every visible tile keyed by id.
    /// - Parameter floatingRects: every visible floating window; their
    ///   rects are carved out of each tile's dim path so floaters render
    ///   bright above any dimmed tile they cover.
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

        // cache raw inputs so setDragOverride can re-stamp from them.
        lastFocusedID = focusedID
        lastTiledRects = tiledRects
        lastFloatingRects = floatingRects
        lastScreens = screens

        // merge the live drag rect over the (possibly stale) floating input
        // so a full update mid-drag doesn't snap the hole back to the poll rect.
        var floatingRects = floatingRects
        if let ov = dragOverride { floatingRects[ov.id] = ov.rect }

        let fillColor = currentFillColor()

        // prune entries for displays that have been unplugged
        let currentDisplayIDs = Set(screens.compactMap { $0.displayID })
        let stale = panels.keys.filter { !currentDisplayIDs.contains($0) }
        for id in stale {
            panels[id]?.panel.orderOut(nil)
            panels.removeValue(forKey: id)
        }

        for screen in screens {
            let entry = ensurePanel(for: screen)
            // panels are reused across scrim/normal switches, so re-apply the
            // level every update. instant on a live panel; isFloatingPanel
            // false at .normal so visibility doesn't track app-active state.
            // set isFloatingPanel FIRST — its setter coerces level to
            // .floating, so level must be assigned after to stick.
            if entry.panel.level != panelLevel {
                entry.panel.isFloatingPanel = (panelLevel != .normal)
                entry.panel.level = panelLevel
            }
            let screenNS = screen.frame
            if entry.panel.frame != screenNS {
                entry.panel.setFrame(screenNS, display: false)
            }

            // map tiled rects into this screen's panel-local NS coords.
            // windows that don't intersect this screen are skipped.
            var onScreen: [(CGWindowID, NSRect)] = []
            for (wid, cgRect) in tiledRects {
                guard let local = localRect(cgRect: cgRect, screenNS: screenNS) else { continue }
                onScreen.append((wid, local))
            }
            let onScreenIDs = Set(onScreen.map { $0.0 })

            // floater locals — subtracted from every tile's path so a
            // floater that overlaps a dimmed tile stays bright.
            let floaters = floatingRects.values.compactMap {
                localRect(cgRect: $0, screenNS: screenNS)
            }

            // focused local — subtracted from non-focused tiles' paths so
            // a min-size-induced overlap doesn't paint dim onto the bright
            // tile. the focused tile's own layer stays at opacity 0, so
            // its path doesn't render either way.
            let focusedLocal: NSRect? = tiledRects[focusedID].flatMap {
                localRect(cgRect: $0, screenNS: screenNS)
            }

            for (wid, local) in onScreen {
                let isFocused = (wid == focusedID)
                let target: Float = isFocused ? 0 : 1

                let path = buildPath(
                    for: wid,
                    local: local,
                    focusedToExclude: isFocused ? nil : focusedLocal,
                    floaters: floaters
                )

                let layer: CAShapeLayer
                let isNew: Bool
                if let existing = entry.windowLayers[wid] {
                    layer = existing
                    isNew = false
                } else {
                    layer = createWindowLayer(in: entry.container)
                    entry.windowLayers[wid] = layer
                    isNew = true
                }

                // geometry: instant
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.fillColor = fillColor
                layer.path = path
                CATransaction.commit()

                // opacity: animate only on target change. fresh layers
                // start at 0 (set in createWindowLayer) so the first
                // animation here naturally fades them in.
                if isNew { entry.lastTargets[wid] = 0 }
                let lastTarget = entry.lastTargets[wid] ?? 0
                if lastTarget != target {
                    animateOpacity(layer, to: target)
                    entry.lastTargets[wid] = target
                }
            }

            // windows that left this screen — fade their layer out then
            // remove it. catches both close (window gone for good) and
            // workspace-switch (window parked off-screen).
            for (wid, layer) in entry.windowLayers where !onScreenIDs.contains(wid) {
                fadeOutAndRemove(wid: wid, layer: layer, from: entry)
            }

            if !entry.panel.isVisible {
                entry.panel.alphaValue = 1
                entry.panel.orderFrontRegardless()
            }
        }
    }

    /// Fade every layer to 0, then orderOut each panel.
    func hideAll() {
        mainThreadOnly()
        guard visible else { return }
        visible = false
        hideEpoch &+= 1
        let epoch = hideEpoch

        for (_, entry) in panels {
            for (wid, layer) in entry.windowLayers {
                let lastTarget = entry.lastTargets[wid] ?? 1
                if lastTarget != 0 {
                    animateOpacity(layer, to: 0)
                    entry.lastTargets[wid] = 0
                }
            }
            let p = entry.panel
            DispatchQueue.main.asyncAfter(deadline: .now() + self.fadeDurationSec + 0.05) { [weak self] in
                // if update() re-enabled the dim while the fade-out was
                // still in flight, hideEpoch will have moved past `epoch`
                // and we leave the panel where update() put it.
                guard let self, self.hideEpoch == epoch, !self.visible else { return }
                p.orderOut(nil)
            }
        }
    }

    /// Restack every panel above the tiles. Unconditional (not gated on
    /// visibility) — panels linger visible through the deferred fade-out, so
    /// a rapid hide→show would otherwise skip the restack.
    func orderFrontAll() {
        mainThreadOnly()
        for (_, entry) in panels { entry.panel.orderFrontRegardless() }
    }

    /// Clamp `value` into `0...1`, apply it as the new dim alpha, and
    /// re-stamp the fillColor on every existing layer so the change is
    /// reflected immediately.
    func setIntensity(_ value: CGFloat) {
        mainThreadOnly()
        intensity = max(0, min(1, value))
        let fill = currentFillColor()
        for (_, entry) in panels {
            for (_, layer) in entry.windowLayers {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.fillColor = fill
                CATransaction.commit()
            }
        }
    }

    /// Set the single live drag-override rect and immediately re-stamp
    /// affected paths from the cached inputs. Geometry only — no opacity,
    /// no animations, no panel ordering. Cheap enough for per-drag calls.
    func setDragOverride(id: CGWindowID, rect: CGRect) {
        mainThreadOnly()
        let prev = dragOverride?.rect
        dragOverride = (id, rect)
        // only re-stamp if a full update has run (we have cached inputs).
        guard visible, enabled, lastFocusedID != 0 else { return }
        restampPaths(dirty: prev == nil ? [rect] : [prev!, rect])
    }

    /// Drop the drag override. The next full update() paints from fresh
    /// caches; nothing is re-stamped here (mouse-up triggers a real refresh).
    func clearDragOverride() {
        mainThreadOnly()
        dragOverride = nil
    }

    /// Re-stamp tile dim paths from cached inputs + the current override,
    /// without touching opacity or panel order. `dirty` rects gate which
    /// tiles get rebuilt: a tile whose local rect can't intersect any dirty
    /// rect keeps its old path (a handful of CGPath builds per drag event).
    private func restampPaths(dirty: [CGRect]) {
        let fillColor = currentFillColor()
        var floatingRects = lastFloatingRects
        if let ov = dragOverride { floatingRects[ov.id] = ov.rect }

        for screen in lastScreens {
            guard let entry = panels[screen.displayID] else { continue }
            let screenNS = screen.frame

            let dirtyLocals = dirty.compactMap { localRect(cgRect: $0, screenNS: screenNS) }
            let floaters = floatingRects.values.compactMap { localRect(cgRect: $0, screenNS: screenNS) }
            let focusedLocal: NSRect? = lastTiledRects[lastFocusedID].flatMap {
                localRect(cgRect: $0, screenNS: screenNS)
            }

            for (wid, cgRect) in lastTiledRects {
                guard wid != lastFocusedID else { continue } // focused tile path never renders (opacity 0)
                guard let layer = entry.windowLayers[wid],
                      let local = localRect(cgRect: cgRect, screenNS: screenNS) else { continue }
                // skip tiles the moved rect can't touch
                guard dirtyLocals.contains(where: { $0.intersects(local) }) else { continue }

                let path = buildPath(for: wid, local: local, focusedToExclude: focusedLocal, floaters: floaters)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.fillColor = fillColor
                layer.path = path
                CATransaction.commit()
            }
        }
    }

    // MARK: - test introspection

    /// Per-window state snapshot. Tests assert against `target` (the value
    /// `animateOpacity` last targeted) and `present`/`model` (CA's actual
    /// current opacity) to verify focus-traversal behavior without
    /// painting.
    struct WindowDimState: Equatable {
        let target: Float
        let model: Float
        let present: Float
    }

    /// Aggregated per-window state across every panel. Tests call this
    /// after driving `update()` / `hideAll()` to verify per-window
    /// opacity targets and current values.
    func currentStates() -> [CGWindowID: WindowDimState] {
        var out: [CGWindowID: WindowDimState] = [:]
        for (_, entry) in panels {
            for (wid, layer) in entry.windowLayers {
                let target = entry.lastTargets[wid] ?? layer.opacity
                let present = layer.presentation()?.opacity ?? layer.opacity
                out[wid] = WindowDimState(target: target, model: layer.opacity, present: present)
            }
        }
        return out
    }

    /// Live window level of each panel, keyed by display id.
    func currentPanelLevels() -> [CGDirectDisplayID: NSWindow.Level] {
        var out: [CGDirectDisplayID: NSWindow.Level] = [:]
        for (id, entry) in panels { out[id] = entry.panel.level }
        return out
    }

    /// The active drag-override rect, or nil. Tests assert it survives a
    /// full update() that carries stale floatingRects (merge semantics).
    func currentDragOverride() -> (id: CGWindowID, rect: CGRect)? { dragOverride }

    /// Per-window dim-path bounding box (union of all subpaths), in
    /// panel-local NS coords, keyed by window id. Tests use this to verify
    /// a carve-out actually landed in the path geometry.
    func currentPathBounds() -> [CGWindowID: CGRect] {
        var out: [CGWindowID: CGRect] = [:]
        for (_, entry) in panels {
            for (wid, layer) in entry.windowLayers {
                if let path = layer.path { out[wid] = path.boundingBoxOfPath }
            }
        }
        return out
    }

    /// The raw dim CGPath for a window on the first panel that has it.
    /// Tests use point-containment to prove a carve-out region is empty.
    func currentPath(for wid: CGWindowID) -> CGPath? {
        for (_, entry) in panels {
            if let layer = entry.windowLayers[wid], let path = layer.path { return path }
        }
        return nil
    }

    // MARK: - internals

    // the dim fill: scrim tint override if set, else black at `intensity`.
    private func currentFillColor() -> CGColor {
        if let ov = fillOverride { return ov.cgColor }
        return NSColor.black.withAlphaComponent(intensity).cgColor
    }

    private func animateOpacity(_ layer: CALayer, to target: Float) {
        layer.removeAnimation(forKey: "fade")
        // resume from the presentation opacity so a mid-flight animation
        // continues smoothly rather than jumping back to the model value
        // (which we set to the previous target).
        let from = layer.presentation()?.opacity ?? layer.opacity
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = from
        anim.toValue = target
        anim.duration = self.fadeDurationSec
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.fillMode = .both
        anim.isRemovedOnCompletion = true
        layer.opacity = target
        layer.add(anim, forKey: "fade")
    }

    private func fadeOutAndRemove(wid: CGWindowID, layer: CAShapeLayer, from entry: PanelEntry) {
        entry.windowLayers.removeValue(forKey: wid)
        entry.lastTargets.removeValue(forKey: wid)
        animateOpacity(layer, to: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + self.fadeDurationSec + 0.05) {
            layer.removeFromSuperlayer()
        }
    }

    /// Path for one window's dim region: the window's rounded rect with
    /// the focused-tile region and every floater rect carved out. When
    /// no carve-outs apply, the path is a single rounded rect; once any
    /// overlap subtracts, it degrades to axis-aligned strips (rounded
    /// corners on a clipped shape would produce visible artifacts).
    private func buildPath(
        for wid: CGWindowID,
        local: NSRect,
        focusedToExclude: NSRect?,
        floaters: [NSRect]
    ) -> CGPath {
        let path = CGMutablePath()
        var pieces = [local]
        if let focused = focusedToExclude {
            pieces = pieces.flatMap { subtract(focused, from: $0) }
        }
        for floater in floaters {
            pieces = pieces.flatMap { subtract(floater, from: $0) }
        }

        if pieces.count == 1, pieces[0] == local {
            let radius = WindowCornerRadius.resolve(for: wid)
            if radius > 0 {
                path.addRoundedRect(in: local, cornerWidth: radius, cornerHeight: radius)
            } else {
                path.addRect(local)
            }
        } else {
            for piece in pieces { path.addRect(piece) }
        }
        return path
    }

    private func createWindowLayer(in container: NSView) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillRule = .nonZero
        layer.opacity = 0
        container.layer?.addSublayer(layer)
        return layer
    }

    private func ensurePanel(for screen: NSScreen) -> PanelEntry {
        let key = screen.displayID
        if let existing = panels[key] { return existing }

        let p = NSPanel(contentRect: screen.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        // level is mode-dependent: .floating - 1 for the normal focus dim
        // (above all normal windows so carve-outs keep floaters bright),
        // .normal for the scratchpad scrim (stack once below the members;
        // quasimodality freezes the stack so no carve-outs are needed).
        // isFloatingPanel first — its setter coerces level to .floating, so
        // level must be assigned after to stick.
        p.isFloatingPanel = (panelLevel != .normal)
        p.level = panelLevel
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
        // disable the system orderFront/orderOut fade — every fade we
        // care about is driven by per-layer opacity animations.
        p.animationBehavior = .none

        let container = NSView(frame: p.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        // layer-HOSTING container so we fully own the sublayer tree.
        // assign before `wantsLayer = true`, per the AppKit convention.
        let hosted = CALayer()
        container.layer = hosted
        container.wantsLayer = true
        p.contentView?.addSubview(container)

        let entry = PanelEntry(panel: p, container: container)
        panels[key] = entry
        return entry
    }

    // rect subtraction: returns up to 4 rects representing `rect` minus `hole`.
    // if hole is nil or doesn't intersect rect, returns [rect] unchanged.
    // produces top/bottom/left/right strips around the hole; any strip
    // that collapses to zero area is skipped.
    private func subtract(_ hole: NSRect?, from rect: NSRect) -> [NSRect] {
        guard let hole, rect.intersects(hole) else { return [rect] }
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
}

private extension NSScreen {
    // CGDirectDisplayID — stable across plug/unplug for the same physical
    // display, unlike localizedName which can collide across identical models.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
