// Single source of truth for `UserConfig`'s scalar default values.
// Used by the init's else branch, by `resetToDefaults`, and by the
// `?? value` fallbacks that absorb a missing optional field on
// decode.

import Cocoa

enum FocusBracketStyle: String, Codable {
    case rounded
    case off
}

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
    static let mouseHoverPollHz: Int = 120
    static let hyprKey: HyprKey = .capsLock
    static let showMenuBarIndicator: Bool = true
    static let showFocusBorder: Bool = false
    static let focusBracketStyle: FocusBracketStyle = .rounded
    static let focusBracketColor: NSColor = .black
    static let focusBracketRadius: CGFloat = 20
    static let focusBracketThickness: CGFloat = 4.5
    static let focusBracketLength: CGFloat = 15
    static let dimInactiveWindows: Bool = true
    static let dimIntensity: Double = 0.135
    // shared fade duration for both the focus border (show/hide) and the
    // dim overlay (per-window opacity transitions on focus traversal and
    // global enable/disable). settle and shake on FocusBorder stay at
    // their own constants.
    static let chromeFadeDurationSec: Double = 0.13
    // compatibility suggestions, not a per-window measurement. Apple
    // documents 16/20/26 pt on Tahoe; Golden Gate's exact unified value
    // is unverified. keep the existing fallback; see docs/settings-polish.md.
    static func windowCornerRadius(forOSMajorVersion majorVersion: Int) -> CGFloat {
        majorVersion >= 26 ? 16 : 10
    }
    // A missing override remains adaptive across macOS upgrades.
    static func resolvedWindowCornerRadius(
        override: CGFloat?,
        forOSMajorVersion majorVersion: Int
    ) -> CGFloat {
        override ?? windowCornerRadius(forOSMajorVersion: majorVersion)
    }
    // windows sent to the scratchpad tile into the layer instead of
    // floating. an explicit saved false still preserves floating-first mode.
    static let scratchpadTileByDefault: Bool = true
    // fraction of the layer monitor inset on each edge for the scratchpad's
    // tiled region — 0.06 keeps a visible scrimmed border, 0 maximizes
    // usable area.
    static let scratchpadRegionInset: CGFloat = 0.06
    static let restoreLayoutOnLaunch: Bool = false
    // focusBorderColorHex / floatingBorderColorHex are nil by default —
    // resolvedFocusBorderColor / resolvedFloatingBorderColor compute the
    // system color when nil.
}
