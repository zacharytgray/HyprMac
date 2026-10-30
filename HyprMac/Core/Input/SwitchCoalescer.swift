import Foundation

/// Folds queued workspace switches that a later queued press makes
/// pointless. Every hotkey action gets its own main-queue block, and a
/// switch can hold main for seconds, so fast presses pile up and each
/// one would render in full. A run is a stretch of queued presses of one
/// kind with no other action in between:
/// - `switchWorkspace`: skipped when a later switch in the run targets the
///   same home monitor.
/// - `cycleWorkspace`: every press but the last is skipped and the last
///   runs with the summed delta. A sign change ends the run, because from
///   an empty workspace `+1 −1` lands on the previous occupied one while a
///   net `0` would stay put.
/// Switches end a cycle run and cycles end a switch run (a cycle counts
/// from the current workspace). Window actions are never dropped.
final class SwitchCoalescer {
    private enum Kind: Equatable { case switchTo, cycleNext, cyclePrevious }

    private let lock = NSLock()
    private var seq: UInt64 = 0
    private var run: UInt64 = 0
    private var lastKind: Kind?
    // value = target workspace for a switch, delta for a cycle
    private var queued: [(seq: UInt64, run: UInt64, value: Int, merged: Int)] = []

    private static func kind(_ action: Action) -> (Kind, Int)? {
        switch action {
        case .switchWorkspace(let n): return (.switchTo, n)
        // only the UI's ±1 merge, so the sum is bounded by the press count
        case .cycleWorkspace(1): return (.cycleNext, 1)
        case .cycleWorkspace(-1): return (.cyclePrevious, -1)
        default: return nil
        }
    }

    /// Tap thread, once per dispatched action, in press order.
    func enqueue(_ action: Action) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        seq += 1
        let k = Self.kind(action)
        if k == nil || k?.0 != lastKind { run += 1 }
        lastKind = k?.0
        if let k { queued.append((seq, run, k.1, 1)) }
        return seq
    }

    /// Main, when the action's block runs. Nil = a later queued press
    /// replaces it; otherwise the action to dispatch and how many presses
    /// it stands for. `sameMonitor` reads main-only state, so it runs
    /// outside the lock the tap thread waits on.
    func admit(_ action: Action, token: UInt64,
               sameMonitor: (Int, Int) -> Bool) -> (action: Action, merged: Int)? {
        lock.lock()
        guard let i = queued.firstIndex(where: { $0.seq == token }) else {
            lock.unlock()
            return (action, 1)
        }
        let mine = queued.remove(at: i)
        if case .cycleWorkspace = action {
            // the token was queued, so this is a ±1 cycle
            defer { lock.unlock() }
            if let j = queued[i...].firstIndex(where: { $0.run == mine.run }) {
                queued[j].value += mine.value
                queued[j].merged += mine.merged
                return nil
            }
            return (.cycleWorkspace(mine.value), mine.merged)
        }
        let later = queued[i...].filter { $0.run == mine.run }.map(\.value)
        lock.unlock()
        return later.contains { sameMonitor($0, mine.value) } ? nil : (action, 1)
    }
}
