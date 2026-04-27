// Single source of truth for `UserConfig`'s scalar default values.
// Used by the init's else branch, by `resetToDefaults`, and by the
// `?? value` fallbacks that absorb a missing optional field on
// decode.

import Foundation

/// Scalar defaults for `UserConfig`.
///
/// Keybinds and excluded bundle ids live in their type-specific
/// files (`DefaultKeybinds.swift` /
/// `UserConfig.defaultExcludedBundleIDs`); this enum holds only the
/// scalar and flag defaults.
enum UserConfigDefaults {
    static let gapSize: CGFloat = 8
    static let outerPadding: CGFloat = 8
    static let enabled: Bool = true
    static let focusFollowsMouse: Bool = true
    static let hyprKey: HyprKey = .capsLock
    static let animateWindows: Bool = true
    static let animationDuration: Double = 0.15
    static let showMenuBarIndicator: Bool = true
    static let showFocusBorder: Bool = true
    static let dimInactiveWindows: Bool = false
    static let dimIntensity: Double = 0.2
    // focusBorderColorHex / floatingBorderColorHex are nil by default —
    // resolvedFocusBorderColor / resolvedFloatingBorderColor compute the
    // system color when nil.
}
