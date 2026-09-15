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

    /// Greedy assignment in leaf order: each leaf takes the best unclaimed
    /// candidate with the same bundle ID. Score: +10 for an exact,
    /// non-empty title match; +5 when the window already sits on the
    /// leaf's workspace. Ties go to the lowest window ID so a plan is
    /// deterministic.
    static func plan(_ snapshot: LayoutSnapshot, candidates: [Candidate]) -> Plan {
        var plan = Plan()
        var claimed = Set<CGWindowID>()

        for layout in snapshot.workspaces {
            for ref in layout.root.leaves {
                var best: (id: CGWindowID, score: Int)?
                for c in candidates where !claimed.contains(c.windowID) && c.bundleID == ref.bundleID {
                    var score = 1
                    if !ref.title.isEmpty && c.title == ref.title { score += 10 }
                    if c.workspace == layout.workspace { score += 5 }
                    if let b = best, !(score > b.score || (score == b.score && c.windowID < b.id)) { continue }
                    best = (c.windowID, score)
                }
                guard let pick = best else {
                    plan.unmatchedRefs.append(ref)
                    continue
                }
                claimed.insert(pick.id)
                plan.workspaceByWindow[pick.id] = layout.workspace
                plan.windowsByRef[layout.workspace, default: [:]][ref, default: []].append(pick.id)
            }
        }
        return plan
    }
}
