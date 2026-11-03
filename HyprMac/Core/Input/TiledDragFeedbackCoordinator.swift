// Carries a degraded tiled drag's deferred error from the drop to the layout
// that settles it. `TiledDragFeedbackReconciler` decides; this runs the effects.

import Cocoa

final class TiledDragFeedbackCoordinator {
    private var reconciler = TiledDragFeedbackReconciler()
    private var pendingCompletion: TiledDragCompletion?
    private var active: (key: TiledDragFeedbackKey, layoutGeneration: UInt64, borderToken: Int)?

    private let currentGeneration: () -> UInt64
    private let displayID: (NSScreen) -> CGDirectDisplayID
    private let screens: () -> [NSScreen]
    private let windowIDsOnWorkspace: (Int) -> Set<CGWindowID>
    private let workspaceFor: (CGWindowID) -> Int?
    private let isFloating: (CGWindowID) -> Bool
    private let allWindows: () -> [HyprWindow]
    private let isAwaitingRetry: (CGWindowID) -> Bool
    private let hasActiveRetry: (Int, NSScreen) -> Bool
    private let beep: () -> Void
    /// Returns the border's token for the error, nil when it did not show.
    private let showFailure: (TiledDragCompletion) -> Int?
    private let cancelFailure: (Int) -> Bool

    init(currentGeneration: @escaping () -> UInt64,
         displayID: @escaping (NSScreen) -> CGDirectDisplayID,
         screens: @escaping () -> [NSScreen],
         windowIDsOnWorkspace: @escaping (Int) -> Set<CGWindowID>,
         workspaceFor: @escaping (CGWindowID) -> Int?,
         isFloating: @escaping (CGWindowID) -> Bool,
         allWindows: @escaping () -> [HyprWindow],
         isAwaitingRetry: @escaping (CGWindowID) -> Bool,
         hasActiveRetry: @escaping (Int, NSScreen) -> Bool,
         beep: @escaping () -> Void,
         showFailure: @escaping (TiledDragCompletion) -> Int?,
         cancelFailure: @escaping (Int) -> Bool) {
        self.currentGeneration = currentGeneration
        self.displayID = displayID
        self.screens = screens
        self.windowIDsOnWorkspace = windowIDsOnWorkspace
        self.workspaceFor = workspaceFor
        self.isFloating = isFloating
        self.allWindows = allWindows
        self.isAwaitingRetry = isAwaitingRetry
        self.hasActiveRetry = hasActiveRetry
        self.beep = beep
        self.showFailure = showFailure
        self.cancelFailure = cancelFailure
    }

    func reset() {
        reconciler.cancel()
        pendingCompletion = nil
        active = nil
    }

    /// The border's error finished showing.
    func errorFinished(token: Int) {
        if let active, active.borderToken == token {
            reconciler.feedbackFinished(generation: active.layoutGeneration)
            self.active = nil
            if !reconciler.hasPendingFeedback {
                pendingCompletion = nil
            }
        }
    }

    /// A later drop finished while an earlier one's error is pending. A
    /// verified drop speaks for the keys it touched.
    func noteDropFinished(_ outcome: TiledDragDropOutcome, completion: TiledDragCompletion,
                          crossTree: TiledDragCrossTree?, affected: Set<CGWindowID>) {
        guard reconciler.hasPendingFeedback else { return }
        switch outcome {
        case .degraded:
            // beginDegraded reports the earlier failure before replacing it.
            break
        case .committed, .rejectedRestored:
            // every key this verified drop touched speaks for its members
            var verified = [(TiledDragFeedbackKey(
                workspace: completion.snapshot.context.workspace,
                displayID: completion.snapshot.context.physicalDisplayID), affected)]
            if let crossTree {
                verified.append((TiledDragFeedbackKey(
                    workspace: crossTree.target.workspace,
                    displayID: crossTree.target.physicalDisplayID), crossTree.target.memberIDs))
            }
            var actions: [TiledDragDeferredFeedbackAction] = []
            let touched = verified.filter { reconciler.isPending(for: $0.0) }
            if touched.isEmpty {
                actions = reconciler.reconcile(.noResult)
            }
            for (key, members) in touched {
                actions += reconciler.reconcile(.accepted(
                    key: key, generation: currentGeneration(),
                    publishedIDs: members, expectedIDs: members))
            }
            apply(actions, completion: pendingCompletion)
            if !reconciler.hasPendingFeedback {
                pendingCompletion = nil
            }
        case .ignored, .superseded, .acrossTrees:
            break
        }
    }

    /// Hold a degraded drop's error until a later layout settles it. An
    /// earlier failure this replaces reports with its own completion, so the
    /// new one is stored only after that.
    func deferDegraded(_ completion: TiledDragCompletion, crossTree: TiledDragCrossTree?,
                       affected: Set<CGWindowID>) {
        let key = TiledDragFeedbackKey(
            workspace: completion.snapshot.context.workspace,
            displayID: completion.snapshot.context.physicalDisplayID)
        // a drop across monitors also waits on the release screen's tree
        var releaseScreen: [TiledDragFeedbackKey: Set<CGWindowID>] = [:]
        if let crossTree {
            releaseScreen[TiledDragFeedbackKey(workspace: crossTree.target.workspace,
                                               displayID: crossTree.target.physicalDisplayID)]
                = crossTree.target.memberIDs
        }
        apply(reconciler.beginDegraded(
            key: key, generation: currentGeneration(),
            affectedIDs: affected, alsoAwaiting: releaseScreen),
            completion: pendingCompletion)
        pendingCompletion = completion
    }

    /// The poll's tile passes, as evidence about whatever is pending.
    func reconcile(with results: [TilingEngine.AdmissionResult], allWindows: [HyprWindow]) {
        guard reconciler.hasPendingFeedback else { return }
        let events = results.map { result -> TiledDragFeedbackReconciliation in
            let key = TiledDragFeedbackKey(
                workspace: result.workspace,
                displayID: displayID(result.screen))
            if result.failure == nil, result.strandedIDs.isEmpty {
                let assigned = windowIDsOnWorkspace(result.workspace)
                let expected = Set(allWindows.filter {
                    assigned.contains($0.windowID) && !isFloating($0.windowID)
                }.map(\.windowID))
                return .accepted(key: key, generation: result.generation,
                                 publishedIDs: result.publishedIDs, expectedIDs: expected)
            }
            return .failed(key: key, generation: result.generation,
                           requiredIDs: result.publishedIDs.union(result.strandedIDs),
                           recoveryPending: result.strandedIDs.contains(where: isAwaitingRetry))
        }
        var activeRetry = false
        for key in reconciler.pendingKeys {
            guard let screen = screens().first(where: {
                displayID($0) == key.displayID
            }) else { continue }
            activeRetry = activeRetry
                || hasActiveRetry(key.workspace, screen)
        }
        let actions = reconciler.reconcileNewest(events, activeRetry: activeRetry)
        if !actions.isEmpty {
            apply(actions, completion: pendingCompletion)
            pendingCompletion = nil
        }
    }

    /// The admission recovery's last word on a key.
    func reconcileRecovery(workspace: Int, screen: NSScreen, result: TilingEngine.AdmissionResult?) {
        guard reconciler.hasPendingFeedback else { return }
        let key = TiledDragFeedbackKey(workspace: workspace,
                                       displayID: displayID(screen))
        let event: TiledDragFeedbackReconciliation
        if let result, result.failure == nil, result.strandedIDs.isEmpty {
            let expected = Set(allWindows().filter {
                workspaceFor($0.windowID) == workspace && !isFloating($0.windowID)
            }.map(\.windowID))
            event = .accepted(key: key, generation: result.generation,
                              publishedIDs: result.publishedIDs, expectedIDs: expected)
        } else {
            event = .terminalFailure(key: key)
        }
        let actions = reconciler.reconcile(event)
        guard !actions.isEmpty else { return }
        apply(actions, completion: pendingCompletion)
        pendingCompletion = nil
    }

    private func apply(_ actions: [TiledDragDeferredFeedbackAction], completion: TiledDragCompletion?) {
        for action in actions {
            switch action {
            case let .showDegraded(key, generation):
                guard let completion else { continue }
                beep()
                if let token = showFailure(completion) {
                    active = (key, generation, token)
                }
            case let .cancelDegraded(key):
                hyprLog(.notice, .tiling, "tiled drag degraded feedback cancelled: verified reconciliation")
                if let active, active.key == key, cancelFailure(active.borderToken) {
                    self.active = nil
                }
            }
        }
    }
}
