// One bounded retry for a newcomer a failed admission stranded, then an
// explicit float in place. A refusal that names some of the newcomers floats
// those and gives the rest the pass again, a bounded number of times. A
// retry that times out gets a few more with backoff and then stays tiled,
// unverified, instead of floating. Nothing here routes a window to another
// workspace. Initial count-based assignment is a separate policy.

import Cocoa

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

/// Bounded recovery for windows a failed admission left outside the tree.
///
/// A tiling pass that inserts a new window and is then refused by the screen
/// keeps its prior tree, which means the newcomer is visible, assigned, not
/// floating and in no tree at all. This owns the two steps that finish it:
/// one retry about 250 ms later under a fresh owned context with only the
/// minima recorded *before* that attempt ignored, and, if that is refused
/// too, an explicit float where the window already is.
///
/// A retry refused on some of its newcomers and not all of them — the
/// window that would not take its frame, both of an overlapping pair, the
/// ones the engine turned away before writing — floats those and runs the
/// pass again for the rest without them, up to `narrowingRounds` times.
/// Eight windows opening on a laptop screen used to float as a set because
/// two of them could not share it with anyone. A failure that names an
/// incumbent or nobody says nothing about which newcomer to give up on, so
/// it ends in the ordinary fallback for all of them.
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
    /// One named policy point so the end state is a single line to change.
    /// `.floatInPlace` is the shipped behaviour;
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

    /// How many times one retry may give up on the newcomers a refusal
    /// named and run the pass again for the rest. Every round floats at
    /// least one window, so the loop ends on its own; the bound keeps a key
    /// that refuses every arrangement from turning the recovery into a
    /// visible resize storm. Past it the rest float as before.
    ///
    /// The rounds of one key also share one main-thread budget, see
    /// `sharingOneBudget`. Once it is spent no round starts, and the rest
    /// float the same way.
    var narrowingRounds = 3

    /// Delays between the passes a vacated key gets after its gap-filling
    /// pass failed on an AX error, one entry per pass. Live, the window
    /// that refused its grow took it on a retry 250 ms later.
    var vacatedRetryDelays: [TimeInterval] = [0.25, 0.5, 1.0]
    /// How long a vacated retry waits out a drag or a workspace transition
    /// before it gives up on its pass, in waits of the first delay.
    var vacatedSuspensionWaits = 8

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
    /// Runs every round of one key's retry under one main-thread budget:
    /// the engine's passes inside it draw on it instead of each round
    /// starting its own. Production hands it to the engine.
    var sharingOneBudget: (() -> Void) -> Void = { $0() }
    /// whether that budget has room for another round
    var budgetLeft: () -> Bool = { true }
    var floatInPlace: (HyprWindow, String) -> Void = { _, _ in }
    /// whether the window is in a published tree right now. The fallback
    /// retile, or a newer layout, may have tiled a pending window since the
    /// round gave up on it; floating it then would tear it out of the slot
    /// it just got.
    var isTiled: (CGWindowID) -> Bool = { _ in false }
    /// One ordinary retile of a key whose newcomers the fallback just
    /// floated, so incumbents left out of the refused pass get admitted on
    /// their own. Returns the ids still visible, not floating and in no
    /// tree once it has run.
    var retileAfterFallback: (_ workspace: Int, _ screen: NSScreen) -> Set<CGWindowID> = { _, _ in [] }
    /// Ask the engine to drop the key's unverified mark. It refuses when a
    /// rollback on that key did not verify, so the answer is its to give.
    var clearUnverified: (Int, NSScreen) -> Void = { _, _ in }
    /// One ordinary pass for a key a window left, after the pass that
    /// should have filled the gap failed on an AX error. nil when there was
    /// nothing to lay out.
    var retileVacated: (_ workspace: Int, _ screen: NSScreen) -> TilingEngine.AdmissionResult? = { _, _ in nil }
    /// a drag is in flight or a workspace transition is settling, the
    /// times the drift re-apply also stays out. production hands it the
    /// drift monitor's gate.
    var isLayoutSuspended: () -> Bool = { false }
    var terminalOutcome: (_ workspace: Int, _ screen: NSScreen,
                          _ result: TilingEngine.AdmissionResult?) -> Void = { _, _, _ in }

    // MARK: - state

    private var records: [CGWindowID: Record] = [:]

    /// A vacated key waiting on its next pass, by workspace.
    private struct VacatedRetry {
        let screen: NSScreen
        /// passes run so far
        var attempts = 0
        /// times it found layout suspended and waited
        var waits = 0
        /// tells a timer still in flight that this retry is not its own
        var token: UInt64
    }
    private var vacatedRetries: [Int: VacatedRetry] = [:]
    private var vacatedToken: UInt64 = 0
    /// set while a vacated retry's own pass runs, so the pass reporting
    /// back through `note` does not arm a second one
    private var runningVacatedRetry = false
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

        noteVacated(result)

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
    /// `ActionPolicy.cancelsPendingRecovery`.
    func cancelAll(reason: String) {
        if !vacatedRetries.isEmpty {
            hyprLog(.notice, .tiling, "vacated layout retry cancelled: ws\(vacatedRetries.keys.sorted()) reason=\(reason)")
            vacatedRetries.removeAll()
        }
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

    // MARK: - a key a window left

    /// A pass on a key a window just left (closed, hidden, moved away) that
    /// failed on an AX error rolled the neighbours back over the gap, and
    /// no event that follows lays the key out again: the drift check skips
    /// an unverified key and the admission retry only tracks newcomers. So
    /// the key gets a few ordinary passes of its own, with backoff. A
    /// geometric refusal gets none — the window answered, and the same
    /// frames would only be refused again. A pass that also stranded a
    /// newcomer is left to the newcomer's retry, so two timers never lay
    /// out one key; that retry does not come back here if it fails too.
    private func noteVacated(_ result: TilingEngine.AdmissionResult) {
        guard !runningVacatedRetry else { return }
        if result.published {
            if vacatedRetries.removeValue(forKey: result.workspace) != nil {
                hyprLog(.notice, .tiling, "vacated layout retry settled: ws\(result.workspace) — another pass filled it")
            }
            return
        }
        guard result.vacated, let failure = result.failure, failure.isAXFailure,
              result.strandedIDs.isEmpty, vacatedRetries[result.workspace] == nil,
              let delay = vacatedRetryDelays.first else { return }
        vacatedToken &+= 1
        vacatedRetries[result.workspace] = VacatedRetry(screen: result.screen, token: vacatedToken)
        hyprLog(.notice, .tiling, "vacated layout retry scheduled: ws\(result.workspace)"
                + " in \(Int((delay * 1000).rounded()))ms cause=\(failure.trace)")
        armVacated(result.workspace, after: delay)
    }

    private func armVacated(_ workspace: Int, after delay: TimeInterval) {
        guard let armed = vacatedRetries[workspace]?.token else { return }
        schedule(delay) { [weak self] in
            guard let self, self.vacatedRetries[workspace]?.token == armed else { return }
            self.runVacated(workspace)
        }
    }

    private func runVacated(_ workspace: Int) {
        guard var retry = vacatedRetries[workspace] else { return }
        // a key that is not on screen now gets its pass when it is shown, and
        // a display change retiles every key once it settles
        let dropped: String?
        if !isWorkspaceVisible(workspace) {
            dropped = "workspace hidden"
        } else if homeScreenForWorkspace(workspace) != retry.screen {
            dropped = "screen changed"
        } else if isDisplayTransitionPending() {
            dropped = "display transition"
        } else if isSessionInterrupted() {
            dropped = "session interrupted"
        } else {
            dropped = nil
        }
        if let dropped {
            vacatedRetries.removeValue(forKey: workspace)
            hyprLog(.notice, .tiling, "vacated layout retry dropped: ws\(workspace) — \(dropped)")
            return
        }
        // a drag or a move's transition is still settling. a pass now would
        // write under the user's hand or read stale frames
        if isLayoutSuspended() {
            guard retry.waits < vacatedSuspensionWaits, let wait = vacatedRetryDelays.first else {
                vacatedRetries.removeValue(forKey: workspace)
                hyprLog(.notice, .tiling, "vacated layout retry dropped: ws\(workspace) — layout stayed suspended")
                return
            }
            retry.waits += 1
            vacatedToken &+= 1
            retry.token = vacatedToken
            vacatedRetries[workspace] = retry
            armVacated(workspace, after: wait)
            return
        }
        retry.attempts += 1
        runningVacatedRetry = true
        let result = retileVacated(workspace, retry.screen)
        runningVacatedRetry = false
        guard let result, !result.published, result.vacated, result.strandedIDs.isEmpty,
              let failure = result.failure, failure.isAXFailure else {
            vacatedRetries.removeValue(forKey: workspace)
            hyprLog(.notice, .tiling, "vacated layout retry \(retry.attempts): ws\(workspace) "
                    + (result?.failure.map { "ended: \($0.trace)" } ?? "filled the gap"))
            return
        }
        guard retry.attempts < vacatedRetryDelays.count else {
            vacatedRetries.removeValue(forKey: workspace)
            hyprLog(.notice, .tiling, "vacated layout retry gave up: ws\(workspace) after"
                    + " \(retry.attempts) passes cause=\(failure.trace)")
            return
        }
        let delay = vacatedRetryDelays[retry.attempts]
        vacatedToken &+= 1
        retry.token = vacatedToken
        vacatedRetries[workspace] = retry
        hyprLog(.notice, .tiling, "vacated layout retry \(retry.attempts) failed: ws\(workspace)"
                + " cause=\(failure.trace) — again in \(Int((delay * 1000).rounded()))ms")
        armVacated(workspace, after: delay)
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
            var bypass = entry.bypass
            var narrowings = 0
            var lastAdmission: TilingEngine.AdmissionResult?
            // every round of this key shares one main-thread budget
            sharingOneBudget {
                while true {
                    let trace = bypass.keys.sorted().map { "\($0):\(bypass[$0]!)" }
                        .joined(separator: ",")
                    hyprLog(.notice, .tiling, "admission retry attempt: ws\(workspace)"
                            + " bypassMinimaBefore=[\(trace)]"
                            + (entry.keepOnTimeout ? " keepOnTimeout=true" : "")
                            + (narrowings > 0 ? " narrowed=\(narrowings)" : ""))
                    let result = attempt(workspace, entry.screen, bypass, entry.keepOnTimeout)
                    lastAdmission = result.admission
                    // a newcomer the fit check turned away was refused, whatever the
                    // rest of the pass then ran into
                    let refused = result.admission?.refusedIDs ?? []
                    for id in bypass.keys.sorted() where result.placed.contains(id) {
                        resolvePlaced(id, failure: result.failure, keepOnTimeout: entry.keepOnTimeout)
                    }
                    let waiting = Set(bypass.keys).subtracting(result.placed)
                    if narrowings < narrowingRounds,
                       let giveUp = Self.narrowing(of: waiting, refused: refused, failure: result.failure),
                       roomForAnotherRound(workspace) {
                        // the refusal names some of the newcomers still waiting
                        // and not all of them: those float now, and the rest get
                        // the pass again without them
                        narrowings += 1
                        hyprLog(.notice, .tiling, "admission recovery narrowed: floating \(Self.list(giveUp))"
                                + " ws\(workspace) cause=\(Self.text(result.failure))"
                                + " — retrying \(Self.list(waiting.subtracting(giveUp))) without them"
                                + " (round \(narrowings) of \(narrowingRounds))")
                        for id in giveUp.sorted() {
                            // a newcomer the engine dropped pre-write floats for
                            // its own reason, not the pass's
                            let cause: FrameSizingFailure? = refused.contains(id) ? .noFittingSlot(id) : result.failure
                            if finish(id, retryFailure: cause) { floated[workspace] = entry.screen }
                        }
                        bypass = bypass.filter { waiting.contains($0.key) && !giveUp.contains($0.key) }
                        continue
                    }
                    var timedOut: Set<CGWindowID> = []
                    var keyBackoff: TimeInterval?
                    for id in waiting.sorted() {
                        if !refused.contains(id),
                           let delay = rearmAfterTimeout(id, failure: result.failure) {
                            timedOut.insert(id)
                            keyBackoff = min(keyBackoff ?? delay, delay)
                        } else if let failure = result.failure, failure.isTimeout, !refused.contains(id) {
                            // the last retry timed out before every window got its
                            // whole frame, so the engine had nothing to keep tiled.
                            // a timeout still does not float anything
                            holdUnanswered(id, workspace: workspace, failure: failure)
                        } else if finish(id, retryFailure: refused.contains(id) ? .noFittingSlot(id) : result.failure) {
                            floated[workspace] = entry.screen
                        }
                    }
                    if let keyBackoff {
                        backoff = min(backoff ?? keyBackoff, keyBackoff)
                        hyprLog(.notice, .tiling, "admission retry timed out: ids=\(Self.list(timedOut))"
                                + " ws\(workspace) cause=\(Self.text(result.failure))"
                                + " — not a refusal, retrying in \(Int((keyBackoff * 1000).rounded()))ms")
                    }
                    break
                }
            }
            let settled = entry.bypass.keys.allSatisfy {
                records[$0] == nil || records[$0]?.phase == .held
            }
            if settled, floated[workspace] == nil {
                terminalOutcome(workspace, entry.screen, lastAdmission)
            }
        }
        if let backoff { arm(after: backoff) }

        for (workspace, screen) in floated.sorted(by: { $0.key < $1.key }) {
            retileWhatIsLeft(workspace, screen)
        }
    }

    /// Whether the budget the rounds share has room for another one. Says
    /// so when it has not: the newcomers still waiting take the ordinary
    /// fallback, as past `narrowingRounds`.
    private func roomForAnotherRound(_ workspace: Int) -> Bool {
        guard !budgetLeft() else { return true }
        hyprLog(.notice, .tiling, "admission recovery stops narrowing: ws\(workspace)"
                + " — the rounds' main-thread budget is spent")
        return false
    }

    /// The retry left `id` in the published tree. Resolved, with the log
    /// line saying how it got there.
    private func resolvePlaced(_ id: CGWindowID, failure: FrameSizingFailure?, keepOnTimeout: Bool) {
        if let failure, failure.isTimeout, keepOnTimeout {
            // placed without an accepted layout: the last retry timed out
            // and the engine kept the tile unverified
            resolve(id, reason: "kept tiled unverified after"
                    + " \((records[id]?.timeouts ?? 0) + 1) timed-out retries,"
                    + " last=\(failure)")
        } else if let failure {
            resolve(id, reason: "in the tree although the retry failed (\(failure))")
        } else {
            resolve(id, reason: "retry tiled it")
        }
    }

    /// The newcomers a refused retry gives up on while the rest get the
    /// pass again: the ones the failure names, plus the ones the engine
    /// refused pre-write. Nil when the failure names none of the waiting
    /// newcomers — an incumbent refused, or nobody did, as in a timeout —
    /// and nil when giving them up would leave nothing to retry. Both end
    /// in the ordinary fallback.
    static func narrowing(of waiting: Set<CGWindowID>, refused: Set<CGWindowID>,
                          failure: FrameSizingFailure?) -> Set<CGWindowID>? {
        guard let failure, !failure.isTimeout else { return nil }
        let named = failure.namedWindowIDs.intersection(waiting)
        guard !named.isEmpty else { return nil }
        let giveUp = named.union(refused.intersection(waiting))
        return giveUp.count < waiting.count ? giveUp : nil
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
        if isTiled(id) {
            resolve(id, reason: "tiled meanwhile")
            return false
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
