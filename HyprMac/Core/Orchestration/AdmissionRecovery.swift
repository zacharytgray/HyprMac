// One bounded retry for a newcomer a failed admission stranded, then an
// explicit float in place. A retry that times out gets a few more with
// backoff and then stays tiled, unverified, instead of floating. Nothing
// here routes a window to another workspace. Initial count-based
// assignment is a separate policy.

import Cocoa

/// Bounded recovery for windows a failed admission left outside the tree.
///
/// A tiling pass that inserts a new window and is then refused by the screen
/// keeps its prior tree, which means the newcomer is visible, assigned, not
/// floating and in no tree at all. This owns the two steps that finish it:
/// one retry about 250 ms later under a fresh owned context with only the
/// minima recorded *before* that attempt ignored, and, if that is refused
/// too, an explicit float where the window already is.
///
/// A retry that times out was not refused: the app did not answer in time.
/// It gets up to `timeoutRetryDelays.count` more retries with backoff, and
/// the last one keeps the window tiled with its key marked unverified.
///
/// Once a workspace's newcomers are floated the key gets one ordinary
/// retile, so incumbents the refused pass left out of the tree are admitted
/// on their own. Anything that retile still leaves visible, nonfloating and
/// in no tree is held: an explicit record with no timer and no float.
///
/// The retry never re-arms itself except after a timeout, and that is
/// bounded by `timeoutRetryDelays`. A window that is unreadable or on a
/// hidden workspace when its turn comes, or whose turn comes while the
/// session is locked or the displays sleep, keeps its place in the pending
/// set and waits for a real discovery or activation event instead of a new
/// timer, so nothing spins and no frame is invented.
///
/// One admission pass for a key, plus the bookkeeping every pass owes.
///
/// Both production retiles run through here — the ordinary per-screen retile
/// and the drift monitor's re-apply — so a pass that strands a window always
/// reaches the recovery, and a revalidation marker the pass consumed is
/// always spent. A retile that reported neither used to leave a stranded
/// window untracked.
struct AdmissionPass {
    let engine: TilingEngine
    let revalidation: MinimaRevalidation
    let recovery: AdmissionRecovery

    @discardableResult
    func run(_ windows: [HyprWindow], onWorkspace workspace: Int,
             screen: NSScreen) -> TilingEngine.AdmissionResult {
        // only windows this pass can actually judge. one that AX did not
        // return keeps its marker rather than spending it on a pass that was
        // never going to look at it.
        let incoming = revalidation.incomingIDs(forWorkspace: workspace, screen: screen)
            .intersection(windows.map(\.windowID))
        let result = incoming.isEmpty
            ? engine.tileWindows(windows, onWorkspace: workspace, screen: screen)
            : engine.revalidateAdmission(windows, incoming: incoming,
                                         onWorkspace: workspace, screen: screen)
        revalidation.noteReveal(incoming, accepted: result.publishedIDs)
        recovery.note(result)
        return result
    }
}

/// Threading: main-thread only.
final class AdmissionRecovery {

    /// What a pending window is waiting for.
    enum Phase: Equatable {
        /// its one retry is armed.
        case awaitingRetry
        /// the window could not be judged when its turn came — unreadable,
        /// its workspace was hidden, the screens were mid-reconfiguration,
        /// or the session was locked or asleep. No timer is running for it.
        case awaitingEvidence
        /// visible, not floating, and in no tree even after the fallback's
        /// ordinary retile. No timer and no float — an explicit record, so
        /// every visible nonfloating window is either a verified tile or a
        /// recovery member, and the state dump shows which.
        case held
    }

    /// Where a newcomer ends up when the retry cannot tile it.
    ///
    /// One named policy point so the end state is a single line to change
    /// once Zach picks one. `.floatInPlace` is the shipped behaviour;
    /// `.routeToFittingWorkspace` is not wired, and the fallback still
    /// floats so no window is ever left untracked.
    enum Outcome: String {
        case floatInPlace
        case routeToFittingWorkspace
    }

    /// The end state for a newcomer the retry could not tile.
    var outcome: Outcome = .floatInPlace

    /// Backoff after a retry that timed out, one entry per extra retry. A
    /// timeout says the app did not answer in time, not that it refused the
    /// frames, so it earns another try instead of the float a refusal gets.
    /// The last retry runs with `keepOnTimeout`: if the app still does not
    /// answer, the engine keeps the window tiled and marks the key
    /// unverified. So a timeout never floats a window.
    var timeoutRetryDelays: [TimeInterval] = [0.5, 1.0]

    /// What one recovery attempt found out.
    struct AttemptResult {
        /// newcomers the attempt left in the published tree.
        var placed: Set<CGWindowID> = []
        /// why the attempt was refused, for the fallback log line.
        var failure: FrameSizingFailure?
        var admission: TilingEngine.AdmissionResult? = nil
    }

    private struct Record {
        let workspace: Int
        let screen: NSScreen
        /// generation of the admission. The retry ignores observed minima
        /// recorded before it for this window, and honours what the
        /// admission itself learned.
        let sinceGeneration: UInt64
        /// the admission's own failure, kept for the fallback log line.
        let firstFailure: FrameSizingFailure?
        var phase: Phase
        /// the one attempt has been spent.
        var attempted = false
        /// retries that timed out so far. each one bought another retry,
        /// up to `timeoutRetryDelays.count`.
        var timeouts = 0
    }

    // MARK: - seams

    /// Injected so tests can drive the delay. Production hands it to the
    /// main queue.
    var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, body in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
    }
    var retryDelay: TimeInterval = 0.25

    // context probes, all re-checked at fire time
    var workspaceFor: (CGWindowID) -> Int? = { _ in nil }
    var homeScreenForWorkspace: (Int) -> NSScreen? = { _ in nil }
    var isWorkspaceVisible: (Int) -> Bool = { _ in false }
    var isFloating: (CGWindowID) -> Bool = { _ in false }
    /// the live window, or nil when it is gone or its app is not running.
    var liveWindow: (CGWindowID) -> HyprWindow? = { _ in nil }
    /// whether AX can still tell us where the window is.
    var isReadable: (HyprWindow) -> Bool = { $0.frame != nil }
    /// screens are mid-reconfiguration. Tiling anything now builds trees at
    /// keys that are about to move, so the retry waits like the ordinary
    /// retile does.
    var isDisplayTransitionPending: () -> Bool = { false }
    /// the session is locked, the displays sleep, or the user session is
    /// switched out. the window list is partial then, so an attempt from it
    /// would lay the key out without the windows it is missing. the retry
    /// waits for the first poll after the span ends.
    var isSessionInterrupted: () -> Bool = { false }

    // actions
    /// `bypass` maps each newcomer to the generation below which the
    /// attempt must ignore its observed minima. `keepOnTimeout` marks the
    /// last retry a timeout can buy: a pass that times out under it keeps
    /// the window tiled with its key marked unverified.
    var attempt: (_ workspace: Int, _ screen: NSScreen,
                  _ bypass: [CGWindowID: UInt64],
                  _ keepOnTimeout: Bool) -> AttemptResult = { _, _, _, _ in AttemptResult() }
    var floatInPlace: (HyprWindow, String) -> Void = { _, _ in }
    /// One ordinary retile of a key whose newcomers the fallback just
    /// floated, so incumbents left out of the refused pass get admitted on
    /// their own. Returns the ids still visible, not floating and in no
    /// tree once it has run.
    var retileAfterFallback: (_ workspace: Int, _ screen: NSScreen) -> Set<CGWindowID> = { _, _ in [] }
    /// Ask the engine to drop the key's unverified mark. It refuses when a
    /// rollback on that key did not verify, so the answer is its to give.
    var clearUnverified: (Int, NSScreen) -> Void = { _, _ in }
    var terminalOutcome: (_ workspace: Int, _ screen: NSScreen,
                          _ result: TilingEngine.AdmissionResult?) -> Void = { _, _, _ in }

    // MARK: - state

    private var records: [CGWindowID: Record] = [:]
    /// bumped by every cancellation, so a timer already in flight finds a
    /// stale token and does nothing.
    private var token: UInt64 = 0

    /// Windows waiting on a bounded recovery attempt or on the evidence to
    /// finish one. The state dump's `recovery pending=`.
    var pendingWindowIDs: Set<CGWindowID> { Set(records.keys) }

    func phase(of windowID: CGWindowID) -> Phase? { records[windowID]?.phase }
    func hasActiveRetry(workspace: Int, screen: NSScreen) -> Bool {
        records.values.contains {
            $0.workspace == workspace && $0.screen == screen && $0.phase == .awaitingRetry
        }
    }

    // MARK: - admission reporting

    /// React to one tiling pass.
    ///
    /// A newcomer that made it into the published tree is finished. One that
    /// did not is stranded, and gets its retry armed unless it is already
    /// pending — the bound is one attempt per window, not one per pass. A
    /// window a bypassed pass refused outright is stranded too: nothing
    /// routed it, because routing inside such a pass would decide with the
    /// bounds the pass is ignoring.
    func note(_ result: TilingEngine.AdmissionResult) {
        // the scratchpad layer runs its own recovery and must never enter
        // this path
        guard result.workspace != TilingEngine.scratchpadWorkspace else { return }

        for id in result.publishedIDs where records[id] != nil {
            resolve(id, reason: "tiled")
        }

        let stranded = result.strandedIDs.filter { records[$0] == nil }
        guard !stranded.isEmpty else { return }
        for id in stranded {
            records[id] = Record(workspace: result.workspace, screen: result.screen,
                                 sinceGeneration: result.generation,
                                 firstFailure: result.failure,
                                 phase: .awaitingRetry,
                                 attempted: result.refusedIDs.contains(id))
        }
        let judged = stranded.filter { result.refusedIDs.contains($0) }
        let retrying = stranded.subtracting(judged)
        if !retrying.isEmpty {
            hyprLog(.notice, .tiling,
                    Self.strandedLog(ids: retrying, workspace: result.workspace,
                                     retryIn: Int(retryDelay * 1000), cause: result.failure))
        }
        if !judged.isEmpty {
            hyprLog(.notice, .tiling,
                    Self.strandedLog(ids: judged, workspace: result.workspace,
                                     retryIn: nil, cause: result.failure))
        }
        arm()
    }

    // MARK: - cancellation

    /// Drop `windowID` from recovery. Used for the user's own later actions:
    /// a float, a workspace move, a close.
    /// Dropping the record is the cancellation: the armed timer works off
    /// `records`, so an id that is no longer there gets no attempt, and the
    /// windows still waiting keep the timer they were promised.
    func cancel(_ windowID: CGWindowID, reason: String) {
        guard records.removeValue(forKey: windowID) != nil else { return }
        hyprLog(.notice, .tiling, "admission retry cancelled: ids=[\(windowID)] reason=\(reason)")
    }

    /// Drop everything. Used for a stop, a display change, and a later key
    /// press that changes membership, all of which make the captured context
    /// stale. Resize, swap and split toggle do not: see
    /// `WindowManager.cancelsPendingRecovery`.
    func cancelAll(reason: String) {
        guard !records.isEmpty else { return }
        let ids = Set(records.keys)
        records.removeAll()
        token &+= 1
        hyprLog(.notice, .tiling, "admission retry cancelled: ids=\(Self.list(ids)) reason=\(reason)")
    }

    /// The window is gone. Ordinary cleanup, no log of its own — the
    /// lifecycle path already says the window went away.
    func forget(_ windowID: CGWindowID) {
        records.removeValue(forKey: windowID)
    }

    private func resolve(_ windowID: CGWindowID, reason: String) {
        guard records.removeValue(forKey: windowID) != nil else { return }
        hyprLog(.notice, .tiling, "admission recovery resolved: \(windowID) (\(reason))")
    }

    // MARK: - the one retry

    private func arm(after delay: TimeInterval? = nil) {
        token &+= 1
        let armed = token
        schedule(delay ?? retryDelay) { [weak self] in
            guard let self, self.token == armed else { return }
            self.run(ids: self.records.filter { $0.value.phase == .awaitingRetry }.map(\.key))
        }
    }

    /// A discovery or activation event said something new about `windowID`.
    /// The only thing that moves a window out of `awaitingEvidence`.
    func noteEvidence(for windowID: CGWindowID) {
        guard records[windowID]?.phase == .awaitingEvidence else { return }
        run(ids: [windowID])
    }

    private func run(ids: [CGWindowID]) {
        var byKey: [Int: (screen: NSScreen, bypass: [CGWindowID: UInt64], keepOnTimeout: Bool)] = [:]
        var floated: [Int: NSScreen] = [:]
        for id in ids.sorted() {
            guard let record = records[id] else { continue }
            switch readiness(id, record: record) {
            case .gone:
                forget(id)
            case let .userActed(reason):
                cancel(id, reason: reason)
            case .notYet:
                hold(id)
            case .ready:
                guard !record.attempted else {
                    // its one attempt is spent; the evidence only unblocks
                    // the verdict
                    if finish(id, retryFailure: nil) { floated[record.workspace] = record.screen }
                    continue
                }
                var entry = byKey[record.workspace]
                    ?? (screen: record.screen, bypass: [:], keepOnTimeout: false)
                entry.bypass[id] = record.sinceGeneration
                // a newcomer on its last timeout retry decides for the key:
                // one sharing the pass is tiled unverified a little early,
                // which is still not a float
                entry.keepOnTimeout = entry.keepOnTimeout
                    || record.timeouts >= timeoutRetryDelays.count
                byKey[record.workspace] = entry
            }
        }

        var backoff: TimeInterval?
        for (workspace, entry) in byKey.sorted(by: { $0.key < $1.key }) {
            for id in entry.bypass.keys { records[id]?.attempted = true }
            let trace = entry.bypass.keys.sorted().map { "\($0):\(entry.bypass[$0]!)" }
                .joined(separator: ",")
            hyprLog(.notice, .tiling, "admission retry attempt: ws\(workspace)"
                    + " bypassMinimaBefore=[\(trace)]"
                    + (entry.keepOnTimeout ? " keepOnTimeout=true" : ""))
            let result = attempt(workspace, entry.screen, entry.bypass, entry.keepOnTimeout)
            // a newcomer the fit check turned away was refused, whatever the
            // rest of the pass then ran into
            let refused = result.admission?.refusedIDs ?? []
            var timedOut: Set<CGWindowID> = []
            var keyBackoff: TimeInterval?
            for id in entry.bypass.keys.sorted() {
                if result.placed.contains(id) {
                    if let failure = result.failure, failure.isTimeout, entry.keepOnTimeout {
                        // placed without an accepted layout: the last retry
                        // timed out and the engine kept the tile unverified
                        resolve(id, reason: "kept tiled unverified after"
                                + " \((records[id]?.timeouts ?? 0) + 1) timed-out retries,"
                                + " last=\(failure)")
                    } else if let failure = result.failure {
                        resolve(id, reason: "in the tree although the retry failed (\(failure))")
                    } else {
                        resolve(id, reason: "retry tiled it")
                    }
                } else if !refused.contains(id),
                          let delay = rearmAfterTimeout(id, failure: result.failure) {
                    timedOut.insert(id)
                    keyBackoff = min(keyBackoff ?? delay, delay)
                } else if let failure = result.failure, failure.isTimeout, !refused.contains(id) {
                    // the last retry timed out before every window got its
                    // whole frame, so the engine had nothing to keep tiled.
                    // a timeout still does not float anything
                    holdUnanswered(id, workspace: workspace, failure: failure)
                } else if finish(id, retryFailure: result.failure) {
                    floated[workspace] = entry.screen
                }
            }
            if let keyBackoff {
                backoff = min(backoff ?? keyBackoff, keyBackoff)
                hyprLog(.notice, .tiling, "admission retry timed out: ids=\(Self.list(timedOut))"
                        + " ws\(workspace) cause=\(Self.text(result.failure))"
                        + " — not a refusal, retrying in \(Int((keyBackoff * 1000).rounded()))ms")
            }
            let settled = entry.bypass.keys.allSatisfy {
                records[$0] == nil || records[$0]?.phase == .held
            }
            if settled, floated[workspace] == nil {
                terminalOutcome(workspace, entry.screen, result.admission)
            }
        }
        if let backoff { arm(after: backoff) }

        for (workspace, screen) in floated.sorted(by: { $0.key < $1.key }) {
            retileWhatIsLeft(workspace, screen)
        }
    }

    /// The last retry timed out before every window got its whole frame, so
    /// there was no tile to keep. Hold it: an explicit record with no timer
    /// and no float, released when a later layout tiles it, exactly like an
    /// incumbent the fallback retile could not place. Any later pass on the
    /// key that tiles it will do: it is a newcomer to every one of them.
    private func holdUnanswered(_ id: CGWindowID, workspace: Int, failure: FrameSizingFailure) {
        guard var record = records[id] else { return }
        record.phase = .held
        record.attempted = true
        records[id] = record
        hyprLog(.notice, .tiling, "admission recovery held: ids=[\(id)] ws\(workspace)"
                + " — last retry timed out without a complete write (\(failure)); in no tree, not floated")
    }

    /// Give a retry that timed out another one later, while the bound lasts.
    /// A timeout is the app not answering, not the app refusing, so it does
    /// not earn the float a refusal gets.
    /// - Returns: the delay to arm, or nil when the failure is not a timeout
    ///   or the bound is spent.
    private func rearmAfterTimeout(_ id: CGWindowID, failure: FrameSizingFailure?) -> TimeInterval? {
        guard let failure, failure.isTimeout, var record = records[id],
              record.timeouts < timeoutRetryDelays.count else { return nil }
        let delay = timeoutRetryDelays[record.timeouts]
        record.timeouts += 1
        record.attempted = false
        record.phase = .awaitingRetry
        records[id] = record
        return delay
    }

    /// Give a key one ordinary retile once the fallback has floated its
    /// newcomers, so incumbents the refused pass left out get admitted on
    /// their own. A returned incumbent whose node was pruned while it was
    /// hidden is in no tree and is not floating, so without this nothing
    /// tracks it at all.
    ///
    /// Whatever the retile still leaves out is held: no timer, no float,
    /// just an explicit record, so every visible nonfloating window is
    /// either a verified tile or a recovery member.
    private func retileWhatIsLeft(_ workspace: Int, _ screen: NSScreen) {
        let held = retileAfterFallback(workspace, screen).filter { records[$0] == nil }
        guard !held.isEmpty else {
            terminalOutcome(workspace, screen, nil)
            return
        }
        for id in held {
            records[id] = Record(workspace: workspace, screen: screen,
                                 sinceGeneration: 0, firstFailure: nil,
                                 phase: .held, attempted: true)
        }
        hyprLog(.notice, .tiling, "admission recovery held: ids=\(Self.list(held))"
                + " ws\(workspace) — in no tree, not floated")
        terminalOutcome(workspace, screen, nil)
    }

    private enum Readiness {
        case ready
        case notYet
        case userActed(String)
        case gone
    }

    private func readiness(_ id: CGWindowID, record: Record) -> Readiness {
        guard let window = liveWindow(id) else { return .gone }
        guard !isDisplayTransitionPending() else { return .notYet }
        guard !isSessionInterrupted() else { return .notYet }
        guard workspaceFor(id) == record.workspace else { return .userActed("moved workspace") }
        guard homeScreenForWorkspace(record.workspace) == record.screen else {
            return .userActed("screen changed")
        }
        guard !isFloating(id) else { return .userActed("user floated it") }
        guard isWorkspaceVisible(record.workspace) else { return .notYet }
        guard isReadable(window) else { return .notYet }
        return .ready
    }

    /// Park a window that could not be judged. No new timer: the plan is to
    /// wait for evidence, and a renewing timer is how a recovery turns into
    /// a spin.
    private func hold(_ id: CGWindowID) {
        guard records[id]?.phase != .awaitingEvidence else { return }
        records[id]?.phase = .awaitingEvidence
        hyprLog(.notice, .tiling, "admission recovery pending: \(id) not judgeable yet — waiting for evidence")
        if let record = records[id] {
            terminalOutcome(record.workspace, record.screen, nil)
        }
    }

    /// Second failure. A readable visible newcomer is left floating exactly
    /// where it is; it is not sent anywhere.
    /// - Returns: whether it actually floated the window.
    @discardableResult
    private func finish(_ id: CGWindowID, retryFailure: FrameSizingFailure?) -> Bool {
        guard let record = records[id] else { return false }
        switch readiness(id, record: record) {
        case .gone:
            forget(id)
            return false
        case let .userActed(reason):
            cancel(id, reason: reason)
            return false
        case .notYet:
            hold(id)
            return false
        case .ready:
            break
        }
        guard let window = liveWindow(id) else { forget(id); return false }
        let cause = "first=\(Self.text(record.firstFailure)) retry=\(Self.text(retryFailure))"
        if outcome == .routeToFittingWorkspace {
            // not wired. nothing here can pick a workspace, and inventing a
            // router inside the fallback is how a refusal turns into a move
            // the user never asked for.
            hyprLog(.notice, .tiling, "admission recovery policy routeToFittingWorkspace"
                    + " is not wired — floating \(id) in place instead")
        }
        hyprLog(.notice, .tiling, "admission recovery fallback: policy=\(outcome.rawValue)"
                + " floated \(id) in place on ws\(record.workspace) \(cause)")
        floatInPlace(window, cause)
        records.removeValue(forKey: id)
        // the key may be able to speak for itself again now that nothing is
        // waiting on it. the engine decides: it saw every attempt that marked
        // the key, and this recovery only saw two of them.
        clearUnverified(record.workspace, record.screen)
        return true
    }

    /// How `note` describes one group of stranded windows. A window a pass
    /// already judged with the bounds it was told to ignore gets no retry,
    /// so its line must not claim one is scheduled.
    static func strandedLog(ids: Set<CGWindowID>, workspace: Int,
                            retryIn delayMS: Int?, cause: FrameSizingFailure?) -> String {
        let head: String
        if let delayMS {
            head = "admission retry scheduled: ids=\(list(ids)) ws\(workspace) in \(delayMS)ms"
        } else {
            head = "admission refusal judged: ids=\(list(ids)) ws\(workspace)"
                + " — floating in place at the next turn"
        }
        return head + " cause=\(text(cause))"
    }

    private static func list(_ ids: Set<CGWindowID>) -> String {
        "[" + ids.sorted().map(String.init).joined(separator: ", ") + "]"
    }

    private static func text(_ failure: FrameSizingFailure?) -> String {
        failure.map { "\($0)" } ?? "none"
    }
}
