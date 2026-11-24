// "Mouse" section of Settings: focus follows mouse, hover speed, the cursor
// on workspace switches, and the Hypr+drag gesture.

import SwiftUI

struct MouseSettingsView: View {
    @ObservedObject var config = UserConfig.shared

    var body: some View {
        VStack(spacing: HyprSpacing.lg) {
            focusCard
            pointerCard
            gesturesCard
            SectionResetFooter(title: "Reset Mouse to defaults",
                               message: "Turns focus follows mouse on at Medium speed and lets switches move the cursor again.") {
                config.resetToDefaults(.mouse)
            }
        }
    }

    // low to high, plus the saved rate when it is none of them
    private var hoverOptions: [(value: Int, label: String)] {
        var options = HoverResponseRate.allCases.reversed().map { ($0.rawValue, $0.title) }
        if HoverResponseRate(rawValue: config.mouseHoverPollHz) == nil {
            options.append((config.mouseHoverPollHz, "Custom"))
        }
        return options
    }

    private var focusCard: some View {
        SettingsCard("Focus") {
            SettingsRow("Focus follows mouse", icon: "cursorarrow.motionlines",
                        subtitle: "The window under the pointer takes focus, no click needed.") {
                Toggle("", isOn: $config.focusFollowsMouse)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
            SettingsRow("Hover speed", icon: "speedometer",
                        subtitle: "\(HoverResponseRate.displayName(for: config.mouseHoverPollHz)). Higher reacts sooner.",
                        divider: false) {
                SettingsSegmented(options: hoverOptions, selection: $config.mouseHoverPollHz)
            }
            .disabled(!config.focusFollowsMouse)
            .opacity(config.focusFollowsMouse ? 1 : 0.5)
        }
    }

    private var pointerCard: some View {
        SettingsCard("Pointer") {
            SettingsRow("Keep the cursor in place on workspace switches", icon: "cursorarrow",
                        subtitle: "A switch to another display still moves it, to that display's center.",
                        divider: false) {
                Toggle("", isOn: $config.keepCursorOnWorkspaceSwitch)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
        }
    }

    private var gesturesCard: some View {
        SettingsCard("Gestures") {
            SettingsRow("Swap tiles by dragging", icon: "hand.draw",
                        subtitle: "Hold Hypr and drag a tile by its title bar onto another, on any display.",
                        divider: false) {
                HStack(spacing: 3) {
                    HyprKeyChip(fontSize: 10)
                    KeyChip("drag", fontSize: 10, onGlass: true)
                }
            }
        }
    }
}
