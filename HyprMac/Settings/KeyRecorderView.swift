// Chord recorder shared by the keybind and app-launcher editor
// sheets.

import SwiftUI

/// Chord recorder. Modifier toggles plus a record button; while
/// recording, a local `NSEvent` monitor captures the next key down.
/// Modifier-only key codes are rejected so users cannot bind to a
/// bare modifier.
struct KeyRecorderView: View {
    @ObservedObject var config = UserConfig.shared
    @Binding var keyCode: UInt16
    @Binding var useHypr: Bool
    @Binding var useShift: Bool
    @Binding var useControl: Bool
    @Binding var useOption: Bool
    @Binding var useCommand: Bool

    @State private var isRecording = false
    @State private var recordingPulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: HyprSpacing.sm) {
            // modifier toggles
            HStack(spacing: HyprSpacing.xs + 2) {
                ModifierToggle("\(config.hyprKey.badgeLabel) Hypr", isOn: $useHypr)
                ModifierToggle("⌃ Ctrl",  isOn: $useControl)
                ModifierToggle("⌥ Opt",   isOn: $useOption)
                ModifierToggle("⇧ Shift", isOn: $useShift)
                ModifierToggle("⌘ Cmd",   isOn: $useCommand)
            }

            // chord display / record button
            Button { isRecording.toggle() } label: {
                HStack(spacing: HyprSpacing.sm) {
                    if isRecording {
                        Circle()
                            .fill(Color.hyprMagenta)
                            .frame(width: 7, height: 7)
                            .opacity(recordingPulse ? 1 : 0.3)
                            .onAppear {
                                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                                    recordingPulse = true
                                }
                            }
                            .onDisappear { recordingPulse = false }
                        Text("Press a key…")
                            .font(.hyprBody)
                            .foregroundStyle(Color.hyprMagenta)
                    } else if keyCode != 0 {
                        KeybadgeView(bind: previewBind)
                    } else {
                        Text("Click to record a chord")
                            .font(.hyprBody)
                            .foregroundStyle(Color.hyprTextSecondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, HyprSpacing.md)
                .padding(.vertical, HyprSpacing.sm + 1)
                .background(
                    RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                        .fill(isRecording
                              ? Color.hyprMagenta.opacity(0.07)
                              : Color.hyprSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                        .strokeBorder(isRecording
                                      ? Color.hyprMagenta.opacity(0.65)
                                      : Color.hyprSeparator,
                                      lineWidth: isRecording ? 1 : 0.5)
                )
            }
            .buttonStyle(.plain)
            .onAppear { setupKeyMonitor() }
        }
    }

    private var previewBind: Keybind {
        Keybind(keyCode: keyCode, modifiers: currentModifiers, action: .toggleFloating)
    }

    var currentModifiers: ModifierFlags {
        .from(hypr: useHypr, shift: useShift, control: useControl, option: useOption, command: useCommand)
    }

    private func setupKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isRecording else { return event }
            let code = event.keyCode
            if kModifierKeyCodes.contains(Int(code)) { return nil }
            keyCode = code
            isRecording = false
            return nil
        }
    }
}

// MARK: - modifier toggle

struct ModifierToggle: View {
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        _isOn = isOn
    }

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(label)
                .font(.hyprMonoSm)
                .padding(.horizontal, HyprSpacing.sm)
                .padding(.vertical, HyprSpacing.xs + 1)
                .background(
                    RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                        .fill(isOn
                              ? Color.hyprCyan.opacity(0.15)
                              : Color.hyprSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                        .strokeBorder(isOn
                                      ? Color.hyprCyan.opacity(0.55)
                                      : Color.hyprSeparator,
                                      lineWidth: 0.5)
                )
                .foregroundStyle(isOn ? Color.hyprCyan : Color.hyprTextPrimary)
        }
        .buttonStyle(.plain)
        .animation(HyprMotion.snap, value: isOn)
    }
}
