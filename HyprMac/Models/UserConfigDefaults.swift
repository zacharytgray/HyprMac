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
    static let mouseHoverPollHz: Int = 120
    static let hyprKey: HyprKey = .capsLock
    static let showMenuBarIndicator: Bool = true
    static let showFocusBorder: Bool = true
    static let dimInactiveWindows: Bool = false
    static let dimIntensity: Double = 0.2
    // shared fade duration for both the focus border (show/hide) and the
    // dim overlay (per-window opacity transitions on focus traversal and
    // global enable/disable). settle and shake on FocusBorder stay at
    // their own constants.
    static let chromeFadeDurationSec: Double = 0.22
    // windows sent to the scratchpad tile into the layer instead of
    // floating. off preserves the original floating-first behavior.
    static let scratchpadTileByDefault: Bool = false
    // fraction of the layer monitor inset on each edge for the scratchpad's
    // tiled region — 0.06 keeps a visible scrimmed border, 0 maximizes
    // usable area.
    static let scratchpadRegionInset: CGFloat = 0.06
    // focusBorderColorHex / floatingBorderColorHex are nil by default —
    // resolvedFocusBorderColor / resolvedFloatingBorderColor compute the
    // system color when nil.
}
