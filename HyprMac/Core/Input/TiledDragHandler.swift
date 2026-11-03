// Coordinates verified tiled-drag capture, deferred release, cache updates,
// and completion reporting.

import Cocoa

struct MouseDragLifecycleState {
    var buttonDown = false
    var sawDragEvent = false
    var preDragFocusedID: CGWindowID = 0
    var swapRequested = false

    mutating func beginPress(hyprHeld: Bool) {
        buttonDown = true
        sawDragEvent = false
        swapRequested = hyprHeld
    }

    mutating func observeDrag(hyprHeld: Bool) {
        sawDragEvent = true
        swapRequested = swapRequested || hyprHeld
    }

    mutating func noteHyprKeyDown() {
        guard buttonDown else { return }
        swapRequested = true
    }

    func releaseRequestsSwap(hyprHeld: Bool) -> Bool {
        swapRequested || hyprHeld
    }

    mutating func finishPress() {
        buttonDown = false
        sawDragEvent = false
        swapRequested = false
    }

    mutating func resetForStop() {
        finishPress()
        preDragFocusedID = 0
    }
}

struct TiledDragRelease: Equatable {
    let pointer: CGPoint
    let swapRequested: Bool
    let sawDragEvent: Bool

    init(pointer: CGPoint, swapRequested: Bool, sawDragEvent: Bool) {
        self.pointer = pointer
        self.swapRequested = swapRequested
        self.sawDragEvent = sawDragEvent
    }
}

struct TiledDragPressResolver {
    static func resolve(pointer: CGPoint,
                        tiledFrames: [CGWindowID: CGRect],
                        occluderFrames: [CGWindowID: CGRect]) -> CGWindowID? {
        func contains(_ frame: CGRect) -> Bool {
            pointer.x >= frame.minX && pointer.x <= frame.maxX
                && pointer.y >= frame.minY && pointer.y <= frame.maxY
        }
        guard !occluderFrames.values.contains(where: contains) else { return nil }
        let matches = tiledFrames.compactMap { id, frame in contains(frame) ? id : nil }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Which workspace a tiled drag released on another monitor lands in: the
/// one visible there. A disabled monitor tiles nothing, and while the
/// scratchpad layer is up its scrim covers every other monitor's tiles, so
/// both refuse and the drop restores.
enum TiledDragReleasePolicy: Equatable {
    case workspace(Int)
    case refused(String)

    static func resolve(monitorDisabled: Bool, scratchpadVisible: Bool,
                        visibleWorkspace: () -> Int) -> TiledDragReleasePolicy {
        if monitorDisabled { return .refused("monitor disabled") }
        if scratchpadVisible { return .refused("scratchpad visible") }
        return .workspace(visibleWorkspace())
    }
}

/// What a finished drag says about each member's cached geometry.
///
/// One decision per window, shared by every cache that holds drag
/// geometry, so `tiledPositions` and `cachedFrame` cannot disagree.
enum TiledDragCacheAction: Equatable {
    /// a verified current readback — take this frame
    case refresh(CGRect)
    /// possibly written, or the dragged window after a native drag, and
    /// nothing verified where it ended up
    case invalidate
    /// provably untouched and still current
    case preserve
}

struct TiledDragCachePolicy {
    /// - Parameters:
    ///   - draggedID: always uncertain after a native drag. macOS moved it,
    ///     not us, so an unverified outcome says nothing about where it is.
    ///   - affectedIDs: the drag's members.
    static func actions(for outcome: TiledDragDropOutcome,
                        draggedID: CGWindowID,
                        affectedIDs: Set<CGWindowID>) -> [CGWindowID: TiledDragCacheAction] {
        var actions: [CGWindowID: TiledDragCacheAction] = [:]
        switch outcome {
        case let .committed(_, actualFrames, _), let .rejectedRestored(_, actualFrames):
            // both verdicts are verified: the candidate landed, or every
            // original was written back and read back within a point
            for id in affectedIDs {
                actions[id] = actualFrames[id].map { .refresh($0) } ?? .invalidate
            }
        case let .degraded(_, _, _, progress):
            guard let progress else {
                // no provenance, so nothing is provably untouched
                for id in affectedIDs { actions[id] = .invalidate }
                return actions
            }
            // a restoration writes every captured original, including
            // windows the candidate never reached, so clearing only the
            // dragged id would leave the rest of the members lying
            let written = progress.possiblyWritten
            for id in affectedIDs {
                actions[id] = (written.contains(id) || id == draggedID) ? .invalidate : .preserve
            }
        case let .acrossTrees(result, cross):
            // the release screen's tree was captured and possibly written
            // too, so its members take the same decision
            return self.actions(for: result, draggedID: draggedID,
                                affectedIDs: affectedIDs.union(cross.target.memberIDs))
        case .superseded, .ignored:
            break
        }
        return actions
    }
}

struct TiledDragCacheUpdate {
    static func applying(_ outcome: TiledDragDropOutcome,
                         draggedID: CGWindowID,
                         affectedIDs: Set<CGWindowID>,
                         to existing: [CGWindowID: CGRect]) -> [CGWindowID: CGRect] {
        var updated = existing
        for (id, action) in TiledDragCachePolicy.actions(for: outcome, draggedID: draggedID,
                                                         affectedIDs: affectedIDs) {
            switch action {
            case let .refresh(frame): updated[id] = frame
            case .invalidate: updated.removeValue(forKey: id)
            case .preserve: break
            }
        }
        return updated
    }
}

struct TiledDragCompletion {
    let snapshot: TiledDragSnapshot
    let outcome: TiledDragDropOutcome
}

enum TiledDragFeedback: Equatable {
    case rejected
    case degraded
}

struct TiledDragFeedbackPolicy {
    static func feedback(for outcome: TiledDragDropOutcome) -> TiledDragFeedback? {
        switch outcome {
        case let .rejectedRestored(reason, _):
            // a release with nowhere to land, on the window's own slot or in
            // a gap, is not a rejected arrangement: the window goes back and
            // nothing was wrong. every other refusal still beeps
            if case .preflight(.noTarget) = reason { return nil }
            return .rejected
        case .degraded:
            return .degraded
        case let .acrossTrees(result, _):
            return feedback(for: result)
        case .committed, .ignored, .superseded:
            return nil
        }
    }
}

final class TiledDragSessionCoordinator {
    typealias Capture = (CGPoint) -> TiledDragCaptureResult
    typealias Apply = (TiledDragSnapshot, TiledDragMode?) -> TiledDragDropOutcome
    typealias ResolveTarget = (CGPoint, TiledDragSnapshot) -> TiledDragTarget?
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    typealias Report = (TiledDragCompletion) -> Void
    typealias CaptureFailureReport = (TiledDragCaptureResult) -> Void
    /// whether a release with no same-tree target landed on another monitor
    typealias IsCrossMonitor = (CGPoint, TiledDragSnapshot) -> Bool

    private(set) var isFinishingDrag = false
    /// the tiled press being dragged, for the live drop preview. nil once
    /// the release is finishing
    var pressSnapshot: TiledDragSnapshot? { isFinishingDrag ? nil : snapshot }
    private let capture: Capture
    private let apply: Apply
    private let resolveTarget: ResolveTarget
    private let schedule: Schedule
    private let report: Report
    private let captureFailureReport: CaptureFailureReport
    private let isCrossMonitor: IsCrossMonitor
    private var pressEpoch: UInt64 = 0
    private var snapshot: TiledDragSnapshot?
    private var captureFailure: TiledDragCaptureResult?

    init(capture: @escaping Capture,
         apply: @escaping Apply,
         resolveTarget: @escaping ResolveTarget,
         schedule: @escaping Schedule,
         report: @escaping Report,
         captureFailureReport: @escaping CaptureFailureReport = { _ in },
         isCrossMonitor: @escaping IsCrossMonitor = { _, _ in false }) {
        self.capture = capture
        self.apply = apply
        self.resolveTarget = resolveTarget
        self.schedule = schedule
        self.report = report
        self.captureFailureReport = captureFailureReport
        self.isCrossMonitor = isCrossMonitor
    }

    func mouseDown(at pointer: CGPoint) {
        pressEpoch &+= 1
        let epoch = pressEpoch
        isFinishingDrag = false
        snapshot = nil
        captureFailure = nil
        let result = capture(pointer)
        guard pressEpoch == epoch else { return }
        if case let .captured(captured) = result {
            snapshot = captured
            captureFailure = nil
        } else {
            snapshot = nil
            if case .unknown = result {
                captureFailure = result
            } else {
                captureFailure = nil
            }
        }
    }

    func mouseUp(_ release: TiledDragRelease) {
        guard release.sawDragEvent else {
            pressEpoch &+= 1
            self.snapshot = nil
            captureFailure = nil
            isFinishingDrag = false
            return
        }
        guard let snapshot else {
            pressEpoch &+= 1
            let epoch = pressEpoch
            if let captureFailure { captureFailureReport(captureFailure) }
            guard pressEpoch == epoch else { return }
            self.captureFailure = nil
            isFinishingDrag = false
            return
        }
        let epoch = pressEpoch
        isFinishingDrag = true
        schedule(0.1) { [weak self] in
            guard let self, self.pressEpoch == epoch else { return }
            let mode: TiledDragMode?
            if let target = self.resolveTarget(release.pointer, snapshot) {
                mode = release.swapRequested
                    ? .swap(targetID: target.windowID)
                    : .insert(targetID: target.windowID, edge: target.edge)
            } else if self.isCrossMonitor(release.pointer, snapshot) {
                mode = .crossMonitor(pointer: release.pointer,
                                     swapRequested: release.swapRequested)
            } else {
                mode = nil
            }
            // no mode is every plain click, so it stays in the trace tier
            hyprLog(mode == nil ? .debug : .notice, .tiling, "tiled drag mode: dragged=\(snapshot.draggedID) "
                    + "swap=\(release.swapRequested) mode=\(Self.describe(mode))")
            let outcome = self.apply(snapshot, mode)
            guard self.pressEpoch == epoch else { return }
            self.report(TiledDragCompletion(snapshot: snapshot, outcome: outcome))
            guard self.pressEpoch == epoch else { return }
            self.snapshot = nil
            self.captureFailure = nil
            self.isFinishingDrag = false
        }
    }

    func cancel() {
        pressEpoch &+= 1
        snapshot = nil
        captureFailure = nil
        isFinishingDrag = false
    }

    private static func describe(_ mode: TiledDragMode?) -> String {
        switch mode {
        case let .insert(targetID, edge)?: return "insert(\(targetID) \(edge))"
        case let .swap(targetID)?: return "swap(\(targetID))"
        case .resize?: return "resize"
        case .crossMonitor?: return "crossMonitor"
        case nil: return "none (no source tile under the point, and not on another monitor)"
        }
    }
}

final class TiledDragHandler {
    typealias Capture = (CGPoint, @escaping ([CGWindowID: CGRect]) -> Void) -> TiledDragCaptureResult
    typealias CacheRead = () -> [CGWindowID: CGRect]
    typealias CacheWrite = ([CGWindowID: CGRect]) -> Void
    typealias Completion = (TiledDragCompletion) -> Void

    private let coordinator: TiledDragSessionCoordinator
    var isFinishingDrag: Bool { coordinator.isFinishingDrag }
    var pressSnapshot: TiledDragSnapshot? { coordinator.pressSnapshot }

    init(capture: @escaping Capture,
         drop: @escaping TiledDragSessionCoordinator.Apply,
         resolveTarget: @escaping TiledDragSessionCoordinator.ResolveTarget,
         schedule: @escaping TiledDragSessionCoordinator.Schedule,
         capturedFrames: @escaping ([CGWindowID: CGRect]) -> Void,
         readCache: @escaping CacheRead,
         writeCache: @escaping CacheWrite,
         completion: @escaping Completion,
         captureFailure: @escaping TiledDragSessionCoordinator.CaptureFailureReport,
         isCrossMonitor: @escaping TiledDragSessionCoordinator.IsCrossMonitor = { _, _ in false }) {
        coordinator = TiledDragSessionCoordinator(
            capture: { point in capture(point, capturedFrames) },
            apply: drop,
            resolveTarget: resolveTarget,
            schedule: schedule,
            report: { result in
                if case .ignored = result.outcome { return }
                if case .superseded = result.outcome {
                    completion(result)
                    return
                }
                // a drop across monitors adds the release screen's members
                // inside the policy
                let updated = TiledDragCacheUpdate.applying(
                    result.outcome,
                    draggedID: result.snapshot.draggedID,
                    affectedIDs: result.snapshot.context.memberIDs,
                    to: readCache()
                )
                writeCache(updated)
                completion(result)
            },
            captureFailureReport: captureFailure,
            isCrossMonitor: isCrossMonitor
        )
    }

    func handleMouseDown(at pointer: CGPoint) {
        coordinator.mouseDown(at: pointer)
    }

    func handleMouseUp(_ release: TiledDragRelease) {
        coordinator.mouseUp(release)
    }

    func cancel() {
        coordinator.cancel()
    }
}
