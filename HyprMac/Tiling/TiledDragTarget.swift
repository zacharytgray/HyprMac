import CoreGraphics

struct TiledDragTarget: Equatable {
    let windowID: CGWindowID
    let edge: BSPTargetEdge
}

struct TiledDragTargetResolver {
    static func resolve(pointer: CGPoint, draggedID: CGWindowID,
                        intendedSlots: [CGWindowID: CGRect]) -> TiledDragTarget? {
        guard pointer.x.isFinite, pointer.y.isFinite else { return nil }
        let hits = intendedSlots.filter { windowID, frame in
            guard windowID != draggedID,
                  frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.size.width.isFinite, frame.size.height.isFinite,
                  frame.size.width > 0, frame.size.height > 0 else { return false }
            return pointer.x >= frame.minX && pointer.x <= frame.maxX
                && pointer.y >= frame.minY && pointer.y <= frame.maxY
        }
        guard hits.count == 1, let (windowID, frame) = hits.first else { return nil }
        return TiledDragTarget(windowID: windowID, edge: edge(of: pointer, in: frame))
    }

    /// The tile nearest `pointer`, for a release on another monitor. A
    /// pointer inside a tile picks it; one in a gap or the padding picks the
    /// closest tile, lower id on a tie. The edge uses the same normalized
    /// rule, measured from the pointer clamped into that tile.
    static func nearest(pointer: CGPoint, slots: [CGWindowID: CGRect]) -> TiledDragTarget? {
        guard pointer.x.isFinite, pointer.y.isFinite else { return nil }
        let ranked = slots.filter { _, frame in
            frame.origin.x.isFinite && frame.origin.y.isFinite
                && frame.size.width.isFinite && frame.size.height.isFinite
                && frame.size.width > 0 && frame.size.height > 0
        }.map { windowID, frame in
            (windowID: windowID, frame: frame, distance: distance(from: pointer, to: frame))
        }
        guard let best = ranked.min(by: {
            ($0.distance, $0.windowID) < ($1.distance, $1.windowID)
        }) else { return nil }
        let clamped = CGPoint(x: min(max(pointer.x, best.frame.minX), best.frame.maxX),
                              y: min(max(pointer.y, best.frame.minY), best.frame.maxY))
        return TiledDragTarget(windowID: best.windowID, edge: edge(of: clamped, in: best.frame))
    }

    /// The one tile within `band` of `pointer`, for a press that hit no
    /// tile: macOS starts an edge resize just outside the window. Unlike
    /// `nearest`, a tie picks none, so the middle of a gap belongs to
    /// neither side.
    static func nearest(pointer: CGPoint, slots: [CGWindowID: CGRect],
                        within band: CGFloat) -> CGWindowID? {
        guard band > 0 else { return nil }
        let near = slots.map { (windowID: $0.key, distance: distance(from: pointer, to: $0.value)) }
            .filter { $0.distance <= band }
            .sorted { $0.distance < $1.distance }
        guard let first = near.first else { return nil }
        if near.count > 1, near[1].distance == first.distance { return nil }
        return first.windowID
    }

    /// How far `pointer` is from `frame`: zero on or inside it.
    static func distance(from pointer: CGPoint, to frame: CGRect) -> CGFloat {
        let dx = max(frame.minX - pointer.x, 0, pointer.x - frame.maxX)
        let dy = max(frame.minY - pointer.y, 0, pointer.y - frame.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Every tile `nearest` weighed, in id order: its frame, its distance
    /// from the pointer, and the normalized distance to each edge from the
    /// pointer clamped into it. For the drop decision's log line.
    static func trace(pointer: CGPoint, slots: [CGWindowID: CGRect]) -> String {
        func number(_ value: CGFloat) -> String { String(format: "%g", Double(value)) }
        func fraction(_ value: CGFloat) -> String { String(format: "%.3f", Double(value)) }
        return slots.sorted { $0.key < $1.key }.map { windowID, frame in
            let clamped = CGPoint(x: min(max(pointer.x, frame.minX), frame.maxX),
                                  y: min(max(pointer.y, frame.minY), frame.maxY))
            let width = max(frame.width, 1)
            let height = max(frame.height, 1)
            return "\(windowID) frame=(\(number(frame.minX)),\(number(frame.minY)),"
                + "\(number(frame.width)),\(number(frame.height))) "
                + "dist=\(number(distance(from: pointer, to: frame))) "
                + "l=\(fraction((clamped.x - frame.minX) / width)) "
                + "r=\(fraction((frame.maxX - clamped.x) / width)) "
                + "t=\(fraction((clamped.y - frame.minY) / height)) "
                + "b=\(fraction((frame.maxY - clamped.y) / height))"
        }.joined(separator: "; ")
    }

    /// Nearest normalized edge of `frame` to `pointer`. Ties go left, right,
    /// top, bottom.
    private static func edge(of pointer: CGPoint, in frame: CGRect) -> BSPTargetEdge {
        let distances: [(BSPTargetEdge, CGFloat)] = [
            (.left, (pointer.x - frame.minX) / frame.width),
            (.right, (frame.maxX - pointer.x) / frame.width),
            (.top, (pointer.y - frame.minY) / frame.height),
            (.bottom, (frame.maxY - pointer.y) / frame.height)
        ]
        return distances.dropFirst().reduce(distances[0]) { nearest, candidate in
            candidate.1 < nearest.1 ? candidate : nearest
        }.0
    }
}

/// What a tiled release at a point would do. The drop and its live preview
/// both come from `TiledDropPlanner`, so they cannot disagree.
enum TiledDropPlan: Equatable {
    /// a tile of the source tree: insert beside it, or swap with it
    case sameTree(TiledDragTarget)
    /// another monitor's tree: beside or swapped with its nearest tile, or
    /// its root when it has none
    case otherMonitor(TiledDragTarget?)
    /// nothing takes the window here, so the drop restores
    case none
}

/// Where the release point is, as far as the plan cares.
enum TiledDropRelease: Equatable {
    /// the source display, or a point on no display
    case source
    /// another display. `slots` is its tree's layout, empty for a workspace
    /// with no tiles, nil when the drop there would decline
    case otherMonitor(slots: [CGWindowID: CGRect]?)
}

struct TiledDropPlanner {
    static func plan(pointer: CGPoint, draggedID: CGWindowID, sourceTiles: CGRect,
                     sourceSlots: [CGWindowID: CGRect],
                     release: TiledDropRelease) -> TiledDropPlan {
        if let target = sameTreeTarget(pointer: pointer, draggedID: draggedID,
                                       sourceTiles: sourceTiles, sourceSlots: sourceSlots) {
            return .sameTree(target)
        }
        guard case let .otherMonitor(slots) = release, let slots else { return .none }
        if slots.isEmpty { return .otherMonitor(nil) }
        return otherMonitorTarget(pointer: pointer, slots: slots).map { .otherMonitor($0) } ?? .none
    }

    /// The source tile under the point. Only a point on the source's tiling
    /// rect counts, and a gap there takes nothing.
    static func sameTreeTarget(pointer: CGPoint, draggedID: CGWindowID, sourceTiles: CGRect,
                               sourceSlots: [CGWindowID: CGRect]) -> TiledDragTarget? {
        guard sourceTiles.contains(pointer) else { return nil }
        return TiledDragTargetResolver.resolve(pointer: pointer, draggedID: draggedID,
                                               intendedSlots: sourceSlots)
    }

    /// The tile of another monitor's tree the point is nearest.
    static func otherMonitorTarget(pointer: CGPoint,
                                   slots: [CGWindowID: CGRect]) -> TiledDragTarget? {
        TiledDragTargetResolver.nearest(pointer: pointer, slots: slots)
    }

    /// A tree's slots as the engine lays them out. The drop and the preview
    /// both pick the release screen's target from these, never from a live
    /// read, so both see the same tiles.
    static func slots(of tree: BSPTree, in usableFrame: CGRect, gap: CGFloat,
                      padding: CGFloat) -> [CGWindowID: CGRect] {
        Dictionary(tree.layout(in: usableFrame, gap: gap, padding: padding)
            .map { ($0.0.windowID, $0.1) }, uniquingKeysWith: { first, _ in first })
    }
}
