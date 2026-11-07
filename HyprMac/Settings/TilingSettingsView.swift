// "Layout" tab. Window gaps, focus color, dim intensity,
// per-monitor enable, max-splits, edge padding and workspaces plus a live
// dwindle preview.

import SwiftUI

/// "Layout" tab.
struct TilingSettingsView: View {
    @ObservedObject var config = UserConfig.shared
    @State private var screens: [NSScreen] = NSScreen.screens

    var body: some View {
        VStack(spacing: HyprSpacing.lg) {
            gapsPanel
            focusPanel
            scratchpadPanel
            monitorsPanel
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
    }

    // MARK: gaps hero — sliders left, live preview right

    private var gapsPanel: some View {
        VStack(alignment: .leading, spacing: HyprSpacing.sm) {
            Text("Gaps")
                .font(.hyprSection)
                .foregroundStyle(Color.hyprTextSecondary)
                .textCase(.uppercase)
                .kerning(0.5)
                .padding(.horizontal, HyprSpacing.md)

            HStack(alignment: .top, spacing: HyprSpacing.lg + 2) {
                VStack(alignment: .leading, spacing: HyprSpacing.md) {
                    gapSlider(label: "Inner gap", value: $config.gapSize)
                    gapSlider(label: "Outer padding", value: $config.outerPadding)
                    Text("The preview updates as you drag.")
                        .font(.hyprCaption)
                        .foregroundStyle(Color.hyprTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                DwindlePreview(
                    windowCount: 4,
                    aspectRatio: 16.0 / 10.0,
                    gap: config.gapSize,
                    padding: config.outerPadding
                )
                .frame(width: 280, height: 175)
                .background(
                    RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                        .fill(Color.hyprBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                        .strokeBorder(Color.hyprSeparator, lineWidth: 0.5)
                )
            }
            .padding(HyprSpacing.md + 2)
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                    .fill(Color.hyprSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                    .strokeBorder(Color.hyprSeparator, lineWidth: 0.5)
            )
        }
    }

    private func gapSlider(label: String, value: Binding<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: HyprSpacing.xs) {
            HStack {
                Text(label).font(.hyprBody)
                Spacer()
                HyprChip("\(Int(value.wrappedValue)) px")
            }
            Slider(value: value, in: 0...32, step: 2)
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
                HyprRow("Corner color", icon: "paintpalette", divider: true) {
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
                HyprRow("Floating window color", icon: "paintpalette.fill", divider: false, floatingMarker: true) {
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

    // MARK: scratchpad

    private var scratchpadPanel: some View {
        HyprPanel("Scratchpad",
                  footer: "Padding insets the tiled region from the screen edges so the dimmed border stays visible — set it to 0% to maximize space. Windows that can't fit the tiled layout stay floating either way.") {
            HyprRow("Tile sent windows", icon: "square.grid.2x2",
                    subtitle: "Windows sent to the scratchpad tile into the layer instead of floating.",
                    divider: true, floatingMarker: true) {
                Toggle("", isOn: $config.scratchpadTileByDefault)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
            HyprRow("Layer padding", icon: "rectangle.center.inset.filled",
                    divider: false, floatingMarker: true) {
                HStack(spacing: HyprSpacing.sm) {
                    Slider(value: $config.scratchpadRegionInset, in: 0...0.15, step: 0.01)
                        .frame(width: 180)
                    HyprChip(String(format: "%.0f%%", config.scratchpadRegionInset * 100))
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
    }

    // MARK: monitors

    // the mapping would leave an enabled monitor with nothing to show
    private var workspaceMappingIgnored: Bool {
        let enabled = WorkspaceManager.leftToRight(screens)
            .filter { !config.disabledMonitors.contains($0.localizedName) }
        return WorkspaceHomeResolver.resolve(enabledNames: enabled.map(\.localizedName),
                                             mapping: config.workspaceMonitors).mappingIgnored
    }

    private var monitorsPanel: some View {
        HyprPanel("Per-Monitor Settings",
                  footer: "Edge padding replaces the outer padding on one side of a monitor, to make room for a bar or the Dock. "
                  + "Workspaces you don't put on a monitor keep their default home.") {
            if workspaceMappingIgnored {
                Text("A monitor would have no workspace, so the default workspace homes apply on this layout.")
                    .font(.hyprCaption)
                    .foregroundStyle(Color.hyprTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, HyprSpacing.md)
                    .padding(.top, HyprSpacing.md)
            }
            ForEach(Array(screens.enumerated()), id: \.element.localizedName) { idx, screen in
                MonitorSplitsRow(
                    screen: screen,
                    tilingEnabled: Binding(
                        get: { !config.disabledMonitors.contains(screen.localizedName) },
                        set: { enabled in
                            if enabled {
                                config.disabledMonitors.remove(screen.localizedName)
                            } else {
                                config.disabledMonitors.insert(screen.localizedName)
                            }
                        }
                    ),
                    maxSplits: Binding(
                        get: { config.maxSplitsPerMonitor[screen.localizedName] ?? 3 },
                        set: { newVal in
                            if newVal == 3 {
                                config.maxSplitsPerMonitor.removeValue(forKey: screen.localizedName)
                            } else {
                                config.maxSplitsPerMonitor[screen.localizedName] = newVal
                            }
                        }
                    ),
                    edgePadding: Binding(
                        get: { config.outerPaddingPerMonitor[screen.localizedName] ?? EdgePadding() },
                        set: { newVal in
                            config.outerPaddingPerMonitor[screen.localizedName] = newVal.isEmpty ? nil : newVal
                        }
                    ),
                    workspaces: Binding(
                        get: { Set(config.workspaceMonitors[screen.localizedName] ?? []) },
                        set: { newVal in
                            config.workspaceMonitors = WorkspaceHomeResolver.setting(
                                newVal, for: screen.localizedName, in: config.workspaceMonitors)
                        }
                    ),
                    gap: config.gapSize,
                    padding: config.outerPadding,
                    isLast: idx == screens.count - 1
                )
            }
        }
    }
}

// MARK: - per-monitor row

private struct MonitorSplitsRow: View {
    let screen: NSScreen
    @Binding var tilingEnabled: Bool
    @Binding var maxSplits: Int
    // a nil side = the shared outer padding
    @Binding var edgePadding: EdgePadding
    // the workspaces put on this monitor; empty = default homes
    @Binding var workspaces: Set<Int>
    let gap: CGFloat
    let padding: CGFloat
    let isLast: Bool

    @State private var editingPadding = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: HyprSpacing.md) {
                let res = screen.frame.size
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(screen.localizedName)
                            .font(.hyprBody)
                        Text("\(Int(res.width)) × \(Int(res.height))")
                            .font(.hyprMonoXs)
                            .foregroundStyle(Color.hyprTextTertiary)
                    }
                    Spacer()
                    Toggle("", isOn: $tilingEnabled)
                        .toggleStyle(HyprToggleStyle())
                        .labelsHidden()
                }

                if tilingEnabled {
                    MonitorSettingLine("Max splits") {
                        MaxSplitsPicker(value: $maxSplits)
                    }

                    MonitorSettingLine("Edge padding") {
                        HStack(spacing: HyprSpacing.sm) {
                            Text(EdgePaddingSummary.text(edgePadding, fallback: padding))
                                .font(.hyprBody)
                                .foregroundStyle(edgePadding.isEmpty ? Color.hyprTextSecondary : Color.hyprTextPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: HyprSpacing.sm)
                            Button("Edit…") { editingPadding = true }
                                .controlSize(.small)
                                .popover(isPresented: $editingPadding, arrowEdge: .bottom) {
                                    EdgePaddingEditor(monitorName: screen.localizedName,
                                                      aspect: res.width / res.height,
                                                      edgePadding: $edgePadding,
                                                      fallback: padding)
                                }
                        }
                    }

                    MonitorSettingLine("Workspaces") {
                        WorkspaceTogglePicker(selection: $workspaces)
                    }

                    DwindlePreview(
                        windowCount: maxSplits + 1,
                        aspectRatio: res.width / res.height,
                        gap: gap,
                        padding: padding,
                        edges: edgePadding
                    )
                    .frame(height: 110)
                    .background(
                        RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                            .fill(Color.hyprBackground)
                    )
                } else {
                    Text("Tiling disabled — windows on this monitor float freely.")
                        .font(.hyprCaption)
                        .foregroundStyle(Color.hyprTextSecondary)
                }
            }
            .padding(.horizontal, HyprSpacing.md)
            .padding(.vertical, HyprSpacing.md)

            if !isLast {
                Rectangle()
                    .fill(Color.hyprSeparator)
                    .frame(height: 0.5)
                    .padding(.horizontal, HyprSpacing.md)
            }
        }
    }
}

// label column + control, one per monitor setting
struct MonitorSettingLine<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HyprSpacing.md) {
            Text(label)
                .font(.hyprBody)
                .foregroundStyle(Color.hyprTextSecondary)
                .frame(width: 100, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - edge padding

enum EdgePaddingSummary {
    static func pt(_ value: CGFloat) -> String {
        String(format: "%g", Double(value))
    }

    // "Default (8 pt)", "Top 40 pt", "Top 40 pt, Left 0 pt"
    static func text(_ edges: EdgePadding, fallback: CGFloat) -> String {
        if edges.isEmpty { return "Default (\(pt(fallback)) pt)" }
        let sides = [("Top", edges.top), ("Left", edges.left), ("Bottom", edges.bottom), ("Right", edges.right)]
        let set = sides.compactMap { name, value in value.map { "\(name) \(pt($0)) pt" } }
        if set.count == 4, let top = edges.top,
           [edges.left, edges.bottom, edges.right].allSatisfy({ $0 == top }) {
            return "\(pt(top)) pt on every side"
        }
        return set.joined(separator: ", ")
    }
}

// popover: one field per screen edge around a small screen diagram
struct EdgePaddingEditor: View {
    let monitorName: String
    let aspect: CGFloat
    @Binding var edgePadding: EdgePadding
    let fallback: CGFloat
    @Environment(\.dismiss) private var dismiss

    // field text per side, so a half-typed number isn't reformatted
    @State private var top: String
    @State private var left: String
    @State private var bottom: String
    @State private var right: String

    init(monitorName: String, aspect: CGFloat, edgePadding: Binding<EdgePadding>, fallback: CGFloat) {
        self.monitorName = monitorName
        self.aspect = aspect
        self._edgePadding = edgePadding
        self.fallback = fallback
        let edges = edgePadding.wrappedValue
        _top = State(initialValue: edges.top.map(EdgePaddingSummary.pt) ?? "")
        _left = State(initialValue: edges.left.map(EdgePaddingSummary.pt) ?? "")
        _bottom = State(initialValue: edges.bottom.map(EdgePaddingSummary.pt) ?? "")
        _right = State(initialValue: edges.right.map(EdgePaddingSummary.pt) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HyprSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Edge padding")
                    .font(.hyprBody.weight(.semibold))
                Text(monitorName)
                    .font(.hyprCaption)
                    .foregroundStyle(Color.hyprTextTertiary)
            }

            VStack(spacing: HyprSpacing.sm) {
                field("Top", $top, \.top)
                HStack(spacing: HyprSpacing.sm) {
                    field("Left", $left, \.left)
                    screenDiagram
                    field("Right", $right, \.right)
                }
                field("Bottom", $bottom, \.bottom)
            }
            .frame(maxWidth: .infinity)

            Text("Space between tiled windows and each edge of this screen. "
                 + "Empty sides use the outer padding (\(EdgePaddingSummary.pt(fallback)) pt).")
                .font(.hyprCaption)
                .foregroundStyle(Color.hyprTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Reset") {
                    top = ""; left = ""; bottom = ""; right = ""
                    edgePadding = EdgePadding()
                }
                .disabled(edgePadding.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(HyprSpacing.lg)
        .frame(width: 360)
    }

    private var effective: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        (edgePadding.top ?? fallback, edgePadding.left ?? fallback,
         edgePadding.bottom ?? fallback, edgePadding.right ?? fallback)
    }

    // not to scale: big enough that 8 pt still shows
    private var screenDiagram: some View {
        let width: CGFloat = 150
        let height = width / max(aspect, 0.5)
        let cap = height * 0.35
        let inset = { (value: CGFloat) in min(value * 0.5, cap) }
        let e = effective
        return RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
            .fill(Color.hyprBackground)
            .overlay(
                RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                    .strokeBorder(Color.hyprSeparator, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.hyprCyan.opacity(0.35))
                    .padding(EdgeInsets(top: inset(e.top), leading: inset(e.left),
                                        bottom: inset(e.bottom), trailing: inset(e.right)))
            )
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }

    // empty = the outer padding, shown as the dimmed placeholder
    private func field(_ name: String, _ text: Binding<String>,
                       _ side: WritableKeyPath<EdgePadding, CGFloat?>) -> some View {
        HStack(spacing: HyprSpacing.xs) {
            TextField(name, text: text, prompt: Text(EdgePaddingSummary.pt(fallback)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
                .help(name)
                .onChange(of: text.wrappedValue) { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty {
                        edgePadding[keyPath: side] = nil
                    } else if let value = Double(trimmed) {
                        edgePadding[keyPath: side] = CGFloat(max(value, 0))
                    }
                }
            Text("pt")
                .font(.hyprCaption)
                .foregroundStyle(Color.hyprTextSecondary)
        }
    }
}

// MARK: - workspace toggles (1–10)

private struct WorkspaceTogglePicker: View {
    @Binding var selection: Set<Int>

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Constants.workspaceRange, id: \.self) { n in
                let on = selection.contains(n)
                Button {
                    if on { selection.remove(n) } else { selection.insert(n) }
                } label: {
                    Text("\(n)")
                        .font(.hyprMonoSm)
                        .frame(width: 26, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                                .fill(on ? Color.hyprCyan.opacity(0.18) : Color.hyprSurfaceElevated)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                                .strokeBorder(on ? Color.hyprCyan.opacity(0.55) : Color.hyprSeparator,
                                              lineWidth: 0.5)
                        )
                        .foregroundStyle(on ? Color.hyprCyan : Color.hyprTextSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - pill picker (1–7)

private struct MaxSplitsPicker: View {
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ForEach(1...7, id: \.self) { n in
                    Button {
                        value = n
                    } label: {
                        Text("\(n)")
                            .font(.hyprMonoSm)
                            .frame(width: 26, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                                    .fill(n == value
                                          ? Color.hyprCyan.opacity(0.18)
                                          : Color.hyprSurfaceElevated)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                                    .strokeBorder(n == value
                                                  ? Color.hyprCyan.opacity(0.55)
                                                  : Color.hyprSeparator,
                                                  lineWidth: 0.5)
                            )
                            .foregroundStyle(n == value ? Color.hyprCyan : Color.hyprTextPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Up to \(RetileAllPlanner.workspaceCapacity(maxDepth: value)) tiles per workspace, depending on window sizes. "
                 + "New windows use the next workspace when full.")
                .font(.hyprCaption)
                .foregroundStyle(Color.hyprTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - dwindle preview

private struct DwindlePreview: View {
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
                .stroke(Color.hyprSeparator, lineWidth: 0.5)
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
