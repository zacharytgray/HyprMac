// "Advanced" section of Settings: iCloud sync, other apps and status bars,
// the config and log files, detailed logging and Reset all.

import SwiftUI

struct AdvancedSettingsView: View {
    @ObservedObject var config = UserConfig.shared
    @AppStorage("HyprMacVerboseLogging") private var verboseLogging = false
    @State private var choosingSyncSide = false
    @State private var confirmingResetAll = false
    // the hook command as typed; saved on Return or when the field loses focus
    @State private var hookDraft = ""
    @FocusState private var hookFocused: Bool

    var body: some View {
        VStack(spacing: HyprSpacing.lg) {
            syncCard
            otherAppsCard
            filesCard
            resetCard
        }
        .onAppear { hookDraft = config.statusHookCommand ?? "" }
        .onChange(of: config.statusHookCommand) { saved in
            if !hookFocused { hookDraft = saved ?? "" }
        }
    }

    // MARK: sync

    // turning sync on asks first when this Mac and iCloud disagree
    private var iCloudSyncBinding: Binding<Bool> {
        Binding(get: { config.iCloudSyncEnabled }, set: { on in
            if on, config.iCloudCopyDiffersFromLocal {
                choosingSyncSide = true
            } else {
                config.iCloudSyncEnabled = on
            }
        })
    }

    private var syncCard: some View {
        SettingsCard("Sync") {
            if config.isICloudDriveAvailable {
                SettingsRow("Sync settings via iCloud", icon: "icloud",
                            subtitle: config.isICloudSyncLocked
                                ? "Off while another tool manages the config file."
                                : "Shares config.json with your other Macs. Monitor settings and this Mac's options stay here.",
                            divider: false) {
                    Toggle("", isOn: iCloudSyncBinding)
                        .toggleStyle(HyprToggleStyle())
                        .labelsHidden()
                }
                .disabled(config.isICloudSyncLocked)
                .opacity(config.isICloudSyncLocked ? 0.5 : 1)
                .alert("iCloud has different settings", isPresented: $choosingSyncSide) {
                    Button("Use the settings in iCloud") { config.turnOnICloudSync(usingThisMac: false) }
                    Button("Use this Mac's settings") { config.turnOnICloudSync(usingThisMac: true) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The other settings are kept as a backup beside config.json.")
                }
            } else {
                SettingsRow("Sync settings via iCloud", icon: "xmark.icloud", tint: .settingsTextMuted,
                            subtitle: "Turn on iCloud Drive in System Settings first.", divider: false) {
                    EmptyView()
                }
            }
        }
    }

    // MARK: other apps

    private var otherAppsCard: some View {
        SettingsCard("Other apps", footer: "Both stay on this Mac and don't sync.") {
            SettingsRow("Allow other apps to control HyprMac", icon: "link",
                        subtitle: "Apps like BetterTouchTool run HyprMac actions with hyprmac:// links.") {
                Toggle("", isOn: $config.externalControlEnabled)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
            SettingsRow("Status bar export", icon: "menubar.dock.rectangle",
                        subtitle: "Writes state.json on every change, for bars like SketchyBar.",
                        divider: config.statusExportEnabled) {
                Toggle("", isOn: $config.statusExportEnabled)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
            if config.statusExportEnabled {
                SettingsRow("Run after each change", icon: "terminal",
                            subtitle: "Optional. Runs without a shell, like a Command keybind.",
                            divider: false) {
                    EmptyView()
                } detail: {
                    TextField("", text: $hookDraft,
                              prompt: Text("sketchybar --trigger hyprmac_change"))
                        .textFieldStyle(.plain)
                        .font(.hyprMonoSm)
                        .foregroundStyle(Color.settingsText)
                        .focused($hookFocused)
                        .onSubmit(saveHook)
                        .onChange(of: hookFocused) { focused in if !focused { saveHook() } }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                                .fill(Color.settingsBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                                .strokeBorder(Color.settingsHairline, lineWidth: 0.5)
                        )
                        .padding(.top, 4)
                }
            }
        }
    }

    private func saveHook() {
        let trimmed = hookDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : trimmed
        if value != config.statusHookCommand { config.statusHookCommand = value }
    }

    // MARK: files and logging

    private var supportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HyprMac", isDirectory: true)
    }

    private var filesCard: some View {
        SettingsCard("Files and logging") {
            fileRow("config.json", subtitle: "Settings that can sync: keys, rules, appearance.",
                    url: supportFolder.appendingPathComponent("config.json"))
            fileRow("monitor-config.json", subtitle: "This Mac only: monitors, status bar export, other apps.",
                    url: supportFolder.appendingPathComponent("monitor-config.json"))
            SettingsRow("Detailed logging", icon: "ladybug",
                        subtitle: "Logs every step, for bug reports. Turn it off after.") {
                Toggle("", isOn: $verboseLogging)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
            fileRow("Log file", subtitle: Self.homeRelative(DebugLogFile.shared.fileURL.path),
                    url: DebugLogFile.shared.fileURL, icon: "doc.text", divider: false)
        }
    }

    private func fileRow(_ title: String, subtitle: String, url: URL,
                         icon: String = "doc", divider: Bool = true) -> some View {
        SettingsRow(title, icon: icon, subtitle: subtitle, divider: divider) {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.settings)
        }
        .help(url.path)
    }

    private static func homeRelative(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: reset all

    private var resetCard: some View {
        SettingsCard("Reset") {
            SettingsRow("Reset all settings", icon: "arrow.counterclockwise", tint: .red,
                        subtitle: "Every section at once. Copies of both files are kept first.",
                        divider: false) {
                Button("Reset All…") { confirmingResetAll = true }
                    .buttonStyle(.settingsDestructive)
            }
        }
        .confirmationDialog("Reset all settings?", isPresented: $confirmingResetAll) {
            Button("Reset All", role: .destructive) { config.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restores the Hypr key, keybinds, rules, workspace names, layout, appearance and monitor settings, and turns off other apps and the status bar export. Keeps this Mac's Show in Dock, Menu bar, Launch at login, iCloud sync, Updates and logging.")
        }
    }
}
