import SwiftUI
import Carbon

// MARK: - key badge components

struct KeybadgeView: View {
    @ObservedObject var config = UserConfig.shared
    let bind: Keybind

    var body: some View {
        HStack(spacing: 3) {
            if bind.modifiers.contains(.hypr)    { KeyChip(config.hyprKey.badgeLabel) }
            if bind.modifiers.contains(.control) { KeyChip("⌃") }
            if bind.modifiers.contains(.option)  { KeyChip("⌥") }
            if bind.modifiers.contains(.shift)   { KeyChip("⇧") }
            if bind.modifiers.contains(.command) { KeyChip("⌘") }
            KeyChip(bind.keyCodeName)
        }
    }
}

struct KeyChip: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.14), radius: 1, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
    }
}

// MARK: - main view

struct KeybindsSettingsView: View {
    @ObservedObject var config = UserConfig.shared
    @State private var selectedBindID: String?
    @State private var showingAddSheet = false
    @State private var editingBind: Keybind?

    private let categoryOrder = [
        "Focus & Navigation",
        "Window Management",
        "Workspaces",
        "System"
    ]

    private var nonLauncherBinds: [Keybind] {
        config.keybinds.filter {
            if case .launchApp = $0.action { return false }
            return true
        }
    }

    private var grouped: [(category: String, binds: [Keybind])] {
        let pairs = nonLauncherBinds.map { ($0, bindCategory($0)) }
        return categoryOrder.compactMap { cat in
            let binds = pairs.filter { $0.1 == cat }.map(\.0)
            return binds.isEmpty ? nil : (cat, binds)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedBindID) {
                ForEach(grouped, id: \.category) { group in
                    Section(group.category) {
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

    private func bindCategory(_ bind: Keybind) -> String {
        switch bind.action {
        case .focusDirection, .focusFloating, .focusMenuBar:
            return "Focus & Navigation"
        case .swapDirection, .toggleFloating, .toggleSplit, .closeWindow:
            return "Window Management"
        case .switchWorkspace, .moveToWorkspace, .moveWorkspaceToMonitor, .cycleWorkspace:
            return "Workspaces"
        case .showKeybinds, .launchApp:
            return "System"
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

    @State private var selectedAction: ActionChoice = .focusDirection
    @State private var directionParam: Direction = .left
    @State private var workspaceParam = 1
    @State private var bundleIDParam = "com.apple.Terminal"

    @State private var recordedKeyCode: UInt16 = 0
    @State private var useHypr = true
    @State private var useShift = false
    @State private var useControl = false
    @State private var useOption = false
    @State private var useCommand = false

    enum ActionChoice: String, CaseIterable {
        case focusDirection         = "Focus Direction"
        case swapDirection          = "Swap Direction"
        case switchWorkspace        = "Switch Workspace"
        case moveToWorkspace        = "Move to Workspace"
        case moveWorkspaceToMonitor = "Move Workspace to Monitor"
        case toggleFloating         = "Toggle Floating"
        case toggleSplit            = "Toggle Split"
        case showKeybinds           = "Show Keybinds"
        case launchApp              = "Launch App"
        case focusMenuBar           = "Focus Menu Bar"
        case focusFloating          = "Focus Floating"
        case closeWindow            = "Close Window"
        case cycleWorkspace         = "Cycle Workspace"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(existingBind == nil ? "Add Keybind" : "Edit Keybind")
                .font(.title3.weight(.semibold))

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

            // action picker
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Action")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Picker("", selection: $selectedAction) {
                        ForEach(ActionChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()

                    switch selectedAction {
                    case .focusDirection, .swapDirection, .moveWorkspaceToMonitor:
                        Picker("Direction", selection: $directionParam) {
                            Text("Left").tag(Direction.left)
                            Text("Right").tag(Direction.right)
                            Text("Up").tag(Direction.up)
                            Text("Down").tag(Direction.down)
                        }
                        .pickerStyle(.segmented)
                    case .switchWorkspace, .moveToWorkspace:
                        Picker("Workspace", selection: $workspaceParam) {
                            ForEach(1...9, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented)
                    case .cycleWorkspace:
                        Picker("Direction", selection: $workspaceParam) {
                            Text("Next").tag(1)
                            Text("Previous").tag(-1)
                        }
                        .pickerStyle(.segmented)
                    case .launchApp:
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Bundle ID", text: $bundleIDParam)
                                .textFieldStyle(.roundedBorder)
                            Text("e.g. com.apple.Terminal, com.googlecode.iterm2")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
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
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(recordedKeyCode == 0)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { loadExisting() }
    }

    private func loadExisting() {
        guard let bind = existingBind else { return }
        recordedKeyCode = bind.keyCode
        useHypr    = bind.modifiers.contains(.hypr)
        useShift   = bind.modifiers.contains(.shift)
        useControl = bind.modifiers.contains(.control)
        useOption  = bind.modifiers.contains(.option)
        useCommand = bind.modifiers.contains(.command)
        switch bind.action {
        case .focusDirection(let d):         selectedAction = .focusDirection;         directionParam = d
        case .swapDirection(let d):          selectedAction = .swapDirection;          directionParam = d
        case .switchWorkspace(let n):          selectedAction = .switchWorkspace;          workspaceParam = n
        case .moveToWorkspace(let n):          selectedAction = .moveToWorkspace;          workspaceParam = n
        case .moveWorkspaceToMonitor(let d): selectedAction = .moveWorkspaceToMonitor; directionParam = d
        case .toggleFloating:                selectedAction = .toggleFloating
        case .toggleSplit:                   selectedAction = .toggleSplit
        case .showKeybinds:                  selectedAction = .showKeybinds
        case .launchApp(let b):              selectedAction = .launchApp;              bundleIDParam = b
        case .focusMenuBar:                  selectedAction = .focusMenuBar
        case .focusFloating:                 selectedAction = .focusFloating
        case .closeWindow:                   selectedAction = .closeWindow
        case .cycleWorkspace(let d):         selectedAction = .cycleWorkspace;         workspaceParam = d
        }
    }

    private func save() {
        let mods = ModifierFlags.from(hypr: useHypr, shift: useShift, control: useControl, option: useOption, command: useCommand)

        let action: Action
        switch selectedAction {
        case .focusDirection:         action = .focusDirection(directionParam)
        case .swapDirection:          action = .swapDirection(directionParam)
        case .switchWorkspace:          action = .switchWorkspace(workspaceParam)
        case .moveToWorkspace:          action = .moveToWorkspace(workspaceParam)
        case .moveWorkspaceToMonitor: action = .moveWorkspaceToMonitor(directionParam)
        case .toggleFloating:         action = .toggleFloating
        case .toggleSplit:            action = .toggleSplit
        case .showKeybinds:           action = .showKeybinds
        case .launchApp:              action = .launchApp(bundleID: bundleIDParam)
        case .focusMenuBar:           action = .focusMenuBar
        case .focusFloating:          action = .focusFloating
        case .closeWindow:            action = .closeWindow
        case .cycleWorkspace:         action = .cycleWorkspace(workspaceParam)
        }

        onSave(Keybind(keyCode: recordedKeyCode, modifiers: mods, action: action))
        dismiss()
    }

}

// MARK: - Keybind display helpers

extension Keybind {
    var keyCodeName: String { keyCodeToName(keyCode) }

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.hypr)    { parts.append(UserConfig.shared.hyprKey.badgeLabel) }
        if modifiers.contains(.command) { parts.append("⌘") }
        if modifiers.contains(.shift)   { parts.append("⇧") }
        if modifiers.contains(.option)  { parts.append("⌥") }
        if modifiers.contains(.control) { parts.append("⌃") }
        parts.append(keyCodeName)
        return parts.joined(separator: "+")
    }

    var actionIcon: String {
        switch action {
        case .focusDirection(let d):
            switch d {
            case .left:  return "arrow.left"
            case .right: return "arrow.right"
            case .up:    return "arrow.up"
            case .down:  return "arrow.down"
            }
        case .swapDirection:
            return "arrow.left.arrow.right"
        case .switchWorkspace:
            return "number.circle"
        case .moveToWorkspace:
            return "arrow.up.right.square"
        case .moveWorkspaceToMonitor:
            return "rectangle.2.swap"
        case .toggleFloating:
            return "macwindow.and.cursorarrow"
        case .toggleSplit:
            return "rectangle.split.2x1"
        case .showKeybinds:
            return "keyboard"
        case .launchApp:
            return "app"
        case .focusMenuBar:
            return "menubar.rectangle"
        case .focusFloating:
            return "macwindow.on.rectangle"
        case .closeWindow:
            return "xmark.circle"
        case .cycleWorkspace:
            return "arrow.clockwise.circle"
        }
    }

    var actionDescription: String {
        switch action {
        case .focusDirection(let d):        return "Focus \(d.rawValue.capitalized)"
        case .swapDirection(let d):         return "Swap \(d.rawValue.capitalized)"
        case .switchWorkspace(let n):         return "Switch to Workspace \(n)"
        case .moveToWorkspace(let n):         return "Move to Workspace \(n)"
        case .moveWorkspaceToMonitor(let d): return "Move Workspace \(d.rawValue.capitalized)"
        case .toggleFloating:               return "Toggle Floating"
        case .toggleSplit:                  return "Toggle Split Direction"
        case .showKeybinds:                 return "Show Keybind Overlay"
        case .launchApp(let b):             return "Launch \(launchAppName(b))"
        case .focusMenuBar:                 return "Focus Menu Bar"
        case .focusFloating:                return "Cycle Floating Windows"
        case .closeWindow:                  return "Close Window"
        case .cycleWorkspace(let d):        return d > 0 ? "Next Workspace" : "Previous Workspace"
        }
    }

    private func launchAppName(_ bundleID: String) -> String {
        appDisplayName(for: bundleID)
    }
}
