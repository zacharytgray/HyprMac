// "Keys" tab. Hypr hero panel, a search field + Add menu, and every
// keybind (including app launchers) grouped by category.

import SwiftUI
import Carbon

/// "Keys" tab.
struct KeybindsSettingsView: View {
    @ObservedObject var config = UserConfig.shared
    @State private var selectedBindID: String?
    @State private var showingAddKeybind = false
    @State private var showingAddLauncher = false
    @State private var editingBind: Keybind?
    @State private var search = ""

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

            Button("Reset to defaults") {
                config.keybinds = Keybind.defaults
            }
            .controlSize(.small)
            .foregroundStyle(Color.hyprTextSecondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, HyprSpacing.xs)
        }
        .sheet(isPresented: $showingAddKeybind) {
            KeybindEditorSheet(existingBind: nil) { config.keybinds.append($0) }
        }
        .sheet(isPresented: $showingAddLauncher) {
            AppLauncherEditorSheet { config.keybinds.append($0) }
        }
        .sheet(item: $editingBind) { bind in
            KeybindEditorSheet(existingBind: bind) { updated in
                if let idx = config.keybinds.firstIndex(where: { $0.id == bind.id }) {
                    config.keybinds[idx] = updated
                }
            }
        }
    }

    // MARK: header — search + add

    private var headerRow: some View {
        HStack(spacing: HyprSpacing.sm) {
            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.hyprTextTertiary)
                TextField("Search actions…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.hyprCaption)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(width: 190)
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                    .fill(Color.hyprSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                    .strokeBorder(Color.hyprSeparator, lineWidth: 0.5)
            )

            Menu {
                Button("Keybind…") { showingAddKeybind = true }
                Button("App launcher…") { showingAddLauncher = true }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Add")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(Color.hyprBackground)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                        .fill(Color.hyprCyan)
                )
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.horizontal, HyprSpacing.xs)
    }

    // MARK: hypr hero

    private var hyprHeroPanel: some View {
        HStack(spacing: HyprSpacing.lg - 2) {
            // 52×52 keycap glyph with a brighter bottom bevel
            Text("⇪")
                .font(.system(size: 22, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.hyprCyan)
                .frame(width: 52, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.hyprSurfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.hyprSeparator, Color.hyprTextPrimary.opacity(0.22)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Hypr key")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.hyprTextPrimary)
                Text("Hold it, press a key, do a window thing. One key unlocks everything.")
                    .font(.hyprCaption)
                    .foregroundStyle(Color.hyprTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: HyprSpacing.sm)

            Picker("", selection: $config.hyprKey) {
                ForEach(HyprKey.allCases) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .labelsHidden()
            .frame(width: 150)
        }
        .padding(.horizontal, HyprSpacing.lg)
        .padding(.vertical, HyprSpacing.md + 2)
        .background(
            RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.hyprCyan.opacity(0.09), Color.hyprMagenta.opacity(0.07)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                .strokeBorder(Color.hyprCyan.opacity(0.22), lineWidth: 1)
        )
    }
}

// MARK: - keybind row

private struct KeybindRow: View {
    let bind: Keybind
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
                        .font(.hyprBody)
                        .foregroundStyle(Color.hyprTextPrimary)
                    if bind.touchesFloatingLayer {
                        Text("◇")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.hyprMagenta)
                    }
                }

                Spacer()

                KeybadgeView(bind: bind)
            }
            .padding(.horizontal, HyprSpacing.md)
            .padding(.vertical, HyprSpacing.sm + 1)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.hyprCyan.opacity(0.10) : Color.clear
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
                        .foregroundStyle(Color.hyprTextTertiary)
                        .padding(3)
                }
            }
            .frame(width: 20, height: 20)
        } else {
            Image(systemName: bind.actionIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.hyprTextSecondary)
                .frame(width: 16)
        }
    }

    private var rowTitle: String {
        if case .launchApp(let bundleID) = bind.action {
            return "Launch / focus \(appDisplayName(for: bundleID))"
        }
        return bind.actionDescription
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
                case .focusDirection, .swapDirection, .moveWindowToMonitor:
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
