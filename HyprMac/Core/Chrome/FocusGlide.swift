// The focus indicator glides when a keyboard action sends focus or a window
// somewhere new. Windows still snap through AX, as they always have; only
// HyprMac's own brackets and border travel. One animation per press, run by
// the render server while the main thread is busy writing and reading
// frames. No AX write per frame.

import Cocoa

struct TeleportMove: Equatable {
    let windowID: CGWindowID
    let from: CGRect
    let to: CGRect
}

/// Which presses glide and which frames count as a teleport. Pure, so the
/// rules are testable without panels.
enum TeleportPlanner {
    // an origin shift smaller than this is a rounding, not a teleport
    static let minimumTravel: CGFloat = 4
    // more than this is a retile, not one window going somewhere
    static let maximumMoves = 4

    /// Keyboard actions that send focus or a tiled window somewhere new.
    /// Not mouse focus (the marks would chase the cursor), not drags (the
    /// user already watched it move), not resize (key repeat, small
    /// steps), not workspace switches (a scene change), not retile all.
    static func animates(_ action: Action) -> Bool {
        switch action {
        case .focusDirection, .swapDirection, .moveWindowToMonitor, .toggleSplit,
             .toggleMaximize, .toggleFloating:
            return true
        default:
            return false
        }
    }

    /// A window moves when its origin shifts, or when its size changes by
    /// more than the engine itself would call on target. A terminal or a
    /// mail viewer that rounds its width keeps sitting a few points past
    /// its tile, and every pass "writes" it without anything visible.
    static func moves(originals: [CGWindowID: CGRect],
                      targets: [(CGWindowID, CGRect)],
                      sizeTolerance: CGFloat = TilingConfig.frameToleranceXPx) -> [TeleportMove] {
        let moves = targets.compactMap { id, to -> TeleportMove? in
            guard let from = originals[id] else { return nil }
            let shift = max(abs(from.minX - to.minX), abs(from.minY - to.minY))
            let resize = max(abs(from.width - to.width), abs(from.height - to.height))
            guard shift >= minimumTravel || resize > sizeTolerance else { return nil }
            return TeleportMove(windowID: id, from: from, to: to)
        }
        return moves.count > maximumMoves ? [] : moves
    }

    static func travel(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY))
    }
}

/// Glides the brackets and border for one press.
///
/// ```
/// arm(action) --willWrite(moves)--> marks travel with the moved window (swap, split, ...)
///             --traversal(from:to:)-> a duration for a focus move, or nil
/// disarm()
/// ```
///
/// Threading: main-thread only.
final class FocusGlide {
    static let duration: TimeInterval = 0.14

    /// cached primary height for the CG → NS flip. set by the owner
    var primaryScreenHeight: CGFloat = 0
    weak var brackets: FocusBrackets?
    weak var border: FocusBorder?

    private(set) var isArmed = false
    private var isTraversal = false

    func arm(for action: Action, enabled: Bool) -> Bool {
        mainThreadOnly()
        guard enabled, TeleportPlanner.animates(action),
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
        isArmed = true
        if case .focusDirection = action { isTraversal = true } else { isTraversal = false }
        return true
    }

    func disarm() {
        mainThreadOnly()
        isArmed = false
        isTraversal = false
    }

    /// The glide duration for focus leaving `from` for `to`, or nil when
    /// the marks should arrive the old way: no armed traversal, nothing
    /// shown yet, or a different screen.
    func traversal(from: CGRect?, to: CGRect) -> TimeInterval? {
        guard isArmed, isTraversal, let from, sameScreen(from, to) else { return nil }
        return Self.duration
    }

    /// Called by the engine with a pass's moves right before its first write.
    func willWrite(_ moves: [TeleportMove]) {
        mainThreadOnly()
        guard isArmed, !isTraversal, !moves.isEmpty else { return }
        var glided = false
        if let brackets, brackets.isVisible,
           let move = moves.first(where: { $0.windowID == brackets.trackedWindowID }),
           sameScreen(move.from, move.to) {
            glided = brackets.glide(from: move.from, to: move.to, duration: Self.duration) || glided
        }
        if let border, let id = border.trackedWindowID,
           let move = moves.first(where: { $0.windowID == id }),
           sameScreen(move.from, move.to) {
            glided = border.glide(from: move.from, to: move.to, duration: Self.duration) || glided
        }
        // hand the layers to the render server now. the main thread is about
        // to block in AX writes and readback, and nothing would draw till then
        if glided { CATransaction.flush() }
    }

    private func sameScreen(_ a: CGRect, _ b: CGRect) -> Bool {
        let screenA = NSScreen.screens.first { $0.frame.contains(nsCenter(a)) }
        let screenB = NSScreen.screens.first { $0.frame.contains(nsCenter(b)) }
        return screenA != nil && screenA == screenB
    }

    private func nsCenter(_ cg: CGRect) -> NSPoint {
        let r = CoordinateSpace.nsRect(fromCG: cg, primaryHeight: primaryScreenHeight)
        return NSPoint(x: r.midX, y: r.midY)
    }
}
