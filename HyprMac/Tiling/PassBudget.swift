// The time the forward passes of one verified layout attempt share. Pure: the
// caller reads the clock and passes it in.

import Foundation

struct PassBudget {
    /// The most the forward passes of one verified layout attempt may hold
    /// the main thread: the candidate, its adjusted pass, the topology
    /// recovery and the timeout recovery's retry share it. Summed, their
    /// own deadlines came to more than three seconds, plus the per-target
    /// and scale-change growth. Each is capped at what is left when it
    /// starts; a pass after the candidate with less than `floor`
    /// left does not start, and the rollback follows instead.
    ///
    /// The rollbacks are outside it. A rollback is the safety net that puts
    /// every window back, and one cut short stops mid-write with some
    /// windows still on candidate frames under the old tree. Each keeps its
    /// own deadline: 0.75 s plus 80 ms per target past three, or the
    /// scale-change budget when it carries a window back across scales.
    ///
    /// The clock runs from the attempt's start, so a rollback's time counts
    /// against the passes after it, but nothing cuts the rollback itself.
    /// The real worst case for one attempt is the capture before it
    /// (0.36 s), 2 s of passes, and one last rollback on its own deadline,
    /// plus one AX call past each pass's last check (100 ms, 250 ms on the
    /// timeout retry). Eight windows on one scale: 0.36 + 2 + 1.15, about
    /// 3.5 s.
    static let total: TimeInterval = 2.0
    /// The least a pass gets: the candidate is never cut below it, and a
    /// later pass that would be is skipped.
    static let floor: TimeInterval = 0.25

    let started: TimeInterval

    func remaining(at now: TimeInterval) -> TimeInterval {
        Self.total - (now - started)
    }

    /// The candidate always runs, on at least the floor.
    func forCandidate(at now: TimeInterval) -> TimeInterval {
        max(Self.floor, remaining(at: now))
    }

    /// A pass after the candidate: what is left, or nil when that is under
    /// the floor and the pass should not start.
    func forLaterPass(at now: TimeInterval) -> TimeInterval? {
        let left = remaining(at: now)
        return left >= Self.floor ? left : nil
    }
}
