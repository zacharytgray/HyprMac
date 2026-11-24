// "Keys" section of Settings: the Hypr key, a search field + Add menu, and
// every keybind (including app launchers) grouped by category.

import SwiftUI
import Carbon

/// "Keys" section.
struct KeybindsSettingsView: View {
    @ObservedObject var config = UserConfig.shared
    @State private var selectedBindID: String?
    @State private var showingAddKeybind = false
    @State private var showingAddLauncher = false
    @State private var showingAddCommand = false
    @State private var editingBind: Keybind?
    @State private var search = ""
    @State private var expandedWorkspaceFamilies: Set<String> = []

    private static let visibleCategories: [KeybindCategory] = [
        .focusNav, .windowManagement, .workspaces, .apps, .system
    ]

    // case-insensitive substring on the action description (launcher rows
    // match on their app name via actionDescription = "Launch <App>").
    private func matches(_ bind: Keybind) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        return bind.actionDescription.localizedCaseInsensitiveContains(q)
    }

    private var grouped: [(category: KeybindCategory, binds: [Keybind])] {
        let pairs = config.keybinds
            .filter(matches)
            .map { ($0, KeybindCategory.from($0.action)) }
        return Self.visibleCategories.compactMap { cat in
            let binds = pairs.filter { $0.1 == cat }.map(\.0)
            return binds.isEmpty ? nil : (cat, binds)
        }
    }

    var body: some View {
        VStack(spacing: HyprSpacing.lg) {
            headerRow
            hyprHeroPanel

            ForEach(grouped, id: \.category) { group in
                if group.category == .workspaces {
                    workspacePanel(group.binds)
                } else {
                    SettingsCard(group.category.rawValue) {
                        bindRows(group.binds)
                    }
                }
            }

            SectionResetFooter(title: "Reset keybinds to defaults",
                               message: "Puts every shortcut back and turns double-tap Caps Lock on, as on a new install. App launchers and commands you added are removed; a copy of your settings is kept beside config.json. The Hypr key stays as it is.") {
                config.resetKeybindsToDefaults()
            }
        }
        .sheet(isPresented: $showingAddKeybind) {
            KeybindEditorSheet(existingBind: nil, otherBinds: config.keybinds) { config.keybinds.append($0) }
        }
        .sheet(isPresented: $showingAddLauncher) {
            AppLauncherEditorSheet(otherBinds: config.keybinds) { config.keybinds.append($0) }
        }
        .sheet(isPresented: $showingAddCommand) {
            KeybindEditorSheet(existingBind: nil, initialAction: .runCommand,
                               otherBinds: config.keybinds) {
                config.keybinds.append($0)
            }
        }
        .sheet(item: $editingBind) { bind in
            KeybindEditorSheet(existingBind: bind, otherBinds: config.keybinds) { updated in
                config.keybinds = config.keybinds.replacingBind(bind, with: updated)
            }
        }
    }

    @ViewBuilder
    private func bindRows(_ binds: [Keybind]) -> some View {
        // position, not chord: a saved config can hold two binds on one chord
        ForEach(Array(binds.enumerated()), id: \.offset) { idx, bind in
            KeybindRow(
                bind: bind,
                showsFloatingMarker: bind.showsFloatingMarker(
                    scratchpadTilesSentWindows: config.scratchpadTileByDefault),
                isSelected: selectedBindID == bind.id,
                divider: idx < binds.count - 1,
                onTap: { selectedBindID = bind.id },
                onDoubleTap: { editingBind = bind },
                onDelete: {
                    config.keybinds = config.keybinds.removingBind(bind)
                    if selectedBindID == bind.id { selectedBindID = nil }
                }
            )
        }
    }

    private func workspacePanel(_ binds: [Keybind]) -> some View {
        let families = KeybindOverlayGrouping.WorkspaceFamily.allCases
        let runs = Dictionary(uniqueKeysWithValues: families.compactMap { family in
            canonicalWorkspaceFamily(in: binds, family: family).map { (family, $0) }
        })
        let collapsedIDs = Set(runs.values.flatMap { $0.map(\.id) })
        let exceptions = binds.filter { !collapsedIDs.contains($0.id) }

        return SettingsCard("Workspaces", footer: "Keys 1–9 select workspaces 1–9; 0 selects workspace 10. Open a group to edit one bind.") {
            ForEach(families, id: \.self) { family in
                if let run = runs[family] {
                    workspaceDisclosure(id: family.rawValue, title: family.title, binds: run)
                }
            }
            bindRows(exceptions)
        }
    }

    // hand-rolled disclosure so the chevron sits in the icon column and the
    // summary chips line up with the rows below
    private func workspaceDisclosure(id: String, title: String, binds: [Keybind]) -> some View {
        let expanded = expandedWorkspaceFamilies.contains(id)
        return VStack(spacing: 0) {
            Button {
                withAnimation(HyprMotion.snap) {
                    if expanded { expandedWorkspaceFamilies.remove(id) }
                    else { expandedWorkspaceFamilies.insert(id) }
                }
            } label: {
                HStack(spacing: HyprSpacing.md) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.hyprCyan)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 16)
                    Text(title)
                        .font(.hyprBody)
                        .foregroundStyle(Color.settingsText)
                    Spacer()
                    workspaceSummaryChord(for: binds[0])
                }
                .padding(.horizontal, HyprSpacing.md)
                .padding(.vertical, HyprSpacing.sm + 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                bindRows(binds)
                    .padding(.leading, HyprSpacing.md + 16)
            }

            Rectangle()
                .fill(Color.settingsHairline.opacity(0.7))
                .frame(height: 1)
                .padding(.leading, HyprSpacing.md + 16 + HyprSpacing.md)
        }
    }

    private func canonicalWorkspaceFamily(in binds: [Keybind],
                                          family wanted: KeybindOverlayGrouping.WorkspaceFamily) -> [Keybind]? {
        let family = binds.compactMap { bind -> (Int, Keybind)? in
            guard let member = KeybindOverlayGrouping.workspaceFamily(of: bind.action),
                  member.family == wanted,
                  KeybindOverlayGrouping.usesCanonicalWorkspaceKey(bind, number: member.number) else {
                return nil
            }
            return (member.number, bind)
        }.sorted { $0.0 < $1.0 }

        guard KeybindOverlayGrouping.isCompleteWorkspaceRange(family.map { $0.0 }),
              Set(family.map { $0.1.modifiers }).count == 1 else { return nil }
        return family.map { $0.1 }
    }

    // same chips as the rows, with N standing in for the number key
    private func workspaceSummaryChord(for bind: Keybind) -> some View {
        let labels = Keybind(keyCode: bind.keyCode, modifiers: bind.modifiers.subtracting(.hypr),
                             action: bind.action).badgeLabels().dropLast()
        return HStack(spacing: 3) {
            if bind.modifiers.contains(.hypr) { HyprKeyChip(fontSize: 11) }
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in KeyChip(label, fontSize: 11, onGlass: true) }
            KeyChip("N", fontSize: 11, onGlass: true)
        }
    }

    // MARK: header — search + add

    private var headerRow: some View {
        HStack(spacing: HyprSpacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.settingsTextFaint)
                TextField("Search keybinds", text: $search)
                    .textFieldStyle(.plain)
                    .font(.hyprCaption)
                    .foregroundStyle(Color.settingsText)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                    .fill(Color.settingsSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                    .strokeBorder(Color.settingsHairline, lineWidth: 0.5)
            )

            Menu {
                Button("Keybind…") { showingAddKeybind = true }
                Button("App launcher…") { showingAddLauncher = true }
                Button("Command…") { showingAddCommand = true }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.settingsProminent)
            .fixedSize()
        }
    }

    // MARK: hypr hero

    private var hyprHeroPanel: some View {
        SettingsCard("Hypr key") {
            SettingsRow("Hypr key", icon: "capslock", subtitle: "Hold it, then press a shortcut key.") {
                // a saved key that is no longer offered keeps its row until
                // the user picks another one
                SettingsMenuPicker(options: HyprKey.pickerRows(for: config.hyprKey).map { ($0, $0.displayName) },
                                   selection: $config.hyprKey)
            }
            SettingsRow("Double-tap Hypr to toggle Caps Lock", icon: "capslock.fill",
                        subtitle: HyprKey.doubleTapCapsLockNote,
                        divider: hasKeyNotes) {
                Toggle("", isOn: $config.doubleTapHyprTogglesCapsLock)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
            if let note = config.hyprKey.notRecommendedNote {
                keyNoteRow(note, icon: "exclamationmark.circle")
            }
            if let note = config.hyprKey.leftModifierNote {
                keyNoteRow(note, icon: "info.circle")
            }
            if let guidance = HyprKeySystemGuidance.forKey(config.hyprKey) {
                modifierKeysReminder(guidance)
            }
        }
    }

    private var hasKeyNotes: Bool {
        config.hyprKey.notRecommendedNote != nil || config.hyprKey.leftModifierNote != nil
            || HyprKeySystemGuidance.forKey(config.hyprKey) != nil
    }

    private func keyNoteRow(_ note: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HyprSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.hyprMagenta)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(note)
                .font(.hyprCaption)
                .foregroundStyle(Color.settingsTextMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HyprSpacing.md)
        .padding(.vertical, HyprSpacing.sm)
    }

    // one line + button; the full explanation sits behind the info button
    private func modifierKeysReminder(_ guidance: HyprKeySystemGuidance) -> some View {
        HStack(spacing: HyprSpacing.md) {
            Image(systemName: "keyboard")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.hyprMagenta)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(guidance.title)
                .font(.hyprCaption)
                .foregroundStyle(Color.settingsTextMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: HyprSpacing.sm)
            GuidanceInfoButton(detail: guidance.detail)
            Button(HyprKeySystemGuidance.openButtonTitle + "…") {
                HyprKeySystemGuidance.openKeyboardSettings()
            }
            .buttonStyle(.settings)
            .fixedSize()
        }
        .padding(.horizontal, HyprSpacing.md)
        .padding(.vertical, HyprSpacing.sm)
        .help(guidance.detail)
    }
}

// info icon that shows the full modifier keys note in a popover
private struct GuidanceInfoButton: View {
    let detail: String
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(Color.settingsTextFaint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More about Modifier Keys")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(detail)
                .font(.hyprCaption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(HyprSpacing.md)
        }
    }
}

// MARK: - keybind row

private struct KeybindRow: View {
    let bind: Keybind
    let showsFloatingMarker: Bool
    let isSelected: Bool
    let divider: Bool
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onDelete: () -> Void

    private var isLauncher: Bool {
        if case .launchApp = bind.action { return true }
        return false
    }

    private var leadingInset: CGFloat {
        // align divider under the label, past icon + gap
        HyprSpacing.md + (isLauncher ? 20 : 16) + HyprSpacing.md
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: HyprSpacing.md) {
                icon

                HStack(spacing: 5) {
                    Text(rowTitle)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(Color.settingsText)
                    if showsFloatingMarker {
                        Text(HyprGlyph.floatingMarker)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.hyprMagenta)
                    }
                }

                Spacer()

                KeybadgeView(bind: bind, fontSize: 11, softKeys: true)
            }
            .padding(.horizontal, HyprSpacing.md)
            .padding(.vertical, HyprSpacing.sm + 1)
            .contentShape(Rectangle())
            // selected: an inset bar, not a row fill
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(LinearGradient(colors: [.hyprMagenta, .hyprCyan], startPoint: .top, endPoint: .bottom))
                        .frame(width: 3, height: 18)
                        .padding(.leading, 3)
                }
            }
            .onTapGesture(count: 2) { onDoubleTap() }
            .onTapGesture(count: 1) { onTap() }
            .contextMenu {
                Button("Edit", action: onDoubleTap)
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            }

            if divider {
                Rectangle()
                    .fill(Color.settingsHairline.opacity(0.7))
                    .frame(height: 1)
                    .padding(.leading, leadingInset)
            }
        }
    }

    @ViewBuilder private var icon: some View {
        if case .launchApp(let bundleID) = bind.action {
            Group {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                } else {
                    Image(systemName: "app")
                        .resizable()
                        .foregroundStyle(Color.settingsTextFaint)
                        .padding(3)
                }
            }
            .frame(width: 20, height: 20)
        } else {
            Image(systemName: bind.actionIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.hyprCyan)
                .frame(width: 16)
        }
    }

    private var rowTitle: String {
        bind.actionDescription
    }
}

// MARK: - editor sheet

struct KeybindEditorSheet: View {
    let existingBind: Keybind?
    /// preselects the action when adding a new bind from a dedicated menu item
    let initialAction: KeybindEditorViewModel.ActionChoice?
    /// the saved list, to refuse a chord another bind already holds
    let otherBinds: [Keybind]
    let onSave: (Keybind) -> Void

    init(existingBind: Keybind?,
         initialAction: KeybindEditorViewModel.ActionChoice? = nil,
         otherBinds: [Keybind] = [],
         onSave: @escaping (Keybind) -> Void) {
        self.existingBind = existingBind
        self.initialAction = initialAction
        self.otherBinds = otherBinds
        self.onSave = onSave
    }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = KeybindEditorViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: HyprSpacing.lg) {
            Text(existingBind == nil ? "Add Keybind" : "Edit Keybind")
                .font(.hyprTitle)

            // shortcut recorder
            VStack(alignment: .leading, spacing: HyprSpacing.sm) {
                Text("Shortcut")
                    .font(.hyprSection)
                    .foregroundStyle(Color.hyprTextSecondary)
                    .textCase(.uppercase)
                    .kerning(0.5)
                KeyRecorderView(
                    keyCode: $vm.recordedKeyCode,
                    useHypr: $vm.useHypr, useShift: $vm.useShift,
                    useControl: $vm.useControl, useOption: $vm.useOption,
                    useCommand: $vm.useCommand
                )
                if let taken = vm.conflict(in: otherBinds, editing: existingBind) {
                    Text("Already bound to \(taken.actionDescription)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            // action picker
            VStack(alignment: .leading, spacing: HyprSpacing.sm) {
                Text("Action")
                    .font(.hyprSection)
                    .foregroundStyle(Color.hyprTextSecondary)
                    .textCase(.uppercase)
                    .kerning(0.5)

                Picker("", selection: $vm.selectedAction) {
                    ForEach(KeybindEditorViewModel.ActionChoice.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .labelsHidden()

                switch vm.selectedAction {
                case .focusDirection, .swapDirection, .moveWindowToMonitor, .resizeDirection:
                    DirectionPicker(direction: $vm.directionParam)
                case .switchWorkspace, .moveToWorkspace, .moveToWorkspaceAndFollow:
                    WorkspacePicker(workspace: $vm.workspaceParam)
                case .cycleWorkspace:
                    Picker("Direction", selection: $vm.workspaceParam) {
                        Text("Next").tag(1)
                        Text("Previous").tag(-1)
                    }
                    .pickerStyle(.segmented)
                case .launchApp:
                    BundleIDPicker(bundleID: $vm.bundleIDParam)
                case .runCommand:
                    CommandPicker(label: $vm.commandLabelParam,
                                  command: $vm.commandParam,
                                  validationMessage: vm.commandValidationMessage)
                default:
                    EmptyView()
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    onSave(vm.buildKeybind())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!vm.canSave || vm.conflict(in: otherBinds, editing: existingBind) != nil)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(HyprSpacing.xl)
        .frame(width: 480)
        .onAppear {
            vm.load(existingBind)
            if existingBind == nil, let initialAction {
                vm.selectedAction = initialAction
            }
        }
    }
}
