// Keybind chord-display chips shared by the Keys tab and the keybind
// overlay.

import SwiftUI

/// Renders a keybind's chord as a row of chip-styled key badges
/// (Hypr, modifiers, key). The Hypr modifier is always the "hypr" chip,
/// whatever physical key the user picked.
struct KeybadgeView: View {
    let bind: Keybind
    var fontSize: CGFloat = 13

    private var otherLabels: [String] {
        let labels = bind.badgeLabels()
        return bind.modifiers.contains(.hypr) ? Array(labels.dropFirst()) : labels
    }

    var body: some View {
        HStack(spacing: 3) {
            if bind.modifiers.contains(.hypr) { HyprKeyChip(fontSize: fontSize) }
            ForEach(Array(otherLabels.enumerated()), id: \.offset) { _, label in
                KeyChip(label, fontSize: fontSize)
            }
        }
        // chips never wrap; the row title gives way instead
        .fixedSize()
    }
}

/// Single chip-styled key label rendered inside `KeybadgeView`.
struct KeyChip: View {
    let label: String
    var fontSize: CGFloat = 13
    // an opaque chip reads as a hole in glass
    @Environment(\.overlayStyle) private var overlayStyle
    init(_ label: String, fontSize: CGFloat = 13) {
        self.label = label
        self.fontSize = fontSize
    }

    var body: some View {
        Text(label)
            .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: 28)
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                    .fill(overlayStyle == .glass ? Color.primary.opacity(0.07) : Color.hyprSurfaceElevated)
            )
            .overlay(
                // key-cap depth: separator on the sides/top, a touch brighter
                // on the bottom edge so the chip reads as a raised key.
                RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.hyprSeparator, Color.hyprTextPrimary.opacity(0.25)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .foregroundStyle(Color.hyprTextPrimary)
    }
}
