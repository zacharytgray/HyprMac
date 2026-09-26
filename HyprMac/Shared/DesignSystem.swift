// Design system tokens for HyprMac's settings window.
//
// Color, font, spacing, radius, and motion constants used by the
// HyprPanel/HyprRow/HyprChip components and the per-tab views.
// Chassis colors defer to NSColor system semantics so light/dark
// behavior matches the rest of macOS. The HyprMac signature accents
// (cyan + magenta) appear in exactly four places: focus border,
// active sidebar item, key recorder pulse, "Hypr Key" badge.

import SwiftUI
import AppKit
import Combine

// MARK: - color tokens

extension Color {
    // chassis — semantic, defer to system
    static let hyprBackground      = Color(nsColor: .windowBackgroundColor)
    static let hyprSurface         = Color(nsColor: .controlBackgroundColor)
    static let hyprSurfaceElevated = Color(nsColor: .underPageBackgroundColor)
    static let hyprSeparator      = Color(nsColor: .separatorColor)
    static let hyprTextPrimary     = Color(nsColor: .labelColor)
    static let hyprTextSecondary   = Color(nsColor: .secondaryLabelColor)
    static let hyprTextTertiary    = Color(nsColor: .tertiaryLabelColor)

    // signature accents — used sparingly
    static let hyprCyan = Color(nsColor: .hyprCyan)
    static let hyprMagenta = Color(nsColor: .hyprMagenta)
}

extension NSColor {
    // dark: bright cyan that reads as neon on near-black.
    // light: deeper cyan that holds contrast against white.
    static let hyprCyan = NSColor(name: "hyprCyan") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0x56/255.0, green: 0xD8/255.0, blue: 0xF0/255.0, alpha: 1)
            : NSColor(red: 0x00/255.0, green: 0x7A/255.0, blue: 0xAA/255.0, alpha: 1)
    }

    static let hyprMagenta = NSColor(name: "hyprMagenta") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0xE8/255.0, green: 0x4B/255.0, blue: 0xCB/255.0, alpha: 1)
            : NSColor(red: 0xB7/255.0, green: 0x22/255.0, blue: 0x8F/255.0, alpha: 1)
    }
}

// MARK: - typography

extension Font {
    static let hyprTitle    = Font.system(size: 17, weight: .semibold, design: .default)
    static let hyprSection  = Font.system(size: 12, weight: .semibold, design: .default)
    static let hyprBody     = Font.system(size: 13, weight: .regular,  design: .default)
    static let hyprCaption  = Font.system(size: 11, weight: .regular,  design: .default)
    static let hyprMono     = Font.system(size: 12, weight: .medium,   design: .monospaced)
    static let hyprMonoSm   = Font.system(size: 11, weight: .medium,   design: .monospaced)
    static let hyprMonoXs   = Font.system(size: 10, weight: .medium,   design: .monospaced)
}

// MARK: - spacing & radius

enum HyprSpacing {
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 12
    static let lg:  CGFloat = 16
    static let xl:  CGFloat = 24
    static let xxl: CGFloat = 32
}

enum HyprRadius {
    static let sm: CGFloat = 4
    static let md: CGFloat = 6
    static let lg: CGFloat = 10
}

// MARK: - motion

enum HyprMotion {
    static let snap     = Animation.easeOut(duration: 0.12)
    static let glide    = Animation.easeOut(duration: 0.20)
    static let physical = Animation.spring(response: 0.35, dampingFraction: 0.82)
}

// shared appearance for transient overlays; nil inherits live system changes.
class OverlayHostingView<Content: View>: NSHostingView<Content> {
    private var appearanceSubscription: AnyCancellable?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        appearanceSubscription = UserConfig.shared.$overlayAppearance.sink { [weak self] mode in
            switch mode {
            case .system: self?.appearance = nil
            case .light: self?.appearance = NSAppearance(named: .aqua)
            case .dark: self?.appearance = NSAppearance(named: .darkAqua)
            }
        }
    }

    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
}

struct OverlayPalette {
    let scheme: ColorScheme
    var isDark: Bool { scheme == .dark }
    var background: Color { opaqueBackground.opacity(0.98) }
    /// `background` with no transparency, for chrome that covers scrolling rows
    var opaqueBackground: Color {
        isDark ? Color(red: 0.025, green: 0.032, blue: 0.075)
            : Color(red: 0.94, green: 0.95, blue: 0.97)
    }
    var surface: Color { isDark ? .white.opacity(0.055) : .black.opacity(0.045) }
    var activeSurface: Color { isDark ? .white.opacity(0.10) : .black.opacity(0.08) }
    var preview: Color { isDark ? .black.opacity(0.35) : .white.opacity(0.65) }
    var separator: Color { isDark ? .white.opacity(0.14) : .black.opacity(0.12) }
    var shadow: Color { .black.opacity(isDark ? 0.42 : 0.22) }
}
