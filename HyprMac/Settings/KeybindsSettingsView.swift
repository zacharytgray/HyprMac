import SwiftUI
import Carbon

// MARK: - main view

struct KeybindsSettingsView: View {
    @ObservedObject var config = UserConfig.shared
    @State private var selectedBindID: String?
    @State private var showingAddSheet = false
    @State private var editingBind: Keybind?

    // launchApp lives in its own settings tab — not shown here
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
        VStack(spacing: 0) {
            List(selection: $selectedBindID) {
                ForEach(grouped, id: \.category) { group in
                    Section(group.category.rawValue) {
                        ForEach(group.binds) { bind in
                            KeybindRow(bind: bind)
                                .tag(bind.id)
                                .onTapGesture(count: 2) { editingBind = bind }
                        }
                        .onDelete { offsets in
                            let ids = Set(offsets.map { group.binds[$0].id })
                            config.keybinds.removeAll { ids.contains($0.id) }
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 2) {
                Button { showingAddSheet = true } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Add keybind")

                if let sel = selectedBindID,
                   let idx = config.keybinds.firstIndex(where: { $0.id == sel }) {
                    Divider().frame(height: 14)

                    Button { editingBind = config.keybinds[idx] } label: {
                        Image(systemName: "pencil")
                            .frame(width: 28, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help("Edit selected")

                    Button(role: .destructive) {
                        config.keybinds.remove(at: idx)
                        selectedBindID = nil
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 28, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help("Delete selected")
                }

                Spacer()

                Button("Reset to Defaults") {
                    config.keybinds = Keybind.defaults
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.callout)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
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

}

private struct KeybindRow: View {
    let bind: Keybind

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: bind.actionIcon)
                .frame(width: 16)
                .foregroundStyle(.secondary)

            Text(bind.actionDescription)
                .frame(maxWidth: .infinity, alignment: .leading)

            KeybadgeView(bind: bind)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - editor sheet

struct KeybindEditorSheet: View {
    let existingBind: Keybind?
    let onSave: (Keybind) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = KeybindEditorViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(existingBind == nil ? "Add Keybind" : "Edit Keybind")
                .font(.title3.weight(.semibold))

            // shortcut recorder
            GroupBox {
                KeyRecorderView(
                    keyCode: $vm.recordedKeyCode,
                    useHypr: $vm.useHypr, useShift: $vm.useShift,
                    useControl: $vm.useControl, useOption: $vm.useOption,
                    useCommand: $vm.useCommand
                )
                .padding(4)
            }

            // action picker
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Action")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

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
                .padding(4)
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
        .padding(20)
        .frame(width: 460)
        .onAppear { vm.load(existingBind) }
    }
}

