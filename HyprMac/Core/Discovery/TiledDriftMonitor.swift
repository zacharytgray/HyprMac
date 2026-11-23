// Same-screen drift: a tiled window whose app moved or resized it back to
// its own saved frame after HyprMac's write was accepted. Cross-screen
// drift is `WindowDiscoveryService`'s job; this is the one nothing owned.

import Cocoa

/// One poll's reading of one tiled window: where it is, and where the
/// published tree says it should be.
struct TiledDriftReading {
    let windowID: CGWindowID
    let workspace: Int
    let screen: NSScreen
    let actual: CGRect
    let intended: CGRect
    /// whether the window is in native full screen. Asked only of a
    /// drifted reading, since it costs an AX read
    var isFullScreen: () -> Bool = { false }
}

/// What the monitor wants done about a drifted window.
enum TiledDriftDecision: Equatable {
    /// re-apply this workspace's layout once, through the ordinary verified
    /// path. One per workspace per poll, one per window per episode.
    case reapply(workspace: Int, screen: NSScreen, windowID: CGWindowID)
    /// the app took its frame back after a re-apply. Stop, and let the key
    /// say it cannot speak for its geometry.
    case abandon(workspace: Int, screen: NSScreen, windowID: CGWindowID)
}

/// Bounded response to a tiled window that stopped matching its tile.
///
/// Safari's Start Page restores its own saved frame a moment after an
/// accepted write, so the new window covered the screen until an unrelated
/// retile two minutes later. Nothing was watching: the frame the tree
/// described and the frame on screen had quietly diverged, and only a
/// cross-screen move would have been noticed.
///
/// The bound matters more than the reaction. One re-apply per window per
/// episode, and if the app takes its frame back again straight away the
/// monitor stops rather than trading writes with it forever. Two
/// consecutive polls must agree on the drifted frame first, so a window
/// mid-animation is not chased — before the re-apply and before the abandon
/// alike.
///
/// Threading: main-thread only. No timers of its own — the discovery poll
/// drives it.
final class TiledDriftMonitor {

    /// How far a tiled window may sit from its intended rect before it
    /// counts as drift. The candidate tolerances: a point of position, and
    /// the size overshoot an accepted layout already tolerates.
    static let positionTolerance: CGFloat = 1
    static let sizeTolerance: CGFloat = 20

    /// A re-apply that drifts again inside this window is the app fighting
    /// back. Outside it, the layout held for a while and this is a new
    /// episode.
    var recurrenceWindow: TimeInterval = 5

    // MARK: - seams

    var now: () -> Date = Date.init
    /// True while something else owns window geometry: a press, a tiled
    /// drag's settle, a display reconfiguration. Nothing is recorded then,
    /// so an episode cannot be assembled out of frames somebody else was
    /// moving.
    var isSuspended: () -> Bool = { false }

    // MARK: - state

    private enum State {
        /// drifted once, at this frame. Not yet acted on.
        case seen(CGRect)
        /// its one re-apply went out at this time.
        case reapplied(Date)
        /// it drifted once since that re-apply, at this frame. Same two-poll
        /// rule as the entry: one sample could be the layout still landing.
        case recurred(Date, CGRect)
        /// it drifted again straight after that. No more writes.
        case abandoned
    }

    private var states: [CGWindowID: State] = [:]
    /// drifted windows last read in native full screen, so each stay is
    /// logged once
    private var fullScreenIDs: Set<CGWindowID> = []

    func forget(_ windowID: CGWindowID) { states.removeValue(forKey: windowID) }

    func reset() {
        states.removeAll()
        fullScreenIDs.removeAll()
    }

    /// Judge one poll's readings.
    ///
    /// A window back where the tree says ends whatever episode it was in.
    /// A window that has left the readings entirely is dropped: it is
    /// floating, hidden, on a hidden workspace, or under a key the engine
    /// can no longer speak for.
    func note(_ readings: [TiledDriftReading]) -> [TiledDriftDecision] {
        guard !isSuspended() else { return [] }
        var decisions: [TiledDriftDecision] = []
        var reapplied: Set<Int> = []
        var present: Set<CGWindowID> = []

        for reading in readings.sorted(by: { $0.windowID < $1.windowID }) {
            present.insert(reading.windowID)
            guard Self.drifted(reading) else {
                states.removeValue(forKey: reading.windowID)
                fullScreenIDs.remove(reading.windowID)
                continue
            }
            // native full screen owns its frame, and a size write ends it
            // (#104). its tile waits for it; leaving starts from scratch
            if reading.isFullScreen() {
                states.removeValue(forKey: reading.windowID)
                if fullScreenIDs.insert(reading.windowID).inserted {
                    hyprLog(.notice, .tiling, "tiled drift: \(reading.windowID) ws\(reading.workspace)"
                            + " is in native full screen — left alone, its tile kept")
                }
                continue
            }
            fullScreenIDs.remove(reading.windowID)
            switch states[reading.windowID] {
            case nil:
                states[reading.windowID] = .seen(reading.actual)
            case let .seen(previous):
                guard Self.settled(previous, reading.actual) else {
                    // still moving — an animation, not a frame the app means
                    states[reading.windowID] = .seen(reading.actual)
                    continue
                }
                states[reading.windowID] = .reapplied(now())
                // the re-apply lays out the whole workspace, so one is
                // enough however many of its windows drifted
                guard reapplied.insert(reading.workspace).inserted else { continue }
                hyprLog(.notice, .tiling, "tiled drift: \(reading.windowID) ws\(reading.workspace)"
                        + " actual=\(Self.text(reading.actual)) intended=\(Self.text(reading.intended))"
                        + " — re-applying the layout once")
                decisions.append(.reapply(workspace: reading.workspace, screen: reading.screen,
                                          windowID: reading.windowID))
            case let .reapplied(at):
                guard now().timeIntervalSince(at) <= recurrenceWindow else {
                    states[reading.windowID] = .seen(reading.actual)
                    continue
                }
                states[reading.windowID] = .recurred(at, reading.actual)
            case let .recurred(at, previous):
                guard now().timeIntervalSince(at) <= recurrenceWindow else {
                    states[reading.windowID] = .seen(reading.actual)
                    continue
                }
                guard Self.settled(previous, reading.actual) else {
                    // still moving — the re-apply may yet be landing
                    states[reading.windowID] = .recurred(at, reading.actual)
                    continue
                }
                states[reading.windowID] = .abandoned
                hyprLog(.notice, .tiling, "tiled drift: \(reading.windowID) ws\(reading.workspace)"
                        + " took its frame back after the re-apply — leaving ws\(reading.workspace)"
                        + " unverified rather than fighting the app")
                decisions.append(.abandon(workspace: reading.workspace, screen: reading.screen,
                                          windowID: reading.windowID))
            case .abandoned:
                continue
            }
        }

        states = states.filter { present.contains($0.key) }
        fullScreenIDs.formIntersection(present)
        return decisions
    }

    /// Whether the window is far enough from its tile to mean something.
    private static func drifted(_ reading: TiledDriftReading) -> Bool {
        let actual = reading.actual
        let intended = reading.intended
        return abs(actual.minX - intended.minX) > positionTolerance
            || abs(actual.minY - intended.minY) > positionTolerance
            || abs(actual.width - intended.width) > sizeTolerance
            || abs(actual.height - intended.height) > sizeTolerance
    }

    /// Whether two polls read the same frame, so the window has stopped.
    private static func settled(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX - second.minX) <= positionTolerance
            && abs(first.minY - second.minY) <= positionTolerance
            && abs(first.width - second.width) <= positionTolerance
            && abs(first.height - second.height) <= positionTolerance
    }

    private static func text(_ rect: CGRect) -> String {
        String(format: "(%g,%g,%g,%g)", Double(rect.minX), Double(rect.minY),
               Double(rect.width), Double(rect.height))
    }
}
