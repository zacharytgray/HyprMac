// "Appearance" section of Settings: the focus indicator, corner marks,
// dimming, colors, window corners and fades, and the overlays.

import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var config = UserConfig.shared

    private enum Indicator: Hashable { case corners, borders, both, none }

    private var indicator: Indicator {
        switch (config.focusBracketStyle != .off, config.showFocusBorder) {
        case (true, false): return .corners
        case (false, true): return .borders
        case (true, true): return .both
        case (false, false): return .none
        }
    }

    private var indicatorBinding: Binding<Indicator> {
        Binding(get: { indicator }, set: { choice in
            switch choice {
            case .corners: config.setFocusIndicators(showCorners: true, showBorders: false)
            case .borders: config.setFocusIndicators(showCorners: false, showBorders: true)
            case .both: config.setFocusIndicators(showCorners: true, showBorders: true)
            case .none: config.setFocusIndicators(showCorners: false, showBorders: false)
            }
        })
    }

    private var showsCorners: Bool { config.focusBracketStyle != .off }

    var body: some View {
        VStack(spacing: HyprSpacing.lg) {
            indicatorCard
            if showsCorners { marksCard }
            dimmingCard
            if indicator != .none { colorsCard }
            windowsCard
            overlaysCard
            SectionResetFooter(title: "Reset Appearance to defaults",
                               message: "Puts back corner marks, dimming, the brand colors, the suggested window corners, the default fade and the system overlay look. Nothing outside Appearance changes.") {
                config.resetAppearanceToDefaults()
            }
        }
    }

    // MARK: focus indicator

    private var indicatorSubtitle: String {
        switch indicator {
        case .corners: return "Corner marks show on the focused window while Hypr is held."
        case .borders: return "A border stays on the focused window."
        case .both: return "Corner marks while Hypr is held, and a border that stays."
        case .none: return "Nothing marks the focused window. Dimming still works."
        }
    }

    private var indicatorCard: some View {
        SettingsCard("Focus indicator") {
            // the choice sits under the title: four labels need the full width
            SettingsRow("Show focus with", icon: "viewfinder", subtitle: indicatorSubtitle) {
                EmptyView()
            } detail: {
                SettingsSegmented(options: [(Indicator.corners, "Corners"), (.borders, "Borders"),
                                            (.both, "Corners and borders"), (.none, "None")],
                                  selection: indicatorBinding)
                    .padding(.top, 5)
            }
            if config.showFocusBorder {
                SettingsRow("Flash on focus change", icon: "sparkle",
                            subtitle: "Briefly tints the window the border moves to.") {
                    Toggle("", isOn: $config.focusBorderFlash)
                        .toggleStyle(HyprToggleStyle())
                        .labelsHidden()
                }
            }
            SettingsRow("Animate focus moves", icon: "arrow.up.and.down.and.arrow.left.and.right",
                        subtitle: "The indicator glides to the window you focus, swap or split from the keyboard.",
                        divider: false) {
                Toggle("", isOn: $config.animateFocusIndicator)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
                    .disabled(indicator == .none)
            }
        }
    }

    // MARK: corner marks

    private var marksCard: some View {
        SettingsCard("Corner marks") {
            sliderRow("Roundness", icon: "viewfinder.circle",
                      value: config.resolvedFocusBracketRadius, range: 0...32, step: 1,
                      defaultValue: UserConfigDefaults.focusBracketRadius,
                      label: { "\(Int($0)) pt" }) { config.focusBracketRadiusOverride = $0 }
            sliderRow("Length", icon: "ruler",
                      value: config.resolvedFocusBracketLength, range: 4...40, step: 1,
                      defaultValue: UserConfigDefaults.focusBracketLength,
                      label: { "\(Int($0)) pt" }) { config.focusBracketLengthOverride = $0 }
            sliderRow("Thickness", icon: "lineweight",
                      value: config.resolvedFocusBracketThickness, range: 1...6, step: 0.5,
                      defaultValue: UserConfigDefaults.focusBracketThickness,
                      label: { String(format: "%.1f pt", $0) }, divider: false) {
                config.focusBracketThicknessOverride = $0
            }
        }
    }

    /// A slider with a Default button that sets the override back to nil.
    /// The button follows the value, not the override, since a loaded
    /// config always holds the length.
    private func sliderRow(_ title: String, icon: String, value: CGFloat,
                           range: ClosedRange<Double>, step: Double, defaultValue: CGFloat,
                           label: @escaping (Double) -> String, divider: Bool = true,
                           set: @escaping (CGFloat?) -> Void) -> some View {
        SettingsRow(title, icon: icon, divider: divider) {
            HStack(spacing: HyprSpacing.sm) {
                SettingsSlider(value: Binding(get: { Double(value) }, set: { set(CGFloat($0)) }),
                               range: range, step: step, label: label, width: 140)
                Button("Default") { set(nil) }
                    .buttonStyle(.settings)
                    .disabled(value == defaultValue)
            }
        }
    }

    // MARK: dimming

    private var dimmingCard: some View {
        SettingsCard("Dimming") {
            SettingsRow("Dim inactive windows", icon: "moon",
                        subtitle: "Every window but the focused one.",
                        divider: config.dimInactiveWindows) {
                Toggle("", isOn: $config.dimInactiveWindows)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
            if config.dimInactiveWindows {
                SettingsRow("Amount", icon: "circle.lefthalf.filled",
                            subtitle: config.dimIntensity > 0.27
                                ? "Saved amount is \(String(format: "%.1f%%", config.dimIntensity * 100)), above the slider; moving it chooses 0–27%."
                                : nil,
                            divider: false) {
                    SettingsSlider(value: Binding(get: { min(max(config.dimIntensity, 0), 0.27) },
                                                  set: { config.dimIntensity = $0 }),
                                   range: 0...0.27, step: 0.005,
                                   label: { String(format: "%.1f%%", $0 * 100) })
                }
            }
        }
    }

    // MARK: colors

    private var colorsCard: some View {
        SettingsCard("Colors") {
            if showsCorners {
                colorRow("Corner marks", icon: "paintpalette", hex: config.focusBracketColorHex,
                         resolved: config.resolvedFocusBracketColor, defaultLabel: "black") {
                    config.focusBracketColorHex = $0
                }
            }
            if config.showFocusBorder {
                colorRow("Border on tiled windows", icon: "paintpalette", hex: config.focusBorderColorHex,
                         resolved: config.resolvedFocusBorderColor, defaultLabel: "cyan") {
                    config.focusBorderColorHex = $0
                }
            }
            colorRow("Floating windows", icon: "paintpalette.fill", tint: .hyprMagenta,
                     subtitle: "Their outline, and the marks on a focused floater.",
                     hex: config.floatingBorderColorHex,
                     resolved: config.resolvedFloatingBorderColor, defaultLabel: "magenta",
                     divider: false) {
                config.floatingBorderColorHex = $0
            }
        }
    }

    private func colorRow(_ title: String, icon: String, tint: Color = .hyprCyan, subtitle: String? = nil,
                          hex: String?, resolved: NSColor, defaultLabel: String, divider: Bool = true,
                          set: @escaping (String?) -> Void) -> some View {
        SettingsRow(title, icon: icon, tint: tint, subtitle: subtitle, divider: divider) {
            ColorPickerRow(label: "", isCustom: hex != nil, onReset: { set(nil) },
                           color: Binding(get: { Color(resolved) }, set: { set(NSColor($0).hexString) }),
                           defaultLabel: defaultLabel + " · default")
        }
    }

    // MARK: windows

    private var windowsCard: some View {
        SettingsCard("Windows") {
            SettingsRow("Window corner rounding", icon: "rectangle.roundedtop",
                        subtitle: "Match your apps, for dimming and borders.") {
                HStack(spacing: HyprSpacing.sm) {
                    SettingsSlider(value: Binding(get: { Double(config.windowCornerRadius) },
                                                  set: { config.windowCornerRadiusOverride = CGFloat($0) }),
                                   range: 0...32, step: 1, label: { "\(Int($0)) pt" }, width: 120)
                    Button("Suggested") { config.windowCornerRadiusOverride = nil }
                        .buttonStyle(.settings)
                        .disabled(config.windowCornerRadiusOverride == nil)
                }
            }
            SettingsRow("Fade duration", icon: "timer",
                        subtitle: "Borders, dimming and the scratchpad backdrop.", divider: false) {
                SettingsSlider(value: $config.chromeFadeDurationSec, range: 0...1, step: 0.01,
                               label: { String(format: "%.0f ms", $0 * 1000) })
            }
        }
    }

    // MARK: overlays

    private var overlaysCard: some View {
        SettingsCard("Overlays") {
            SettingsRow("Overlay look", icon: "circle.lefthalf.filled",
                        subtitle: "Hypr+K, the window rules card, the HUDs and the menu bar panel.") {
                SettingsSegmented(options: OverlayAppearance.allCases.map { ($0, $0.displayName) },
                                  selection: $config.overlayAppearance)
            }
            SettingsRow("Overlay accent", icon: "paintpalette",
                        subtitle: "One color in place of the cyan and magenta pair.", divider: false) {
                ColorPickerRow(label: "", isCustom: config.overlayAccentHex != nil,
                               onReset: { config.overlayAccentHex = nil },
                               color: Binding(get: { Color.overlayPrimary },
                                              set: { config.overlayAccentHex = NSColor($0).hexString }),
                               defaultLabel: "cyan · default")
            }
        }
    }
}
