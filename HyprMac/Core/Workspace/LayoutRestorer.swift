// Runs one layout restore end to end: match saved leaves to live windows,
// move windows to their saved workspaces, rebuild each saved tree shape,
// and say what actually happened. The pill and the log read the outcome;
// nothing here talks to AX directly.

import Cocoa

/// What one restore did, and how complete it was.
struct LayoutRestoreOutcome {
    enum Verdict: Equatable {
        /// no snapshot for the current display setup
        case noSnapshot
        /// nothing had to change
        case alreadyInPlace
        /// every matched window placed, every shape rebuilt
        case complete
        /// some of it applied, some was refused
        case partial
        /// something was asked and none of it applied
        case failed
    }

    /// Why a saved shape was not applied; the live tree was kept.
    enum ShapeFailure: Equatable {
        case exceedsMaxDepth(Int)
        case refusedIncumbents([CGWindowID])
        case rejected(FrameSizingFailure?)
    }

    var hasSnapshot = true
    /// windows the matcher paired with a saved leaf
    var matched = 0
    /// saved leaves no open window matched. informational only.
    var absent = 0
    var moved: [CGWindowID: Int] = [:]
    var refusedMoves: [CGWindowID: WorkspaceOrchestrator.BatchMoveResult.Refusal] = [:]
    /// workspaces whose saved shape was published
    var rebuilt: [Int] = []
    /// rebuilt workspaces whose shape actually differs from before
    var reshaped: [Int] = []
    var shapeFailures: [Int: ShapeFailure] = [:]
    /// windows a rebuilt tree had no slot for, by workspace. handed to admission recovery.
    var refusedNewcomers: [Int: [CGWindowID]] = [:]

    static let noSnapshot = LayoutRestoreOutcome(hasSnapshot: false)

    /// windows that should have ended up tiled on their saved workspace and did not
    var unplacedWindowCount: Int {
        refusedMoves.count + refusedNewcomers.values.reduce(0) { $0 + $1.count }
    }

    var verdict: Verdict {
        guard hasSnapshot else { return .noSnapshot }
        let refused = unplacedWindowCount > 0 || !shapeFailures.isEmpty
        if !refused {
            return moved.isEmpty && reshaped.isEmpty ? .alreadyInPlace : .complete
        }
        // a workspace already in its saved shape still counts as done
        return moved.isEmpty && rebuilt.isEmpty ? .failed : .partial
    }

    /// Pill text for a manual restore.
    var message: String {
        switch verdict {
        case .noSnapshot:
            return "No saved layout for this display setup"
        case .alreadyInPlace:
            return "Layout already in place" + absentNote
        case .complete:
            return "Layout restored" + absentNote
        case .failed:
            return "Couldn't restore layout"
        case .partial:
            let windows = unplacedWindowCount
            if windows > 0 {
                return "Layout partly restored — \(windows) window\(windows == 1 ? "" : "s") didn't fit"
            }
            let spaces = shapeFailures.count
            return "Layout partly restored — \(spaces) workspace\(spaces == 1 ? "" : "s") kept \(spaces == 1 ? "its" : "their") layout"
        }
    }

    /// Title and detail for the manual-restore HUD.
    var hud: (title: String, detail: String?, failed: Bool) {
        let absentLine = absent > 0 ? "\(absent) saved window\(absent == 1 ? "" : "s") not open" : nil
        let refusedLine: String? = {
            let windows = unplacedWindowCount
            if windows > 0 { return "\(windows) window\(windows == 1 ? "" : "s") didn't fit" }
            let spaces = shapeFailures.count
            return spaces > 0 ? "\(spaces) workspace\(spaces == 1 ? "" : "s") kept \(spaces == 1 ? "its" : "their") layout" : nil
        }()
        switch verdict {
        case .noSnapshot: return ("No saved layout", "Nothing saved for this display setup", true)
        case .alreadyInPlace: return ("Already in place", absentLine, false)
        case .complete: return ("Restored", absentLine, false)
        case .partial: return ("Partly restored", refusedLine, false)
        case .failed: return ("Couldn't restore", refusedLine, true)
        }
    }

    // short enough for a pill; the log always carries the count
    private var absentNote: String {
        absent > 0 && absent < 100 ? " — \(absent) saved window\(absent == 1 ? "" : "s") not open" : ""
    }

    /// One-line summary for the log.
    var logSummary: String {
        guard hasSnapshot else { return "no snapshot" }
        var parts = ["\(verdict)", "\(matched) matched", "\(moved.count) moved",
                     "\(rebuilt.count) trees rebuilt (\(reshaped.count) changed)",
                     "\(absent) saved windows absent"]
        if !refusedMoves.isEmpty {
            parts.append("moves refused " + refusedMoves.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }.joined(separator: ", "))
        }
        if !shapeFailures.isEmpty {
            parts.append("shape kept live for " + shapeFailures.sorted { $0.key < $1.key }
                .map { "ws\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        if !refusedNewcomers.isEmpty {
            parts.append("no slot for " + refusedNewcomers.sorted { $0.key < $1.key }
                .map { "ws\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        return parts.joined(separator: "; ")
    }
}

/// Restore orchestration, kept out of `WindowManager` so it runs headless.
///
/// Moves go through `WorkspaceOrchestrator.moveWindows` (the same
/// suppression, tree removal and park/place sequence as `Hypr+Shift+N`),
/// shapes through `TilingEngine.rebuildTree`. Floaters and scratchpad
/// members are never matched. Workspaces whose home monitor is disabled
/// keep their shape. Hidden workspaces publish the shape unverified and
/// verify on their next show.
struct LayoutRestorer {
    let engine: TilingEngine
    let orchestrator: WorkspaceOrchestrator
    let workspaceManager: WorkspaceManager
    let stateCache: WindowStateCache
    let recovery: AdmissionRecovery
    let isScratchpad: (CGWindowID) -> Bool
    let ref: (HyprWindow) -> SavedWindowRef?

    /// Every regular workspace's saved form: its tree shape, plus the
    /// windows assigned to it that have not joined the tree yet (sent to a
    /// hidden workspace that hasn't been shown since). Floaters, scratchpad
    /// members and closed-but-alive windows are left out.
    func capture() -> [WorkspaceLayout] {
        let ghosts = stateCache.hiddenWindowIDs
        return workspaceManager.regularWorkspaceWindowIDs().keys.sorted().compactMap { ws -> WorkspaceLayout? in
            let root = engine.layoutTree(forWorkspace: ws, ref: ref)
            let inTrees = engine.windowIDs(inAnyTreeForWorkspace: ws)
            let unplaced = workspaceManager.windowIDs(onWorkspace: ws).sorted().compactMap { id -> SavedWindowRef? in
                guard !inTrees.contains(id), !ghosts.contains(id),
                      !stateCache.floatingWindowIDs.contains(id), !isScratchpad(id),
                      let window = stateCache.cachedWindows[id] else { return nil }
                return ref(window)
            }
            guard root != nil || !unplaced.isEmpty else { return nil }
            return WorkspaceLayout(workspace: ws, root: root, unplaced: unplaced)
        }
    }

    func restore(_ snapshot: LayoutSnapshot?, windows allWindows: [HyprWindow]) -> LayoutRestoreOutcome {
        guard let snapshot else { return .noSnapshot }
        var outcome = LayoutRestoreOutcome()

        let excluded = { (id: CGWindowID) in
            stateCache.floatingWindowIDs.contains(id) || isScratchpad(id)
        }
        let candidates = allWindows.compactMap { w -> LayoutMatcher.Candidate? in
            guard !excluded(w.windowID),
                  let ws = workspaceManager.workspaceFor(w.windowID),
                  let ref = ref(w) else { return nil }
            return LayoutMatcher.Candidate(windowID: w.windowID, bundleID: ref.bundleID,
                                           title: ref.title, workspace: ws)
        }
        let plan = LayoutMatcher.plan(snapshot, candidates: candidates)
        outcome.matched = plan.workspaceByWindow.count
        outcome.absent = plan.unmatchedRefs.count

        let byID = Dictionary(allWindows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let moves: [(window: HyprWindow, workspace: Int)] = plan.workspaceByWindow
            .compactMap { wid, ws in
                guard let w = byID[wid], workspaceManager.workspaceFor(wid) != ws else { return nil }
                return (w, ws)
            }
            .sorted { $0.window.windowID < $1.window.windowID }
        let batch = orchestrator.moveWindows(moves)
        outcome.moved = batch.moved
        outcome.refusedMoves = batch.refused

        // shape pass: rebuild each saved workspace's tree around the
        // windows now on it. visible workspaces verify frames, hidden ones
        // publish the shape and verify on their next show.
        for layout in snapshot.workspaces {
            let ws = layout.workspace
            guard let screen = workspaceManager.homeScreenForWorkspace(ws),
                  !workspaceManager.isMonitorDisabled(screen) else { continue }
            let onWorkspace = allWindows.filter {
                workspaceManager.workspaceFor($0.windowID) == ws && !excluded($0.windowID)
            }
            // no saved tree: the moved windows join one when the workspace is shown
            guard let root = layout.root, !onWorkspace.isEmpty else { continue }
            let before = engine.layoutTree(forWorkspace: ws, ref: ref)
            var queues = plan.windowsByRef[ws] ?? [:]
            let result = engine.rebuildTree(
                forWorkspace: ws, screen: screen, from: root,
                windows: onWorkspace, applyFrames: workspaceManager.isWorkspaceVisible(ws)
            ) { ref in
                guard var queue = queues[ref], !queue.isEmpty else { return nil }
                let id = queue.removeFirst()
                queues[ref] = queue
                return byID[id]
            }
            switch result {
            case let .rebuilt(_, refused):
                outcome.rebuilt.append(ws)
                if engine.layoutTree(forWorkspace: ws, ref: ref) != before { outcome.reshaped.append(ws) }
                if !refused.isEmpty {
                    outcome.refusedNewcomers[ws] = refused
                    handOff(refused, workspace: ws, screen: screen)
                }
            case .exceedsMaxDepth(let depth):
                outcome.shapeFailures[ws] = .exceedsMaxDepth(depth)
            case .refusedIncumbents(let ids):
                outcome.shapeFailures[ws] = .refusedIncumbents(ids)
            case .rejected(let reason):
                outcome.shapeFailures[ws] = .rejected(reason)
            }
        }
        return outcome
    }

    /// Refused newcomers go to the bounded admission recovery exactly as a
    /// tile pass's refusals do: stranded, already judged, float in place on
    /// the next turn unless something tiles them first.
    private func handOff(_ ids: [CGWindowID], workspace: Int, screen: NSScreen) {
        let published = Set(engine.windowIDs(inTreeForWorkspace: workspace, screen: screen))
        recovery.note(TilingEngine.AdmissionResult(
            workspace: workspace, screen: screen,
            generation: engine.currentLayoutGeneration,
            insertedIDs: [], publishedIDs: published,
            failure: nil, restoredIDs: [], refusedIDs: Set(ids)))
    }
}
