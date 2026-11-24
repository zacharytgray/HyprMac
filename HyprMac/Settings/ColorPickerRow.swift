// Color picker used by Settings → Appearance for the corner marks, the
// focus border, the floating outline and the overlay accent.

import SwiftUI

/// `HStack` row of label + optional Reset button + `ColorPicker`,
/// sharing the "default vs. user-customized hex" reset semantics.
/// When `defaultLabel` is set and the color is unset (`!isCustom`),
/// shows a mono "<token> · default" chip next to the swatch instead
/// of a Reset button.
struct ColorPickerRow: View {
    let label: String
    let isCustom: Bool
    let onReset: () -> Void
    @Binding var color: Color
    var defaultLabel: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if !label.isEmpty {
                Text(label)
                Spacer()
            }
            if isCustom {
                Button("Default", action: onReset)
                    .buttonStyle(.settings)
            } else if let defaultLabel {
                Text(defaultLabel)
                    .font(.hyprMonoXs)
                    .foregroundStyle(Color.settingsTextFaint)
            }
            // a navy swatch; the system well sits on top, nearly clear, so
            // a click still opens the color panel
            RoundedRectangle(cornerRadius: HyprRadius.sm + 1, style: .continuous)
                .fill(color)
                .frame(width: 38, height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: HyprRadius.sm + 1, style: .continuous)
                        .strokeBorder(Color.settingsHairline, lineWidth: 1)
                )
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                        .fill(Color.settingsRaised)
                )
                .overlay {
                    ColorPicker("", selection: $color, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 42, height: 24)
                        .opacity(0.02)
                }
                .accessibilityElement(children: .combine)
        }
    }
}
