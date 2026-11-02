// What a tiled drag captured at mouse-down.

import Cocoa

struct TiledDragSnapshot {
    let draggedID: CGWindowID
    let sourceTree: BSPTree
    let originalTree: BSPTree
    let context: TiledDragContext
    let originalFrames: [CGWindowID: CGRect]
    let generation: UInt64
    /// where the press landed, global CG. nil for a capture by id, which only tests do
    var pressPoint: CGPoint? = nil

    /// How far inside a frame's left, right or bottom edge a press grabs its
    /// resize border. Inside only: a press has to land on a tile to be
    /// captured at all.
    static let resizeBorderBand: CGFloat = 8
    /// The top edge's band, narrower because the title bar starts right
    /// below it.
    static let resizeTopBorderBand: CGFloat = 4
    /// How far the edge opposite a grabbed one may drift and still count as
    /// held. A point of slack over the one-point readback tolerance, for an
    /// app that rounds its size to cells as it resizes.
    static let heldEdgeTolerance: CGFloat = 3
    /// How much a grabbed axis has to change size before a border press is
    /// a resize rather than a move that barely started.
    static let resizeMinimumChange: CGFloat = 4

    /// The edges whose band holds the press, corners giving two. nil when
    /// the press point is not known.
    var pressedEdges: Set<BSPTargetEdge>? {
        guard let pressPoint else { return nil }
        guard let frame = originalFrames[draggedID],
              pressPoint.x >= frame.minX, pressPoint.x <= frame.maxX,
              pressPoint.y >= frame.minY, pressPoint.y <= frame.maxY else { return [] }
        var edges = Set<BSPTargetEdge>()
        if pressPoint.x - frame.minX < Self.resizeBorderBand { edges.insert(.left) }
        if frame.maxX - pressPoint.x < Self.resizeBorderBand { edges.insert(.right) }
        if pressPoint.y - frame.minY < Self.resizeTopBorderBand { edges.insert(.top) }
        if frame.maxY - pressPoint.y < Self.resizeBorderBand { edges.insert(.bottom) }
        return edges
    }

    /// For each grabbed edge, in left, right, top, bottom order, how far the
    /// edge opposite it has moved: maxX for a left edge, minY for a bottom
    /// edge, and so on.
    func oppositeEdgeDrift(to frame: CGRect) -> [(edge: BSPTargetEdge, drift: CGFloat)] {
        guard let original = originalFrames[draggedID], let edges = pressedEdges else { return [] }
        return BSPTargetEdge.allCases.filter(edges.contains).map { edge in
            switch edge {
            case .left: return (edge, abs(frame.maxX - original.maxX))
            case .right: return (edge, abs(frame.minX - original.minX))
            case .top: return (edge, abs(frame.maxY - original.maxY))
            case .bottom: return (edge, abs(frame.minY - original.minY))
            }
        }
    }

    /// What the drag has done to the window, judged from `frame` against its
    /// captured frame. The drop asks with the read 100 ms after release, the
    /// live preview with the window list as the drag goes, so the two cannot
    /// disagree.
    ///
    /// Unmoved is within a point of where it was. A resize grabbed an edge
    /// in its band, held the edge opposite every grabbed one within
    /// `heldEdgeTolerance`, and changed a grabbed axis by more than
    /// `resizeMinimumChange`. A size change on an axis nobody grabbed does
    /// not count either way: an aspect-locked side resize moves the other
    /// axis, and a corner press can register as one edge. Anything else is a
    /// move, which holds no edge still even when the app changes its own
    /// size on the way, the way Messages does onto the ultrawide. A capture
    /// by id (tests only) has no press point, so size alone decides there,
    /// over 20 points.
    func gesture(to frame: CGRect) -> TiledDragGesture {
        guard let original = originalFrames[draggedID] else { return .move }
        let tolerance = FrameSizingConfiguration()
        let widthChange = abs(frame.width - original.width)
        let heightChange = abs(frame.height - original.height)
        if abs(frame.minX - original.minX) <= tolerance.positionTolerance,
           abs(frame.minY - original.minY) <= tolerance.positionTolerance,
           widthChange <= tolerance.sizeTolerance, heightChange <= tolerance.sizeTolerance {
            return .unmoved
        }
        guard let edges = pressedEdges else {
            return widthChange > 20 || heightChange > 20 ? .resize : .move
        }
        guard !edges.isEmpty,
              oppositeEdgeDrift(to: frame).allSatisfy({ $0.drift <= Self.heldEdgeTolerance })
        else { return .move }
        let widthGrabbed = edges.contains(.left) || edges.contains(.right)
        let heightGrabbed = edges.contains(.top) || edges.contains(.bottom)
        let grabbedAxisChanged = (widthGrabbed && widthChange > Self.resizeMinimumChange)
            || (heightGrabbed && heightChange > Self.resizeMinimumChange)
        return grabbedAxisChanged ? .resize : .move
    }
}
