// Single source of truth for `UserConfig`'s scalar default values.
// Used by the init's else branch, by `resetToDefaults`, and by the
// `?? value` fallbacks that absorb a missing optional field on
// decode.

import Cocoa

enum FocusBracketStyle: String, Codable {
    case rounded
    case off
}

enum OverlayAppearance: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Where the workspace-switch HUD sits on the screen.
enum SwitchHUDPosition: String, Codable, CaseIterable, Identifiable {
    case topLeft, top, topRight
    case center
    case bottomLeft, bottom, bottomRight

    var id: Self { self }

    var displayName: String {
        switch self {
        case .topLeft: return "Top left"
        case .top: return "Top"
        case .topRight: return "Top right"
        case .center: return "Center"
        case .bottomLeft: return "Bottom left"
        case .bottom: return "Bottom"
        case .bottomRight: return "Bottom right"
        }
    }
}

/// What the workspace-switch HUD draws.
enum SwitchHUDStyle: String, Codable, CaseIterable, Identifiable {
    // one big number (or name)
    case number
    // the monitor's workspaces as a row of numbers, glyphs, or dots
    case numbers, squares, dots

    var id: Self { self }

    var displayName: String {
        switch self {
        case .number: return "Large number"
        case .numbers: return "Numbers  1 2 3"
        case .squares: return "Squares  ■ □ ·"
        case .dots: return "Dots  ● ○"
        }
    }
}

enum SwitchHUDFont: String, Codable, CaseIterable, Identifiable {
    case rounded, standard, monospaced, serif

    var id: Self { self }

    var displayName: String {
        switch self {
        case .rounded: return "Rounded"
        case .standard: return "System"
        case .monospaced: return "Monospaced"
        case .serif: return "Serif"
        }
    }
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
    static let overlayAppearance: OverlayAppearance = .system
    static let switchHUDPosition: SwitchHUDPosition = .bottom
    static let switchHUDStyle: SwitchHUDStyle = .number
    static let switchHUDFont: SwitchHUDFont = .rounded
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
