// Moves the chrome with a window that moved or resized on its own: the
// app's own move, another tool's AX write, a drag, or a frame HyprMac wrote
// landing late. Driven by the apps' AX move and resize notifications.

import Foundation
import CoreGraphics

/// Coalesces window move and resize events into chrome updates.
///
/// Each run loop turn with an event for a window that has chrome gets one
/// `follow` with those windows, in event order: the marks move to each
/// window's window-list frame. An app posts the move before the window
/// server has the new frame, so `follow` returns the windows the list still
/// shows where the marks are, and those are read again a display frame
/// later, at most `maxRereads` times. Once the events stop for
/// `settleDelay`, one `settle` runs the full refresh (occlusion masks, the
/// dim). A window without chrome costs one `isTracked` check.
///
/// Threading: main-thread only.
final class ChromeFrameFollow {
    /// quiet time after the last move before the full refresh
    static let settleDelay: TimeInterval = 0.12
    /// one display frame at 60 Hz
    static let retryDelay: TimeInterval = 1.0 / 60
    /// rereads after an event before the settle refresh is left to catch it
    static let maxRereads = 6

    private let isTracked: (CGWindowID) -> Bool
    private let follow: ([CGWindowID]) -> [CGWindowID]
    private let settle: () -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var pending: [CGWindowID] = []
    private var followQueued = false
    private var settleGeneration = 0
    // windows the list still showed at the old spot, with their rereads so far
    private var rereads: [CGWindowID: Int] = [:]
    private var rereadQueued = false

    init(isTracked: @escaping (CGWindowID) -> Bool,
         follow: @escaping ([CGWindowID]) -> [CGWindowID],
         settle: @escaping () -> Void,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, body in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
         }) {
        self.isTracked = isTracked
        self.follow = follow
        self.settle = settle
        self.schedule = schedule
    }

    func noteFrameChange(_ id: CGWindowID) {
        guard isTracked(id) else { return }
        rereads[id] = nil
        if !pending.contains(id) { pending.append(id) }
        if !followQueued {
            followQueued = true
            schedule(0) { [weak self] in self?.flush() }
        }
        settleGeneration += 1
        let generation = settleGeneration
        schedule(Self.settleDelay) { [weak self] in
            guard let self, self.settleGeneration == generation else { return }
            self.settle()
        }
    }

    private func flush() {
        followQueued = false
        let ids = pending
        pending = []
        guard !ids.isEmpty else { return }
        for id in follow(ids) { rereads[id] = 0 }
        queueReread()
    }

    private func reread() {
        rereadQueued = false
        let ids = rereads.keys.sorted().filter { !pending.contains($0) }
        guard !ids.isEmpty else { return }
        let notMoved = Set(follow(ids))
        for id in ids {
            let done = (rereads[id] ?? 0) + 1
            rereads[id] = notMoved.contains(id) && done < Self.maxRereads ? done : nil
        }
        queueReread()
    }

    private func queueReread() {
        guard !rereads.isEmpty, !rereadQueued else { return }
        rereadQueued = true
        schedule(Self.retryDelay) { [weak self] in self?.reread() }
    }
}
