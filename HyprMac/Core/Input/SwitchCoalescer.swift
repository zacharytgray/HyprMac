import Foundation

/// Drops absolute workspace switches that a later queued switch makes
/// pointless. Every hotkey action gets its own main-queue block, and a
/// switch can hold main for seconds, so fast presses pile up and each
/// one would render in full. A queued `switchWorkspace` is skipped when a
/// later one in the same run (no other action pressed in between) targets
/// the same home monitor. Relative and window actions are never dropped
/// and end the run, so nothing they depend on changes.
final class SwitchCoalescer {
    private let lock = NSLock()
    private var seq: UInt64 = 0
    private var run: UInt64 = 0
    private var queued: [(seq: UInt64, run: UInt64, workspace: Int)] = []

    /// Tap thread, once per dispatched action, in press order.
    func enqueue(_ action: Action) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        seq += 1
        if case .switchWorkspace(let n) = action {
            queued.append((seq, run, n))
        } else {
            run += 1
        }
        return seq
    }

    /// Main, when the action's block runs. False = a later queued switch
    /// replaces it. `sameMonitor` reads main-only state, so it runs
    /// outside the lock the tap thread waits on.
    func shouldRun(_ action: Action, token: UInt64, sameMonitor: (Int, Int) -> Bool) -> Bool {
        guard case .switchWorkspace(let n) = action else { return true }
        lock.lock()
        guard let i = queued.firstIndex(where: { $0.seq == token }) else {
            lock.unlock()
            return true
        }
        let mine = queued.remove(at: i)
        let later = queued[i...].filter { $0.run == mine.run }.map(\.workspace)
        lock.unlock()
        return !later.contains { sameMonitor($0, n) }
    }
}
