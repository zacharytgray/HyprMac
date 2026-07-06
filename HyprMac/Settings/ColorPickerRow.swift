// Reusable color picker row used by the Tiling tab for the focus
// border and floating border colors.

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
            Text(label)
            Spacer()
            if isCustom {
                Button("Reset", action: onReset)
                    .font(.caption)
            } else if let defaultLabel {
                Text(defaultLabel)
                    .font(.hyprMonoXs)
                    .foregroundStyle(Color.hyprTextTertiary)
            }
            ColorPicker("", selection: $color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 36)
        }
    }
}
