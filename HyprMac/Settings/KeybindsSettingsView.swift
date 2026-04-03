import SwiftUI
import Carbon

// MARK: - key badge components

struct KeybadgeView: View {
    let bind: Keybind

    var body: some View {
        HStack(spacing: 3) {
            if bind.modifiers.contains(.hypr)    { KeyChip("⇪") }
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
        case .switchDesktop, .moveToDesktop, .moveWorkspaceToMonitor, .cycleWorkspace:
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
    @State private var directionParam = "left"
    @State private var desktopParam = 1
    @State private var bundleIDParam = "com.apple.Terminal"

    @State private var recordedKeyCode: UInt16 = 0
    @State private var useHypr = true
    @State private var useShift = false
    @State private var useControl = false
    @State private var useOption = false
    @State private var useCommand = false
    @State private var isRecording = false
    @State private var keyDisplay = ""
    @State private var recordingPulse = false

    enum ActionChoice: String, CaseIterable {
        case focusDirection         = "Focus Direction"
        case swapDirection          = "Swap Direction"
        case switchDesktop          = "Switch Workspace"
        case moveToDesktop          = "Move to Workspace"
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
                VStack(alignment: .leading, spacing: 10) {
                    Text("Shortcut")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    // modifier toggles
                    HStack(spacing: 6) {
                        ModifierToggle("⇪ Caps",  isOn: $useHypr)
                        ModifierToggle("⌃ Ctrl",  isOn: $useControl)
                        ModifierToggle("⌥ Opt",   isOn: $useOption)
                        ModifierToggle("⇧ Shift", isOn: $useShift)
                        ModifierToggle("⌘ Cmd",   isOn: $useCommand)
                    }

                    // key recorder
                    Button { isRecording.toggle() } label: {
                        HStack(spacing: 8) {
                            if recordedKeyCode != 0 && !isRecording {
                                KeybadgeView(bind: previewBind)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text(isRecording ? "Press a key…" : "Click to record a key")
                                    .foregroundStyle(isRecording ? Color.accentColor : Color.secondary)
                                    .font(isRecording ? .body : .callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            if isRecording {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 7, height: 7)
                                    .opacity(recordingPulse ? 1 : 0.3)
                                    .onAppear {
                                        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                                            recordingPulse = true
                                        }
                                    }
                                    .onDisappear { recordingPulse = false }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(isRecording
                                      ? Color.accentColor.opacity(0.07)
                                      : Color(nsColor: .controlBackgroundColor))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(isRecording ? Color.accentColor : Color(nsColor: .separatorColor),
                                                lineWidth: isRecording ? 1.5 : 0.5)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .onAppear { setupKeyMonitor() }
                }
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
                            Text("Left").tag("left")
                            Text("Right").tag("right")
                            Text("Up").tag("up")
                            Text("Down").tag("down")
                        }
                        .pickerStyle(.segmented)
                    case .switchDesktop, .moveToDesktop:
                        Picker("Workspace", selection: $desktopParam) {
                            ForEach(1...9, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented)
                    case .cycleWorkspace:
                        Picker("Direction", selection: $desktopParam) {
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

    // keybind used for the live badge preview (action doesn't matter for display)
    private var previewBind: Keybind {
        var mods = ModifierFlags()
        if useHypr    { mods.insert(.hypr) }
        if useShift   { mods.insert(.shift) }
        if useControl { mods.insert(.control) }
        if useOption  { mods.insert(.option) }
        if useCommand { mods.insert(.command) }
        return Keybind(keyCode: recordedKeyCode, modifiers: mods, action: .toggleFloating)
    }

    private func loadExisting() {
        guard let bind = existingBind else { return }
        recordedKeyCode = bind.keyCode
        useHypr    = bind.modifiers.contains(.hypr)
        useShift   = bind.modifiers.contains(.shift)
        useControl = bind.modifiers.contains(.control)
        useOption  = bind.modifiers.contains(.option)
        useCommand = bind.modifiers.contains(.command)
        keyDisplay = keyCodeToName(bind.keyCode)

        switch bind.action {
        case .focusDirection(let d):         selectedAction = .focusDirection;         directionParam = d
        case .swapDirection(let d):          selectedAction = .swapDirection;          directionParam = d
        case .switchDesktop(let n):          selectedAction = .switchDesktop;          desktopParam = n
        case .moveToDesktop(let n):          selectedAction = .moveToDesktop;          desktopParam = n
        case .moveWorkspaceToMonitor(let d): selectedAction = .moveWorkspaceToMonitor; directionParam = d
        case .toggleFloating:                selectedAction = .toggleFloating
        case .toggleSplit:                   selectedAction = .toggleSplit
        case .showKeybinds:                  selectedAction = .showKeybinds
        case .launchApp(let b):              selectedAction = .launchApp;              bundleIDParam = b
        case .focusMenuBar:                  selectedAction = .focusMenuBar
        case .focusFloating:                 selectedAction = .focusFloating
        case .closeWindow:                   selectedAction = .closeWindow
        case .cycleWorkspace(let d):         selectedAction = .cycleWorkspace;         desktopParam = d
        }
    }

    private func save() {
        var mods = ModifierFlags()
        if useHypr    { mods.insert(.hypr) }
        if useShift   { mods.insert(.shift) }
        if useControl { mods.insert(.control) }
        if useOption  { mods.insert(.option) }
        if useCommand { mods.insert(.command) }

        let action: Keybind.ActionDescriptor
        switch selectedAction {
        case .focusDirection:         action = .focusDirection(directionParam)
        case .swapDirection:          action = .swapDirection(directionParam)
        case .switchDesktop:          action = .switchDesktop(desktopParam)
        case .moveToDesktop:          action = .moveToDesktop(desktopParam)
        case .moveWorkspaceToMonitor: action = .moveWorkspaceToMonitor(directionParam)
        case .toggleFloating:         action = .toggleFloating
        case .toggleSplit:            action = .toggleSplit
        case .showKeybinds:           action = .showKeybinds
        case .launchApp:              action = .launchApp(bundleID: bundleIDParam)
        case .focusMenuBar:           action = .focusMenuBar
        case .focusFloating:          action = .focusFloating
        case .closeWindow:            action = .closeWindow
        case .cycleWorkspace:         action = .cycleWorkspace(desktopParam)
        }

        onSave(Keybind(keyCode: recordedKeyCode, modifiers: mods, action: action))
        dismiss()
    }

    private func setupKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isRecording else { return event }
            let code = event.keyCode
            if [55, 54, 56, 58, 59, 61, 62, 60].contains(Int(code)) { return nil }
            recordedKeyCode = code
            keyDisplay = keyCodeToName(code)
            isRecording = false
            return nil
        }
    }

    private func keyCodeToName(_ code: UInt16) -> String {
        switch Int(code) {
        case kVK_LeftArrow: return "←"; case kVK_RightArrow: return "→"
        case kVK_UpArrow:   return "↑"; case kVK_DownArrow:  return "↓"
        case kVK_Return:    return "Return";  case kVK_Space:  return "Space"
        case kVK_Tab:       return "Tab";     case kVK_Delete: return "Delete"
        case kVK_Escape:    return "Escape"
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
        case kVK_ANSI_Minus:        return "-"; case kVK_ANSI_Equal:        return "="
        case kVK_ANSI_LeftBracket:  return "["; case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Semicolon:    return ";"; case kVK_ANSI_Quote:        return "'"
        case kVK_ANSI_Comma:        return ","; case kVK_ANSI_Period:        return "."
        case kVK_ANSI_Slash:        return "/"; case kVK_ANSI_Backslash:    return "\\"
        case kVK_ANSI_Grave:        return "`"
        case kVK_F1:  return "F1";  case kVK_F2:  return "F2";  case kVK_F3:  return "F3"
        case kVK_F4:  return "F4";  case kVK_F5:  return "F5";  case kVK_F6:  return "F6"
        case kVK_F7:  return "F7";  case kVK_F8:  return "F8";  case kVK_F9:  return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default: return "Key(\(code))"
        }
    }
}

// MARK: - modifier toggle button

struct ModifierToggle: View {
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        _isOn = isOn
    }

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isOn ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(isOn ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                )
                .foregroundStyle(isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Keybind display helpers

extension Keybind {
    var keyCodeName: String {
        switch Int(keyCode) {
        case kVK_LeftArrow: return "←"; case kVK_RightArrow: return "→"
        case kVK_UpArrow:   return "↑"; case kVK_DownArrow:  return "↓"
        case kVK_Return:    return "Return";  case kVK_Space:  return "Space"
        case kVK_Tab:       return "Tab";     case kVK_Delete: return "Delete"
        case kVK_Escape:    return "Escape"
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
        case kVK_ANSI_Minus:        return "-"; case kVK_ANSI_Equal:        return "="
        case kVK_ANSI_LeftBracket:  return "["; case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Semicolon:    return ";"; case kVK_ANSI_Quote:        return "'"
        case kVK_ANSI_Comma:        return ","; case kVK_ANSI_Period:        return "."
        case kVK_ANSI_Slash:        return "/"; case kVK_ANSI_Backslash:    return "\\"
        case kVK_ANSI_Grave:        return "`"
        case kVK_F1:  return "F1";  case kVK_F2:  return "F2";  case kVK_F3:  return "F3"
        case kVK_F4:  return "F4";  case kVK_F5:  return "F5";  case kVK_F6:  return "F6"
        case kVK_F7:  return "F7";  case kVK_F8:  return "F8";  case kVK_F9:  return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default: return "Key(\(keyCode))"
        }
    }

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.hypr)    { parts.append("⇪") }
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
            case "left":  return "arrow.left"
            case "right": return "arrow.right"
            case "up":    return "arrow.up"
            default:      return "arrow.down"
            }
        case .swapDirection:
            return "arrow.left.arrow.right"
        case .switchDesktop:
            return "number.circle"
        case .moveToDesktop:
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
        case .focusDirection(let d):        return "Focus \(d.capitalized)"
        case .swapDirection(let d):         return "Swap \(d.capitalized)"
        case .switchDesktop(let n):         return "Switch to Workspace \(n)"
        case .moveToDesktop(let n):         return "Move to Workspace \(n)"
        case .moveWorkspaceToMonitor(let d): return "Move Workspace \(d.capitalized)"
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
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }
}
