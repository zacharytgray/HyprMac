// Follow-up polls for a window an app announced that no poll has admitted
// yet, and the on-screen evidence that says one is still out there.

import CoreGraphics
import Foundation

/// After a window create (or a focus event that shows an unseen window),
/// the first poll can run before AX lists the window or answers for its
/// frame. Nothing else asks again: the next event or the 10 s reconcile
/// did. A watch keeps asking on a short backoff until a poll admits a
/// window of that app or the budget runs out.
///
/// Evidence comes from the window server: an on-screen layer-0 window of
/// the app that discovery does not know. The first retry after a create
/// is blind, since the window may not be on screen yet; later ones need
/// that evidence. A focus or main-window event triggers a poll only for an
/// unknown window no poll has walked past yet, so a window discovery
/// rejects (a dialog, an excluded app) costs one poll, not one per focus.
///
/// A window a watch spent its whole budget on is no evidence for the next
/// watch while it stays on screen. Safari keeps two layer-0 windows up
/// that AX never lists, and sends a create for every popover; each of
/// those used to cost the create poll and three retries, four walks of
/// the desktop for a window that was never coming.
///
/// Pure: the caller supplies the clock and the window list.
struct DiscoveryFollowUp {
    /// waits before each retry, from the poll that missed
    static let backoff: [TimeInterval] = [0.3, 0.6, 1.2]
    /// a poll this soon after the event was already pending when it came.
    /// the trailing poll the event asked for is its first real look
    static let minimumLook: TimeInterval = 0.15
    /// smaller on-screen windows are not counted as evidence
    static let minimumSide: CGFloat = 40

    struct Watch: Equatable {
        let pid: pid_t
        let reason: String
        let since: TimeInterval
        var retries = 0
        /// a create gets one retry without on-screen evidence
        let blindRetry: Bool
    }

    enum Outcome: Equatable {
        case admitted(pid: pid_t, windowIDs: [CGWindowID], afterMS: Int, retries: Int, reason: String)
        case retry(pid: pid_t, after: TimeInterval, attempt: Int, unknown: [CGWindowID], reason: String)
        /// budget spent with unknown windows still on screen
        case gaveUp(pid: pid_t, retries: Int, unknown: [CGWindowID], afterMS: Int, reason: String)
        /// nothing unknown on screen any more: the window was admitted
        /// earlier, or the create was for something that is not a window
        case settled(pid: pid_t, retries: Int, reason: String)
    }

    private(set) var watches: [pid_t: Watch] = [:]
    /// unknown on-screen windows a finished poll walked past
    private(set) var seenByPoll: Set<CGWindowID> = []
    /// unknown windows a poll was already asked for, until it runs
    private(set) var asked: Set<CGWindowID> = []
    /// unknown on-screen windows a watch gave up on, until they leave the
    /// screen. The reconcile still looks at them
    private(set) var givenUp: Set<CGWindowID> = []
    /// when each unknown on-screen window was first noticed
    private(set) var firstSeen: [CGWindowID: TimeInterval] = [:]
    /// the last AX event from each app, for the reconcile line
    private(set) var lastEvent: [pid_t: (kind: String, at: TimeInterval)] = [:]
    private(set) var lastCreate: [pid_t: TimeInterval] = [:]

    /// Unknown on-screen layer-0 windows by app. `filtered` are the windows
    /// the last walk read and its filter kept out: a browser's dropdown or
    /// hover card is listed by AX and answered for, so it is not a window a
    /// later poll could still admit. Every one of them used to cost its
    /// create three retries.
    static func unknownOnScreen(_ windows: [StackedWindow], known: Set<CGWindowID>,
                                hidden: Set<CGWindowID>, filtered: Set<CGWindowID> = [],
                                ownPID: pid_t) -> [pid_t: [CGWindowID]] {
        var result: [pid_t: [CGWindowID]] = [:]
        for w in windows where w.layer == 0 && w.alpha > 0.01 && w.ownerPID != ownPID {
            guard let b = w.bounds, b.width >= minimumSide, b.height >= minimumSide,
                  !known.contains(w.windowID), !hidden.contains(w.windowID),
                  !filtered.contains(w.windowID) else { continue }
            result[w.ownerPID, default: []].append(w.windowID)
        }
        return result
    }

    mutating func noteEvent(_ kind: String, pid: pid_t, now: TimeInterval) {
        lastEvent[pid] = (kind, now)
        if kind == "windowCreated" { lastCreate[pid] = now }
    }

    /// Start watching `pid`. A watch already running keeps its start and
    /// budget, so a burst of creates stays bounded.
    mutating func watch(pid: pid_t, reason: String, blindRetry: Bool, now: TimeInterval) {
        guard watches[pid] == nil else { return }
        watches[pid] = Watch(pid: pid, reason: reason, since: now, blindRetry: blindRetry)
    }

    /// The app's unknown windows that no poll has walked past or been
    /// asked for yet; they count as asked for from here. Each is noted as
    /// seen on screen from now if it was not already.
    mutating func unpolled(_ ids: [CGWindowID], now: TimeInterval) -> [CGWindowID] {
        for id in ids where firstSeen[id] == nil { firstSeen[id] = now }
        let fresh = ids.filter { !seenByPoll.contains($0) && !asked.contains($0) }
        asked.formUnion(fresh)
        return fresh
    }

    /// How long `id` has been on screen as far as HyprMac saw, nil if never.
    func onScreenMS(_ id: CGWindowID, now: TimeInterval) -> Int? {
        firstSeen[id].map { Int(((now - $0) * 1000).rounded()) }
    }

    /// Settle every watch against a finished poll. `admitted` holds the
    /// windows this poll made known, by app; `unknown` is the window
    /// server's unknown on-screen windows read after it.
    mutating func afterPoll(admitted: [pid_t: [CGWindowID]], unknown: [pid_t: [CGWindowID]],
                            now: TimeInterval) -> [Outcome] {
        let onScreen = Set(unknown.values.joined())
        for id in onScreen where firstSeen[id] == nil { firstSeen[id] = now }
        // admitted and departed windows drop out here, so read `onScreenMS`
        // for this poll's newcomers before calling
        firstSeen = firstSeen.filter { onScreen.contains($0.key) }
        seenByPoll = onScreen
        asked = []
        givenUp.formIntersection(onScreen)

        var outcomes: [Outcome] = []
        for pid in watches.keys.sorted() {
            guard var w = watches[pid] else { continue }
            let afterMS = Int(((now - w.since) * 1000).rounded())
            if let ids = admitted[pid], !ids.isEmpty {
                outcomes.append(.admitted(pid: pid, windowIDs: ids.sorted(), afterMS: afterMS,
                                          retries: w.retries, reason: w.reason))
                watches[pid] = nil
                continue
            }
            if now - w.since < Self.minimumLook { continue }
            let left = (unknown[pid] ?? []).filter { !givenUp.contains($0) }.sorted()
            let evidence = !left.isEmpty || (w.blindRetry && w.retries == 0)
            if w.retries < Self.backoff.count, evidence {
                outcomes.append(.retry(pid: pid, after: Self.backoff[w.retries], attempt: w.retries + 1,
                                       unknown: left, reason: w.reason))
                w.retries += 1
                watches[pid] = w
            } else if left.isEmpty {
                outcomes.append(.settled(pid: pid, retries: w.retries, reason: w.reason))
                watches[pid] = nil
            } else {
                outcomes.append(.gaveUp(pid: pid, retries: w.retries, unknown: left,
                                        afterMS: afterMS, reason: w.reason))
                givenUp.formUnion(left)
                watches[pid] = nil
            }
        }
        return outcomes
    }

    /// Drop everything for an app that quit.
    mutating func forget(pid: pid_t) {
        watches[pid] = nil
        lastEvent[pid] = nil
        lastCreate[pid] = nil
    }
}
