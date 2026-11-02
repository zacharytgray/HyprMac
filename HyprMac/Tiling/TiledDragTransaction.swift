import Cocoa

struct TiledDragContext: Equatable {
    let workspace: Int
    let physicalDisplayID: CGDirectDisplayID
    let usableFrame: CGRect
    let gap: CGFloat
    let padding: CGFloat
    let maxDepth: Int
    let memberIDs: Set<CGWindowID>
    let floatingIDs: Set<CGWindowID>
    let fingerprint: BSPTree.StructuralFingerprint
    // what a rollback verifies against. it covers the unpadded screen too:
    // tiles laid out before a padding change still stand in the old strip.
    // nil means usableFrame
    var restorationFrame: CGRect? = nil
}

enum TiledDragMode {
    case insert(targetID: CGWindowID, edge: BSPTargetEdge)
    case swap(targetID: CGWindowID)
    case resize(frame: CGRect)
    /// released over another monitor. only the engine can resolve that
    /// screen's tree, so the pointer travels as it was.
    case crossMonitor(pointer: CGPoint, swapRequested: Bool)
}

enum TiledDragRejection: Equatable, Error {
    case notTiled
    case floating
    case invalidTarget
    case maxDepthExceeded
    case noTarget
    /// a known minimum does not fit its slot even after ratio adjustment
    case noRoom
}

enum TiledDragFailure: Equatable {
    case preflight(TiledDragRejection)
    case sizing(FrameSizingFailure)

    /// the failure with raw AX codes, for logs
    var trace: String {
        switch self {
        case let .preflight(rejection): return "preflight(\(rejection))"
        case let .sizing(failure): return "sizing(\(failure.trace))"
        }
    }
}

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

/// What a tiled drag did to the dragged window.
enum TiledDragGesture: String, Equatable {
    /// nothing a point or more: a press that selected text, say
    case unmoved
    case move
    /// a manual resize from an edge or corner
    case resize
}

enum TiledDragCaptureResult {
    case captured(TiledDragSnapshot)
    case ineligible(TiledDragRejection)
    case unknown(FrameSizingFailure)
}

enum TiledDragDropOutcome {
    case ignored
    /// `progress` says what the accepted attempt actually did, so the
    /// engine can apply the same publication gate the tiling trees use.
    case committed(candidate: BSPTree, actualFrames: [CGWindowID: CGRect],
                   progress: FrameSizingProgressReport)
    case rejectedRestored(reason: TiledDragFailure, actualFrames: [CGWindowID: CGRect])
    /// `progress` is nil when nothing knows what was written — provenance
    /// the cache policy cannot narrow with, so it falls back to clearing
    /// every member.
    case degraded(candidateReason: TiledDragFailure?, restorationReason: FrameSizingFailure?,
                  actualFrames: [CGWindowID: CGRect],
                  progress: FrameSizingProgressReport?)
    case superseded
    /// a drop that reached another monitor's tree. the inner outcome is
    /// committed, rejectedRestored or degraded, over both trees' members;
    /// its candidate is the source tree's.
    indirect case acrossTrees(TiledDragDropOutcome, TiledDragCrossTree)
}

/// What a drop onto another monitor's tree did beyond the source tree.
struct TiledDragCrossTree {
    /// the release screen's tree as it stood when the drop started
    let target: TiledDragContext
    /// the release screen's new tree. set on a commit only
    let targetCandidate: BSPTree?
    /// the workspace each window belongs to after a commit: the dragged one
    /// on the release screen's, a swapped one on the source's. empty
    /// otherwise, because membership changes only on a commit
    let moves: [CGWindowID: Int]
}

/// The release screen's tree for a drop onto another monitor, and how to
/// tell it is still the one on screen. `tree` is an empty stand-in when that
/// workspace has no tree yet.
struct TiledDragCrossTarget {
    let tree: BSPTree
    let context: TiledDragContext
    let currentContext: () -> TiledDragContext?
}

/// One drop's time on the main thread. Once it is spent, a call that times
/// out gets no longer try; the plain attempts and rollbacks still run. The
/// worst case with every retry was over ten seconds.
final class TiledDragBudget {
    static let defaultLimit: TimeInterval = 2.5

    let limit: TimeInterval
    private var startedAt: TimeInterval?

    init(limit: TimeInterval = TiledDragBudget.defaultLimit) {
        self.limit = limit
    }

    /// The drop began at `now`. Only the first call counts.
    func start(at now: TimeInterval) {
        if startedAt == nil { startedAt = now }
    }

    func allowsRecovery(at now: TimeInterval) -> Bool {
        start(at: now)
        return now - (startedAt ?? now) < limit
    }
}

struct TiledDragTransaction {
    typealias IOFactory = ([CGWindowID: HyprWindow], @escaping () -> UInt64) -> FrameSizingIO

    let ioFactory: IOFactory
    let minimumSize: (HyprWindow?) -> CGSize
    /// shared by every attempt of the drop this transaction runs
    let budget: TiledDragBudget

    init(ioFactory: @escaping IOFactory,
         minimumSize: @escaping (HyprWindow?) -> CGSize = { _ in .zero },
         budget: TiledDragBudget = TiledDragBudget()) {
        self.ioFactory = ioFactory
        self.minimumSize = minimumSize
        self.budget = budget
    }

    /// A sizing transaction for this drop: one longer try for a call that
    /// times out, while the drop's budget lasts.
    private func sizing(_ attempt: FrameSizingAttempt) -> FrameSizingTransaction {
        let budget = self.budget
        return FrameSizingTransaction(attempt: attempt, recoversTimeouts: true,
                                      recoveryAllowed: { budget.allowsRecovery(at: attempt.io.now()) })
    }

    func capture(pointer: CGPoint, tree: BSPTree, context: TiledDragContext,
                 occludingWindows: [HyprWindow], generation: UInt64,
                 currentContext: @escaping () -> TiledDragContext?,
                 onCapturedFrames: ([CGWindowID: CGRect]) -> Void = { _ in })
        -> TiledDragCaptureResult {
        guard pointer.x.isFinite, pointer.y.isFinite else { return .ineligible(.noTarget) }
        guard currentContext() == context,
              tree.structuralFingerprint() == context.fingerprint else {
            return .unknown(.superseded)
        }
        guard context.floatingIDs.isDisjoint(with: context.memberIDs) else {
            return .ineligible(.floating)
        }
        let tiledWindows = tree.allWindows
        let windows = tiledWindows + occludingWindows
        var seen = Set<CGWindowID>()
        for window in windows where !seen.insert(window.windowID).inserted {
            return .unknown(.duplicateWindowID(window.windowID))
        }
        let tiledIDs = Set(tiledWindows.map(\.windowID))
        guard tiledIDs == context.memberIDs else { return .ineligible(.notTiled) }
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        let io = ioFactory(byID) {
            guard currentContext() == context,
                  tree.structuralFingerprint() == context.fingerprint else {
                return generation &+ 1
            }
            return generation
        }
        let ids = windows.map(\.windowID)
        let captured = FrameSizingAttempt(io: io).captureFrames(windowIDs: ids,
                                                                generation: generation)
        guard case .accepted = captured.verdict,
              captured.actualFrames.count == ids.count else {
            let failure: FrameSizingFailure
            switch captured.verdict {
            case .accepted: failure = .windowUnavailable(ids.first ?? 0)
            case let .rejected(reason), let .unknown(reason): failure = reason
            }
            return .unknown(failure)
        }
        guard currentContext() == context,
              tree.structuralFingerprint() == context.fingerprint else {
            return .unknown(.superseded)
        }
        onCapturedFrames(captured.actualFrames)
        guard currentContext() == context,
              tree.structuralFingerprint() == context.fingerprint else {
            return .unknown(.superseded)
        }
        let tiledHits = tiledWindows.filter {
            captured.actualFrames[$0.windowID]?.contains(pointer) == true
        }
        let occluded = occludingWindows.contains {
            captured.actualFrames[$0.windowID]?.contains(pointer) == true
        }
        guard tiledHits.count == 1, !occluded, let dragged = tiledHits.first else {
            return .ineligible(.noTarget)
        }
        let originals = captured.actualFrames.filter { tiledIDs.contains($0.key) }
        return .captured(TiledDragSnapshot(
            draggedID: dragged.windowID,
            sourceTree: tree,
            originalTree: tree.deepClone(),
            context: context,
            originalFrames: originals,
            generation: generation,
            pressPoint: pointer
        ))
    }

    func capture(draggedID: CGWindowID, tree: BSPTree, context: TiledDragContext,
                 generation: UInt64,
                 currentContext: @escaping () -> TiledDragContext?) -> TiledDragCaptureResult {
        guard currentContext() == context,
              tree.structuralFingerprint() == context.fingerprint else {
            return .unknown(.superseded)
        }
        guard !context.floatingIDs.contains(draggedID) else {
            return .ineligible(.floating)
        }
        let windows = tree.allWindows
        let ids = windows.map(\.windowID)
        var seen = Set<CGWindowID>()
        for id in ids where !seen.insert(id).inserted {
            return .unknown(.duplicateWindowID(id))
        }
        let memberIDs = Set(ids)
        guard memberIDs == context.memberIDs, memberIDs.contains(draggedID) else {
            return .ineligible(.notTiled)
        }
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        let io = ioFactory(byID) {
            guard currentContext() == context,
                  tree.structuralFingerprint() == context.fingerprint else {
                return generation &+ 1
            }
            return generation
        }
        let captured = FrameSizingAttempt(io: io).captureFrames(windowIDs: ids,
                                                                generation: generation)
        guard case .accepted = captured.verdict,
              captured.actualFrames.count == ids.count else {
            let failure: FrameSizingFailure
            switch captured.verdict {
            case .accepted:
                failure = .windowUnavailable(draggedID)
            case let .rejected(reason), let .unknown(reason):
                failure = reason
            }
            return .unknown(failure)
        }
        return .captured(TiledDragSnapshot(
            draggedID: draggedID,
            sourceTree: tree,
            originalTree: tree.deepClone(),
            context: context,
            originalFrames: captured.actualFrames,
            generation: generation
        ))
    }

    func drop(_ snapshot: TiledDragSnapshot, mode: TiledDragMode?,
              currentContext: @escaping () -> TiledDragContext?) -> TiledDragDropOutcome {
        guard isCurrent(snapshot, currentContext: currentContext) else { return .superseded }
        let windows = snapshot.sourceTree.allWindows
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        let io = ioFactory(byID) {
            isCurrent(snapshot, currentContext: currentContext)
                ? snapshot.generation : snapshot.generation &+ 1
        }
        let attempt = FrameSizingAttempt(io: io)
        budget.start(at: io.now())

        guard let mode else {
            return restore(snapshot, reason: .preflight(.noTarget), attempt: attempt)
        }
        let candidate: BSPTree
        switch sameTreeCandidate(snapshot, mode: mode) {
        case let .success(built): candidate = built
        case let .failure(rejection):
            return restore(snapshot, reason: .preflight(rejection), attempt: attempt)
        }
        let layouts = adjustedLayouts(candidate, context: snapshot.context)
        guard valid(layouts, context: snapshot.context, attempt: attempt) else {
            return restore(snapshot, reason: .preflight(.invalidTarget), attempt: attempt)
        }
        guard isCurrent(snapshot, currentContext: currentContext) else { return .superseded }
        let transaction = sizing(attempt)
        let result = transaction.apply(
            targets: layouts.map { .init(windowID: $0.0.windowID, frame: $0.1) },
            originalFrames: snapshot.originalFrames,
            usableFrame: snapshot.context.usableFrame,
            restorationUsableFrame: snapshot.context.restorationFrame,
            gap: snapshot.context.gap,
            generation: snapshot.generation
        )
        switch result.outcome {
        case let .accepted(actualFrames):
            guard isCurrent(snapshot, currentContext: currentContext) else { return .superseded }
            return .committed(candidate: candidate, actualFrames: actualFrames,
                              progress: result.progress)
        case let .rejectedRestored(reason, actualFrames):
            return .rejectedRestored(reason: .sizing(reason), actualFrames: actualFrames)
        case let .degraded(candidateReason, restorationReason, actualFrames):
            if candidateReason == .superseded, restorationReason == nil { return .superseded }
            return .degraded(candidateReason: .sizing(candidateReason),
                             restorationReason: restorationReason,
                             actualFrames: actualFrames,
                             progress: result.progress)
        }
    }

    /// `moved`, when given, takes a plain move in place of the same-tree
    /// drop, with the frame the dragged window was read at. A resize, an
    /// unmoved window and a failed read go the ordinary way.
    func dropRelease(_ snapshot: TiledDragSnapshot, mode: TiledDragMode?,
                     currentContext: @escaping () -> TiledDragContext?,
                     moved: ((CGRect) -> TiledDragDropOutcome)? = nil)
        -> TiledDragDropOutcome {
        guard isCurrent(snapshot, currentContext: currentContext) else { return .superseded }
        let windows = snapshot.sourceTree.allWindows
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        let io = ioFactory(byID) {
            isCurrent(snapshot, currentContext: currentContext)
                ? snapshot.generation : snapshot.generation &+ 1
        }
        let attempt = FrameSizingAttempt(io: io)
        budget.start(at: io.now())
        let classified = sizing(attempt).capture(windowIDs: [snapshot.draggedID], generation: snapshot.generation)
        guard case .accepted = classified.verdict,
              let frame = classified.actualFrames[snapshot.draggedID] else {
            let failure: FrameSizingFailure
            switch classified.verdict {
            case .accepted: failure = .windowUnavailable(snapshot.draggedID)
            case let .rejected(reason), let .unknown(reason): failure = reason
            }
            if failure == .superseded { return .superseded }
            hyprLog(.notice, .tiling, "tiled drag settle read failed: dragged=\(snapshot.draggedID) "
                    + "reason=\(failure.trace) — restoring")
            return restore(snapshot, reason: .sizing(failure), attempt: attempt)
        }
        guard isCurrent(snapshot, currentContext: currentContext) else { return .superseded }
        let original = snapshot.originalFrames[snapshot.draggedID]
        // the same rule the live preview applies as the drag goes
        let gesture = snapshot.gesture(to: frame)
        let resized = gesture == .resize
        let unchanged = gesture == .unmoved
        let centeredOnSource = snapshot.context.usableFrame.contains(CGPoint(x: frame.midX,
                                                                             y: frame.midY))
        let decision: String
        if resized, mode == nil, !centeredOnSource {
            decision = "resize off the source tiles — restore"
        } else if unchanged {
            decision = "unmoved — ignored"
        } else if resized {
            decision = "resize — same-tree resize"
        } else if moved != nil {
            decision = "move — across monitors"
        } else {
            decision = mode == nil ? "move — no target, restore" : "move — same-tree drop"
        }
        let press = snapshot.pressPoint.map { "cg(\(Self.traced($0.x)),\(Self.traced($0.y)))" } ?? "none"
        let edges = snapshot.pressedEdges.map { edges in
            "[" + BSPTargetEdge.allCases.filter(edges.contains).map { "\($0)" }.joined(separator: ",") + "]"
        } ?? "unknown"
        // how far each grabbed edge's opposite moved; a resize holds them all
        let drift = "[" + snapshot.oppositeEdgeDrift(to: frame)
            .map { "\($0.edge):\(Self.traced($0.drift))" }.joined(separator: ",") + "]"
        // every plain click lands here unmoved. that goes to the trace tier
        hyprLog(unchanged ? .debug : .notice, .tiling, "tiled drag settle read: dragged=\(snapshot.draggedID) "
                + "original=\(original.map(Self.traced) ?? "none") read=\(Self.traced(frame)) "
                + "dw=\(original.map { Self.traced(frame.width - $0.width) } ?? "?") "
                + "dh=\(original.map { Self.traced(frame.height - $0.height) } ?? "?") "
                + "press=\(press) pressEdges=\(edges) oppositeDrift=\(drift) "
                + "gesture=\(gesture.rawValue) centerOnSource=\(centeredOnSource) "
                + "decision=\(decision)")
        if resized, mode == nil, !centeredOnSource {
            return restore(snapshot, reason: .preflight(.noTarget), attempt: attempt)
        }
        if unchanged { return .ignored }
        let outcome: TiledDragDropOutcome
        if !resized, let moved {
            outcome = moved(frame)
        } else {
            outcome = drop(snapshot, mode: resized ? .resize(frame: frame) : mode,
                           currentContext: currentContext)
        }
        guard isCurrent(snapshot, currentContext: currentContext) else { return .superseded }
        return outcome
    }

    /// A plain move released over another monitor's tree. The dragged window
    /// leaves the source tree and joins `target` beside the tile nearest the
    /// release point, trades places with that tile on a swap, or becomes the
    /// root of an empty tree. Both candidates are private clones and both are
    /// verified, the release screen first. Any failure puts both trees'
    /// captured originals back and verifies them.
    ///
    /// The release screen's originals are read here, before anything is
    /// written. `releaseFrame` is where the drag left the dragged window.
    /// `positionFirst` picks, per screen, the windows that move before they
    /// are sized.
    func dropAcrossTrees(
        _ snapshot: TiledDragSnapshot, into target: TiledDragCrossTarget,
        pointer: CGPoint, swapRequested: Bool, releaseFrame: CGRect,
        currentContext: @escaping () -> TiledDragContext?,
        configuration: FrameSizingConfiguration = FrameSizingConfiguration(),
        positionFirst: ([CGWindowID: CGRect], [(HyprWindow, CGRect)], CGRect) -> Set<CGWindowID>
            = { _, _, _ in [] }
    ) -> TiledDragDropOutcome {
        let isCurrent = {
            self.isCurrent(snapshot, currentContext: currentContext)
                && target.currentContext() == target.context
                && target.tree.structuralFingerprint() == target.context.fingerprint
        }
        guard isCurrent() else { return .superseded }
        let sourceWindows = snapshot.sourceTree.allWindows
        let targetWindows = target.tree.allWindows
        let byID = Dictionary((sourceWindows + targetWindows).map { ($0.windowID, $0) },
                              uniquingKeysWith: { first, _ in first })
        let io = ioFactory(byID) {
            isCurrent() ? snapshot.generation : snapshot.generation &+ 1
        }
        let attempt = FrameSizingAttempt(io: io, configuration: configuration)
        budget.start(at: io.now())
        let targetIDs = targetWindows.map(\.windowID)
        guard byID.count == sourceWindows.count + targetWindows.count,
              Set(targetIDs) == target.context.memberIDs,
              target.context.floatingIDs.isDisjoint(with: target.context.memberIDs),
              let dragged = sourceWindows.first(where: { $0.windowID == snapshot.draggedID }) else {
            return restore(snapshot, reason: .preflight(.invalidTarget), attempt: attempt)
        }

        let captured = sizing(attempt).capture(windowIDs: targetIDs, generation: snapshot.generation)
        guard case .accepted = captured.verdict, captured.actualFrames.count == targetIDs.count else {
            let failure = Self.failure(of: captured.verdict)
                ?? .windowUnavailable(targetIDs.first ?? snapshot.draggedID)
            if failure == .superseded { return .superseded }
            hyprLog(.notice, .tiling, "tiled drag across monitors: release screen read failed "
                    + "reason=\(failure.trace) — restoring the source")
            // nothing was written over there, so only the source goes back
            return restore(snapshot, reason: .sizing(failure), attempt: attempt)
        }
        let targetOriginals = captured.actualFrames
        let untouched = TiledDragCrossTree(target: target.context, targetCandidate: nil, moves: [:])
        func restoreBoth(_ reason: TiledDragFailure,
                         candidate: FrameSizingAttempt.Progress? = nil) -> TiledDragDropOutcome {
            restoreAcross(snapshot, target: target, targetOriginals: targetOriginals,
                          reason: reason, attempt: attempt, candidate: candidate, cross: untouched)
        }

        // a refusal before the first write puts back only the source: the
        // release screen was read, never written. the target comes from the
        // tree's own slots, as the live preview's does, not the frames read
        var hit: TiledDragTarget?
        if !targetIDs.isEmpty {
            let slots = TiledDropPlanner.slots(of: target.tree, in: target.context.usableFrame,
                                               gap: target.context.gap,
                                               padding: target.context.padding)
            hit = TiledDropPlanner.otherMonitorTarget(pointer: pointer, slots: slots)
            hyprLog(.notice, .tiling, "tiled drag across monitors targets: dragged=\(dragged.windowID) "
                    + "point=cg(\(Self.traced(pointer.x)),\(Self.traced(pointer.y))) "
                    + "tiles=[\(TiledDragTargetResolver.trace(pointer: pointer, slots: slots))] "
                    + "chosen=\(hit.map { "\($0.windowID) \($0.edge)" } ?? "none")")
            guard hit != nil else {
                return restore(snapshot, reason: .preflight(.noTarget), attempt: attempt)
            }
        }
        let built: CrossCandidates
        switch crossCandidates(snapshot, into: target, hit: hit, swap: swapRequested) {
        case let .success(value): built = value
        case let .failure(rejection):
            hyprLog(.notice, .tiling, "tiled drag across monitors: dragged=\(dragged.windowID) "
                    + "ws\(snapshot.context.workspace) → ws\(target.context.workspace) "
                    + "refused: \(rejection)")
            return restore(snapshot, reason: .preflight(rejection), attempt: attempt)
        }
        hyprLog(.notice, .tiling, "tiled drag across monitors: dragged=\(dragged.windowID) "
                + "ws\(snapshot.context.workspace) → ws\(target.context.workspace) "
                + "placement=\(built.placement)")
        let sourceCandidate = built.source
        let targetCandidate = built.target
        let moves = built.moves
        let sourceLayouts: [(HyprWindow, CGRect)]
        let targetLayouts: [(HyprWindow, CGRect)]
        switch crossLayouts(built, snapshot: snapshot, target: target, attempt: attempt) {
        case let .fitted(source, arriving):
            sourceLayouts = source
            targetLayouts = arriving
        case let .noRoom(window, slot):
            hyprLog(.notice, .tiling, "tiled drag across monitors: no room for \(window.windowID) "
                    + "min=\(minimumSize(window)) slot=\(slot.size)")
            return restore(snapshot, reason: .preflight(.noRoom), attempt: attempt)
        case .invalid:
            return restore(snapshot, reason: .preflight(.invalidTarget), attempt: attempt)
        }
        guard isCurrent() else { return .superseded }

        // where each window stands before the writes: its original, and the
        // dragged one wherever the drag left it
        var standing = snapshot.originalFrames.merging(targetOriginals) { first, _ in first }
        standing[dragged.windowID] = releaseFrame
        var progress: FrameSizingAttempt.Progress?
        var frames: [CGWindowID: CGRect] = [:]
        var failure: FrameSizingFailure?
        for (layouts, context) in [(targetLayouts, target.context), (sourceLayouts, snapshot.context)] {
            var screenAttempt = attempt
            screenAttempt.configuration.positionSettleWindowIDs =
                positionFirst(standing, layouts, context.usableFrame)
            let result = sizing(screenAttempt)
                .candidate(targets: layouts.map { .init(windowID: $0.0.windowID, frame: $0.1) },
                           usableFrame: context.usableFrame, gap: context.gap,
                           generation: snapshot.generation)
            progress = progress.map { Self.merged($0, result.progress) } ?? result.progress
            frames.merge(result.actualFrames) { _, read in read }
            failure = Self.failure(of: result.verdict)
            if failure != nil { break }
        }
        let candidateProgress = progress ?? FrameSizingAttempt.Progress()
        // accepted frames the setters did not all confirm cannot publish. the
        // dragged window may already stand on the release screen, so put both
        // trees back rather than leave membership claiming the source
        if failure == nil, let unverified = Self.unverifiedCommit(candidateProgress) {
            hyprLog(.notice, .tiling, "tiled drag across monitors accepted but not fully written: "
                    + "\(unverified.trace) — restoring both trees")
            guard isCurrent() else { return .superseded }
            return restoreBoth(.sizing(unverified), candidate: candidateProgress)
        }
        guard let reason = failure else {
            guard isCurrent() else { return .superseded }
            return .acrossTrees(
                .committed(candidate: sourceCandidate, actualFrames: frames,
                           progress: FrameSizingProgressReport(candidate: candidateProgress)),
                TiledDragCrossTree(target: target.context, targetCandidate: targetCandidate,
                                   moves: moves))
        }
        // a newer operation owns the geometry now; write nothing over it
        if reason == .superseded { return .superseded }
        guard isCurrent() else {
            return .acrossTrees(.degraded(candidateReason: .sizing(reason), restorationReason: nil,
                                          actualFrames: frames,
                                          progress: FrameSizingProgressReport(candidate: candidateProgress)),
                                untouched)
        }
        return restoreBoth(.sizing(reason), candidate: candidateProgress)
    }

    /// The source tree after a same-tree `mode`, within Max Splits, or why
    /// the drop refuses it. The drop and its preview both build it here.
    private func sameTreeCandidate(_ snapshot: TiledDragSnapshot,
                                   mode: TiledDragMode) -> Result<BSPTree, TiledDragRejection> {
        let targetID: CGWindowID?
        switch mode {
        case let .insert(id, _), let .swap(id): targetID = id
        case .resize, .crossMonitor: targetID = nil
        }
        guard targetID.map({ $0 != snapshot.draggedID
            && snapshot.context.memberIDs.contains($0) }) ?? true else {
            return .failure(.invalidTarget)
        }

        let candidate: BSPTree?
        switch mode {
        case let .insert(targetID, edge):
            candidate = snapshot.originalTree.candidateTree(
                draggedID: snapshot.draggedID, targetID: targetID,
                edge: edge, maxDepth: snapshot.context.maxDepth)
        case let .swap(targetID):
            let clone = snapshot.originalTree.deepClone()
            guard let dragged = clone.allWindows.first(where: { $0.windowID == snapshot.draggedID }),
                  let target = clone.allWindows.first(where: { $0.windowID == targetID }) else {
                return .failure(.invalidTarget)
            }
            clone.swap(dragged, target)
            candidate = clone
        case let .resize(frame):
            let clone = snapshot.originalTree.deepClone()
            guard let dragged = clone.allWindows.first(where: {
                $0.windowID == snapshot.draggedID
            }) else {
                return .failure(.invalidTarget)
            }
            clone.applyResizeDelta(for: dragged, newFrame: frame,
                                   in: snapshot.context.usableFrame,
                                   gap: snapshot.context.gap,
                                   padding: snapshot.context.padding)
            candidate = clone
        case .crossMonitor:
            // another screen's tree is the engine's to resolve
            return .failure(.noTarget)
        }
        guard let candidate else { return .failure(.maxDepthExceeded) }
        guard candidate.root.allLeavesRightToLeft().allSatisfy({
            $0.depth <= snapshot.context.maxDepth
        }) else {
            return .failure(.maxDepthExceeded)
        }
        return .success(candidate)
    }

    /// Where the dragged window lands for `plan`, from the same candidates
    /// and layouts the drop builds, without a single AX call. nil when the
    /// drop would restore. `target` is the release screen's side for an
    /// `.otherMonitor` plan.
    func previewFrame(_ snapshot: TiledDragSnapshot, plan: TiledDropPlan, swap: Bool,
                      target: TiledDragCrossTarget?) -> CGRect? {
        // frame checks only; nothing here reads or writes a window
        let attempt = FrameSizingAttempt(io: ioFactory([:]) { snapshot.generation })
        let layouts: [(HyprWindow, CGRect)]
        switch plan {
        case .none:
            return nil
        case let .sameTree(hit):
            let mode: TiledDragMode = swap
                ? .swap(targetID: hit.windowID) : .insert(targetID: hit.windowID, edge: hit.edge)
            guard case let .success(candidate) = sameTreeCandidate(snapshot, mode: mode) else {
                return nil
            }
            layouts = adjustedLayouts(candidate, context: snapshot.context)
            guard valid(layouts, context: snapshot.context, attempt: attempt) else { return nil }
        case let .otherMonitor(hit):
            guard let target,
                  case let .success(built) = crossCandidates(snapshot, into: target, hit: hit,
                                                             swap: swap),
                  case let .fitted(_, arriving) = crossLayouts(built, snapshot: snapshot,
                                                               target: target,
                                                               attempt: attempt) else { return nil }
            layouts = arriving
        }
        return layouts.first { $0.0.windowID == snapshot.draggedID }?.1
    }

    private struct CrossCandidates {
        let source: BSPTree
        let target: BSPTree
        let moves: [CGWindowID: Int]
        let placement: String
    }

    /// Both trees after a drop onto another monitor's tree, within each
    /// screen's Max Splits and with every member accounted for, or why the
    /// drop refuses them. A nil `hit` is an empty tree taking its root. The
    /// drop and its preview both build them here.
    private func crossCandidates(_ snapshot: TiledDragSnapshot, into target: TiledDragCrossTarget,
                                 hit: TiledDragTarget?,
                                 swap: Bool) -> Result<CrossCandidates, TiledDragRejection> {
        guard let dragged = snapshot.sourceTree.allWindows.first(where: {
            $0.windowID == snapshot.draggedID
        }) else { return .failure(.invalidTarget) }
        var moves: [CGWindowID: Int] = [dragged.windowID: target.context.workspace]
        let sourceCandidate: BSPTree?
        let targetCandidate: BSPTree?
        // why a nil target candidate is refused
        var refusal = TiledDragRejection.invalidTarget
        let placement: String
        if let hit {
            if swap {
                guard let swapped = target.tree.allWindows.first(where: {
                    $0.windowID == hit.windowID
                }) else { return .failure(.invalidTarget) }
                sourceCandidate = snapshot.originalTree.candidateTree(replacing: dragged.windowID,
                                                                      with: swapped)
                targetCandidate = target.tree.candidateTree(replacing: swapped.windowID, with: dragged)
                moves[swapped.windowID] = snapshot.context.workspace
                placement = "swap with \(swapped.windowID)"
            } else {
                sourceCandidate = snapshot.originalTree.candidateTree(removing: dragged.windowID)
                targetCandidate = target.tree.candidateTree(inserting: dragged, beside: hit.windowID,
                                                            edge: hit.edge,
                                                            maxDepth: target.context.maxDepth)
                refusal = .maxDepthExceeded
                placement = "\(hit.edge) of \(hit.windowID)"
            }
        } else {
            sourceCandidate = snapshot.originalTree.candidateTree(removing: dragged.windowID)
            targetCandidate = target.tree.candidateTree(rootedAt: dragged)
            placement = "root"
        }
        guard let sourceCandidate else { return .failure(.invalidTarget) }
        guard let targetCandidate else { return .failure(refusal) }
        // max splits holds for both screens, including a limit lowered
        // under an existing tree
        guard sourceCandidate.root.allLeavesRightToLeft().allSatisfy({
            $0.depth <= snapshot.context.maxDepth
        }), targetCandidate.root.allLeavesRightToLeft().allSatisfy({
            $0.depth <= target.context.maxDepth
        }) else {
            return .failure(.maxDepthExceeded)
        }
        let staying = Set(sourceCandidate.allWindows.map(\.windowID))
        let arriving = Set(targetCandidate.allWindows.map(\.windowID))
        guard staying.isDisjoint(with: arriving),
              staying.union(arriving) == snapshot.context.memberIDs.union(target.context.memberIDs),
              arriving.contains(dragged.windowID) else {
            return .failure(.invalidTarget)
        }
        return .success(CrossCandidates(source: sourceCandidate, target: targetCandidate,
                                        moves: moves, placement: placement))
    }

    private enum CrossLayouts {
        case fitted(source: [(HyprWindow, CGRect)], target: [(HyprWindow, CGRect)])
        /// a known minimum still overflows this slot after ratio adjustment
        case noRoom(HyprWindow, CGRect)
        case invalid
    }

    /// Both screens' layouts for `built`, with the same known-minimum ratio
    /// adjustment as any drop.
    private func crossLayouts(_ built: CrossCandidates, snapshot: TiledDragSnapshot,
                              target: TiledDragCrossTarget,
                              attempt: FrameSizingAttempt) -> CrossLayouts {
        let sourceLayouts = adjustedLayouts(built.source, context: snapshot.context)
        let targetLayouts = adjustedLayouts(built.target, context: target.context)
        if let crowded = (sourceLayouts + targetLayouts).first(where: { window, frame in
            let minimum = minimumSize(window)
            return minimum.width > frame.width + TilingConfig.frameToleranceXPx
                || minimum.height > frame.height + TilingConfig.frameToleranceXPx
        }) {
            return .noRoom(crowded.0, crowded.1)
        }
        guard valid(sourceLayouts, memberIDs: Set(built.source.allWindows.map(\.windowID)),
                    usableFrame: snapshot.context.usableFrame, gap: snapshot.context.gap,
                    attempt: attempt),
              valid(targetLayouts, memberIDs: Set(built.target.allWindows.map(\.windowID)),
                    usableFrame: target.context.usableFrame, gap: target.context.gap,
                    attempt: attempt) else { return .invalid }
        return .fitted(source: sourceLayouts, target: targetLayouts)
    }

    private func isCurrent(_ snapshot: TiledDragSnapshot,
                           currentContext: () -> TiledDragContext?) -> Bool {
        currentContext() == snapshot.context
            && snapshot.sourceTree.structuralFingerprint() == snapshot.context.fingerprint
    }

    private func restore(_ snapshot: TiledDragSnapshot, reason: TiledDragFailure,
                         attempt: FrameSizingAttempt) -> TiledDragDropOutcome {
        let result = sizing(attempt).restore(
            originalFrames: snapshot.originalFrames,
            usableFrame: snapshot.context.restorationFrame ?? snapshot.context.usableFrame,
            gap: snapshot.context.gap,
            generation: snapshot.generation
        )
        switch result.verdict {
        case .accepted:
            return .rejectedRestored(reason: reason, actualFrames: result.actualFrames)
        case let .rejected(failure), let .unknown(failure):
            if failure == .superseded { return .superseded }
            // nothing ran a candidate here, so the only writes on record
            // are the rollback's own
            return .degraded(candidateReason: reason,
                             restorationReason: failure,
                             actualFrames: result.actualFrames,
                             progress: FrameSizingProgressReport(
                                restoration: result.progress,
                                restorationOverlaps: result.overlaps))
        }
    }

    /// Both trees back where they were: the source's originals, the dragged
    /// window's among them, then the release screen's. Each is verified
    /// against its own screen. Superseded work writes nothing more.
    private func restoreAcross(_ snapshot: TiledDragSnapshot, target: TiledDragCrossTarget,
                               targetOriginals: [CGWindowID: CGRect], reason: TiledDragFailure,
                               attempt: FrameSizingAttempt,
                               candidate: FrameSizingAttempt.Progress?,
                               cross: TiledDragCrossTree) -> TiledDragDropOutcome {
        let restorer = sizing(attempt)
        let source = restorer.restore(originalFrames: snapshot.originalFrames,
                                      usableFrame: snapshot.context.restorationFrame
                                          ?? snapshot.context.usableFrame,
                                      gap: snapshot.context.gap,
                                      generation: snapshot.generation)
        if Self.failure(of: source.verdict) == .superseded { return .superseded }
        let arriving = restorer.restore(originalFrames: targetOriginals,
                                        usableFrame: target.context.restorationFrame
                                            ?? target.context.usableFrame,
                                        gap: target.context.gap,
                                        generation: snapshot.generation)
        if Self.failure(of: arriving.verdict) == .superseded { return .superseded }
        let frames = source.actualFrames.merging(arriving.actualFrames) { first, _ in first }
        guard let failure = Self.failure(of: source.verdict) ?? Self.failure(of: arriving.verdict) else {
            return .acrossTrees(.rejectedRestored(reason: reason, actualFrames: frames), cross)
        }
        return .acrossTrees(.degraded(
            candidateReason: reason, restorationReason: failure, actualFrames: frames,
            progress: FrameSizingProgressReport(
                candidate: candidate ?? FrameSizingAttempt.Progress(),
                restoration: Self.merged(source.progress, arriving.progress),
                restorationOverlaps: source.overlaps + arriving.overlaps)), cross)
    }

    /// `tree`'s layout in `context`, with split ratios moved for any known
    /// minimum that would not fit its slot. Adjusts the candidate in place.
    private func adjustedLayouts(_ tree: BSPTree,
                                 context: TiledDragContext) -> [(HyprWindow, CGRect)] {
        var layouts = tree.layout(in: context.usableFrame, gap: context.gap,
                                  padding: context.padding)
        let knownConflicts = layouts.compactMap { window, frame -> (HyprWindow, CGSize)? in
            let minimum = minimumSize(window)
            guard minimum.width > frame.width + TilingConfig.minSizeConflictSlackPx
                    || minimum.height > frame.height + TilingConfig.minSizeConflictSlackPx else {
                return nil
            }
            return (window, minimum)
        }
        if !knownConflicts.isEmpty {
            tree.adjustForMinSizes(knownConflicts, in: context.usableFrame,
                                   gap: context.gap, padding: context.padding)
            layouts = tree.layout(in: context.usableFrame, gap: context.gap,
                                  padding: context.padding)
        }
        return layouts
    }

    private func valid(_ layouts: [(HyprWindow, CGRect)], context: TiledDragContext,
                       attempt: FrameSizingAttempt) -> Bool {
        valid(layouts, memberIDs: context.memberIDs, usableFrame: context.usableFrame,
              gap: context.gap, attempt: attempt)
    }

    private func valid(_ layouts: [(HyprWindow, CGRect)], memberIDs: Set<CGWindowID>,
                       usableFrame: CGRect, gap: CGFloat,
                       attempt: FrameSizingAttempt) -> Bool {
        guard layouts.count == memberIDs.count,
              Set(layouts.map { $0.0.windowID }) == memberIDs else { return false }
        for (_, frame) in layouts {
            guard frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.size.width.isFinite, frame.size.height.isFinite,
                  frame.size.width > 0, frame.size.height > 0 else { return false }
        }
        let targets = layouts.map {
            FrameSizingAttempt.Target(windowID: $0.0.windowID, frame: $0.1)
        }
        let frames = Dictionary(uniqueKeysWithValues: layouts.map { ($0.0.windowID, $0.1) })
        return attempt.validateFrames(targets: targets, actualFrames: frames,
                                      usableFrame: usableFrame,
                                      gap: gap).verdict == .accepted
    }

    private static func traced(_ value: CGFloat) -> String {
        String(format: "%g", Double(value))
    }

    private static func traced(_ rect: CGRect) -> String {
        "(\(traced(rect.minX)),\(traced(rect.minY)),\(traced(rect.width)),\(traced(rect.height)))"
    }

    /// Why accepted frames may not publish: a target whose setters did not
    /// all return success, or a readback that was not complete and stable.
    /// nil when the progress can publish. `FrameSizingAttempt` does not
    /// accept either today; this holds the drop to the same gate the trees use.
    static func unverifiedCommit(_ progress: FrameSizingAttempt.Progress) -> FrameSizingFailure? {
        guard !FrameSizingProgressReport(candidate: progress).candidateVerified else { return nil }
        if let unwritten = progress.targetIDs.first(where: { !progress.writesCompleted.contains($0) }) {
            return .writeFailed(unwritten, .failure)
        }
        return .attemptsExhausted
    }

    private static func failure(of verdict: FrameSizingAttempt.Verdict) -> FrameSizingFailure? {
        switch verdict {
        case .accepted: return nil
        case let .rejected(reason), let .unknown(reason): return reason
        }
    }

    /// Two screens' attempts read as one: every target, every write, and a
    /// readback that is complete and stable only if both were.
    private static func merged(_ first: FrameSizingAttempt.Progress,
                               _ second: FrameSizingAttempt.Progress) -> FrameSizingAttempt.Progress {
        var both = first
        both.targetIDs += second.targetIDs
        both.possiblyWritten.formUnion(second.possiblyWritten)
        both.writesCompleted.formUnion(second.writesCompleted)
        both.timeoutShapedCannotComplete = first.timeoutShapedCannotComplete
            || second.timeoutShapedCannotComplete
        both.readbackComplete = first.readbackComplete && second.readbackComplete
        both.readbackStable = first.readbackStable && second.readbackStable
        return both
    }
}
