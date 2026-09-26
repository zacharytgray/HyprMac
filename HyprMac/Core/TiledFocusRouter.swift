// Keyboard focus for a tiled window without lifting it over a floater.
// The usual focus path writes AXMain and activates the app, and both bring
// the tile above any floater covering it. When a floater covers the target,
// this sends only the SkyLight front-process and key-window events, checks
// a moment later whether focus landed, and falls back to the usual path
// when it did not.

import Cocoa

/// Picks the focus path for a HyprMac-initiated focus change.
///
/// Callers record the new focus intent in `FocusStateController` before
/// calling `focus`. The delayed steps compare against that intent and give
/// up quietly once something newer has been focused.
///
/// Threading: main-thread only.
final class TiledFocusRouter {
    /// What the usual path does for this caller. Hover focus adds the
    /// synthetic title-bar click Tahoe needs from a mouse-move context.
    enum Fallback: String {
        case activate
        case activateAndClick = "activate+click"
    }

    enum Path: Equatable {
        case usual
        case noRaise
        case alreadyFocused
    }

    struct Route {
        let path: Path
        /// the target's frame and the floaters covering it, from the window list
        let targetFrame: CGRect?
        let coveringFrames: [CGRect]

        /// where a cursor warp should land so it is over the target, not a floater
        var warpPoint: CGPoint? {
            guard let targetFrame else { return nil }
            guard !coveringFrames.isEmpty else { return CGPoint(x: targetFrame.midX, y: targetFrame.midY) }
            return WindowStacking.exposedPoint(of: targetFrame, coveredBy: coveringFrames)
        }
    }

    /// What the verify step saw.
    struct Check: Equatable {
        let frontPID: pid_t?
        let keyWindowID: CGWindowID?
        let floatersAbove: [CGWindowID]

        func landed(on target: HyprWindow) -> Bool {
            frontPID == target.ownerPID && keyWindowID == target.windowID
        }
    }

    // gap between the lost and gained focus events, as yabai spaces them
    static let keyHandoffDelay: TimeInterval = 0.04
    // time for the window server and the app to settle before checking
    static let verifyDelay: TimeInterval = 0.08

    // seams
    var windowList: () -> [StackedWindow]? = { WindowStacking.onScreen() }
    var visibleFloaterIDs: () -> Set<CGWindowID> = { [] }
    var isTiled: (CGWindowID) -> Bool = { _ in false }
    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var keyWindowID: (pid_t) -> CGWindowID? = { HyprWindow.axFocusedWindowID(pid: $0) }
    var postWindowFocus: (pid_t, CGWindowID, Bool) -> Void = { pid, wid, gained in
        HyprWindow.postWindowFocusEvent(pid: pid, windowID: wid, gained: gained)
    }
    var makeFrontAndKey: (HyprWindow) -> String? = { $0.makeFrontAndKeyWithoutRaise() }
    var usualFocus: (HyprWindow, Fallback) -> Void = { window, fallback in
        window.focusWithoutRaise()
        if fallback == .activateAndClick { window.focusViaSyntheticClick() }
    }
    var lastFocusedID: () -> CGWindowID = { 0 }
    var focusGeneration: () -> UInt64 = { 0 }
    var openPopup: () -> StackedWindow? = { nil }
    var isMenuTracking: () -> Bool = { false }
    var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, body in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
    }

    /// Focus `target`. A tile with a floater above it takes the no-raise
    /// path; everything else takes the usual one.
    @discardableResult
    func focus(_ target: HyprWindow, reason: String, fallback: Fallback) -> Route {
        let wid = target.windowID
        let pid = target.ownerPID
        let floaters = visibleFloaterIDs().subtracting([wid])
        guard isTiled(wid), !floaters.isEmpty, let windows = windowList() else {
            usualFocus(target, fallback)
            return Route(path: .usual, targetFrame: nil, coveringFrames: [])
        }
        let targetFrame = windows.first { $0.windowID == wid }?.bounds
        let covering = WindowStacking.floaters(above: wid, among: floaters, in: windows)
        guard !covering.isEmpty else {
            usualFocus(target, fallback)
            return Route(path: .usual, targetFrame: targetFrame, coveringFrames: [])
        }
        let route = Route(path: .noRaise, targetFrame: targetFrame,
                          coveringFrames: covering.compactMap(\.bounds))
        let coveringIDs = covering.map(\.windowID)

        let front = frontmostPID()
        let previousKey = front == pid ? keyWindowID(pid) : nil
        if front == pid, previousKey == wid {
            hyprLog(.debug, .focus, "no-raise focus: wid=\(wid) already key (reason=\(reason))")
            return Route(path: .alreadyFocused, targetFrame: route.targetFrame,
                         coveringFrames: route.coveringFrames)
        }

        let generation = focusGeneration()
        hyprLog(.notice, .focus, "no-raise focus: wid=\(wid) pid=\(pid) reason=\(reason) "
                + "floaters=\(coveringIDs) front=\(front.map(String.init) ?? "nil") "
                + "prevKey=\(previousKey.map(String.init) ?? "nil")")

        let finish = { [weak self] in
            guard let self else { return }
            let rc = self.makeFrontAndKey(target) ?? "no psn"
            hyprLog(.debug, .focus, "no-raise focus: wid=\(wid) \(rc)")
            self.schedule(Self.verifyDelay) { [weak self] in
                self?.verify(target, reason: reason, fallback: fallback,
                             generation: generation, covering: coveringIDs, startFront: front)
            }
        }

        if let previousKey, previousKey != wid {
            // same app: hand key status from its current window to the target
            postWindowFocus(pid, previousKey, false)
            schedule(Self.keyHandoffDelay) { [weak self] in
                guard let self else { return }
                guard self.isCurrent(wid, generation) else {
                    hyprLog(.notice, .focus, "no-raise focus superseded: wid=\(wid)")
                    return
                }
                self.postWindowFocus(pid, wid, true)
                finish()
            }
        } else {
            finish()
        }
        return route
    }

    private func isCurrent(_ wid: CGWindowID, _ generation: UInt64) -> Bool {
        lastFocusedID() == wid && focusGeneration() == generation
    }

    private func probe(_ target: HyprWindow) -> Check {
        let floaters = visibleFloaterIDs().subtracting([target.windowID])
        let above = windowList().map {
            WindowStacking.floaters(above: target.windowID, among: floaters, in: $0).map(\.windowID)
        } ?? []
        return Check(frontPID: frontmostPID(), keyWindowID: keyWindowID(target.ownerPID),
                     floatersAbove: above)
    }

    private func verify(_ target: HyprWindow, reason: String, fallback: Fallback,
                        generation: UInt64, covering: [CGWindowID], startFront: pid_t?) {
        let wid = target.windowID
        guard isCurrent(wid, generation) else {
            hyprLog(.notice, .focus, "no-raise focus verify: wid=\(wid) superseded")
            return
        }
        let check = probe(target)
        let landed = check.landed(on: target)
        let buried = covering.filter { !check.floatersAbove.contains($0) }
        hyprLog(.notice, .focus, "no-raise focus verify: wid=\(wid) reason=\(reason) "
                + "front=\(check.frontPID.map(String.init) ?? "nil") (want \(target.ownerPID)) "
                + "key=\(check.keyWindowID.map(String.init) ?? "nil") "
                + "floatersAbove=\(check.floatersAbove) buried=\(buried) "
                + "→ \(landed ? "landed" : "missed")")
        guard !landed else { return }
        // the user switched to a third app meanwhile (Cmd-Tab, a Dock click)
        if let now = check.frontPID, now != target.ownerPID, now != startFront {
            hyprLog(.notice, .focus, "no-raise focus fallback skipped: wid=\(wid) front moved to \(now)")
            return
        }
        // the fallback's activation and click would close an open menu
        if isMenuTracking() {
            hyprLog(.notice, .focus, "no-raise focus fallback skipped: wid=\(wid) menu tracking")
            return
        }
        if let popup = openPopup() {
            hyprLog(.notice, .focus, "no-raise focus fallback skipped: wid=\(wid) "
                    + "popup wid=\(popup.windowID) layer=\(popup.layer)")
            return
        }
        hyprLog(.notice, .focus, "no-raise focus fallback: wid=\(wid) path=\(fallback.rawValue)")
        usualFocus(target, fallback)
    }
}
