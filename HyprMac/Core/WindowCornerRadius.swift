// Window corner radius for the focus border and dim overlay.
//
// macOS apps render their corners themselves and there's no public AX
// attribute to read the actual radius. Per-bundle override tables and
// dynamic probing both produced inconsistent results across apps, so
// we use one user-configurable global radius. Its default remains keyed
// to the macOS version so existing installations keep their appearance.
// The same value drives all focus chrome so its curves stay in sync.

import Cocoa

enum WindowCornerRadius {

    /// Current user-selected radius. `UserConfigDefaults` preserves the
    /// previous 16pt Tahoe / 10pt earlier-version behavior when the saved
    /// config predates this setting.
    static var global: CGFloat { UserConfig.shared.windowCornerRadius }

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
