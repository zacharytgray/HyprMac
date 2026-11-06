// Design system tokens for HyprMac's settings window.
//
// Color, font, spacing, radius, and motion constants used by the
// HyprPanel/HyprRow/HyprChip components and the per-tab views.
// Chassis colors defer to NSColor system semantics so light/dark
// behavior matches the rest of macOS. The HyprMac signature accents
// are cyan and magenta.

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

    // overlay accents: the user's one accent when set, else the brand pair.
    // read per draw, so views observing UserConfig pick up a change at once
    static var overlayPrimary: Color {
        UserConfig.shared.overlayAccentHex.flatMap(NSColor.fromHex).map { Color(nsColor: $0) } ?? .hyprCyan
    }
    static var overlaySecondary: Color {
        UserConfig.shared.overlayAccentHex.flatMap(NSColor.fromHex).map { Color(nsColor: $0) } ?? .hyprMagenta
    }
}

extension UserConfig {
    // the configured floating color for swiftui markers; brand magenta when unset
    var resolvedFloatingColor: Color { Color(nsColor: resolvedFloatingBorderColor) }
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

/// Panel for click-through overlays (focus border, dim, brackets, drop
/// preview). `ignoresMouseEvents` does not stop AppKit from routing
/// enter/exit through the panel when it moves under the cursor or the
/// cursor crosses it, and each one resets the cursor to the arrow. With a
/// customized accessibility pointer that reset re-renders the pointer
/// image every time, which made hover focus changes expensive.
///
/// These panels are also hidden from screen capture. A window picker took
/// the dim panel for the inactive window under the pointer, so the shot came
/// out as an empty gray square of dim.
final class ClickThroughPanel: NSPanel {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style,
                   backing: backingStoreType, defer: flag)
        sharingType = .none
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .mouseEntered, .mouseExited, .cursorUpdate: return
        default: super.sendEvent(event)
        }
    }
}

struct OverlayPalette {
    let scheme: ColorScheme
    var style: OverlayStyle = .classic
    var isDark: Bool { scheme == .dark }
    var isGlass: Bool { style == .glass }
    var background: Color { opaqueBackground.opacity(0.98) }
    /// `background` with no transparency, for chrome that covers scrolling rows
    var opaqueBackground: Color {
        isDark ? Color(red: 0.025, green: 0.032, blue: 0.075)
            : Color(red: 0.94, green: 0.95, blue: 0.97)
    }
    var surface: Color { isDark ? .white.opacity(0.055) : .black.opacity(0.045) }
    var activeSurface: Color { isDark ? .white.opacity(0.10) : .black.opacity(0.08) }
    var preview: Color {
        if isGlass { return isDark ? .black.opacity(0.22) : .white.opacity(0.4) }
        return isDark ? .black.opacity(0.35) : .white.opacity(0.65)
    }
    var separator: Color { isDark ? .white.opacity(0.14) : .black.opacity(0.12) }
    var shadow: Color { .black.opacity(isDark ? 0.42 : 0.22) }

    // where the accent goes. classic spreads the brand pair over captions,
    // headers and borders; glass keeps labels neutral and saves the one
    // accent for small marks: the caret, a match, ACTIVE, the HUD caption
    var hudCaption: Color { isGlass ? .overlayPrimary : .overlaySecondary }
    var sectionCaption: Color { isGlass ? .secondary : .overlaySecondary }
    var listSectionHeader: Color { isGlass ? .secondary : .overlayPrimary }
    /// nil lets the rows behind show through; see `OverlayListLayout.edgeFade`
    var listSectionHeaderFill: Color? { isGlass ? nil : opaqueBackground }
    var fieldBorder: Color { isGlass ? separator : .overlayPrimary.opacity(0.45) }
    var buttonFill: Color { isGlass ? surface : .overlayPrimary.opacity(0.12) }
    var tiledWindowFill: Color { isGlass ? Color.primary.opacity(0.12) : .overlayPrimary.opacity(0.22) }
    var floatingWindowOpacity: Double { isGlass ? 0.3 : 0.45 }
    func workspaceCardBorder(isActive: Bool) -> Color {
        isActive && !isGlass ? .overlayPrimary.opacity(0.7) : separator
    }
}

// MARK: - overlay style

private struct OverlayStyleKey: EnvironmentKey {
    // classic outside an overlay, so Settings never picks up glass chips
    static let defaultValue: OverlayStyle = .classic
}

extension EnvironmentValues {
    var overlayStyle: OverlayStyle {
        get { self[OverlayStyleKey.self] }
        set { self[OverlayStyleKey.self] = newValue }
    }
}

extension View {
    /// Put the saved overlay style in the environment and keep it live.
    /// Goes on an overlay's root view.
    func overlayStyleFromConfig() -> some View { modifier(OverlayStyleProvider()) }

    /// The one switch point for an overlay card's chrome. Classic draws the
    /// given fill and border with the usual shadow. Glass draws a neutral
    /// glass shape behind the content instead.
    func overlayCard<Fill: View, Border: View>(cornerRadius: CGFloat,
                                              classicFill: Fill,
                                              classicBorder: Border) -> some View {
        modifier(OverlayCard(cornerRadius: cornerRadius, classicFill: classicFill,
                             classicBorder: classicBorder))
    }
}

// watches only overlayStyle, not all of UserConfig, so other settings
// don't redraw the overlay
private struct OverlayStyleProvider: ViewModifier {
    @State private var style = UserConfig.shared.overlayStyle

    func body(content: Content) -> some View {
        content
            .environment(\.overlayStyle, style)
            .onReceive(UserConfig.shared.$overlayStyle.removeDuplicates()) { style = $0 }
    }
}

private struct OverlayCard<Fill: View, Border: View>: ViewModifier {
    @Environment(\.overlayStyle) private var style
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let classicFill: Fill
    let classicBorder: Border

    // the content keeps one identity in both styles, so switching keeps the
    // list's scroll position and the overview's search text
    func body(content: Content) -> some View {
        let classic = style == .classic
        content
            .background { if classic { classicFill } }
            .overlay { if classic { classicBorder } }
            .compositingGroup()
            .shadow(color: classic ? OverlayPalette(scheme: colorScheme).shadow : .clear,
                    radius: 18, x: 0, y: 8)
            // outside the compositing group: glass has to see what is behind it
            .background { if !classic { OverlayGlassBackground(cornerRadius: cornerRadius) } }
    }
}

/// Neutral glass for an overlay card. Liquid Glass on macOS 26 and later,
/// a behind-window blur before that. Never the navy card.
struct OverlayGlassBackground: View {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular,
                                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            blurFallback
        }
        #else
        blurFallback
        #endif
    }

    // the blur's mask has circular corners, so the stroke and shadow do too
    private var blurFallback: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
        let isDark = colorScheme == .dark
        return BehindWindowBlur(cornerRadius: cornerRadius)
            .overlay(shape.strokeBorder(Color.white.opacity(isDark ? 0.16 : 0.55), lineWidth: 0.5))
            .background(OuterShadow(shape: shape, color: .black.opacity(isDark ? 0.32 : 0.14)))
    }
}

// a drop shadow that stays outside the shape, so it can't darken the
// see-through middle
private struct OuterShadow<S: Shape>: View {
    let shape: S
    let color: Color

    var body: some View {
        shape.fill(Color.black)
            .shadow(color: color, radius: 18, x: 0, y: 8)
            .mask {
                ZStack {
                    // negative padding draws past the frame, where the shadow lands
                    Rectangle().padding(-64)
                    shape.blendMode(.destinationOut)
                }
                .compositingGroup()
            }
    }
}

// NSVisualEffectView ignores layer corner radius for behind-window blur;
// the window server only honors maskImage
private struct BehindWindowBlur: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        // the overlays never activate the app, so never let it go inactive
        view.state = .active
        view.maskImage = Self.mask(cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    static func mask(_ radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
