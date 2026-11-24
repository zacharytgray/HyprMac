// "Tiling" section of Settings: the gaps with a live preview, and the
// float and tile rules. Also, until their sections are redone, the old
// Layout tab's focus appearance, scratchpad and per-monitor panels, plus
// the editors and previews they share.

import SwiftUI

/// "Tiling": space between tiles, and which apps float or tile.
struct TilingSettingsView: View {
    @ObservedObject var config = UserConfig.shared

    var body: some View {
        VStack(spacing: HyprSpacing.lg) {
            gapsCard
            rulesCard
            SectionResetFooter(title: "Reset Tiling to defaults",
                               message: "Sets both gaps to \(Int(UserConfigDefaults.gapSize)) px and puts the rules back to the two defaults, FaceTime and System Settings floating. Rules you added are removed; a copy of your settings is kept beside config.json.") {
                config.resetToDefaults(.tiling)
            }
        }
    }

    // MARK: gaps: sliders left, live preview right

    private var gapsCard: some View {
        SettingsCard("Gaps") {
            HStack(alignment: .center, spacing: HyprSpacing.lg) {
                VStack(alignment: .leading, spacing: HyprSpacing.md) {
                    gapSlider("Between windows", icon: "rectangle.split.2x1", value: $config.gapSize)
                    gapSlider("Screen edges", icon: "rectangle.dashed", value: $config.outerPadding)
                    Text("Monitors can change the edges one side at a time.")
                        .font(.hyprCaption)
                        .foregroundStyle(Color.settingsTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                DwindlePreview(windowCount: 4, aspectRatio: 16.0 / 10.0,
                               gap: config.gapSize, padding: config.outerPadding)
                    .frame(width: 220, height: 138)
                    .background(
                        RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                            .fill(Color.settingsBackground)
                    )
            }
            .padding(HyprSpacing.md)
        }
    }

    private func gapSlider(_ title: String, icon: String, value: Binding<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: HyprSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.hyprCyan)
                    .frame(width: 18)
                Text(title)
                    .font(.hyprBody)
                    .foregroundStyle(Color.settingsText)
            }
            SettingsSlider(value: Binding(get: { Double(value.wrappedValue) },
                                          set: { value.wrappedValue = CGFloat($0) }),
                           range: 0...32, step: 2, label: { "\(Int($0)) px" }, width: 150)
                .padding(.leading, 18 + HyprSpacing.sm)
        }
    }

    // MARK: float and tile rules

    // one list for every rule: an app in Never tile, an app tile rule, and
    // the rules for one kind of window, made from the menu bar or an action
    private var rulesCard: some View {
        SettingsCard("Float and tile rules",
                     footer: "A rule for one kind of window beats a rule for its app.") {
            let rows = FloatingRuleRow.rows(excludedBundleIDs: config.excludedBundleIDs,
                                            rules: config.floatingRules)
            if rows.isEmpty {
                SettingsRow("No rules", icon: "circle.dashed", tint: .settingsTextMuted,
                            subtitle: "HyprMac decides what floats.") { EmptyView() }
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { _, row in
                    FloatingRuleRowView(row: row, config: config, isLast: false,
                                        appName: appDisplayName(for: row.bundleID))
                }
            }
            SettingsRow("Always float an app", icon: "plus.circle", divider: false) {
                Button("Choose…") { pickAlwaysFloatApp() }
                    .buttonStyle(.settings)
            } detail: {
                ShortcutHint("Or a rule for the focused window with", action: .showWindowRules)
            }
        }
    }

    private func pickAlwaysFloatApp() {
        let panel = NSOpenPanel()
        panel.title = "Select Application to Exclude"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url,
           let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
            // through the rule path, so an app tile rule for it goes
            config.addAlwaysFloatApp(id)
        }
    }
}

/// The old "Layout" tab's other panels, unchanged in look, shown in their
/// new sections until each section gets its redesign.
struct MovedLayoutPanels: View {
    enum Panel { case focus }

    let panels: [Panel]
    @ObservedObject var config = UserConfig.shared
    @State private var screens: [NSScreen] = NSScreen.screens

    var body: some View {
        VStack(spacing: HyprSpacing.lg) {
            ForEach(Array(panels.enumerated()), id: \.offset) { _, panel in
                switch panel {
                case .focus: focusPanel
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
    }

    // MARK: focus indicator + dim

    private enum FocusIndicatorChoice: String, Hashable {
        case corners = "Corners"
        case borders = "Window borders"
        case both = "Both (saved)"
        case none = "None"
    }

    private var focusIndicatorChoice: FocusIndicatorChoice {
        switch (config.focusBracketStyle != .off, config.showFocusBorder) {
        case (true, false): return .corners
        case (false, true): return .borders
        case (true, true): return .both
        case (false, false): return .none
        }
    }

    private var focusIndicatorChoices: [FocusIndicatorChoice] {
        var choices: [FocusIndicatorChoice] = [.corners, .borders, .none]
        if focusIndicatorChoice == .both { choices.insert(.both, at: 2) }
        return choices
    }

    private func selectFocusIndicator(_ choice: FocusIndicatorChoice) {
        switch choice {
        case .corners:
            config.setFocusIndicators(showCorners: true, showBorders: false)
        case .borders:
            config.setFocusIndicators(showCorners: false, showBorders: true)
        case .both:
            config.setFocusIndicators(showCorners: true, showBorders: true)
        case .none:
            config.setFocusIndicators(showCorners: false, showBorders: false)
        }
    }

    private func floatingColorRow(divider: Bool) -> some View {
        HyprRow("Floating window color", icon: "paintpalette.fill",
                subtitle: config.focusBracketStyle != .off
                    ? "Outlines floating windows and colors the focus marks on a floating window."
                    : nil,
                divider: divider, floatingMarker: true) {
            ColorPickerRow(
                label: "",
                isCustom: config.floatingBorderColorHex != nil,
                onReset: { config.floatingBorderColorHex = nil },
                color: Binding(
                    get: { Color(config.resolvedFloatingBorderColor) },
                    set: { config.floatingBorderColorHex = NSColor($0).hexString }
                ),
                defaultLabel: "magenta · default"
            )
        }
    }

    private var focusPanel: some View {
        HyprPanel("Focus appearance",
                  footer: "Dimming is independent from the focus indicator. Corners appear while the Hypr key is held; window borders remain visible.") {
            HyprRow("Dim inactive windows", icon: "moon",
                    divider: true) {
                Toggle("", isOn: $config.dimInactiveWindows)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
            if config.dimInactiveWindows {
                HyprRow("Dim intensity", icon: "circle.lefthalf.filled",
                        subtitle: config.dimIntensity > 0.27
                            ? "Saved amount is outside the slider range; moving it chooses 0–27%."
                            : nil) {
                    HStack(spacing: HyprSpacing.sm) {
                        Slider(value: Binding(
                            get: { min(max(config.dimIntensity, 0), 0.27) },
                            set: { config.dimIntensity = $0 }
                        ), in: 0...0.27)
                            .frame(width: 180)
                        HyprChip(String(format: "%.1f%%", config.dimIntensity * 100))
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }

            HyprRow("Focus indicator", icon: "viewfinder", divider: true) {
                Picker("", selection: Binding(
                    get: { focusIndicatorChoice },
                    set: { selectFocusIndicator($0) }
                )) {
                    ForEach(focusIndicatorChoices, id: \.self) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
            }
            if config.showFocusBorder {
                HyprRow("Flash on focus change", icon: "sparkle",
                        subtitle: "Briefly tints the window the border moves to. Off keeps only the border.",
                        divider: true) {
                    Toggle("", isOn: $config.focusBorderFlash)
                        .toggleStyle(HyprToggleStyle())
                        .labelsHidden()
                }
            }
            HyprRow("Animate focus moves", icon: "arrow.up.and.down.and.arrow.left.and.right",
                    subtitle: "The indicator glides to the window you focus, swap or split from the keyboard.",
                    divider: true) {
                Toggle("", isOn: $config.animateFocusIndicator)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
                    .disabled(focusIndicatorChoice == .none)
            }
            if config.focusBracketStyle != .off {
                HyprRow("Mark roundness", icon: "viewfinder.circle", divider: false) {
                    VStack(alignment: .trailing, spacing: HyprSpacing.xs) {
                        HStack(spacing: HyprSpacing.sm) {
                            Slider(value: Binding(
                                get: { config.resolvedFocusBracketRadius },
                                set: { config.focusBracketRadiusOverride = $0 }
                            ), in: 0...32, step: 1)
                                .frame(width: 180)
                            HyprChip("\(Int(config.resolvedFocusBracketRadius)) pt")
                                .frame(width: 56, alignment: .trailing)
                        }
                        Button("Reset to \(Int(UserConfigDefaults.focusBracketRadius)) pt") {
                            config.focusBracketRadiusOverride = nil
                        }
                        .controlSize(.small)
                        .disabled(config.focusBracketRadiusOverride == nil)
                    }
                }
                HyprRow("Mark length", icon: "ruler", divider: false) {
                    VStack(alignment: .trailing, spacing: HyprSpacing.xs) {
                        HStack(spacing: HyprSpacing.sm) {
                            Slider(value: Binding(
                                get: { config.resolvedFocusBracketLength },
                                set: { config.focusBracketLengthOverride = $0 }
                            ), in: 4...40, step: 1)
                                .frame(width: 180)
                            HyprChip("\(Int(config.resolvedFocusBracketLength)) pt")
                                .frame(width: 56, alignment: .trailing)
                        }
                        Button("Reset to \(Int(UserConfigDefaults.focusBracketLength)) pt") {
                            config.focusBracketLengthOverride = nil
                        }
                        .controlSize(.small)
                        .disabled(config.focusBracketLengthOverride == nil)
                    }
                }
                HyprRow("Mark thickness", icon: "lineweight", divider: false) {
                    HStack(spacing: HyprSpacing.sm) {
                        Slider(value: Binding(
                            get: { config.resolvedFocusBracketThickness },
                            set: { config.focusBracketThicknessOverride = $0 }
                        ), in: 1...6, step: 0.5)
                            .frame(width: 180)
                        HyprChip(String(format: "%.1f pt", config.resolvedFocusBracketThickness))
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                HyprRow("Corner color", icon: "paintpalette", divider: config.showFocusBorder) {
                    ColorPickerRow(
                        label: "",
                        isCustom: config.focusBracketColorHex != nil,
                        onReset: { config.focusBracketColorHex = nil },
                        color: Binding(
                            get: { Color(config.resolvedFocusBracketColor) },
                            set: { config.focusBracketColorHex = NSColor($0).hexString }
                        ),
                        defaultLabel: "black · default"
                    )
                }
                // corners alone: the floater outlines use it. with
                // borders on, the row sits in the border group below
                if !config.showFocusBorder {
                    floatingColorRow(divider: true)
                }
            }

            HyprRow("Window corner radius", icon: "rectangle.roundedtop",
                    subtitle: "Match the app window edge for dimming and borders.",
                    divider: true) {
                VStack(alignment: .trailing, spacing: HyprSpacing.xs) {
                    HStack(spacing: HyprSpacing.sm) {
                        Slider(value: Binding(
                            get: { config.windowCornerRadius },
                            set: { config.windowCornerRadiusOverride = $0 }
                        ), in: 0...32, step: 1)
                            .frame(width: 180)
                        HyprChip("\(Int(config.windowCornerRadius)) pt")
                            .frame(width: 56, alignment: .trailing)
                    }
                    Button("Reset to Suggested") {
                        config.windowCornerRadiusOverride = nil
                    }
                    .controlSize(.small)
                    .disabled(config.windowCornerRadiusOverride == nil)
                }
            }

            if config.showFocusBorder {
                HyprRow("Tiled window color", icon: "paintpalette", divider: false) {
                    ColorPickerRow(
                        label: "",
                        isCustom: config.focusBorderColorHex != nil,
                        onReset: { config.focusBorderColorHex = nil },
                        color: Binding(
                            get: { Color(config.resolvedFocusBorderColor) },
                            set: { config.focusBorderColorHex = NSColor($0).hexString }
                        ),
                        defaultLabel: "cyan · default"
                    )
                }
                floatingColorRow(divider: false)
            }

            HyprRow("Overlay accent", icon: "paintpalette",
                    subtitle: "Keybind sheet and menu bar.",
                    divider: true) {
                ColorPickerRow(
                    label: "",
                    isCustom: config.overlayAccentHex != nil,
                    onReset: { config.overlayAccentHex = nil },
                    color: Binding(
                        get: { Color.overlayPrimary },
                        set: { config.overlayAccentHex = NSColor($0).hexString }
                    ),
                    defaultLabel: "cyan · default"
                )
            }

            HyprRow("Fade duration", icon: "timer",
                    subtitle: "Shared by borders, dimming, and the scratchpad scrim.",
                    divider: true) {
                HStack(spacing: HyprSpacing.sm) {
                    Slider(value: $config.chromeFadeDurationSec, in: 0.0...1.0, step: 0.01)
                        .frame(width: 180)
                    HyprChip(String(format: "%.0fms", config.chromeFadeDurationSec * 1000))
                        .frame(width: 56, alignment: .trailing)
                }
            }

            HyprRow("Appearance defaults", icon: "arrow.counterclockwise", divider: false) {
                Button("Reset all appearance defaults") {
                    config.resetAppearanceToDefaults()
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - dwindle preview

struct DwindlePreview: View {
    let windowCount: Int
    let aspectRatio: CGFloat
    let gap: CGFloat
    let padding: CGFloat
    // per-side overrides; a nil side uses `padding`
    var edges = EdgePadding()

    var body: some View {
        GeometryReader { geo in
            let previewSize = DwindleLayout.fitSize(in: geo.size, aspect: aspectRatio)
            let origin = CGPoint(
                x: (geo.size.width - previewSize.width) / 2,
                y: (geo.size.height - previewSize.height) / 2
            )
            let outerRect = CGRect(origin: origin, size: previewSize)

            let scale = previewSize.width / (aspectRatio * 1000)
            let scaledGap = max(gap * scale, 1)
            let pad = { (side: CGFloat?) in max((side ?? padding) * scale, 1) }
            let top = pad(edges.top), left = pad(edges.left)
            let bottom = pad(edges.bottom), right = pad(edges.right)

            let innerRect = CGRect(x: outerRect.minX + left, y: outerRect.minY + top,
                                   width: max(outerRect.width - left - right, 1),
                                   height: max(outerRect.height - top - bottom, 1))
            let rects = DwindleLayout.rects(count: windowCount, in: innerRect, gap: scaledGap)

            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.settingsHairline, lineWidth: 0.5)
                .frame(width: previewSize.width, height: previewSize.height)
                .position(x: outerRect.midX, y: outerRect.midY)

            ForEach(Array(rects.enumerated()), id: \.offset) { idx, rect in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.hyprCyan.opacity(0.45 - Double(idx) * 0.05))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }
}
