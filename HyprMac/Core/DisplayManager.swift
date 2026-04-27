// Tracks the live NSScreen list and converts between AppKit's
// bottom-left NS origin and CoreGraphics' top-left CG origin. Listens
// for `didChangeScreenParameters` and refreshes automatically.

import Cocoa

/// Owner of the active screen list and the NS↔CG coordinate
/// conversions every other subsystem relies on.
///
/// `primaryScreenHeight` is cached so the conversion does not hit
/// `NSScreen.screens` on every call. Subscribed to
/// `didChangeScreenParameters` so monitor connect/disconnect refreshes
/// the cache automatically.
class DisplayManager {
    /// Current screens in `NSScreen.screens` order. Refreshed on every
    /// `didChangeScreenParameters` notification.
    private(set) var screens: [NSScreen] = []

    /// Height of the primary screen — the basis for NS↔CG conversion.
    /// Cached to avoid `NSScreen.screens.first` on every call.
    private(set) var primaryScreenHeight: CGFloat = 0

    init() {
        refresh()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    /// Reread `NSScreen.screens` and rebuild the cached primary
    /// height. Called automatically on screen parameter changes; safe
    /// to invoke manually.
    @objc func refresh() {
        screens = NSScreen.screens
        primaryScreenHeight = screens.first?.frame.height ?? 0
        hyprLog(.debug, .lifecycle, "displays: \(screens.count)")
        for (i, screen) in screens.enumerated() {
            let frame = screen.frame
            let visible = screen.visibleFrame
            let cg = cgRect(for: screen)
            hyprLog(.debug, .lifecycle, "  display \(i): frame=\(frame) visible=\(visible) cg=\(cg)")
        }
    }

    /// Convert `screen.visibleFrame` (NS, bottom-left origin) to CG
    /// coordinates (top-left origin). Works for every screen, not just
    /// the primary, by anchoring to the cached primary height.
    func cgRect(for screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let primaryH = primaryScreenHeight

        return CGRect(
            x: visible.origin.x,
            y: primaryH - visible.origin.y - visible.height,
            width: visible.width,
            height: visible.height
        )
    }

    /// Resolve which screen contains `cgPoint` (top-left origin).
    /// Falls back to the nearest screen by Manhattan distance to its
    /// edge when no screen actually contains the point — handles
    /// out-of-bounds inputs (e.g. cursor on a disconnected display).
    func screen(at cgPoint: CGPoint) -> NSScreen? {
        let primaryH = primaryScreenHeight

        // exact match first
        for screen in screens {
            let frame = screen.frame
            let cgFrame = CGRect(
                x: frame.origin.x,
                y: primaryH - frame.origin.y - frame.height,
                width: frame.width,
                height: frame.height
            )
            if cgFrame.contains(cgPoint) { return screen }
        }

        // no exact match — find nearest screen by distance to center
        var best: NSScreen?
        var bestDist = CGFloat.infinity
        for screen in screens {
            let frame = screen.frame
            let cgFrame = CGRect(
                x: frame.origin.x,
                y: primaryH - frame.origin.y - frame.height,
                width: frame.width,
                height: frame.height
            )
            let dx = max(0, max(cgFrame.minX - cgPoint.x, cgPoint.x - cgFrame.maxX))
            let dy = max(0, max(cgFrame.minY - cgPoint.y, cgPoint.y - cgFrame.maxY))
            let dist = dx + dy
            if dist < bestDist {
                bestDist = dist
                best = screen
            }
        }
        return best ?? screens.first
    }

    /// Resolve which screen `window` lives on, using its center point
    /// (or top-left position when the size is unknown).
    func screen(for window: HyprWindow) -> NSScreen? {
        guard let center = window.center else {
            // can't determine — try position alone
            guard let pos = window.position else { return nil }
            return screen(at: pos)
        }
        return screen(at: center)
    }

    /// Resolve a screen by index. `CGSCopyManagedDisplaySpaces` and
    /// `NSScreen.screens` use the same ordering, so the index returned
    /// from one can index into the other.
    func screen(forDisplayIndex index: Int) -> NSScreen? {
        guard index >= 0 && index < screens.count else { return nil }
        return screens[index]
    }

    var mainScreen: NSScreen? { NSScreen.main }
}
