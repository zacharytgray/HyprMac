import SwiftUI
import Carbon

struct AppLauncherSettingsView: View {
    @ObservedObject var config = UserConfig.shared
    @State private var showingAddSheet = false

    private var launcherEntries: [(index: Int, bind: Keybind)] {
        config.keybinds.enumerated().compactMap { (i, bind) in
            if case .launchApp = bind.action { return (i, bind) }
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if launcherEntries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "app.badge")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("No App Launchers")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Bind a hotkey to instantly launch or focus any app.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Button("Add App Launcher") { showingAddSheet = true }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                }
                .padding()
                Spacer()
            } else {
                List {
                    ForEach(launcherEntries, id: \.bind.id) { entry in
                        if case .launchApp(let bundleID) = entry.bind.action {
                            HStack(spacing: 12) {
                                // app icon
                                Group {
                                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                            .resizable()
                                    } else {
                                        Image(systemName: "app")
                                            .resizable()
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 28, height: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(appName(for: bundleID))
                                        .font(.body)
                                    Text(bundleID)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }

                                Spacer()

                                KeybadgeView(bind: entry.bind)

                                Button(role: .destructive) {
                                    config.keybinds.remove(at: entry.index)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red.opacity(0.8))
                                }
                                .buttonStyle(.borderless)
                                .help("Remove")
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Button { showingAddSheet = true } label: {
                    Label("Add App Launcher", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $showingAddSheet) {
            AppLauncherEditorSheet { bind in
                config.keybinds.append(bind)
            }
        }
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }
}

// MARK: - editor sheet

struct AppLauncherEditorSheet: View {
    let onSave: (Keybind) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedAppName = ""
    @State private var selectedBundleID = ""
    @State private var recordedKeyCode: UInt16 = 0
    @State private var keyDisplay = ""
    @State private var useHypr = true
    @State private var useShift = false
    @State private var useControl = false
    @State private var useOption = false
    @State private var useCommand = false
    @State private var isRecording = false
    @State private var recordingPulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add App Launcher")
                .font(.title3.weight(.semibold))

            // app picker
            GroupBox {
                HStack(spacing: 12) {
                    Group {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: selectedBundleID),
                           !selectedAppName.isEmpty {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                        } else {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .overlay(Image(systemName: "app").foregroundStyle(.tertiary))
                        }
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        if selectedAppName.isEmpty {
                            Text("No app selected")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(selectedAppName).font(.body)
                            Text(selectedBundleID).font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                    Button("Choose App…") { pickApp() }
                }
                .padding(4)
            } label: {
                Text("Application")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            // shortcut recorder
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Shortcut")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    HStack(spacing: 6) {
                        ModifierToggle("⇪ Caps",  isOn: $useHypr)
                        ModifierToggle("⌃ Ctrl",  isOn: $useControl)
                        ModifierToggle("⌥ Opt",   isOn: $useOption)
                        ModifierToggle("⇧ Shift", isOn: $useShift)
                        ModifierToggle("⌘ Cmd",   isOn: $useCommand)
                    }

                    Button { isRecording.toggle() } label: {
                        HStack(spacing: 8) {
                            if recordedKeyCode != 0 && !isRecording {
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
                    .frame(maxWidth: .infinity)
                    .onAppear { setupKeyMonitor() }
                }
                .padding(4)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(recordedKeyCode == 0 || selectedBundleID.isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var previewBind: Keybind {
        var mods = ModifierFlags()
        if useHypr    { mods.insert(.hypr) }
        if useShift   { mods.insert(.shift) }
        if useControl { mods.insert(.control) }
        if useOption  { mods.insert(.option) }
        if useCommand { mods.insert(.command) }
        return Keybind(keyCode: recordedKeyCode, modifiers: mods, action: .toggleFloating)
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.title = "Select Application"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            if let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
                selectedBundleID = id
                selectedAppName = url.deletingPathExtension().lastPathComponent
            }
        }
    }

    private func save() {
        var mods = ModifierFlags()
        if useHypr    { mods.insert(.hypr) }
        if useShift   { mods.insert(.shift) }
        if useControl { mods.insert(.control) }
        if useOption  { mods.insert(.option) }
        if useCommand { mods.insert(.command) }

        onSave(Keybind(keyCode: recordedKeyCode, modifiers: mods,
                       action: .launchApp(bundleID: selectedBundleID)))
        dismiss()
    }

    private func setupKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isRecording else { return event }
            let code = event.keyCode
            if [55, 54, 56, 58, 59, 61, 62, 60].contains(Int(code)) { return nil }
            recordedKeyCode = code
            keyDisplay = keyCodeToName(code)
            isRecording = false
            return nil
        }
    }

    private func keyCodeToName(_ code: UInt16) -> String {
        switch Int(code) {
        case kVK_LeftArrow: return "←"; case kVK_RightArrow: return "→"
        case kVK_UpArrow:   return "↑"; case kVK_DownArrow:  return "↓"
        case kVK_Return: return "Return"; case kVK_Space: return "Space"
        case kVK_Tab:    return "Tab";    case kVK_Delete: return "Delete"
        case kVK_ANSI_A: return "A"; case kVK_ANSI_B: return "B"; case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"; case kVK_ANSI_E: return "E"; case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"; case kVK_ANSI_H: return "H"; case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"; case kVK_ANSI_K: return "K"; case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"; case kVK_ANSI_N: return "N"; case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"; case kVK_ANSI_Q: return "Q"; case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"; case kVK_ANSI_T: return "T"; case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"; case kVK_ANSI_W: return "W"; case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"; case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"; case kVK_ANSI_1: return "1"; case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"; case kVK_ANSI_4: return "4"; case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"; case kVK_ANSI_7: return "7"; case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"
        case kVK_F4: return "F4"; case kVK_F5: return "F5"; case kVK_F6: return "F6"
        case kVK_F7: return "F7"; case kVK_F8: return "F8"; case kVK_F9: return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default: return "Key(\(code))"
        }
    }
}
