// What the window server says about stacking: the frontmost app's popup
// windows, a pointer hit-test that stops at them, which floaters sit above
// or below a tile, and what covers each floater. Everything here is pure
// over a decoded CGWindowList so the rules can be tested with an injected
// list.

import Cocoa

/// One on-screen window as `CGWindowListCopyWindowInfo` reports it.
/// Lists come front to back.
struct StackedWindow: Equatable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let layer: Int
    let bounds: CGRect?
    let alpha: CGFloat

    init(windowID: CGWindowID, ownerPID: pid_t, layer: Int = 0,
         bounds: CGRect?, alpha: CGFloat = 1) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.layer = layer
        self.bounds = bounds
        self.alpha = alpha
    }

    init?(info: [String: Any]) {
        guard let number = Self.int(info[kCGWindowNumber as String]) else { return nil }
        windowID = CGWindowID(truncatingIfNeeded: number)
        ownerPID = pid_t(truncatingIfNeeded: Self.int(info[kCGWindowOwnerPID as String]) ?? 0)
        layer = Self.int(info[kCGWindowLayer as String]) ?? 0
        if let raw = info[kCGWindowBounds as String] as? NSDictionary {
            bounds = CGRect(dictionaryRepresentation: raw as CFDictionary)
        } else {
            bounds = nil
        }
        alpha = (info[kCGWindowAlpha as String] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 1
    }

    // the list hands back NSNumber; tests hand back plain swift ints
    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let v as Int: return v
        case let v as UInt32: return Int(v)
        case let v as Int32: return Int(v)
        case let v as NSNumber: return v.intValue
        default: return nil
        }
    }

    var isVisible: Bool {
        guard alpha > 0.01, let bounds else { return false }
        return bounds.width > 1 && bounds.height > 1
    }
}

enum WindowStacking {
    static let dockLayer = Int(CGWindowLevelForKey(.dockWindow))
    static let mainMenuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
    static let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
    static let popUpMenuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
    static let screenSaverLayer = Int(CGWindowLevelForKey(.screenSaverWindow))
    static let floatingLayer = Int(CGWindowLevelForKey(.floatingWindow))

    /// Layers a managed floater can sit on. AppKit puts a floating panel
    /// (a Quick Look preview, an inspector) at the floating level while its
    /// app is active and drops it to layer 0 when the app deactivates, so
    /// both count. Only windows HyprMac manages as floaters are asked about;
    /// an unmanaged floating-level window stays out of every floater rule.
    static func isFloaterLayer(_ layer: Int) -> Bool {
        layer == 0 || layer == floatingLayer
    }

    /// Layers that mean "a menu is open". NSMenu draws at the pop-up menu
    /// level, and so do Chrome's own menu windows (bookmark-bar folders):
    /// chromium's NativeWidgetMac maps a TYPE_MENU widget to
    /// kCGPopUpMenuWindowLevel. Overlays and help tags sit just above it.
    static let popupLayers = popUpMenuLayer..<screenSaverLayer

    /// On-screen windows, front to back. `nil` when the list is unavailable.
    static func onScreen() -> [StackedWindow]? {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        return decode(raw)
    }

    static func decode(_ raw: [[String: Any]]) -> [StackedWindow] {
        raw.compactMap(StackedWindow.init(info:))
    }

    /// The frontmost app's popup-level window, when one is on screen.
    ///
    /// Only the frontmost app counts. Other apps' high windows (notification
    /// banners, other status menus, our own panels) must not freeze focus.
    static func openPopup(in windows: [StackedWindow], frontmostPID: pid_t?,
                          ownPID: pid_t) -> StackedWindow? {
        openPopups(in: windows, frontmostPID: frontmostPID, ownPID: ownPID).first
    }

    /// Every popup-level window of the frontmost app, front to back.
    static func openPopups(in windows: [StackedWindow], frontmostPID: pid_t?,
                           ownPID: pid_t) -> [StackedWindow] {
        guard let frontmostPID, frontmostPID != ownPID else { return [] }
        return windows.filter {
            $0.ownerPID == frontmostPID && popupLayers.contains($0.layer) && $0.isVisible
        }
    }

    /// A raised window the frontmost app owns: floating panels, menus,
    /// overlays. Never the Dock, the menu bar, status items, or the
    /// screen saver and above.
    static func isAppRaisedLayer(_ layer: Int) -> Bool {
        layer > 0 && layer < screenSaverLayer
            && layer != dockLayer && layer != mainMenuLayer && layer != statusLayer
    }

    enum Hit: Equatable {
        /// the first normal-layer window under the point, or a managed
        /// floater at the floating level
        case window(CGWindowID)
        /// a raised window of the frontmost app is under the point.
        /// hovering it must not reach the window below.
        case blocked(StackedWindow)
        case none
    }

    /// Front-to-back hit test at `point` (CG coordinates).
    ///
    /// Our own windows and invisible windows are skipped. Other apps'
    /// raised windows are skipped too, as before, so a click-through
    /// overlay cannot kill focus-follows-mouse. A managed floater raised
    /// to the floating level is a hit on that floater, whichever app is in
    /// front; any other raised window of the frontmost app blocks.
    static func hitTest(_ point: CGPoint, in windows: [StackedWindow],
                        frontmostPID: pid_t?, ownPID: pid_t,
                        managedFloaters: Set<CGWindowID> = []) -> Hit {
        for window in windows {
            guard window.ownerPID != ownPID, window.alpha > 0.01,
                  let bounds = window.bounds, bounds.contains(point) else { continue }
            if window.layer == 0 {
                return window.windowID == 0 ? .none : .window(window.windowID)
            }
            if window.layer == floatingLayer, managedFloaters.contains(window.windowID) {
                return .window(window.windowID)
            }
            if let frontmostPID, window.ownerPID == frontmostPID,
               isAppRaisedLayer(window.layer) {
                return .blocked(window)
            }
        }
        return .none
    }

    /// Smallest overlap, in points on each axis, that counts as covering.
    /// Tiles sit a gap apart, so a touching edge is not an overlap.
    static let minOverlap: CGFloat = 4

    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let shared = a.intersection(b)
        return !shared.isNull && shared.width >= minOverlap && shared.height >= minOverlap
    }

    /// Floaters stacked above `target` that overlap it, front to back. A
    /// floater at the floating level is above every normal window; it is
    /// still at risk, because activating the tile's app drops it to layer 0.
    static func floaters(above target: CGWindowID, among floaterIDs: Set<CGWindowID>,
                         in windows: [StackedWindow]) -> [StackedWindow] {
        guard let targetIndex = windows.firstIndex(where: { $0.windowID == target }),
              let targetFrame = windows[targetIndex].bounds else { return [] }
        return windows[..<targetIndex].filter {
            floaterIDs.contains($0.windowID) && isFloaterLayer($0.layer)
                && ($0.bounds.map { overlaps($0, targetFrame) } ?? false)
        }
    }

    /// Visible floaters stacked below `target` that it overlaps, front to
    /// back. After a click on a tile, these are the floaters it buried.
    static func floaters(below target: CGWindowID, among floaterIDs: Set<CGWindowID>,
                         in windows: [StackedWindow]) -> [StackedWindow] {
        guard let targetIndex = windows.firstIndex(where: { $0.windowID == target }),
              let targetFrame = windows[targetIndex].bounds else { return [] }
        return windows[(targetIndex + 1)...].filter {
            floaterIDs.contains($0.windowID) && isFloaterLayer($0.layer) && $0.isVisible
                && ($0.bounds.map { overlaps($0, targetFrame) } ?? false)
        }
    }

    /// For each floater, the frames in `covers` stacked above it that touch
    /// it, front to back.
    ///
    /// The dim cuts a floater's hole only where the floater is in front, so
    /// these come back out of the hole. A floater the list does not show
    /// gets no entry and keeps its whole hole, as before, and so does a
    /// floater at the floating level, which is above every layer-0 window.
    /// Covers count only on layer 0.
    static func occluders(ofFloaters floaterFrames: [CGWindowID: CGRect],
                          covers: [CGWindowID: CGRect],
                          in windows: [StackedWindow]) -> [CGWindowID: [CGRect]] {
        var depth: [CGWindowID: (index: Int, layer: Int)] = [:]
        for (index, window) in windows.enumerated()
        where isFloaterLayer(window.layer) && depth[window.windowID] == nil {
            depth[window.windowID] = (index, window.layer)
        }
        var result: [CGWindowID: [CGRect]] = [:]
        for (floater, frame) in floaterFrames {
            guard let entry = depth[floater], entry.layer == 0 else { continue }
            let floaterDepth = entry.index
            let above = covers.compactMap { id, rect -> (Int, CGRect)? in
                guard id != floater, let cover = depth[id], cover.layer == 0,
                      cover.index < floaterDepth,
                      !rect.intersection(frame).isEmpty else { return nil }
                return (cover.index, rect)
            }
            if !above.isEmpty {
                result[floater] = above.sorted { $0.0 < $1.0 }.map(\.1)
            }
        }
        return result
    }

    /// A point inside `frame` that none of `covers` hides: the center of
    /// the largest uncovered strip. `nil` when nothing is left uncovered.
    static func exposedPoint(of frame: CGRect, coveredBy covers: [CGRect]) -> CGPoint? {
        var open = [frame]
        for cover in covers {
            open = open.flatMap { subtract(cover, from: $0) }
        }
        guard let best = open.max(by: { $0.width * $0.height < $1.width * $1.height }),
              best.width >= minOverlap, best.height >= minOverlap else { return nil }
        return CGPoint(x: best.midX, y: best.midY)
    }

    /// `rect` minus `cover`, as up to four strips.
    static func subtract(_ cover: CGRect, from rect: CGRect) -> [CGRect] {
        let hole = rect.intersection(cover)
        guard !hole.isNull, hole.width > 0, hole.height > 0 else { return [rect] }
        var strips: [CGRect] = []
        if hole.minY > rect.minY {
            strips.append(CGRect(x: rect.minX, y: rect.minY,
                                 width: rect.width, height: hole.minY - rect.minY))
        }
        if hole.maxY < rect.maxY {
            strips.append(CGRect(x: rect.minX, y: hole.maxY,
                                 width: rect.width, height: rect.maxY - hole.maxY))
        }
        if hole.minX > rect.minX {
            strips.append(CGRect(x: rect.minX, y: hole.minY,
                                 width: hole.minX - rect.minX, height: hole.height))
        }
        if hole.maxX < rect.maxX {
            strips.append(CGRect(x: hole.maxX, y: hole.minY,
                                 width: rect.maxX - hole.maxX, height: hole.height))
        }
        return strips
    }
}
