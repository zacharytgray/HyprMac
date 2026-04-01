import SwiftUI
import Carbon

struct AppLauncherSettingsView: View {
    @ObservedObject var config = UserConfig.shared
    @State private var showingAddSheet = false

    // indices of launcher keybinds in config.keybinds
    private var launcherEntries: [(index: Int, bind: Keybind)] {
        config.keybinds.enumerated().compactMap { (i, bind) in
            if case .launchApp = bind.action { return (i, bind) }
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bind hotkeys to launch or focus applications. Select an app from Finder.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            List {
                ForEach(launcherEntries, id: \.bind.id) { entry in
                    if case .launchApp(let bundleID) = entry.bind.action {
                        HStack(spacing: 10) {
                            // app icon
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable()
                                    .frame(width: 24, height: 24)
                            }

                            Text(entry.bind.displayString)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 100, alignment: .leading)

                            Text(appName(for: bundleID))
                            Spacer()
                            Text(bundleID)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)

                            Button(role: .destructive) {
                                config.keybinds.remove(at: entry.index)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            HStack {
                Button(action: { showingAddSheet = true }) {
                    Label("Add App Launcher", systemImage: "plus")
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
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
    @State private var keyDisplay = "Press a key..."
    @State private var useHypr = true
    @State private var useShift = false
    @State private var useControl = false
    @State private var useOption = false
    @State private var useCommand = false
    @State private var isRecording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add App Launcher")
                .font(.headline)

            // app picker
            GroupBox("Application") {
                HStack {
                    if !selectedAppName.isEmpty {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: selectedBundleID) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 32, height: 32)
                        }
                        VStack(alignment: .leading) {
                            Text(selectedAppName)
                                .font(.body)
                            Text(selectedBundleID)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("No app selected")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Choose App...") {
                        pickApp()
                    }
                }
                .padding(4)
            }

            // key recording
            GroupBox("Shortcut") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(keyDisplay)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(isRecording ? Color.accentColor.opacity(0.1) : Color.gray.opacity(0.1))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(isRecording ? Color.accentColor : Color.clear, lineWidth: 1)
                            )

                        Button(isRecording ? "Stop" : "Record Key") {
                            isRecording.toggle()
                        }
                    }
                    .onAppear { setupKeyMonitor() }

                    HStack(spacing: 12) {
                        Toggle("⇪ Hypr", isOn: $useHypr)
                        Toggle("⇧ Shift", isOn: $useShift)
                        Toggle("⌃ Ctrl", isOn: $useControl)
                        Toggle("⌥ Opt", isOn: $useOption)
                        Toggle("⌘ Cmd", isOn: $useCommand)
                    }
                    .font(.caption)
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
            }
        }
        .padding()
        .frame(width: 420)
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
        if useHypr { mods.insert(.hypr) }
        if useShift { mods.insert(.shift) }
        if useControl { mods.insert(.control) }
        if useOption { mods.insert(.option) }
        if useCommand { mods.insert(.command) }

        let bind = Keybind(keyCode: recordedKeyCode, modifiers: mods,
                           action: .launchApp(bundleID: selectedBundleID))
        onSave(bind)
        dismiss()
    }

    private func setupKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isRecording else { return event }
            let code = event.keyCode
            // ignore modifier-only keys
            if code == 55 || code == 54 || code == 56 || code == 58 ||
               code == 59 || code == 61 || code == 62 || code == 60 { return nil }
            recordedKeyCode = code
            keyDisplay = keyCodeToName(code)
            isRecording = false
            return nil
        }
    }

    private func keyCodeToName(_ code: UInt16) -> String {
        switch Int(code) {
        case kVK_LeftArrow: return "←"; case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"; case kVK_DownArrow: return "↓"
        case kVK_Return: return "Return"; case kVK_Space: return "Space"
        case kVK_Tab: return "Tab"; case kVK_Delete: return "Delete"
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
