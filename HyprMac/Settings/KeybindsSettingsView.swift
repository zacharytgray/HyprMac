// "Keybinds" tab. Lists every non-launcher keybind grouped by
// category and offers an editor sheet for adding or modifying one.

import SwiftUI
import Carbon

/// "Keybinds" tab.
struct KeybindsSettingsView: View {
    @ObservedObject var config = UserConfig.shared
    @State private var selectedBindID: String?
    @State private var showingAddSheet = false
    @State private var editingBind: Keybind?

    private static let visibleCategories: [KeybindCategory] = [
        .focusNav, .windowManagement, .workspaces, .system
    ]

    private var nonLauncherBinds: [Keybind] {
        config.keybinds.filter {
            if case .launchApp = $0.action { return false }
            return true
        }
    }

    private var grouped: [(category: KeybindCategory, binds: [Keybind])] {
        let pairs = nonLauncherBinds.map { ($0, KeybindCategory.from($0.action)) }
        return Self.visibleCategories.compactMap { cat in
            let binds = pairs.filter { $0.1 == cat }.map(\.0)
            return binds.isEmpty ? nil : (cat, binds)
        }
    }

    var body: some View {
        VStack(spacing: HyprSpacing.lg) {
            hyprKeyPanel

            ForEach(grouped, id: \.category) { group in
                HyprPanel(group.category.rawValue) {
                    ForEach(Array(group.binds.enumerated()), id: \.element.id) { idx, bind in
                        KeybindRow(
                            bind: bind,
                            isSelected: selectedBindID == bind.id,
                            divider: idx < group.binds.count - 1,
                            onTap: { selectedBindID = bind.id },
                            onDoubleTap: { editingBind = bind },
                            onDelete: {
                                config.keybinds.removeAll { $0.id == bind.id }
                                if selectedBindID == bind.id { selectedBindID = nil }
                            }
                        )
                    }
                }
            }

            actionsRow
        }
        .sheet(isPresented: $showingAddSheet) {
            KeybindEditorSheet(existingBind: nil) { config.keybinds.append($0) }
        }
        .sheet(item: $editingBind) { bind in
            KeybindEditorSheet(existingBind: bind) { updated in
                if let idx = config.keybinds.firstIndex(where: { $0.id == bind.id }) {
                    config.keybinds[idx] = updated
                }
            }
        }
    }

    private var hyprKeyPanel: some View {
        HyprPanel("Hypr Key", footer: hyprKeyDescription) {
            HyprRow("Physical key", icon: "command", divider: false) {
                Picker("", selection: $config.hyprKey) {
                    ForEach(HyprKey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
        }
    }

    private var hyprKeyDescription: String {
        if config.hyprKey.usesCapsLockRemap {
            return "Caps Lock is remapped to F18 via hidutil while HyprMac is running, then restored when the app quits."
        }
        if config.hyprKey.nativeModifierFlag != nil {
            return "\(config.hyprKey.displayName) acts as a dedicated Hypr key while HyprMac is running and is swallowed before apps see it."
        }
        return "\(config.hyprKey.displayName) acts as the Hypr key while HyprMac is running and is swallowed before apps see it."
    }

    private var actionsRow: some View {
        HStack(spacing: HyprSpacing.sm) {
            Button { showingAddSheet = true } label: {
                Label("Add keybind", systemImage: "plus")
            }
            .controlSize(.small)

            if let sel = selectedBindID,
               let idx = config.keybinds.firstIndex(where: { $0.id == sel }) {
                Button { editingBind = config.keybinds[idx] } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .controlSize(.small)

                Button(role: .destructive) {
                    config.keybinds.remove(at: idx)
                    selectedBindID = nil
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .controlSize(.small)
                .tint(.red)
            }

            Spacer()

            Button("Reset to defaults") {
                config.keybinds = Keybind.defaults
            }
            .controlSize(.small)
            .foregroundStyle(Color.hyprTextSecondary)
        }
        .padding(.horizontal, HyprSpacing.xs)
    }
}

private struct KeybindRow: View {
    let bind: Keybind
    let isSelected: Bool
    let divider: Bool
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: HyprSpacing.md) {
                Image(systemName: bind.actionIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.hyprTextSecondary)
                    .frame(width: 16)

                Text(bind.actionDescription)
                    .font(.hyprBody)
                    .foregroundStyle(Color.hyprTextPrimary)

                Spacer()

                KeybadgeView(bind: bind)
            }
            .padding(.horizontal, HyprSpacing.md)
            .padding(.vertical, HyprSpacing.sm + 1)
            .contentShape(Rectangle())
            .background(
                isSelected
                    ? Color.hyprCyan.opacity(0.10)
                    : Color.clear
            )
            .onTapGesture(count: 2) { onDoubleTap() }
            .onTapGesture(count: 1) { onTap() }
            .contextMenu {
                Button("Edit", action: onDoubleTap)
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            }

            if divider {
                Rectangle()
                    .fill(Color.hyprSeparator)
                    .frame(height: 0.5)
                    .padding(.leading, HyprSpacing.md + 16 + HyprSpacing.md)
            }
        }
    }
}

// MARK: - editor sheet

struct KeybindEditorSheet: View {
    let existingBind: Keybind?
    let onSave: (Keybind) -> Void

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
                case .focusDirection, .swapDirection, .moveWorkspaceToMonitor:
                    DirectionPicker(direction: $vm.directionParam)
                case .switchWorkspace, .moveToWorkspace:
                    WorkspacePicker(workspace: $vm.workspaceParam)
                case .cycleWorkspace:
                    Picker("Direction", selection: $vm.workspaceParam) {
                        Text("Next").tag(1)
                        Text("Previous").tag(-1)
                    }
                    .pickerStyle(.segmented)
                case .launchApp:
                    BundleIDPicker(bundleID: $vm.bundleIDParam)
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
                .disabled(!vm.canSave)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(HyprSpacing.xl)
        .frame(width: 480)
        .onAppear { vm.load(existingBind) }
    }
}
