import SwiftUI

struct TilingSettingsView: View {
    @ObservedObject var config = UserConfig.shared

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

            Section("Preview") {
                TilingPreview(gap: config.gapSize, padding: config.outerPadding)
                    .frame(height: 160)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct TilingPreview: View {
    let gap: CGFloat
    let padding: CGFloat

    var body: some View {
        GeometryReader { geo in
            let rect = geo.frame(in: .local).insetBy(dx: padding / 2, dy: padding / 2)
            let halfGap = gap / 4

            HStack(spacing: halfGap) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: rect.width * 0.5 - halfGap)

                VStack(spacing: halfGap) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.4))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.3))
                }
            }
            .padding(padding / 2)
        }
    }
}
