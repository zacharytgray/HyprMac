// Pairs the leaves of a saved layout with live windows. Pure — no AX,
// no tree access — so the assignment policy is unit-testable and one
// plan feeds both the workspace moves and the tree rebuild.

import Foundation

enum LayoutMatcher {

    /// A live window that may take a saved leaf. Callers exclude
    /// floaters, scratchpad members, and windows on disabled monitors
    /// before matching — the snapshot never contains them.
    struct Candidate: Equatable {
        let windowID: CGWindowID
        let bundleID: String
        let title: String
        let workspace: Int
    }

    /// Result of `plan`. Every window appears at most once.
    struct Plan: Equatable {
        /// Window → workspace the snapshot places it on.
        var workspaceByWindow: [CGWindowID: Int] = [:]
        /// Workspace → leaf ref → the windows assigned to that ref, in
        /// leaf order. Two leaves with the same ref get one window each.
        var windowsByRef: [Int: [SavedWindowRef: [CGWindowID]]] = [:]
        /// Saved leaves no live window matched.
        var unmatchedRefs: [SavedWindowRef] = []
    }

    /// Two passes over the leaves, each greedy in leaf order. The first
    /// pass only pairs exact, non-empty title matches, so a missing
    /// earlier leaf can't take a window a later leaf names exactly. The
    /// second pass gives each remaining leaf the best unclaimed window
    /// with the same bundle ID. Within a pass the window already on the
    /// leaf's workspace wins, then the lowest window ID, so a plan is
    /// deterministic.
    /// `exactOnly` skips the second pass: a leaf takes only the window it
    /// names. The tutorial's desk restore uses it, since window ids don't
    /// change during a tutorial and a new window must never take an old
    /// one's place.
    static func plan(_ snapshot: LayoutSnapshot, candidates: [Candidate], exactOnly: Bool = false) -> Plan {
        let leaves: [(workspace: Int, ref: SavedWindowRef)] = snapshot.workspaces.flatMap { layout in
            layout.refs.map { (layout.workspace, $0) }
        }
        var pick = [CGWindowID?](repeating: nil, count: leaves.count)
        var claimed = Set<CGWindowID>()

        func claim(_ i: Int, exactOnly: Bool) {
            let (workspace, ref) = leaves[i]
            var best: (id: CGWindowID, score: Int)?
            for c in candidates where !claimed.contains(c.windowID) && c.bundleID == ref.bundleID {
                let exact = !ref.title.isEmpty && c.title == ref.title
                if exactOnly && !exact { continue }
                let score = (exact ? 10 : 0) + (c.workspace == workspace ? 5 : 0)
                if let b = best, !(score > b.score || (score == b.score && c.windowID < b.id)) { continue }
                best = (c.windowID, score)
            }
            guard let id = best?.id else { return }
            claimed.insert(id)
            pick[i] = id
        }

        for i in leaves.indices where !leaves[i].ref.title.isEmpty { claim(i, exactOnly: true) }
        if !exactOnly {
            for i in leaves.indices where pick[i] == nil { claim(i, exactOnly: false) }
        }

        // assemble in leaf order so windowsByRef keeps leaf order
        var plan = Plan()
        for (i, leaf) in leaves.enumerated() {
            guard let id = pick[i] else {
                plan.unmatchedRefs.append(leaf.ref)
                continue
            }
            plan.workspaceByWindow[id] = leaf.workspace
            plan.windowsByRef[leaf.workspace, default: [:]][leaf.ref, default: []].append(id)
        }
        return plan
    }
}
