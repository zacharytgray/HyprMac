import Cocoa

// MinSizeMemory — per-window min-size bookkeeping for the tiling subsystem.
//
// macOS apps don't expose reliable AXMinimumSize. for tiled apps with hard
// minimums (Spotify, Messages, Xcode), we learn the actual floor from
// FrameReadbackPoller's pass-1 readback: when an app refuses to shrink, the
// observed actual size becomes the new "known" min until a later layout
// witnesses an even tighter accepted resize and lowers the bound.
//
// hysteresis on both ends:
//   - record: only raise (max with existing on the affected axis); reject
//     bogus AX sentinels via `usableMinSizeMaxPx`.
//   - lower:  require an accepted size at least `lowerMinSizeAcceptedDeltaPx`
//     below the current bound before relaxing — sub-pixel accepts shouldn't
//     ratchet the floor down.
//
// the memory mirrors back onto each HyprWindow's `observedMinSize` so other
// subsystems (drag-swap fit checks) see consistent values.
class MinSizeMemory {
    private var known: [CGWindowID: CGSize] = [:]

    /// Sync this map and the window's observedMinSize. If we already have a
    /// recorded bound, push it onto the window; otherwise pick up a usable
    /// AX-seeded value as our starting estimate.
    func prime(_ windows: [HyprWindow]) {
        for window in windows {
            if let knownSize = known[window.windowID] {
                window.observedMinSize = knownSize
            } else if let seeded = window.observedMinSize, isUsable(seeded) {
                known[window.windowID] = seeded
            }
        }
    }

    func forget(windowID: CGWindowID) {
        known.removeValue(forKey: windowID)
    }

    func minimumSize(for window: HyprWindow?) -> CGSize {
        guard let window else { return .zero }
        return known[window.windowID] ?? window.observedMinSize ?? .zero
    }

    /// Record a settled min-size conflict from FrameReadbackPoller. Raises the
    /// bound on whichever axis the conflict touched; never lowers from here.
    func recordObserved(_ window: HyprWindow,
                        actual: CGSize,
                        widthConflict: Bool,
                        heightConflict: Bool) {
        let existing = minimumSize(for: window)
        let updated = CGSize(
            width: widthConflict ? max(existing.width, actual.width) : existing.width,
            height: heightConflict ? max(existing.height, actual.height) : existing.height
        )
        guard isUsable(updated) else { return }
        known[window.windowID] = updated
        window.observedMinSize = updated
    }

    /// An accepted readback at least `lowerMinSizeAcceptedDeltaPx` smaller than
    /// the recorded bound unlocks a new (lower) bound. without this, a
    /// previously-recorded high mark would never relax even after the app
    /// learns to shrink (e.g., after a window-mode toggle in Xcode).
    func lowerIfAccepted(_ window: HyprWindow, actual: CGSize) {
        guard let knownSize = known[window.windowID] else { return }
        guard actual.width < knownSize.width - TilingConfig.lowerMinSizeAcceptedDeltaPx
            || actual.height < knownSize.height - TilingConfig.lowerMinSizeAcceptedDeltaPx else { return }
        let updated = CGSize(width: min(knownSize.width, actual.width),
                             height: min(knownSize.height, actual.height))
        if isUsable(updated) {
            known[window.windowID] = updated
            window.observedMinSize = updated
        } else {
            known.removeValue(forKey: window.windowID)
            window.observedMinSize = nil
        }
        hyprLog(.debug, .lifecycle, "lowered min-size for '\(window.title ?? "?")' → \(Int(updated.width))x\(Int(updated.height))")
    }

    /// Drop everything we knew about these windows and clear their
    /// observedMinSize. Used when a min-size adjustment fails to find a layout
    /// — the prior estimate must have been wrong, so start over.
    func clear(for windows: [HyprWindow]) {
        for window in windows {
            known.removeValue(forKey: window.windowID)
            window.observedMinSize = nil
        }
    }

    /// Reject NaN, infinities, fully-zero sizes, and bogus AX sentinels.
    private func isUsable(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && (size.width > 0 || size.height > 0)
            && size.width < TilingConfig.usableMinSizeMaxPx
            && size.height < TilingConfig.usableMinSizeMaxPx
    }
}
