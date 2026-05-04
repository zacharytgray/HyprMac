// Window corner radius for the focus border and dim overlay.
//
// macOS apps render their corners themselves and there's no public AX
// attribute to read the actual radius. Per-bundle override tables and
// dynamic probing both produced inconsistent results across apps, so
// we pick one global radius keyed only on the macOS version. Same
// value used by FocusBorder and DimmingOverlay so they stay in sync.

import Cocoa

enum WindowCornerRadius {

    // Tahoe (macOS 26) renders noticeably rounder corners than Sequoia
    // (15). everything else inherits the same value.
    static let global: CGFloat = {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
            return 12
        }
        return 10
    }()

    /// Resolve the radius for `wid`. Currently returns the same global
    /// value for every window — the API shape is preserved so the
    /// callers in FocusBorder / DimmingOverlay don't change if we ever
    /// reintroduce per-window resolution.
    static func resolve(for wid: CGWindowID) -> CGFloat { global }

    /// Prime hook — kept as a no-op so call sites in WindowManager can
    /// stay in place.
    static func prime(for window: HyprWindow) {}

    /// Forget hook — kept as a no-op for the same reason.
    static func forget(_ wid: CGWindowID) {}
}
