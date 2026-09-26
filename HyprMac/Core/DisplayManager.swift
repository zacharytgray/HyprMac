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

    private let screenSource: () -> [NSScreen]
    private var fingerprintUsableBounds: [String: CGRect] = [:]

    init(screenSource: @escaping () -> [NSScreen] = { NSScreen.screens }) {
        self.screenSource = screenSource
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
        screens = screenSource()
        primaryScreenHeight = screens.first?.frame.height ?? 0
        hyprLog(.debug, .lifecycle, "displays: \(screens.count)")
        for (i, screen) in screens.enumerated() {
            let frame = screen.frame
            let visible = screen.visibleFrame
            let cg = cgRect(for: screen)
            hyprLog(.debug, .lifecycle, "  display \(i): frame=\(frame) visible=\(visible) cg=\(cg)")
        }
    }

    /// Read the provider at each comparison, independent of observer order.
    func refreshedFingerprint() -> String {
        refresh()
        var nextBounds: [String: CGRect] = [:]
        let fingerprint = screens.map { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let key = "\(id?.uint32Value ?? 0):\(screen.localizedName)@\(screen.frame)"
            let visible = screen.visibleFrame
            let prior = fingerprintUsableBounds[key]
            let slack = TilingConfig.rectComparisonSlackPx
            // size as well as edges: opposite edges each moving one point
            // inward stays inside the per-edge slack but is a two-point
            // change in usable area, which layouts must see.
            let unchanged = prior.map {
                abs($0.minX - visible.minX) <= slack && abs($0.minY - visible.minY) <= slack
                    && abs($0.maxX - visible.maxX) <= slack && abs($0.maxY - visible.maxY) <= slack
                    && abs($0.width - visible.width) <= slack
                    && abs($0.height - visible.height) <= slack
            } ?? false
            // keep the anchor so successive one-point shifts cannot accumulate.
            let stable = unchanged ? prior! : visible
            nextBounds[key] = stable
            return "\(key)/\(stable)"
        }.joined(separator: "|")
        fingerprintUsableBounds = nextBounds
        return fingerprint
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

    /// Full physical display bounds in Core Graphics coordinates.
    func cgFullRect(for screen: NSScreen) -> CGRect {
        let frame = screen.frame
        return CGRect(x: frame.minX, y: primaryScreenHeight - frame.maxY,
                      width: frame.width, height: frame.height)
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

    /// The screen holding the largest part of `frame` (CG). A frame on no
    /// screen at all falls back to the screen nearest its origin, so a window
    /// parked in the hide corner counts for the screen it is parked on.
    func screen(containingMostOf frame: CGRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in screens {
            let overlap = frame.intersection(cgFullRect(for: screen))
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best ?? screen(at: frame.origin)
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
