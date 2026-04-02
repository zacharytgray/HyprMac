import SwiftUI
import Carbon

struct KeybindsSettingsView: View {
    @ObservedObject var config = UserConfig.shared
    @State private var selectedBindID: String?
    @State private var showingAddSheet = false
    @State private var editingBind: Keybind?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keybinds — click a row to edit, or add custom bindings below.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

            List(selection: $selectedBindID) {
                ForEach(config.keybinds) { bind in
                    HStack {
                        Text(bind.displayString)
                            .font(.system(.body, design: .monospaced))
                            .frame(minWidth: 140, alignment: .leading)
                        Text(bind.actionDescription)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        editingBind = bind
                    }
                }
                .onDelete { offsets in
                    config.keybinds.remove(atOffsets: offsets)
                }
            }

            HStack(spacing: 12) {
                Button(action: { showingAddSheet = true }) {
                    Label("Add Keybind", systemImage: "plus")
                }

                if let sel = selectedBindID,
                   let idx = config.keybinds.firstIndex(where: { $0.id == sel }) {
                    Button(action: { editingBind = config.keybinds[idx] }) {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button(action: { config.keybinds.remove(at: idx); selectedBindID = nil }) {
                        Label("Remove", systemImage: "minus")
                    }
                }

                Spacer()

                Button("Reset to Defaults") {
                    config.keybinds = Keybind.defaults
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $showingAddSheet) {
            KeybindEditorSheet(existingBind: nil) { newBind in
                config.keybinds.append(newBind)
            }
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

// MARK: - keybind editor sheet

struct KeybindEditorSheet: View {
    let existingBind: Keybind?
    let onSave: (Keybind) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedAction: ActionChoice = .focusDirection
    @State private var directionParam: String = "left"
    @State private var desktopParam: Int = 1
    @State private var bundleIDParam: String = "com.apple.Terminal"

    // key recording
    @State private var recordedKeyCode: UInt16 = 0
    @State private var useHypr = true
    @State private var useShift = false
    @State private var useControl = false
    @State private var useOption = false
    @State private var useCommand = false
    @State private var isRecording = false
    @State private var keyDisplay = "Press a key..."

    enum ActionChoice: String, CaseIterable {
        case focusDirection = "Focus Direction"
        case swapDirection = "Swap Direction"
        case switchDesktop = "Switch Workspace"
        case moveToDesktop = "Move to Workspace"
        case moveWorkspaceToMonitor = "Move Workspace to Monitor"
        case toggleFloating = "Toggle Floating"
        case toggleSplit = "Toggle Split"
        case showKeybinds = "Show Keybinds"
        case launchApp = "Launch App"
        case focusMenuBar = "Focus Menu Bar"
        case focusFloating = "Focus Floating"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existingBind == nil ? "Add Keybind" : "Edit Keybind")
                .font(.headline)

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

            // action picker
            GroupBox("Action") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Type", selection: $selectedAction) {
                        ForEach(ActionChoice.allCases, id: \.self) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }

                    // params based on action type
                    switch selectedAction {
                    case .focusDirection, .swapDirection, .moveWorkspaceToMonitor:
                        Picker("Direction", selection: $directionParam) {
                            Text("Left").tag("left")
                            Text("Right").tag("right")
                            Text("Up").tag("up")
                            Text("Down").tag("down")
                        }
                        .pickerStyle(.segmented)
                    case .switchDesktop, .moveToDesktop:
                        Picker("Workspace", selection: $desktopParam) {
                            ForEach(1...9, id: \.self) { n in
                                Text("\(n)").tag(n)
                            }
                        }
                    case .launchApp:
                        TextField("Bundle ID", text: $bundleIDParam)
                            .textFieldStyle(.roundedBorder)
                        Text("e.g. com.apple.Terminal, com.googlecode.iterm2")
                            .font(.caption2)
                            .foregroundColor(.secondary)
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
            }
        }
        .padding()
        .frame(width: 450)
        .onAppear { loadExisting() }
    }

    private func loadExisting() {
        guard let bind = existingBind else { return }
        recordedKeyCode = bind.keyCode
        useHypr = bind.modifiers.contains(.hypr)
        useShift = bind.modifiers.contains(.shift)
        useControl = bind.modifiers.contains(.control)
        useOption = bind.modifiers.contains(.option)
        useCommand = bind.modifiers.contains(.command)
        keyDisplay = keyCodeToName(bind.keyCode)

        switch bind.action {
        case .focusDirection(let d):
            selectedAction = .focusDirection; directionParam = d
        case .swapDirection(let d):
            selectedAction = .swapDirection; directionParam = d
        case .switchDesktop(let n):
            selectedAction = .switchDesktop; desktopParam = n
        case .moveToDesktop(let n):
            selectedAction = .moveToDesktop; desktopParam = n
        case .moveWorkspaceToMonitor(let d):
            selectedAction = .moveWorkspaceToMonitor; directionParam = d
        case .toggleFloating:
            selectedAction = .toggleFloating
        case .toggleSplit:
            selectedAction = .toggleSplit
        case .showKeybinds:
            selectedAction = .showKeybinds
        case .launchApp(let b):
            selectedAction = .launchApp; bundleIDParam = b
        case .focusMenuBar:
            selectedAction = .focusMenuBar
        case .focusFloating:
            selectedAction = .focusFloating
        }
    }

    private func save() {
        var mods = ModifierFlags()
        if useHypr { mods.insert(.hypr) }
        if useShift { mods.insert(.shift) }
        if useControl { mods.insert(.control) }
        if useOption { mods.insert(.option) }
        if useCommand { mods.insert(.command) }

        let action: Keybind.ActionDescriptor
        switch selectedAction {
        case .focusDirection: action = .focusDirection(directionParam)
        case .swapDirection: action = .swapDirection(directionParam)
        case .switchDesktop: action = .switchDesktop(desktopParam)
        case .moveToDesktop: action = .moveToDesktop(desktopParam)
        case .moveWorkspaceToMonitor: action = .moveWorkspaceToMonitor(directionParam)
        case .toggleFloating: action = .toggleFloating
        case .toggleSplit: action = .toggleSplit
        case .showKeybinds: action = .showKeybinds
        case .launchApp: action = .launchApp(bundleID: bundleIDParam)
        case .focusMenuBar: action = .focusMenuBar
        case .focusFloating: action = .focusFloating
        }

        let bind = Keybind(keyCode: recordedKeyCode, modifiers: mods, action: action)
        onSave(bind)
        dismiss()
    }

    // listen for key presses while recording
    private func setupKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isRecording else { return event }
            // ignore modifier-only keys
            let code = event.keyCode
            if code == 55 || code == 54 || code == 56 || code == 58 ||
               code == 59 || code == 61 || code == 62 || code == 60 { return nil }
            recordedKeyCode = code
            keyDisplay = keyCodeToName(code)
            isRecording = false
            return nil  // consume the event
        }
    }

    private func keyCodeToName(_ code: UInt16) -> String {
        switch Int(code) {
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Return: return "Return"
        case kVK_Space: return "Space"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_Escape: return "Escape"
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
        case kVK_ANSI_Minus: return "-"; case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["; case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Semicolon: return ";"; case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","; case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"; case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Grave: return "`"
        case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"
        case kVK_F4: return "F4"; case kVK_F5: return "F5"; case kVK_F6: return "F6"
        case kVK_F7: return "F7"; case kVK_F8: return "F8"; case kVK_F9: return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default: return "Key(\(code))"
        }
    }
}

// MARK: - display helpers

extension Keybind {
    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.hypr) { parts.append("⇪") }
        if modifiers.contains(.command) { parts.append("⌘") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.control) { parts.append("⌃") }
        parts.append(keyCodeName)
        return parts.joined(separator: " + ")
    }

    var keyCodeName: String {
        switch Int(keyCode) {
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Return: return "Return"
        case kVK_ANSI_1: return "1"; case kVK_ANSI_2: return "2"; case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"; case kVK_ANSI_5: return "5"; case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"; case kVK_ANSI_8: return "8"; case kVK_ANSI_9: return "9"
        case kVK_ANSI_A: return "A"; case kVK_ANSI_B: return "B"; case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"; case kVK_ANSI_E: return "E"; case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"; case kVK_ANSI_H: return "H"; case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"; case kVK_ANSI_K: return "K"; case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"; case kVK_ANSI_N: return "N"; case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"; case kVK_ANSI_Q: return "Q"; case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"; case kVK_ANSI_T: return "T"; case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"; case kVK_ANSI_W: return "W"; case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"; case kVK_ANSI_Z: return "Z"
        default: return "Key(\(keyCode))"
        }
    }

    var actionDescription: String {
        switch action {
        case .focusDirection(let d): return "Focus \(d)"
        case .swapDirection(let d): return "Swap \(d)"
        case .switchDesktop(let n): return "Switch to Workspace \(n)"
        case .moveToDesktop(let n): return "Move to Workspace \(n)"
        case .moveWorkspaceToMonitor(let d): return "Move Workspace \(d)"
        case .toggleFloating: return "Toggle Floating"
        case .toggleSplit: return "Toggle Split"
        case .showKeybinds: return "Show Keybinds"
        case .launchApp(let b): return "Launch \(b)"
        case .focusMenuBar: return "Focus Menu Bar"
        case .focusFloating: return "Focus Floating"
        }
    }
}
