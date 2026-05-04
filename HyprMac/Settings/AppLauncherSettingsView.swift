// "App Launcher" tab. Manages every `launchApp` keybind separately
// from the main Keybinds tab so the launcher list stays focused.

import SwiftUI
import Carbon

/// "App Launcher" tab.
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
        VStack(spacing: HyprSpacing.lg) {
            if launcherEntries.isEmpty {
                emptyPanel
            } else {
                launchersPanel
            }

            HStack {
                Button { showingAddSheet = true } label: {
                    Label("Add app launcher", systemImage: "plus")
                }
                .controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, HyprSpacing.xs)
        }
        .sheet(isPresented: $showingAddSheet) {
            AppLauncherEditorSheet { bind in
                config.keybinds.append(bind)
            }
        }
    }

    private var emptyPanel: some View {
        HyprPanel {
            VStack(spacing: HyprSpacing.sm) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Color.hyprTextTertiary)
                Text("No app launchers")
                    .font(.hyprBody)
                    .foregroundStyle(Color.hyprTextSecondary)
                Text("Bind a hotkey to instantly launch or focus any app.")
                    .font(.hyprCaption)
                    .foregroundStyle(Color.hyprTextTertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HyprSpacing.xl)
            .padding(.horizontal, HyprSpacing.xl)
        }
    }

    private var launchersPanel: some View {
        HyprPanel("Launchers") {
            ForEach(Array(launcherEntries.enumerated()), id: \.element.bind.id) { idx, entry in
                if case .launchApp(let bundleID) = entry.bind.action {
                    launcherRow(
                        bundleID: bundleID,
                        bind: entry.bind,
                        isLast: idx == launcherEntries.count - 1,
                        onDelete: { config.keybinds.remove(at: entry.index) }
                    )
                }
            }
        }
    }

    private func launcherRow(bundleID: String,
                             bind: Keybind,
                             isLast: Bool,
                             onDelete: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: HyprSpacing.md) {
                Group {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                    } else {
                        Image(systemName: "app")
                            .resizable()
                            .foregroundStyle(Color.hyprTextTertiary)
                            .padding(4)
                    }
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(appDisplayName(for: bundleID))
                        .font(.hyprBody)
                    Text(bundleID)
                        .font(.hyprMonoXs)
                        .foregroundStyle(Color.hyprTextTertiary)
                }

                Spacer()

                KeybadgeView(bind: bind)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red.opacity(0.75))
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }
            .padding(.horizontal, HyprSpacing.md)
            .padding(.vertical, HyprSpacing.sm + 1)

            if !isLast {
                Rectangle()
                    .fill(Color.hyprSeparator)
                    .frame(height: 0.5)
                    .padding(.leading, HyprSpacing.md + 28 + HyprSpacing.md)
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
        VStack(alignment: .leading, spacing: HyprSpacing.lg) {
            Text("Add App Launcher")
                .font(.hyprTitle)

            // app picker
            VStack(alignment: .leading, spacing: HyprSpacing.sm) {
                Text("Application")
                    .font(.hyprSection)
                    .foregroundStyle(Color.hyprTextSecondary)
                    .textCase(.uppercase)
                    .kerning(0.5)

                HStack(spacing: HyprSpacing.md) {
                    Group {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: selectedBundleID),
                           !selectedAppName.isEmpty {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                        } else {
                            RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                                .fill(Color.hyprSurfaceElevated)
                                .overlay(
                                    Image(systemName: "app")
                                        .foregroundStyle(Color.hyprTextTertiary)
                                )
                        }
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        if selectedAppName.isEmpty {
                            Text("No app selected")
                                .font(.hyprBody)
                                .foregroundStyle(Color.hyprTextSecondary)
                        } else {
                            Text(selectedAppName).font(.hyprBody)
                            Text(selectedBundleID)
                                .font(.hyprMonoXs)
                                .foregroundStyle(Color.hyprTextTertiary)
                        }
                    }

                    Spacer()
                    Button("Choose…") { pickApp() }
                }
                .padding(HyprSpacing.md)
                .background(
                    RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                        .fill(Color.hyprSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                        .strokeBorder(Color.hyprSeparator, lineWidth: 0.5)
                )
            }

            // shortcut recorder
            VStack(alignment: .leading, spacing: HyprSpacing.sm) {
                Text("Shortcut")
                    .font(.hyprSection)
                    .foregroundStyle(Color.hyprTextSecondary)
                    .textCase(.uppercase)
                    .kerning(0.5)
                KeyRecorderView(
                    keyCode: $recordedKeyCode,
                    useHypr: $useHypr, useShift: $useShift,
                    useControl: $useControl, useOption: $useOption,
                    useCommand: $useCommand
                )
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
        .padding(HyprSpacing.xl)
        .frame(width: 460)
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
