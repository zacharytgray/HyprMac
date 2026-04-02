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
                Toggle("Animate window swaps", isOn: $config.animateWindows)

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

            Section("Per-Monitor Max Splits") {
                ForEach(screens, id: \.localizedName) { screen in
                    MonitorSplitsRow(
                        screen: screen,
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
    @Binding var maxSplits: Int
    let gap: CGFloat
    let padding: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // monitor name + resolution
            let res = screen.frame.size
            Text("\(screen.localizedName) — \(Int(res.width))×\(Int(res.height))")
                .font(.headline)

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
            Text("splits")
                .font(.caption)
                .foregroundColor(.secondary)
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
            let previewSize = fitSize(in: geo.size, aspect: aspectRatio)
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
            let rects = dwindleRects(count: windowCount, in: innerRect, gap: scaledGap)

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

    // fit preview to available space while maintaining aspect ratio
    private func fitSize(in container: CGSize, aspect: CGFloat) -> CGSize {
        let maxW = container.width - 16
        let maxH = container.height - 8
        let w = min(maxW, maxH * aspect)
        let h = w / aspect
        return CGSize(width: w, height: h)
    }

    // recursive dwindle split — alternates h/v by aspect ratio
    private func dwindleRects(count: Int, in rect: CGRect, gap: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        if count == 1 { return [rect] }

        let halfGap = gap / 2
        let horizontal = rect.width >= rect.height

        let first: CGRect
        let rest: CGRect

        if horizontal {
            let splitX = rect.width * 0.5
            first = CGRect(x: rect.minX, y: rect.minY,
                           width: splitX - halfGap, height: rect.height)
            rest = CGRect(x: rect.minX + splitX + halfGap, y: rect.minY,
                          width: rect.width - splitX - halfGap, height: rect.height)
        } else {
            let splitY = rect.height * 0.5
            first = CGRect(x: rect.minX, y: rect.minY,
                           width: rect.width, height: splitY - halfGap)
            rest = CGRect(x: rect.minX, y: rect.minY + splitY + halfGap,
                          width: rect.width, height: rect.height - splitY - halfGap)
        }

        return [first] + dwindleRects(count: count - 1, in: rest, gap: gap)
    }
}
