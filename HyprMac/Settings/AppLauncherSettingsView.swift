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
                                    Text(appDisplayName(for: bundleID))
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

}

// MARK: - editor sheet

struct AppLauncherEditorSheet: View {
    let onSave: (Keybind) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedAppName = ""
    @State private var selectedBundleID = ""
    @State private var recordedKeyCode: UInt16 = 0
    @State private var useHypr = true
    @State private var useShift = false
    @State private var useControl = false
    @State private var useOption = false
    @State private var useCommand = false

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
                KeyRecorderView(
                    keyCode: $recordedKeyCode,
                    useHypr: $useHypr, useShift: $useShift,
                    useControl: $useControl, useOption: $useOption,
                    useCommand: $useCommand
                )
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
        let mods = ModifierFlags.from(hypr: useHypr, shift: useShift, control: useControl, option: useOption, command: useCommand)
        onSave(Keybind(keyCode: recordedKeyCode, modifiers: mods,
                       action: .launchApp(bundleID: selectedBundleID)))
        dismiss()
    }
}
