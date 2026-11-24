// "Workspaces" section of Settings: names for workspaces 1–10, app pins,
// and the scratchpad.

import SwiftUI

struct WorkspacesSettingsView: View {
    @ObservedObject var config = UserConfig.shared

    var body: some View {
        VStack(spacing: HyprSpacing.lg) {
            namesCard
            pinsCard
            scratchpadCard
            SectionResetFooter(title: "Reset Workspaces to defaults",
                               message: "Clears workspace names and app pins and puts the scratchpad back to tiling with a 6% margin. A copy of your settings is kept beside config.json.") {
                config.resetToDefaults(.workspaces)
            }
        }
    }

    // MARK: names

    private var namesCard: some View {
        SettingsCard("Names",
                     footer: "A name replaces the number in the switch HUD, the menu bar and the workspace pickers. Leave it empty to keep the number.") {
            // 1–5 left, 6–10 right
            HStack(alignment: .top, spacing: HyprSpacing.lg) {
                nameColumn(Array(Constants.workspaceRange.prefix(5)))
                nameColumn(Array(Constants.workspaceRange.dropFirst(5)))
            }
            .padding(HyprSpacing.md)
        }
    }

    private func nameColumn(_ workspaces: [Int]) -> some View {
        VStack(spacing: 6) {
            ForEach(workspaces, id: \.self) { workspace in
                HStack(spacing: HyprSpacing.sm) {
                    Text("\(workspace)")
                        .font(.hyprMonoSm)
                        .foregroundStyle(Color.hyprCyan)
                        .frame(width: 18, alignment: .trailing)
                    // a hand-drawn placeholder: the system one is too bright on navy
                    TextField("", text: nameBinding(workspace))
                        .textFieldStyle(.plain)
                        .font(.hyprBody)
                        .foregroundStyle(Color.settingsText)
                        .background(alignment: .leading) {
                            if (config.workspaceNames[String(workspace)] ?? "").isEmpty {
                                Text("No name")
                                    .font(.hyprBody)
                                    .foregroundStyle(Color.settingsTextFaint)
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityLabel("Name for workspace \(workspace)")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                                .fill(Color.settingsBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                                .strokeBorder(Color.settingsHairline, lineWidth: 0.5)
                        )
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // empty removes the key
    private func nameBinding(_ workspace: Int) -> Binding<String> {
        Binding(get: { config.workspaceNames[String(workspace)] ?? "" },
                set: { config.workspaceNames[String(workspace)] = $0.isEmpty ? nil : $0 })
    }

    // MARK: pins

    private var pinsCard: some View {
        SettingsCard("Pin apps",
                     footer: "New windows from a pinned app open on its workspace or in the scratchpad, and HyprMac shows it. Retile All also moves the app's open windows there, and a scratchpad pin applies at launch too.") {
            let sorted = config.windowRules.sorted {
                appDisplayName(for: $0.bundleID).localizedCaseInsensitiveCompare(
                    appDisplayName(for: $1.bundleID)) == .orderedAscending
            }
            if sorted.isEmpty {
                SettingsRow("No pinned apps", icon: "pin.slash", tint: .settingsTextMuted,
                            subtitle: "New windows open on the display they appear on.") { EmptyView() }
            }
            ForEach(sorted, id: \.id) { rule in
                pinnedRow(rule)
            }
            SettingsRow("Pin an app", icon: "plus.circle", divider: false) {
                Button("Choose…") { pickPinnedApp() }
                    .buttonStyle(.settings)
            }
        }
    }

    private func pinnedRow(_ rule: WindowRule) -> some View {
        HStack(spacing: HyprSpacing.md) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "app").font(.system(size: 16)).foregroundStyle(Color.settingsTextFaint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(appDisplayName(for: rule.bundleID))
                    .font(.hyprBody)
                    .foregroundStyle(Color.settingsText)
                Text(rule.bundleID)
                    .font(.hyprMonoXs)
                    .foregroundStyle(Color.settingsTextFaint)
            }
            Spacer()
            Text("opens on")
                .font(.hyprCaption)
                .foregroundStyle(Color.settingsTextMuted)
            SettingsMenuPicker(options: workspaceOptions,
                               selection: Binding(get: { rule.workspace },
                                                  set: { setPinnedWorkspace($0, for: rule.bundleID) }))
            Button {
                config.windowRules.removeAll { $0.bundleID == rule.bundleID }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(Color.red.opacity(0.75))
            }
            .buttonStyle(.borderless)
            .help("Unpin this app")
        }
        .padding(.horizontal, HyprSpacing.md)
        .padding(.vertical, HyprSpacing.sm)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.settingsHairline.opacity(0.7))
                .frame(height: 1)
                .padding(.leading, HyprSpacing.md + 22 + HyprSpacing.md)
        }
    }

    private var workspaceOptions: [(value: Int, label: String)?] {
        [(WindowRule.scratchpad, "Scratchpad"), nil]
            + Constants.workspaceRange.map { ($0, UserConfig.workspaceDisplayName($0, names: config.workspaceNames)) }
    }

    private func setPinnedWorkspace(_ workspace: Int, for bundleID: String) {
        guard let index = config.windowRules.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        config.windowRules[index].workspace = workspace
    }

    // one rule per app: picking an app that already has one leaves it as is
    private func pickPinnedApp() {
        let panel = NSOpenPanel()
        panel.title = "Select Applications to Pin"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        let added = WindowRule.newRules(forBundleIDs: ids, existing: config.windowRules)
        if !added.isEmpty { config.windowRules.append(contentsOf: added) }
    }

    // MARK: scratchpad

    // magenta: the scratchpad is the floating layer
    private var scratchpadCard: some View {
        SettingsCard("Scratchpad",
                     footer: "The margin keeps the dimmed edge in view; 0% uses the whole screen. Windows that can't fit the tiled layout float either way.") {
            SettingsRow("Tile windows in the scratchpad", icon: "square.grid.2x2", tint: .hyprMagenta,
                        subtitle: "Windows you send there tile in its layer instead of floating.") {
                Toggle("", isOn: $config.scratchpadTileByDefault)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            } detail: {
                ShortcutHint("Show it with", action: .toggleScratchpad)
            }
            SettingsRow("Scratchpad margin", icon: "rectangle.center.inset.filled", tint: .hyprMagenta,
                        divider: false) {
                SettingsSlider(value: Binding(get: { Double(config.scratchpadRegionInset) },
                                              set: { config.scratchpadRegionInset = CGFloat($0) }),
                               range: 0...0.15, step: 0.01, label: { String(format: "%.0f%%", $0 * 100) })
            }
        }
    }
}
