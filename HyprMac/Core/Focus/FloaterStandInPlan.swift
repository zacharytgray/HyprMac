// Which floaters get a stand-in: a HyprMac panel on the floater's frame,
// above the tiles, while a tile covers it. Pure over a decoded window list
// so the rules can be tested. The panel itself is `FloaterStandIn`.

import Cocoa

/// What the stand-in shows. Read from the `floaterStandIn` user default.
enum FloaterStandInMode: String, Equatable {
    case off
    /// app icon and title, no permission needed
    case card
    /// a ScreenCaptureKit picture of the floater; needs Screen Recording
    case live

    static let defaultsKey = "floaterStandIn"

    /// Unset or unknown: `live` in Debug builds, `off` in Release builds.
    static func resolve(_ raw: String?, isDebugBuild: Bool) -> FloaterStandInMode {
        if let raw, let mode = FloaterStandInMode(rawValue: raw.lowercased()) { return mode }
        return isDebugBuild ? .live : .off
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func current(_ defaults: UserDefaults = .standard) -> FloaterStandInMode {
        resolve(defaults.string(forKey: defaultsKey), isDebugBuild: isDebugBuild)
    }
}

enum FloaterStandInPlan {
    /// Floaters a tile is stacked above where they overlap. These get a panel.
    ///
    /// `floaters` are the visible managed floaters, scratchpad members left
    /// out; `tiles` the managed tiles. A floater the list does not show, or
    /// one at the floating level, is above every tile and gets none. A
    /// touching edge is not an overlap.
    static func covered(floaters: [CGWindowID: CGRect], tiles: [CGWindowID: CGRect],
                        in windows: [StackedWindow]) -> Set<CGWindowID> {
        let occluders = WindowStacking.occluders(ofFloaters: floaters, covers: tiles, in: windows)
        var result: Set<CGWindowID> = []
        for (id, covers) in occluders {
            guard let frame = floaters[id] else { continue }
            if covers.contains(where: { WindowStacking.overlaps($0, frame) }) { result.insert(id) }
        }
        return result
    }

    /// Floaters a tile overlaps, in front or behind. A tile can cover any of
    /// these with one click, so each keeps its picture warm. Only floaters
    /// the window list shows on screen count: a hidden or minimized one has
    /// no picture to keep.
    static func atRisk(floaters: [CGWindowID: CGRect], tiles: [CGWindowID: CGRect],
                       in windows: [StackedWindow]) -> Set<CGWindowID> {
        let onScreen = Set(windows.filter(\.isVisible).map(\.windowID))
        var result: Set<CGWindowID> = []
        for (id, frame) in floaters where onScreen.contains(id) {
            if tiles.contains(where: { $0.key != id && WindowStacking.overlaps($0.value, frame) }) {
                result.insert(id)
            }
        }
        return result
    }

    /// A press at `point` (CG): the tile pressed and the floaters it is
    /// about to cover, nil when it covers none. The clicked app raises its window before any refresh could
    /// see it, so the panel goes up on the mouse-down.
    ///
    /// The press must land on a tile. A floater at layer 0 that the tile
    /// overlaps goes under it. One at the floating level stays above while
    /// its app is active, so only a tile of another app buries it (its app
    /// deactivates and drops it to layer 0).
    static func coveredByPress(at point: CGPoint, in windows: [StackedWindow],
                               floaters: [CGWindowID: CGRect], tiles: [CGWindowID: CGRect],
                               frontmostPID: pid_t?, ownPID: pid_t,
                               mouseTarget: ((CGPoint) -> CGWindowID)? = nil)
        -> (tile: CGWindowID, floaters: Set<CGWindowID>)? {
        guard case .window(let pressed) = WindowStacking.hitTest(
                point, in: windows, frontmostPID: frontmostPID, ownPID: ownPID,
                managedFloaters: Set(floaters.keys), mouseTarget: mouseTarget),
              let tileFrame = tiles[pressed],
              let tile = windows.first(where: { $0.windowID == pressed }) else { return nil }
        var result: Set<CGWindowID> = []
        for (id, frame) in floaters where id != pressed {
            guard let floater = windows.first(where: { $0.windowID == id }), floater.isVisible,
                  WindowStacking.overlaps(frame, tileFrame) else { continue }
            if floater.layer == 0
                || (floater.layer == WindowStacking.floatingLayer && floater.ownerPID != tile.ownerPID) {
                result.insert(id)
            }
        }
        return result.isEmpty ? nil : (pressed, result)
    }
}
