// Everything between a tiled press and its settled result that is not the
// drag's own state machine: capture and drop wiring, the live drop preview, and
// the bookkeeping a finished drop owes. `TiledDragHandler` runs the state machine.

import Cocoa

final class TiledDragController {
    private let config: UserConfig
    private let displayManager: DisplayManager
    private let tilingEngine: TilingEngine
    private let workspaceManager: WorkspaceManager
    private let stateCache: WindowStateCache
    private let minimaRevalidation: MinimaRevalidation
    private let scratchpad: ScratchpadController
    private let focusController: FocusStateController
    private let focusBorder: FocusBorder
    private let focusBrackets: FocusBrackets
    private let tiledDragFeedback: TiledDragFeedbackCoordinator

    // verified tiled drag capture and completion.
    private var tiledDragHandler: TiledDragHandler!

    // live highlight of where a tiled drag will land. the frames come from
    // the press capture and the trees, never from AX while the pointer moves
    private let dropPreviewPanel = TiledDropPreviewPanel()
    private lazy var dropPreview = TiledDragPreviewSession(presenter: .init(
        show: { [weak self] rect in self?.dropPreviewPanel.show(rect) },
        hide: { [weak self] in self?.dropPreviewPanel.hide() }))
    // per drag: each other display's tree as a drop there would find it,
    // kept while its workspace and tree stay what they were
    private var dropPreviewTargets: [CGDirectDisplayID: (workspace: Int, target: TiledDragCrossTarget)] = [:]

    // WindowManager-side helpers
    var isManagerRunning: () -> Bool = { false }
    /// the current press, global CG. written before the handler hears of it
    var pressPoint: () -> CGPoint? = { nil }
    var releaseRequestsSwap: () -> Bool = { false }
    var visibleFloatingWindows: () -> [HyprWindow] = { [] }
    var acceptTiledDragCapture: ([CGWindowID: CGRect]) -> Void = { _ in }
    var isFullscreenSuppressed: (HyprWindow) -> Bool = { _ in false }
    var refreshDimming: (_ tiledRects: [CGWindowID: CGRect]) -> Void = { _ in }
    var schedulePoll: () -> Void = {}

    private var isRunning: Bool { isManagerRunning() }

    init(config: UserConfig,
         displayManager: DisplayManager,
         tilingEngine: TilingEngine,
         workspaceManager: WorkspaceManager,
         stateCache: WindowStateCache,
         minimaRevalidation: MinimaRevalidation,
         scratchpad: ScratchpadController,
         focusController: FocusStateController,
         focusBorder: FocusBorder,
         focusBrackets: FocusBrackets,
         feedback: TiledDragFeedbackCoordinator) {
        self.config = config
        self.displayManager = displayManager
        self.tilingEngine = tilingEngine
        self.workspaceManager = workspaceManager
        self.stateCache = stateCache
        self.minimaRevalidation = minimaRevalidation
        self.scratchpad = scratchpad
        self.focusController = focusController
        self.focusBorder = focusBorder
        self.focusBrackets = focusBrackets
        self.tiledDragFeedback = feedback
        self.tiledDragHandler = makeTiledDragHandler()
    }

    var isFinishingDrag: Bool { tiledDragHandler.isFinishingDrag }

    func handleMouseDown(at point: CGPoint) { tiledDragHandler.handleMouseDown(at: point) }
    func handleMouseUp(_ release: TiledDragRelease) { tiledDragHandler.handleMouseUp(release) }
    func cancel() { tiledDragHandler.cancel() }

    /// A drop changes with the workspace under it and the Hypr key, even
    /// with the pointer standing still.
    func refreshPreview() { dropPreview.refresh() }

    /// Hide the drop preview and forget the drag's release trees.
    func endTiledDropPreview() {
        dropPreview.end()
        dropPreviewTargets = [:]
    }

    private func makeTiledDragHandler() -> TiledDragHandler {
        TiledDragHandler(
            capture: { [weak self] point, publish in
                guard let self, self.isRunning,
                      let screen = self.exactScreen(containing: point) else {
                    return .ineligible(.noTarget)
                }
                let displayID = Self.tiledDragDisplayID(screen)
                return self.tilingEngine.captureTiledDrag(
                    pointer: point,
                    occludingWindows: self.visibleFloatingWindows(),
                    currentLocation: { [weak self] in
                        guard let self, self.isRunning else { return nil }
                        let matches = self.displayManager.screens.filter {
                            Self.tiledDragDisplayID($0) == displayID
                        }
                        guard matches.count == 1, let screen = matches.first,
                              let workspace = self.tiledDragWorkspace(on: screen) else { return nil }
                        return (workspace, screen, self.stateCache.floatingWindowIDs)
                    },
                    onCapturedFrames: publish)
            },
            drop: { [weak self] snapshot, mode in
                guard let self, self.isRunning else { return .superseded }
                var releaseLocation: () -> (workspace: Int, screen: NSScreen,
                                            floatingIDs: Set<CGWindowID>)? = { nil }
                if case let .crossMonitor(pointer, _) = mode {
                    releaseLocation = self.tiledDragReleaseLocation(pointer, leaving: snapshot)
                }
                let outcome = self.tilingEngine.dropTiledDrag(
                    snapshot,
                    mode: mode,
                    currentLocation: { [weak self] in self?.tiledDragLocation(for: snapshot) },
                    releaseLocation: releaseLocation)
                // membership moves in the same step the engine published both
                // trees, so nothing between here and the report can split them
                if case let .acrossTrees(.committed, cross) = outcome {
                    for (id, workspace) in cross.moves.sorted(by: { $0.key < $1.key }) {
                        self.workspaceManager.moveWindow(id, toWorkspace: workspace)
                        self.minimaRevalidation.cancel(id, reason: "tiled drag across monitors")
                    }
                }
                return outcome
            },
            resolveTarget: { [weak self] pointer, snapshot in
                let onSourceTiles = snapshot.context.usableFrame.contains(pointer)
                // the planner the live preview uses, on the same press capture
                let target = TiledDropPlanner.sameTreeTarget(
                    pointer: pointer, draggedID: snapshot.draggedID,
                    sourceTiles: snapshot.context.usableFrame, sourceSlots: snapshot.originalFrames)
                self?.noteTiledDragRelease(pointer, snapshot: snapshot,
                                           onSourceTiles: onSourceTiles, target: target)
                return target
            },
            schedule: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            },
            capturedFrames: { [weak self] frames in self?.acceptTiledDragCapture(frames) },
            readCache: { [weak self] in self?.stateCache.tiledPositions ?? [:] },
            writeCache: { [weak self] frames in self?.stateCache.tiledPositions = frames },
            completion: { [weak self] completion in self?.completeTiledDrag(completion) },
            captureFailure: { [weak self] result in self?.reportTiledDragCaptureFailure(result) },
            isCrossMonitor: { [weak self] pointer, snapshot in
                guard let self, let screen = self.exactFullScreen(containing: pointer) else {
                    return false
                }
                return Self.tiledDragDisplayID(screen) != snapshot.context.physicalDisplayID
            })
    }

    /// Start or move the live drop preview. Only a press the tiled capture
    /// took gets one, once it is past the drag threshold. Whether it shows
    /// is the drop's own call: see `tiledDropPreviewFrame`.
    func updateTiledDropPreview(_ event: NSEvent) {
        let point = TiledDragEvent.point(event: event, primaryHeight: displayManager.primaryScreenHeight)
        if !dropPreview.isActive {
            guard isRunning, config.enabled, let snapshot = tiledDragHandler.pressSnapshot,
                  TiledDragEvent.isDrag(from: pressPoint(), to: point, sawDragEvent: true) else {
                return
            }
            dropPreviewTargets = [:]
            dropPreviewPanel.primaryScreenHeight = displayManager.primaryScreenHeight
            dropPreviewPanel.accentColor = config.resolvedDropPreviewColor
            dropPreviewPanel.cornerRadius = config.windowCornerRadius
            dropPreview.begin { [weak self] point in
                self?.tiledDropPreviewFrame(at: point, snapshot: snapshot)
            }
        }
        dropPreview.move(to: point)
    }

    /// Where the dragged window would land if released at `point`, nil where
    /// the drop would restore. The drop's own planner and candidates, fed
    /// the press capture and the trees; no AX.
    private func tiledDropPreviewFrame(at point: CGPoint, snapshot: TiledDragSnapshot) -> CGRect? {
        // a drop only acts on a move: an unmoved window is ignored and a
        // resize resizes. judged by the drop's own rule, on the window list
        // any layout since the press supersedes the drop, and there is then
        // nothing to show
        guard isRunning, tiledDragHandler.pressSnapshot?.generation == snapshot.generation,
              tilingEngine.currentLayoutGeneration == snapshot.generation,
              tiledDragGesture(snapshot) == .move else { return nil }
        let swap = releaseRequestsSwap()
        var release = TiledDropRelease.source
        var target: TiledDragCrossTarget?
        if let screen = exactFullScreen(containing: point),
           Self.tiledDragDisplayID(screen) != snapshot.context.physicalDisplayID {
            let found = dropPreviewTarget(on: screen, snapshot: snapshot)
            target = found?.target
            release = .otherMonitor(slots: found?.slots)
        }
        let plan = TiledDropPlanner.plan(pointer: point, draggedID: snapshot.draggedID,
                                         sourceTiles: snapshot.context.usableFrame,
                                         sourceSlots: snapshot.originalFrames, release: release)
        return tilingEngine.tiledDragPreviewFrame(snapshot, plan: plan, swap: swap, target: target)
    }

    /// Another display's tree as a drop there would find it. The policy is
    /// asked every time, so a disabled monitor or the scratchpad refuses as
    /// it would at release, and a cached tree is kept only while its
    /// workspace is still the visible one and the tree itself is unchanged.
    private func dropPreviewTarget(on screen: NSScreen, snapshot: TiledDragSnapshot)
        -> (target: TiledDragCrossTarget, slots: [CGWindowID: CGRect])? {
        let displayID = Self.tiledDragDisplayID(screen)
        guard case let .workspace(workspace) = tiledDragReleasePolicy(on: screen) else {
            dropPreviewTargets[displayID] = nil
            return nil
        }
        if let cached = dropPreviewTargets[displayID], cached.workspace == workspace,
           cached.target.currentContext() == cached.target.context {
            return (cached.target, Self.slots(of: cached.target))
        }
        guard let found = tilingEngine.tiledDragPreviewTarget(
            for: snapshot, location: (workspace, screen, stateCache.floatingWindowIDs)) else {
            dropPreviewTargets[displayID] = nil
            return nil
        }
        dropPreviewTargets[displayID] = (workspace, found)
        return (found, Self.slots(of: found))
    }

    private static func slots(of target: TiledDragCrossTarget) -> [CGWindowID: CGRect] {
        TiledDropPlanner.slots(of: target.tree, in: target.context.usableFrame,
                               gap: target.context.gap, padding: target.context.padding)
    }

    /// What the drag is doing to the dragged window right now, by the drop's
    /// own rule, from the window list rather than AX. A press that selects
    /// text is `.unmoved`, an edge drag `.resize`.
    private func tiledDragGesture(_ snapshot: TiledDragSnapshot) -> TiledDragGesture? {
        var id = UnsafeRawPointer(bitPattern: UInt(snapshot.draggedID))
        guard let ids = CFArrayCreate(kCFAllocatorDefault, &id, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]],
              let raw = list.first?[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return nil }
        return snapshot.gesture(to: bounds)
    }

    private func exactScreen(containing point: CGPoint) -> NSScreen? {
        let matches = displayManager.screens.filter { displayManager.cgRect(for: $0).contains(point) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// One notice line per tiled release: the point in global CG coordinates,
    /// the source and release screens, and the same-tree target with every
    /// source tile it weighed. The drop decision reads from here.
    private func noteTiledDragRelease(_ pointer: CGPoint, snapshot: TiledDragSnapshot,
                                      onSourceTiles: Bool, target: TiledDragTarget?) {
        func describe(_ screen: NSScreen?) -> String {
            guard let screen else { return "none" }
            return "'\(screen.localizedName)' display=\(Self.tiledDragDisplayID(screen)) "
                + "full=\(displayManager.cgFullRect(for: screen))"
        }
        let source = displayManager.screens.first {
            Self.tiledDragDisplayID($0) == snapshot.context.physicalDisplayID
        }
        var slots = snapshot.originalFrames
        slots.removeValue(forKey: snapshot.draggedID)
        let tiles = onSourceTiles
            ? " tiles=[\(TiledDragTargetResolver.trace(pointer: pointer, slots: slots))]" : ""
        // runs on every click of a tiled window. the mode and settle lines
        // carry the decision; this geometry is for the trace tier
        hyprLog(.debug, .tiling, "tiled drag release: dragged=\(snapshot.draggedID) "
                + String(format: "point=cg(%g,%g) ", Double(pointer.x), Double(pointer.y))
                + "source=ws\(snapshot.context.workspace) on \(describe(source)) "
                + "sourceTiles=\(snapshot.context.usableFrame) onSourceTiles=\(onSourceTiles) "
                + "release=\(describe(exactFullScreen(containing: pointer))) "
                + "sameTree=\(target.map { "\($0.windowID) \($0.edge)" } ?? "none")" + tiles)
    }

    /// The one screen whose whole display holds `point`, menu bar and Dock
    /// included, so a release there still counts for that monitor.
    private func exactFullScreen(containing point: CGPoint) -> NSScreen? {
        let matches = displayManager.screens.filter { displayManager.cgFullRect(for: $0).contains(point) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Where a tiled drag released over another monitor lands: that screen's
    /// visible workspace, re-read on every call so the engine can tell when
    /// it goes stale. A screen that cannot take the window logs why once
    /// and yields nothing, and the drop restores.
    private func tiledDragReleaseLocation(_ pointer: CGPoint, leaving snapshot: TiledDragSnapshot)
        -> () -> (workspace: Int, screen: NSScreen, floatingIDs: Set<CGWindowID>)? {
        guard let screen = exactFullScreen(containing: pointer) else {
            hyprLog(.notice, .tiling, "tiled drag across monitors refused: release point on no screen")
            return { nil }
        }
        let displayID = Self.tiledDragDisplayID(screen)
        guard displayID != snapshot.context.physicalDisplayID else { return { nil } }
        let policy = tiledDragReleasePolicy(on: screen)
        guard case let .workspace(workspace) = policy else {
            if case let .refused(reason) = policy {
                hyprLog(.notice, .tiling, "tiled drag across monitors refused on "
                        + "\(screen.localizedName): \(reason)")
            }
            return { nil }
        }
        return { [weak self] in
            guard let self, self.isRunning else { return nil }
            let matches = self.displayManager.screens.filter { Self.tiledDragDisplayID($0) == displayID }
            guard matches.count == 1, let current = matches.first,
                  self.tiledDragReleasePolicy(on: current) == .workspace(workspace) else { return nil }
            return (workspace, current, self.stateCache.floatingWindowIDs)
        }
    }

    private func tiledDragReleasePolicy(on screen: NSScreen) -> TiledDragReleasePolicy {
        TiledDragReleasePolicy.resolve(
            monitorDisabled: workspaceManager.isMonitorDisabled(screen),
            scratchpadVisible: scratchpad.isVisible,
            visibleWorkspace: { workspaceManager.workspaceForScreen(screen) })
    }

    private func tiledDragLocation(for snapshot: TiledDragSnapshot)
        -> (workspace: Int, screen: NSScreen, floatingIDs: Set<CGWindowID>)? {
        guard isRunning else { return nil }
        let screens = displayManager.screens.filter {
            Self.tiledDragDisplayID($0) == snapshot.context.physicalDisplayID
        }
        guard screens.count == 1, let screen = screens.first,
              tiledDragWorkspace(on: screen) == snapshot.context.workspace,
              snapshot.context.memberIDs.allSatisfy({
                  workspaceManager.workspaceFor($0) == snapshot.context.workspace
              }) else { return nil }
        return (snapshot.context.workspace, screen, stateCache.floatingWindowIDs)
    }

    /// The workspace a tiled drag on `screen` works in: the scratchpad's
    /// tree while it's up on that monitor, nil on the other monitors then
    /// (their tiles are under the scrim), else the screen's workspace.
    private func tiledDragWorkspace(on screen: NSScreen) -> Int? {
        if let layer = scratchpad.visibleLayer {
            guard Self.tiledDragDisplayID(layer.screen) == Self.tiledDragDisplayID(screen) else { return nil }
            return ScratchpadController.workspace
        }
        return workspaceManager.workspaceForScreen(screen)
    }

    static func tiledDragDisplayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? 0
    }

    private func completeTiledDrag(_ completion: TiledDragCompletion) {
        let affected = completion.snapshot.context.memberIDs
        // a drop onto another monitor wraps the ordinary outcome together
        // with the release screen's tree
        var outcome = completion.outcome
        var crossTree: TiledDragCrossTree?
        if case let .acrossTrees(result, cross) = completion.outcome {
            outcome = result
            crossTree = cross
        }
        tiledDragFeedback.noteDropFinished(outcome, completion: completion,
                                           crossTree: crossTree, affected: affected)
        let scope = crossTree == nil ? "" : " across monitors"
        hyprLog(.debug, .tiling, "tiled drag result: dragged=\(completion.snapshot.draggedID) "
                + "members=\(affected.union(crossTree?.target.memberIDs ?? []).sorted()) "
                + "outcome=\(Self.outcomeName(completion.outcome))")
        switch outcome {
        case let .rejectedRestored(reason, frames):
            hyprLog(.notice, .tiling, "tiled drag\(scope) rejected and restored: reason=\(reason.trace) actual=\(frames)")
        case let .degraded(candidateReason, restorationReason, frames, progress):
            let candidate = candidateReason?.trace ?? "nil"
            let restoration = restorationReason?.trace ?? "nil"
            let written = (progress?.possiblyWritten ?? []).sorted()
            hyprLog(.notice, .tiling, "tiled drag\(scope) degraded: candidate=\(candidate) restoration=\(restoration) "
                    + "written=\(written) actual=\(frames)")
        case .committed, .superseded, .ignored, .acrossTrees: break
        }
        switch outcome {
        case .superseded, .ignored: return
        case .committed, .rejectedRestored, .degraded, .acrossTrees: break
        }
        // the drop already moved membership with the trees
        var committedAcross: [CGWindowID: CGRect]?
        if crossTree != nil, case let .committed(_, frames, _) = outcome {
            focusController.recordFocus(completion.snapshot.draggedID,
                                        reason: "tiled drag across monitors")
            committedAcross = frames
        }
        if completion.snapshot.context.workspace == ScratchpadController.workspace {
            scratchpad.syncTiledFrames()
        }
        // the same per-window decisions the tiled-position cache just
        // applied, so the two cannot drift apart. a drop across monitors
        // brings the release screen's members in through the policy
        let actions = TiledDragCachePolicy.actions(for: completion.outcome,
                                                   draggedID: completion.snapshot.draggedID,
                                                   affectedIDs: affected)
        for (id, action) in actions {
            switch action {
            case let .refresh(frame): stateCache.cachedWindows[id]?.cachedFrame = frame
            case .invalidate: stateCache.cachedWindows[id]?.cachedFrame = nil
            case .preserve: break
            }
        }
        if let id = focusBorder.trackedWindowID, let action = actions[id] {
            switch action {
            case let .refresh(frame): focusBorder.updatePosition(frame)
            case .invalidate: focusBorder.hide()
            case .preserve: break
            }
        }
        if let id = focusBrackets.trackedWindowID, let action = actions[id] {
            switch action {
            case let .refresh(frame): if focusBrackets.isVisible { focusBrackets.updatePosition(frame) }
            case .invalidate: focusBrackets.hide()
            case .preserve: break
            }
        }
        // the dragged window keeps focus on its new monitor. the border goes
        // on the verified frame: a live AX read lags the write
        let draggedID = completion.snapshot.draggedID
        if let frame = committedAcross?[draggedID], config.showFocusBorder,
           let window = stateCache.cachedWindows[draggedID],
           !isFullscreenSuppressed(window) {
            focusBorder.accentCGColor = config.resolvedFocusBorderColor.cgColor
            focusBorder.show(around: frame, windowID: draggedID)
        }
        if committedAcross != nil {
            NotificationCenter.default.post(name: .hyprMacWorkspaceChanged, object: nil)
        }
        refreshDimming(stateCache.tiledPositions)
        switch TiledDragFeedbackPolicy.feedback(for: completion.outcome) {
        case .rejected:
            NSSound.beep()
            let frame = completion.snapshot.originalFrames[completion.snapshot.draggedID]
                ?? completion.snapshot.context.usableFrame
            focusBorder.flashError(around: frame, windowID: completion.snapshot.draggedID,
                                   message: "Arrangement rejected; previous positions restored")
        case .degraded:
            tiledDragFeedback.deferDegraded(completion, crossTree: crossTree, affected: affected)
            hyprLog(.notice, .tiling, "tiled drag degraded feedback deferred until reconciliation")
            schedulePoll()
        case nil:
            break
        }
    }

    private static func outcomeName(_ outcome: TiledDragDropOutcome) -> String {
        switch outcome {
        case .ignored: return "ignored"
        case .committed: return "committed"
        case .rejectedRestored: return "rejectedRestored"
        case .degraded: return "degraded"
        case .superseded: return "superseded"
        case let .acrossTrees(result, cross):
            return "acrossTrees(\(outcomeName(result)) ws\(cross.target.workspace))"
        }
    }

    private func reportTiledDragCaptureFailure(_ result: TiledDragCaptureResult) {
        guard case let .unknown(reason) = result, let point = pressPoint() else { return }
        hyprLog(.notice, .tiling, "tiled drag capture failed: reason=\(reason)")
        NSSound.beep()
        focusBorder.flashError(around: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2),
                               windowID: 0, message: "Could not verify window positions")
    }
}
