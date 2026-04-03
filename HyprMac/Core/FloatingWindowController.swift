import Cocoa

// manages floating window z-order and focus cycling
class FloatingWindowController {

    // dependencies
    var isWindowVisible: (CGWindowID) -> Bool = { _ in false }
    var cachedWindow: (CGWindowID) -> HyprWindow? = { _ in nil }
    var screenAt: (CGPoint) -> NSScreen? = { _ in nil }
    var screenID: (NSScreen) -> Int = { _ in 0 }
    var screens: () -> [NSScreen] = { [] }

    // check if any visible floating window is behind a tiled window using CGWindowListCopyWindowInfo
    func floatingWindowsBehindTiled(
        floatingWindowIDs: Set<CGWindowID>,
        tiledPositions: [CGWindowID: CGRect]
    ) -> [CGWindowID] {
        let visibleFloaters = floatingWindowIDs.filter { isWindowVisible($0) }
        guard !visibleFloaters.isEmpty else { return [] }

        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return Array(visibleFloaters)
        }

        // build z-index map: lower index = closer to front
        var zIndex: [CGWindowID: Int] = [:]
        for (i, info) in infoList.enumerated() {
            if let wid = info[kCGWindowNumber as String] as? CGWindowID {
                zIndex[wid] = i
            }
        }

        // find the frontmost tiled window z-index per screen
        var frontTiledZ: [Int: Int] = [:]
        for (wid, rect) in tiledPositions {
            guard let z = zIndex[wid],
                  let screen = screenAt(CGPoint(x: rect.midX, y: rect.midY)) else { continue }
            let sid = screenID(screen)
            if frontTiledZ[sid].map({ z < $0 }) ?? true {
                frontTiledZ[sid] = z
            }
        }

        // floating window needs raising if behind frontmost tiled on its screen
        var needsRaise: [CGWindowID] = []
        for wid in visibleFloaters {
            guard let fz = zIndex[wid],
                  let w = cachedWindow(wid), let frame = w.frame else { continue }
            let screen = screenAt(CGPoint(x: frame.midX, y: frame.midY))
            let sid = screen.map { screenID($0) } ?? -1
            if let tz = frontTiledZ[sid], fz > tz {
                needsRaise.append(wid)
            }
        }
        return needsRaise
    }

    // cycle through and raise visible floating windows
    func focusFloating(
        floatingWindowIDs: Set<CGWindowID>,
        getAllWindows: () -> [HyprWindow],
        getFocusedWindow: () -> HyprWindow?,
        displayManager: DisplayManager,
        isFrameVisible: (CGRect, CGRect) -> Bool
    ) -> HyprWindow? {
        let visibleFloaters = floatingWindowIDs.sorted().compactMap { wid -> HyprWindow? in
            guard isWindowVisible(wid) else { return nil }
            return cachedWindow(wid) ?? getAllWindows().first { $0.windowID == wid }
        }
        guard !visibleFloaters.isEmpty else { return nil }

        let focused = getFocusedWindow()
        var target = visibleFloaters[0]
        if let focused = focused,
           let idx = visibleFloaters.firstIndex(where: { $0.windowID == focused.windowID }) {
            target = visibleFloaters[(idx + 1) % visibleFloaters.count]
        }

        // bring offscreen floaters to center of nearest screen
        if let frame = target.frame {
            let onScreen = screens().contains { screen in
                isFrameVisible(frame, displayManager.cgRect(for: screen))
            }
            if !onScreen {
                let screen = screens().first ?? NSScreen.main!
                let screenRect = displayManager.cgRect(for: screen)
                let sz = target.size ?? CGSize(width: 800, height: 600)
                target.position = CGPoint(x: screenRect.midX - sz.width / 2,
                                          y: screenRect.midY - sz.height / 2)
                print("[HyprMac] brought offscreen floater '\(target.title ?? "?")' to center")
            }
        }

        print("[HyprMac] focused floating window '\(target.title ?? "?")' (\(visibleFloaters.count) total)")
        return target
    }
}
