// Which floaters get a stand-in: a HyprMac panel on the floater's frame,
// above the tiles, while a tile covers it. Pure over a decoded window list
// so the rules can be tested. The panel itself is `FloaterStandIn`.

import Cocoa

/// What the stand-in shows. Settings → Tiling → "Keep floating windows in
/// front" turns it on; Screen Recording decides the look.
enum FloaterStandInMode: String, Equatable {
    case off
    /// app icon and title, no permission needed
    case card
    /// a ScreenCaptureKit picture of the floater; needs Screen Recording
    case live

    /// Debug builds only: `card` here shows the card with Screen Recording
    /// granted, so both looks can be checked on one Mac.
    static let debugLookKey = "floaterStandInLook"

    static func resolve(on: Bool, captureGranted: Bool, forcesCard: Bool = false) -> FloaterStandInMode {
        guard on else { return .off }
        return captureGranted && !forcesCard ? .live : .card
    }

    /// Debug builds only: keep the old z-order repairs (raise behind, raise
    /// before focus, lift over floaters) running with the switch on, to
    /// compare. They are off with the switch on otherwise.
    static let debugKeepRepairsKey = "floaterStandInKeepRepairs"

    static func debugKeepsRepairs(_ defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
        return defaults.bool(forKey: debugKeepRepairsKey)
        #else
        return false
        #endif
    }

    static func debugForcesCard(_ defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
        return defaults.string(forKey: debugLookKey)?.lowercased() == "card"
        #else
        return false
        #endif
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

/// Part of a floater's chrome (its outline, its stand-in) that must not draw:
/// a window stacked above the floater. A floater's cut is its rounded frame,
/// so no square corner of outline shows around a rounded window.
struct ChromeCut: Equatable {
    let rect: CGRect
    let rounded: Bool
}

extension FloaterStandInPlan {
    /// Managed floaters on screen, front to back, as the window list stacks them.
    static func floaterOrder(_ floaters: Set<CGWindowID>, in windows: [StackedWindow]) -> [CGWindowID] {
        var seen: Set<CGWindowID> = []
        return windows.compactMap { w in
            guard floaters.contains(w.windowID), w.isVisible, seen.insert(w.windowID).inserted else { return nil }
            return w.windowID
        }
    }

    /// What each floater's outline and stand-in must leave out, so they
    /// follow the real stacking order.
    ///
    /// - A tile above a floater cuts its outline, unless the floater has a
    ///   stand-in up: then the outline draws whole over the tile, like the
    ///   picture under it.
    /// - A floater above another cuts the back one's outline and picture
    ///   with its rounded frame, stand-in or not.
    /// - `unsettled` floaters are changing place (a press, a focus): until
    ///   the window list shows the new order, two real floaters that overlap
    ///   cut each other, so neither order draws for a frame. A stand-in is
    ///   never cut for that: its picture would leave a hole.
    ///
    /// `reach` is how far an outline's glow reaches past its window.
    static func chromeCuts(floaters: [CGWindowID: CGRect], tiles: [CGWindowID: CGRect],
                           standIns: Set<CGWindowID>, unsettled: Set<CGWindowID> = [],
                           reach: CGFloat = 0, in windows: [StackedWindow]) -> [CGWindowID: [ChromeCut]] {
        var depth: [CGWindowID: Int] = [:]
        for (index, window) in windows.enumerated() where depth[window.windowID] == nil {
            depth[window.windowID] = index
        }
        var result: [CGWindowID: [ChromeCut]] = [:]
        for (id, frame) in floaters {
            guard let mine = depth[id] else { continue }
            let area = frame.insetBy(dx: -reach, dy: -reach)
            var cuts: [(Int, ChromeCut)] = []
            if !standIns.contains(id) {
                for (tile, rect) in tiles where tile != id {
                    guard let d = depth[tile], d < mine, rect.intersects(area) else { continue }
                    cuts.append((d, ChromeCut(rect: rect, rounded: false)))
                }
            }
            for (other, rect) in floaters where other != id {
                guard let d = depth[other], rect.intersects(area) else { continue }
                let above = d < mine
                let swapping = (unsettled.contains(id) || unsettled.contains(other))
                    && !standIns.contains(id) && !standIns.contains(other)
                if above || swapping { cuts.append((d, ChromeCut(rect: rect, rounded: true))) }
            }
            if !cuts.isEmpty { result[id] = cuts.sorted { $0.0 < $1.0 }.map(\.1) }
        }
        return result
    }

    /// Whether `id` is above every floater it overlaps: a raise has landed.
    static func isAboveOverlappingFloaters(_ id: CGWindowID, floaters: [CGWindowID: CGRect],
                                           in windows: [StackedWindow]) -> Bool {
        guard let frame = floaters[id],
              let mine = windows.firstIndex(where: { $0.windowID == id }) else { return false }
        return !floaters.contains { other, rect in
            other != id && WindowStacking.overlaps(rect, frame)
                && (windows.firstIndex(where: { $0.windowID == other }).map { $0 < mine } ?? false)
        }
    }

    /// Whether `point` (CG) falls in one of `cuts`, rounded ones by their
    /// corner radius.
    static func isCut(_ point: CGPoint, by cuts: [ChromeCut], cornerRadius: CGFloat) -> Bool {
        cuts.contains { cut in
            guard cut.rect.contains(point) else { return false }
            let r = min(cornerRadius, cut.rect.width / 2, cut.rect.height / 2)
            guard cut.rounded, r > 0 else { return true }
            return CGPath(roundedRect: cut.rect, cornerWidth: r, cornerHeight: r, transform: nil).contains(point)
        }
    }
}

/// Why a floater may not have a stand-in right now.
enum StandInBlock: String, Equatable {
    case notFloating = "not a managed floater"
    /// HyprMac counts it hidden: closed while its app runs (a ghost),
    /// minimized, or its app hidden
    case hidden = "hidden or closed"
    /// the window list doesn't show it: ordered out (Teams keeps a closed
    /// window and its id), minimized or app-hidden before HyprMac knows
    case offScreen = "not on screen"
    case excluded = "scratchpad member or pop-up"
}

extension FloaterStandInPlan {
    /// The one test every stand-in path asks: may `id` have a stand-in now?
    ///
    /// HyprMac's own floater list can hold a window that is gone: a window
    /// closed while its app keeps running keeps its workspace (a ghost), and
    /// discovery may only call it hidden seconds later. So the window list
    /// decides too: the floater must be on screen there. A floater HyprMac
    /// parked for a hidden workspace still is (in the hide corner), so it
    /// keeps its picture; a closed, minimized or app-hidden one is ordered
    /// out and is not.
    static func standInBlock(_ id: CGWindowID, floating: Set<CGWindowID>, hidden: Set<CGWindowID>,
                             excluded: Set<CGWindowID>, in windows: [StackedWindow]) -> StandInBlock? {
        guard floating.contains(id) else { return .notFloating }
        if excluded.contains(id) { return .excluded }
        if hidden.contains(id) { return .hidden }
        guard windows.contains(where: { $0.windowID == id && $0.isVisible && WindowStacking.isFloaterLayer($0.layer) })
        else { return .offScreen }
        return nil
    }

    /// A switch put `revealed` back. Of the kept pictures (`kept`, by the
    /// frame each floater was last seen at), `show` are the ones that go up
    /// at once: the gate lets the floater through and a tile of the incoming
    /// workspace will cover it, by the slots the layout gives its tiles.
    /// `drop` are kept pictures of revealed floaters the gate stops (a
    /// closed Teams window keeps its id but is ordered out): they go for good.
    static func revealPictures(kept: [CGWindowID: CGRect], revealed: Set<CGWindowID>,
                               floating: Set<CGWindowID>, hidden: Set<CGWindowID>, excluded: Set<CGWindowID>,
                               tileSlots: [CGRect], in windows: [StackedWindow])
        -> (show: Set<CGWindowID>, drop: [CGWindowID: StandInBlock]) {
        var show: Set<CGWindowID> = []
        var drop: [CGWindowID: StandInBlock] = [:]
        for (id, frame) in kept where revealed.contains(id) {
            if let block = standInBlock(id, floating: floating, hidden: hidden, excluded: excluded, in: windows) {
                drop[id] = block
            } else if tileSlots.contains(where: { WindowStacking.overlaps($0, frame) }) {
                show.insert(id)
            }
        }
        return (show, drop)
    }
}
