import Cocoa

class DisplayManager {
    private(set) var screens: [NSScreen] = []
    // cached to avoid hitting NSScreen.screens on every coordinate conversion
    private(set) var primaryScreenHeight: CGFloat = 0

    init() {
        refresh()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    @objc func refresh() {
        screens = NSScreen.screens
        primaryScreenHeight = screens.first?.frame.height ?? 0
        hyprLog("displays: \(screens.count)")
        for (i, screen) in screens.enumerated() {
            let frame = screen.frame
            let visible = screen.visibleFrame
            let cg = cgRect(for: screen)
            hyprLog("  display \(i): frame=\(frame) visible=\(visible) cg=\(cg)")
        }
    }

    // convert NSScreen's visibleFrame (bottom-left origin) to CG coordinates (top-left origin)
    // this works correctly for ALL screens, not just the primary
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

    // find which screen a CG point (top-left origin) is on
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

    // find which screen a window is on (by its center point)
    func screen(for window: HyprWindow) -> NSScreen? {
        guard let center = window.center else {
            // can't determine — try position alone
            guard let pos = window.position else { return nil }
            return screen(at: pos)
        }
        return screen(at: center)
    }

    // find NSScreen by display UUID (from CGSCopyManagedDisplaySpaces "Display Identifier")
    // the display identifier is like "Main" or a UUID string — match by index order
    // since CGSCopyManagedDisplaySpaces and NSScreen.screens use the same ordering
    func screen(forDisplayIndex index: Int) -> NSScreen? {
        guard index >= 0 && index < screens.count else { return nil }
        return screens[index]
    }

    var mainScreen: NSScreen? { NSScreen.main }
}
