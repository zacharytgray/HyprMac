// Reusable building blocks for the settings window. Each tab is a
// vertical stack of `HyprPanel`s, each panel a stack of `HyprRow`s.
// Identifier-ish text (keybind chords, bundle ids, monitor names)
// goes through `HyprChip` so monospace styling lives in one place.
// `HyprAccentBadge` is the only place the cyan signature color
// appears outside the focus border / key recorder.

import SwiftUI

// MARK: - HyprPanel

/// Rounded section container. Replaces `Form { Section { ... } }`
/// for the settings overhaul. Pass an optional `title` (rendered in
/// `.hyprSection`) and `footer` (rendered in `.hyprCaption`).
struct HyprPanel<Content: View>: View {
    let title: String?
    let footer: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil,
         footer: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HyprSpacing.sm) {
            if let title {
                Text(title)
                    .font(.hyprSection)
                    .foregroundStyle(Color.hyprTextSecondary)
                    .textCase(.uppercase)
                    .kerning(0.5)
                    .padding(.horizontal, HyprSpacing.md)
            }

            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                    .fill(Color.hyprSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                    .strokeBorder(Color.hyprSeparator, lineWidth: 0.5)
            )

            if let footer {
                Text(footer)
                    .font(.hyprCaption)
                    .foregroundStyle(Color.hyprTextSecondary)
                    .padding(.horizontal, HyprSpacing.md)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - HyprRow

/// Single label + control row inside a `HyprPanel`. Pass `divider`
/// = false on the last row of a panel to suppress the trailing
/// hairline.
struct HyprRow<Trailing: View>: View {
    let icon: String?
    let title: String
    let subtitle: String?
    let divider: Bool
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String,
         icon: String? = nil,
         subtitle: String? = nil,
         divider: Bool = true,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.icon = icon
        self.subtitle = subtitle
        self.divider = divider
        self.trailing = trailing
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: HyprSpacing.md) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.hyprTextSecondary)
                        .frame(width: 16)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.hyprBody)
                    if let subtitle {
                        Text(subtitle)
                            .font(.hyprCaption)
                            .foregroundStyle(Color.hyprTextSecondary)
                    }
                }
                Spacer(minLength: HyprSpacing.md)
                trailing()
            }
            .padding(.horizontal, HyprSpacing.md)
            .padding(.vertical, HyprSpacing.sm + 2)

            if divider {
                Rectangle()
                    .fill(Color.hyprSeparator)
                    .frame(height: 0.5)
                    .padding(.leading, icon != nil ? HyprSpacing.md + 16 + HyprSpacing.md : HyprSpacing.md)
            }
        }
    }
}

extension HyprRow where Trailing == EmptyView {
    init(_ title: String,
         icon: String? = nil,
         subtitle: String? = nil,
         divider: Bool = true) {
        self.init(title, icon: icon, subtitle: subtitle, divider: divider) { EmptyView() }
    }
}

// MARK: - HyprChip

/// Small monospace pill. Used everywhere identifier-like text appears:
/// keybind glyphs, bundle ids, monitor names, key codes.
struct HyprChip: View {
    let text: String
    let prominent: Bool

    init(_ text: String, prominent: Bool = false) {
        self.text = text
        self.prominent = prominent
    }

    var body: some View {
        Text(text)
            .font(.hyprMonoSm)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                    .fill(prominent ? Color.hyprSurfaceElevated : Color.hyprSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                    .strokeBorder(Color.hyprSeparator, lineWidth: 0.5)
            )
            .foregroundStyle(Color.hyprTextPrimary)
    }
}

// MARK: - HyprAccentBadge

/// Cyan-accent pill. Reserved for the "Hypr key" indicator, the
/// active sidebar item marker, and similar signature moments. This is
/// the only widget that paints with `.hyprCyan` by default — every
/// other surface stays monochrome.
struct HyprAccentBadge: View {
    let text: String
    let icon: String?

    init(_ text: String, icon: String? = nil) {
        self.text = text
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.hyprMonoXs)
                .kerning(0.5)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(Color.hyprCyan)
        .background(
            RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                .fill(Color.hyprCyan.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                .strokeBorder(Color.hyprCyan.opacity(0.55), lineWidth: 0.5)
        )
    }
}

// MARK: - HyprToggleStyle

/// Pill switch. Custom because the default macOS `ToggleStyle.switch`
/// uses the system accent color and a glossy capsule that fights the
/// flat surfaces of the rest of the settings window. This version is
/// flat, monochrome off / cyan on, snap-animated.
struct HyprToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: HyprSpacing.md) {
            configuration.label
            Spacer(minLength: HyprSpacing.sm)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn
                          ? Color.hyprCyan.opacity(0.85)
                          : Color.hyprTextTertiary.opacity(0.30))
                    .frame(width: 36, height: 20)
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .padding(.horizontal, 2)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            }
            .animation(HyprMotion.snap, value: configuration.isOn)
            .onTapGesture { configuration.isOn.toggle() }
        }
    }
}
