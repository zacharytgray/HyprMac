// Reusable color picker row used by the Tiling tab for the focus
// border and floating border colors.

import SwiftUI

/// `HStack` row of label + optional Reset button + `ColorPicker`,
/// sharing the "default vs. user-customized hex" reset semantics.
struct ColorPickerRow: View {
    let label: String
    let isCustom: Bool
    let onReset: () -> Void
    @Binding var color: Color

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            if isCustom {
                Button("Reset", action: onReset)
                    .font(.caption)
            }
            ColorPicker("", selection: $color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 36)
        }
    }
}
