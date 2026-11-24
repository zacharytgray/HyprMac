// Reusable building blocks for the settings window. Each tab is a
// vertical stack of `HyprPanel`s, each panel a stack of `HyprRow`s.
// Identifier-ish text (keybind chords, bundle ids, monitor names)
// goes through `HyprChip` so monospace styling lives in one place.

import SwiftUI

// MARK: - HyprPanel

/// Rounded section container. Pass an optional `title` (rendered in
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
    /// appends the magenta ○ floating-layer marker after the title
    let floatingMarker: Bool
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String,
         icon: String? = nil,
         subtitle: String? = nil,
         divider: Bool = true,
         floatingMarker: Bool = false,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.icon = icon
        self.subtitle = subtitle
        self.divider = divider
        self.floatingMarker = floatingMarker
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
                    (Text(title)
                        + (floatingMarker
                            ? Text("  " + HyprGlyph.floatingMarker).font(.system(size: 10)).foregroundColor(.hyprMagenta)
                            : Text("")))
                        .font(.hyprBody)
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

/// Cyan-accent pill for status badges such as ACTIVE and ENABLED.
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

// MARK: - ReadOnlyConfigNotice

/// Shown above every tab while a config file can't be saved, as when Nix
/// or a dotfiles tool manages it.
struct ReadOnlyConfigNotice: View {
    var body: some View {
        HyprPanel {
            HyprRow("Managed outside HyprMac", icon: "lock.doc",
                    subtitle: "Changes here aren't saved. They last until the file reloads.",
                    divider: false) {
                HyprChip("READ-ONLY")
            }
        }
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

// MARK: - redesigned screens

// the navy look for screens already redone. old screens keep HyprPanel and
// HyprRow until their turn, so both sets live here for now

/// Page title plus one line saying what the page holds.
struct SettingsPageHeader: View {
    let title: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.hyprTitle)
                .foregroundStyle(Color.settingsText)
            Text(summary)
                .font(.hyprCaption)
                .foregroundStyle(Color.settingsTextMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Titled card of rows on the navy chassis.
struct SettingsCard<Content: View>: View {
    let title: String?
    let footer: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, footer: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.settingsTextMuted)
                    .textCase(.uppercase)
                    .kerning(0.8)
                    .padding(.horizontal, HyprSpacing.md)
            }
            VStack(spacing: 0) { content() }
                .background(
                    RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                        .fill(Color.settingsSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                        .strokeBorder(Color.settingsHairline, lineWidth: 0.5)
                )
            if let footer {
                Text(footer)
                    .font(.hyprCaption)
                    .foregroundStyle(Color.settingsTextMuted)
                    .padding(.horizontal, HyprSpacing.md)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One setting: colored icon, title, a one-line subtitle, the control.
struct SettingsRow<Trailing: View, Detail: View>: View {
    let title: String
    let icon: String
    let tint: Color
    let subtitle: String?
    let divider: Bool
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let detail: () -> Detail

    init(_ title: String, icon: String, tint: Color = .hyprCyan, subtitle: String? = nil,
         divider: Bool = true,
         @ViewBuilder trailing: @escaping () -> Trailing,
         @ViewBuilder detail: @escaping () -> Detail) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.subtitle = subtitle
        self.divider = divider
        self.trailing = trailing
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: HyprSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.hyprBody)
                    .foregroundStyle(Color.settingsText)
                if let subtitle {
                    Text(subtitle)
                        .font(.hyprCaption)
                        .foregroundStyle(Color.settingsTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                detail()
            }
            Spacer(minLength: HyprSpacing.md)
            // the toggle style carries its own spacer; fixedSize keeps the
            // control from taking half the row
            trailing().fixedSize()
        }
        .padding(.horizontal, HyprSpacing.md)
        .padding(.vertical, HyprSpacing.sm + 1)
        // a full point at lower opacity: a half-point line on a fractional
        // row edge blurs away to nothing
        .overlay(alignment: .bottom) {
            if divider {
                Rectangle()
                    .fill(Color.settingsHairline.opacity(0.7))
                    .frame(height: 1)
                    .padding(.leading, HyprSpacing.md + 18 + HyprSpacing.md)
            }
        }
    }
}

extension SettingsRow where Detail == EmptyView {
    init(_ title: String, icon: String, tint: Color = .hyprCyan, subtitle: String? = nil,
         divider: Bool = true, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title, icon: icon, tint: tint, subtitle: subtitle, divider: divider,
                  trailing: trailing, detail: { EmptyView() })
    }
}

/// Segmented choice with descriptive labels. The chosen segment gets a raised
/// fill, primary text and a short cyan bar, not an accent fill.
struct SettingsSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let chosen = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(.system(size: 11.5, weight: chosen ? .semibold : .regular))
                        .foregroundStyle(chosen ? Color.settingsText : Color.settingsTextMuted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: HyprRadius.sm + 1, style: .continuous)
                                .fill(chosen ? Color.settingsRaised : Color.clear)
                        )
                        .overlay(alignment: .bottom) {
                            if chosen {
                                Capsule().fill(Color.hyprCyan)
                                    .frame(width: 14, height: 2)
                                    .offset(y: -1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                .fill(Color.settingsBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                .strokeBorder(Color.settingsHairline, lineWidth: 0.5)
        )
        .fixedSize()
    }
}

/// Small status word in a hairline pill: GRANTED, ON, MANAGED.
struct SettingsStatusPill: View {
    let text: String
    var tint: Color = .hyprCyan

    var body: some View {
        Text(text)
            .font(.hyprMonoXs)
            .kerning(0.5)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .overlay(
                RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                    .strokeBorder(tint.opacity(0.55), lineWidth: 0.5)
            )
    }
}

/// "Reset Mouse to defaults…" at the foot of a section. Asks first, says
/// what it resets, and keeps per-Mac settings out of it.
struct SectionResetFooter: View {
    let title: String
    let message: String
    let action: () -> Void
    @State private var confirming = false

    var body: some View {
        HStack {
            Spacer()
            Button(title + "…") { confirming = true }
                .buttonStyle(.settingsDestructive)
        }
        .confirmationDialog(title + "?", isPresented: $confirming) {
            Button("Reset", role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

/// The one button look on navy screens: a raised navy key with a hairline,
/// cyan for the main action, red text for resets.
struct SettingsButtonStyle: ButtonStyle {
    enum Kind { case secondary, prominent, destructive }
    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                    .fill(fill.opacity(pressed ? 0.75 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 0.5)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .animation(HyprMotion.snap, value: pressed)
    }

    private var foreground: Color {
        switch kind {
        case .secondary: return .settingsText
        case .prominent: return .settingsBackground
        case .destructive: return .red
        }
    }

    private var fill: Color {
        kind == .prominent ? .hyprCyan : .settingsRaised
    }

    private var stroke: Color {
        switch kind {
        case .secondary: return .settingsHairline
        case .prominent: return .hyprCyan
        case .destructive: return .red.opacity(0.45)
        }
    }
}

extension ButtonStyle where Self == SettingsButtonStyle {
    static var settings: SettingsButtonStyle { SettingsButtonStyle() }
    static var settingsProminent: SettingsButtonStyle { SettingsButtonStyle(kind: .prominent) }
    static var settingsDestructive: SettingsButtonStyle { SettingsButtonStyle(kind: .destructive) }
}

/// "Pause or resume with [hypr][P]" under a row, from the user's own bind.
/// Shows nothing when the action has no bind.
struct ShortcutHint: View {
    let lead: String
    let action: Action
    @ObservedObject private var config = UserConfig.shared

    init(_ lead: String, action: Action) {
        self.lead = lead
        self.action = action
    }

    var body: some View {
        if let bind = config.keybinds.first(where: { $0.action == action }) {
            HStack(spacing: 6) {
                Text(lead)
                    .font(.hyprCaption)
                    .foregroundStyle(Color.settingsTextMuted)
                // light key caps, so the chord reads as a hint, not a control
                HStack(spacing: 3) {
                    let labels = bind.badgeLabels()
                    if bind.modifiers.contains(.hypr) { HyprKeyChip(fontSize: 9.5) }
                    ForEach(Array(labels.dropFirst(bind.modifiers.contains(.hypr) ? 1 : 0).enumerated()),
                            id: \.offset) { _, label in
                        KeyChip(label, fontSize: 9.5, onGlass: true)
                    }
                }
                .fixedSize()
            }
            .padding(.top, 3)
        }
    }
}

/// Slider with its value in a small mono chip, on the navy cards.
struct SettingsSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: (Double) -> String
    var width: CGFloat = 170

    var body: some View {
        HStack(spacing: HyprSpacing.sm) {
            // snapped in the binding: a stepped Slider draws a tick per step
            Slider(value: Binding(get: { value },
                                  set: { value = ($0 / step).rounded() * step }),
                   in: range)
                .tint(.hyprCyan)
                .frame(width: width)
            Text(label(value))
                .font(.hyprMonoSm)
                .foregroundStyle(Color.settingsText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .frame(minWidth: 52)
                .background(
                    RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                        .fill(Color.settingsRaised)
                )
        }
    }
}
