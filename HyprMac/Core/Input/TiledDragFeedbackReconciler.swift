// Matches a tiled drag's deferred feedback to the layout that ends it.

import Cocoa

struct TiledDragFeedbackKey: Hashable {
    let workspace: Int
    let displayID: CGDirectDisplayID
}

enum TiledDragFeedbackReconciliation {
    case accepted(key: TiledDragFeedbackKey, generation: UInt64,
                  publishedIDs: Set<CGWindowID>, expectedIDs: Set<CGWindowID>)
    case failed(key: TiledDragFeedbackKey, generation: UInt64,
                requiredIDs: Set<CGWindowID>, recoveryPending: Bool)
    case terminalFailure(key: TiledDragFeedbackKey)
    case noResult
}

enum TiledDragDeferredFeedbackAction: Equatable {
    case showDegraded(key: TiledDragFeedbackKey, generation: UInt64)
    case cancelDegraded(key: TiledDragFeedbackKey)
}

struct TiledDragFeedbackReconciler {
    private struct Waiting {
        /// ids a verified layout under this key must publish
        var ids: Set<CGWindowID>
        /// the newest generation heard from this key
        var generation: UInt64
    }

    private struct Pending {
        /// the key the feedback is shown and cancelled under: the drop's source
        let key: TiledDragFeedbackKey
        var generation: UInt64
        /// every key the drop touched that has not been cleared yet. a drop
        /// across monitors waits on the release screen's key as well
        var awaiting: [TiledDragFeedbackKey: Waiting]
        var shownGeneration: UInt64?
    }

    private var pending: Pending?
    var hasPendingFeedback: Bool { pending != nil }
    func isPending(for key: TiledDragFeedbackKey) -> Bool { pending?.awaiting[key] != nil }
    /// every key the pending feedback still waits on
    var pendingKeys: [TiledDragFeedbackKey] { pending.map { Array($0.awaiting.keys) } ?? [] }
    var shownGeneration: UInt64? { pending?.shownGeneration }

    /// `alsoAwaiting` names other keys the drop touched, each with the ids a
    /// verified layout there must publish before the feedback is cancelled.
    ///
    /// A second failure from the same source adds to what the first is still
    /// waiting for rather than replacing it, so a cross drop's release screen
    /// is not forgotten. A failure from another source reports the pending
    /// one first, as before, since its feedback cannot cancel under this key.
    mutating func beginDegraded(key: TiledDragFeedbackKey, generation: UInt64,
                                affectedIDs: Set<CGWindowID>,
                                alsoAwaiting: [TiledDragFeedbackKey: Set<CGWindowID>] = [:])
        -> [TiledDragDeferredFeedbackAction] {
        if let pending, pending.key == key, generation <= pending.generation {
            return []
        }
        let actions: [TiledDragDeferredFeedbackAction]
        if let pending, pending.key != key, pending.shownGeneration == nil {
            actions = [.showDegraded(key: pending.key, generation: pending.generation)]
        } else {
            actions = []
        }
        var touched = alsoAwaiting
        touched[key, default: []].formUnion(affectedIDs)
        if let pending, pending.key == key {
            for (earlier, waiting) in pending.awaiting {
                touched[earlier, default: []].formUnion(waiting.ids)
            }
        }
        // every key waits for a verified layout newer than this failure
        let awaiting = touched.mapValues { Waiting(ids: $0, generation: generation) }
        pending = Pending(key: key, generation: generation, awaiting: awaiting, shownGeneration: nil)
        return actions
    }

    mutating func reconcile(_ event: TiledDragFeedbackReconciliation)
        -> [TiledDragDeferredFeedbackAction] {
        guard let pending else { return [] }
        let key: TiledDragFeedbackKey
        let generation: UInt64
        switch event {
        case let .accepted(eventKey, eventGeneration, _, _),
             let .failed(eventKey, eventGeneration, _, _):
            key = eventKey
            generation = eventGeneration
        case let .terminalFailure(eventKey):
            guard pending.awaiting[eventKey] != nil else { return [] }
            return showOnce()
        case .noResult:
            return showOnce()
        }
        guard let waiting = pending.awaiting[key], generation > waiting.generation else { return [] }

        switch event {
        case let .accepted(_, _, publishedIDs, expectedIDs):
            if publishedIDs == expectedIDs, publishedIDs.isSuperset(of: waiting.ids) {
                self.pending?.awaiting[key] = nil
                // every key the drop touched has to come back verified
                guard self.pending?.awaiting.isEmpty == true else { return [] }
                self.pending = nil
                return [.cancelDegraded(key: pending.key)]
            }
            heard(generation, from: key)
            return showOnce()
        case let .failed(_, _, requiredIDs, recoveryPending):
            self.pending?.awaiting[key]?.ids.formUnion(requiredIDs)
            heard(generation, from: key)
            return recoveryPending ? [] : showOnce()
        case .terminalFailure, .noResult:
            return []
        }
    }

    mutating func reconcileNewest(_ events: [TiledDragFeedbackReconciliation],
                                  activeRetry: Bool) -> [TiledDragDeferredFeedbackAction] {
        guard let pending else { return [] }
        var newest: [TiledDragFeedbackKey: (generation: UInt64, event: TiledDragFeedbackReconciliation)] = [:]
        for event in events {
            switch event {
            case let .accepted(key, generation, _, _), let .failed(key, generation, _, _):
                guard pending.awaiting[key] != nil,
                      newest[key].map({ generation > $0.generation }) ?? true else { continue }
                newest[key] = (generation, event)
            case .terminalFailure, .noResult:
                continue
            }
        }
        var actions: [TiledDragDeferredFeedbackAction] = []
        for (_, entry) in newest.sorted(by: { $0.value.generation < $1.value.generation }) {
            actions += reconcile(entry.event)
        }
        // a key the pass never reached cannot be verified by it
        guard let still = self.pending,
              still.awaiting.keys.contains(where: { newest[$0] == nil }) else { return actions }
        return activeRetry ? actions : actions + reconcile(.noResult)
    }

    mutating func cancel() {
        pending = nil
    }

    mutating func feedbackFinished(generation: UInt64) {
        if pending?.shownGeneration == generation { pending = nil }
    }

    private mutating func heard(_ generation: UInt64, from key: TiledDragFeedbackKey) {
        pending?.awaiting[key]?.generation = generation
        if let current = pending?.generation, generation > current {
            pending?.generation = generation
        }
    }

    private mutating func showOnce() -> [TiledDragDeferredFeedbackAction] {
        guard let pending, pending.shownGeneration == nil else { return [] }
        self.pending?.shownGeneration = pending.generation
        return [.showDegraded(key: pending.key, generation: pending.generation)]
    }
}
