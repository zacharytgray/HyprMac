// Which newcomers an admission retry leaves out. Pure over its two closures.

import CoreGraphics

enum NewcomerRefusal {
    /// The fewest newcomers to leave out so the rest fit beside the
    /// incumbents on the known floors. Drops the newcomer whose removal makes
    /// the rest fit, else the one with the biggest floor, and repeats. nil
    /// when no newcomer would be left to tile.
    static func choose(_ judged: [HyprWindow], newcomers: Set<CGWindowID>,
                       minimumSize: (HyprWindow) -> CGSize,
                       fits: ([HyprWindow]) -> Bool) -> Set<CGWindowID>? {
        var kept = judged
        var dropped: Set<CGWindowID> = []
        while !fits(kept) {
            let candidates = kept.filter { newcomers.contains($0.windowID) }.sorted { lhs, rhs in
                let left = minimumSize(lhs), right = minimumSize(rhs)
                let leftArea = left.width * left.height, rightArea = right.width * right.height
                return leftArea != rightArea ? leftArea > rightArea : lhs.windowID > rhs.windowID
            }
            guard let first = candidates.first else { return nil }
            let drop = candidates.first { candidate in
                fits(kept.filter { $0.windowID != candidate.windowID })
            } ?? first
            kept.removeAll { $0.windowID == drop.windowID }
            dropped.insert(drop.windowID)
        }
        guard kept.contains(where: { newcomers.contains($0.windowID) }) else { return nil }
        return dropped
    }
}
