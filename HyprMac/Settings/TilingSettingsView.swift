import SwiftUI

struct TilingSettingsView: View {
    @ObservedObject var config = UserConfig.shared
    @State private var screens: [NSScreen] = NSScreen.screens

    var body: some View {
        Form {
            Section("Window Gaps") {
                HStack {
                    Text("Inner Gap")
                    Slider(value: $config.gapSize, in: 0...32, step: 2)
                    Text("\(Int(config.gapSize))px")
                        .frame(width: 40)
                        .monospacedDigit()
                }

                HStack {
                    Text("Outer Padding")
                    Slider(value: $config.outerPadding, in: 0...32, step: 2)
                    Text("\(Int(config.outerPadding))px")
                        .frame(width: 40)
                        .monospacedDigit()
                }
            }

            Section("Animation") {
                Toggle("Animate window transitions", isOn: $config.animateWindows)

                if config.animateWindows {
                    HStack {
                        Text("Duration")
                        Slider(value: $config.animationDuration, in: 0.05...0.4, step: 0.05)
                        Text("\(Int(config.animationDuration * 1000))ms")
                            .frame(width: 48)
                            .monospacedDigit()
                    }
                }
            }

            Section("Focus Indicator") {
                Toggle("Show focus border", isOn: $config.showFocusBorder)

                if config.showFocusBorder {
                    ColorPickerRow(
                        label: "Border Color",
                        isCustom: config.focusBorderColorHex != nil,
                        onReset: { config.focusBorderColorHex = nil },
                        color: Binding(
                            get: { Color(config.resolvedFocusBorderColor) },
                            set: { config.focusBorderColorHex = NSColor($0).hexString }
                        )
                    )
                    ColorPickerRow(
                        label: "Floating Border Color",
                        isCustom: config.floatingBorderColorHex != nil,
                        onReset: { config.floatingBorderColorHex = nil },
                        color: Binding(
                            get: { Color(config.resolvedFloatingBorderColor) },
                            set: { config.floatingBorderColorHex = NSColor($0).hexString }
                        )
                    )
                    Text("Tints the window during traversal; shows as an outline when settled. Floating windows use a separate color.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider().padding(.vertical, 4)

                Toggle("Dim inactive windows", isOn: $config.dimInactiveWindows)
                if config.dimInactiveWindows {
                    HStack {
                        Text("Dim intensity")
                        Slider(value: $config.dimIntensity, in: 0.05...0.6)
                        Text(String(format: "%.0f%%", config.dimIntensity * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Text("Darkens everything except the focused window. Uses an overlay panel ordered below the focused window — no SIP required.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Per-Monitor Settings") {
                ForEach(screens, id: \.localizedName) { screen in
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
                        padding: config.outerPadding
                    )
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // monitor name + resolution + tiling toggle
            let res = screen.frame.size
            HStack {
                Text("\(screen.localizedName) — \(Int(res.width))×\(Int(res.height))")
                    .font(.headline)
                Spacer()
                Toggle("Tiling", isOn: $tilingEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if tilingEnabled {
                // pill picker
                MaxSplitsPicker(value: $maxSplits)

                // dwindle preview matching monitor aspect ratio
                let aspect = res.width / res.height
                DwindlePreview(
                    windowCount: maxSplits + 1,
                    aspectRatio: aspect,
                    gap: gap,
                    padding: padding
                )
                .frame(height: 120)
                .background(Color(nsColor: .windowBackgroundColor))
                .cornerRadius(8)
            } else {
                Text("Tiling disabled — windows on this monitor float freely.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - pill picker (1–7)

private struct MaxSplitsPicker: View {
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...7, id: \.self) { n in
                Button {
                    value = n
                } label: {
                    Text("\(n)")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(n == value ? Color.accentColor : Color.gray.opacity(0.15))
                        )
                        .foregroundColor(n == value ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
            Text("max splits")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        Text("Maximum number of tiled windows on this display. Additional windows auto-float.")
            .font(.caption)
            .foregroundColor(.secondary)
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

            // scale gaps/padding relative to preview vs real screen
            let scale = previewSize.width / (aspectRatio * 1000) // normalize
            let scaledGap = max(gap * scale, 1)
            let scaledPad = max(padding * scale, 1)

            let innerRect = outerRect.insetBy(dx: scaledPad, dy: scaledPad)
            let rects = DwindleLayout.rects(count: windowCount, in: innerRect, gap: scaledGap)

            // monitor outline
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                .frame(width: previewSize.width, height: previewSize.height)
                .position(x: outerRect.midX, y: outerRect.midY)

            ForEach(Array(rects.enumerated()), id: \.offset) { idx, rect in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.6 - Double(idx) * 0.06))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }
}
