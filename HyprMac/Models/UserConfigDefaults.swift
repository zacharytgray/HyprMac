import Foundation

// single source of truth for UserConfig's default values.
//
// extracted in phase 6 because the same defaults were spelled out in three
// places (UserConfig.init's else branch, UserConfig.resetToDefaults, and the
// `?? value` fallbacks applied when a v0.4.2 config decodes without an
// optional field). triplication made it easy for one to drift behind.
//
// keybinds + excluded bundle IDs intentionally stay in their respective
// type-specific files (DefaultKeybinds.swift / UserConfig.defaultExcludedBundleIDs)
// so this file is purely the scalar/flag defaults.

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
