// "Tiling" tab. Window gaps, focus color, dim intensity,
// per-monitor enable + max-splits configuration plus a live dwindle
// preview.

import SwiftUI

/// "Tiling" tab.
struct TilingSettingsView: View {
    @ObservedObject var config = UserConfig.shared
    @State private var screens: [NSScreen] = NSScreen.screens

    var body: some View {
        VStack(spacing: HyprSpacing.lg) {
            gapsPanel
            focusPanel
            monitorsPanel
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
    }

    // MARK: gaps

    private var gapsPanel: some View {
        HyprPanel("Window Gaps") {
            HyprRow("Inner gap", icon: "rectangle.inset.filled.and.person.filled") {
                HStack(spacing: HyprSpacing.sm) {
                    Slider(value: $config.gapSize, in: 0...32, step: 2)
                        .frame(width: 180)
                    HyprChip("\(Int(config.gapSize))px")
                        .frame(width: 56, alignment: .trailing)
                }
            }
            HyprRow("Outer padding", icon: "square.dashed", divider: false) {
                HStack(spacing: HyprSpacing.sm) {
                    Slider(value: $config.outerPadding, in: 0...32, step: 2)
                        .frame(width: 180)
                    HyprChip("\(Int(config.outerPadding))px")
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
    }

    // MARK: focus indicator + dim

    private var focusPanel: some View {
        HyprPanel("Focus Indicator",
                  footer: "Corner brackets appear around the focused window while the Hypr key is held. Show focus border adds a persistent outline that tints during traversal and settles to a thin border. Both use the focus color. Dim darkens everything except the focused window — no SIP required.") {
            HyprRow("Focus color", icon: "paintpalette", divider: true) {
                ColorPickerRow(
                    label: "",
                    isCustom: config.focusBorderColorHex != nil,
                    onReset: { config.focusBorderColorHex = nil },
                    color: Binding(
                        get: { Color(config.resolvedFocusBorderColor) },
                        set: { config.focusBorderColorHex = NSColor($0).hexString }
                    )
                )
            }
            HyprRow("Show focus border", icon: "rectangle.dashed",
                    divider: config.showFocusBorder) {
                Toggle("", isOn: $config.showFocusBorder)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }

            if config.showFocusBorder {
                HyprRow("Floating border color", icon: "paintpalette.fill",
                        divider: true) {
                    ColorPickerRow(
                        label: "",
                        isCustom: config.floatingBorderColorHex != nil,
                        onReset: { config.floatingBorderColorHex = nil },
                        color: Binding(
                            get: { Color(config.resolvedFloatingBorderColor) },
                            set: { config.floatingBorderColorHex = NSColor($0).hexString }
                        )
                    )
                }
            }

            HyprRow("Dim inactive windows", icon: "moon",
                    divider: config.dimInactiveWindows) {
                Toggle("", isOn: $config.dimInactiveWindows)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
            if config.dimInactiveWindows {
                HyprRow("Dim intensity", icon: "circle.lefthalf.filled") {
                    HStack(spacing: HyprSpacing.sm) {
                        Slider(value: $config.dimIntensity, in: 0.05...0.6)
                            .frame(width: 180)
                        HyprChip(String(format: "%.0f%%", config.dimIntensity * 100))
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
            // shared between the focus border and dim overlay — they
            // fade in lockstep so chrome appears/disappears together.
            HyprRow("Animation duration", icon: "timer", divider: false) {
                HStack(spacing: HyprSpacing.sm) {
                    Slider(value: $config.chromeFadeDurationSec, in: 0.0...1.0, step: 0.01)
                        .frame(width: 180)
                    HyprChip(String(format: "%.0fms", config.chromeFadeDurationSec * 1000))
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
    }

    // MARK: monitors

    private var monitorsPanel: some View {
        HyprPanel("Per-Monitor Settings") {
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
    let gap: CGFloat
    let padding: CGFloat
    let isLast: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: HyprSpacing.sm) {
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
                    MaxSplitsPicker(value: $maxSplits)

                    let aspect = res.width / res.height
                    DwindlePreview(
                        windowCount: maxSplits + 1,
                        aspectRatio: aspect,
                        gap: gap,
                        padding: padding
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
                Text("max splits")
                    .font(.hyprCaption)
                    .foregroundStyle(Color.hyprTextSecondary)
                    .padding(.leading, HyprSpacing.xs)
            }
            Text("Maximum number of tiled windows on this display. Additional windows auto-float.")
                .font(.hyprCaption)
                .foregroundStyle(Color.hyprTextTertiary)
        }
    }
}

// MARK: - dwindle preview

private struct DwindlePreview: View {
    let windowCount: Int
    let aspectRatio: CGFloat
    let gap: CGFloat
    let padding: CGFloat

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
            let scaledPad = max(padding * scale, 1)

            let innerRect = outerRect.insetBy(dx: scaledPad, dy: scaledPad)
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
