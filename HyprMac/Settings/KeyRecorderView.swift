import SwiftUI

// reusable shortcut recorder: modifier toggles + key capture button + live preview badge
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Shortcut")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            // modifier toggles
            HStack(spacing: 6) {
                ModifierToggle("\(config.hyprKey.badgeLabel) Hypr", isOn: $useHypr)
                ModifierToggle("⌃ Ctrl",  isOn: $useControl)
                ModifierToggle("⌥ Opt",   isOn: $useOption)
                ModifierToggle("⇧ Shift", isOn: $useShift)
                ModifierToggle("⌘ Cmd",   isOn: $useCommand)
            }

            // key recorder
            Button { isRecording.toggle() } label: {
                HStack(spacing: 8) {
                    if keyCode != 0 && !isRecording {
                        KeybadgeView(bind: previewBind)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(isRecording ? "Press a key…" : "Click to record a key")
                            .foregroundStyle(isRecording ? Color.accentColor : Color.secondary)
                            .font(isRecording ? .body : .callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if isRecording {
                        Circle()
                            .fill(.red)
                            .frame(width: 7, height: 7)
                            .opacity(recordingPulse ? 1 : 0.3)
                            .onAppear {
                                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                                    recordingPulse = true
                                }
                            }
                            .onDisappear { recordingPulse = false }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isRecording
                              ? Color.accentColor.opacity(0.07)
                              : Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(isRecording ? Color.accentColor : Color(nsColor: .separatorColor),
                                        lineWidth: isRecording ? 1.5 : 0.5)
                        )
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

// MARK: - modifier toggle button

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
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isOn ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(isOn ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                )
                .foregroundStyle(isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}
