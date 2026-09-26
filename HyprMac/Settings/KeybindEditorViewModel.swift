// State machine for the keybind editor sheet.

import SwiftUI
import Combine

/// State machine for the keybind editor sheet. Holds the in-progress
/// chord, the selected action, and per-action parameter values;
/// loads from an existing keybind on open and builds a new keybind
/// on save.
@MainActor
final class KeybindEditorViewModel: ObservableObject {
    @Published var selectedAction: ActionChoice = .focusDirection
    @Published var directionParam: Direction = .left
    @Published var workspaceParam = 1
    @Published var bundleIDParam = "com.apple.Terminal"
    @Published var commandLabelParam = ""
    @Published var commandParam = ""

    @Published var recordedKeyCode: UInt16 = 0
    @Published var useHypr = true
    @Published var useShift = false
    @Published var useControl = false
    @Published var useOption = false
    @Published var useCommand = false

    enum ActionChoice: String, CaseIterable {
        case focusDirection         = "Focus Direction"
        case swapDirection          = "Swap Direction"
        case switchWorkspace        = "Switch Workspace"
        case moveToWorkspace        = "Move to Workspace"
        case moveToWorkspaceAndFollow = "Move to Workspace and Follow"
        case moveWindowToMonitor    = "Move Window to Monitor"
        case toggleFloating         = "Toggle Floating"
        case toggleSplit            = "Toggle Split"
        case showKeybinds           = "Show Keybinds"
        case showWorkspaceOverview  = "Show Workspace Overview"
        case launchApp              = "Launch App"
        case focusMenuBar           = "Focus Menu Bar"
        case focusFloating          = "Focus Floating"
        case moveToNextEmptyWorkspace = "Move to dedicated workspace"
        case closeWindow            = "Close Window"
        case cycleWorkspace         = "Cycle Workspace"
        case toggleScratchpad       = "Toggle Scratchpad"
        case moveToScratchpad       = "Send to Scratchpad"
        case resizeDirection        = "Resize Direction"
        case toggleTiling           = "Pause / Resume Tiling"
        case runCommand             = "Run a command"
        case saveLayout             = "Save Layout"
        case restoreLayout          = "Restore Layout"
    }

    /// nil unless the command action is selected and its line is unusable
    var commandValidationError: CommandRunner.ValidationError? {
        selectedAction == .runCommand ? CommandRunner.validate(commandParam) : nil
    }

    var commandValidationMessage: String? { commandValidationError?.message }

    var canSave: Bool { recordedKeyCode != 0 && commandValidationError == nil }

    func load(_ bind: Keybind?) {
        guard let bind else { return }
        recordedKeyCode = bind.keyCode
        useHypr    = bind.modifiers.contains(.hypr)
        useShift   = bind.modifiers.contains(.shift)
        useControl = bind.modifiers.contains(.control)
        useOption  = bind.modifiers.contains(.option)
        useCommand = bind.modifiers.contains(.command)
        switch bind.action {
        case .focusDirection(let d):         selectedAction = .focusDirection;         directionParam = d
        case .swapDirection(let d):          selectedAction = .swapDirection;          directionParam = d
        case .switchWorkspace(let n):        selectedAction = .switchWorkspace;        workspaceParam = n
        case .moveToWorkspace(let n):        selectedAction = .moveToWorkspace;        workspaceParam = n
        case .moveToWorkspaceAndFollow(let n): selectedAction = .moveToWorkspaceAndFollow; workspaceParam = n
        case .moveWindowToMonitor(let d):    selectedAction = .moveWindowToMonitor;    directionParam = d
        case .toggleFloating:                selectedAction = .toggleFloating
        case .toggleSplit:                   selectedAction = .toggleSplit
        case .showKeybinds:                  selectedAction = .showKeybinds
        case .showWorkspaceOverview:         selectedAction = .showWorkspaceOverview
        case .launchApp(let b):              selectedAction = .launchApp;              bundleIDParam = b
        case .focusMenuBar:                  selectedAction = .focusMenuBar
        case .focusFloating:                 selectedAction = .focusFloating
        case .moveToNextEmptyWorkspace:      selectedAction = .moveToNextEmptyWorkspace
        case .closeWindow:                   selectedAction = .closeWindow
        case .cycleWorkspace(let d):         selectedAction = .cycleWorkspace;         workspaceParam = d
        case .toggleScratchpad:              selectedAction = .toggleScratchpad
        case .moveToScratchpad:              selectedAction = .moveToScratchpad
        case .resizeDirection(let d):        selectedAction = .resizeDirection;       directionParam = d
        case .toggleTiling:                  selectedAction = .toggleTiling
        case .runCommand(let label, let cmd):
            selectedAction = .runCommand
            commandLabelParam = label
            commandParam = cmd
        case .saveLayout:                    selectedAction = .saveLayout
        case .restoreLayout:                 selectedAction = .restoreLayout
        }
    }

    func buildKeybind() -> Keybind {
        let mods = ModifierFlags.from(
            hypr: useHypr, shift: useShift, control: useControl,
            option: useOption, command: useCommand
        )
        let action: Action
        switch selectedAction {
        case .focusDirection:         action = .focusDirection(directionParam)
        case .swapDirection:          action = .swapDirection(directionParam)
        case .switchWorkspace:        action = .switchWorkspace(workspaceParam)
        case .moveToWorkspace:        action = .moveToWorkspace(workspaceParam)
        case .moveToWorkspaceAndFollow: action = .moveToWorkspaceAndFollow(workspaceParam)
        case .moveWindowToMonitor:    action = .moveWindowToMonitor(directionParam)
        case .toggleFloating:         action = .toggleFloating
        case .toggleSplit:            action = .toggleSplit
        case .showKeybinds:           action = .showKeybinds
        case .showWorkspaceOverview:  action = .showWorkspaceOverview
        case .launchApp:              action = .launchApp(bundleID: bundleIDParam)
        case .focusMenuBar:           action = .focusMenuBar
        case .focusFloating:          action = .focusFloating
        case .moveToNextEmptyWorkspace: action = .moveToNextEmptyWorkspace
        case .closeWindow:            action = .closeWindow
        case .cycleWorkspace:         action = .cycleWorkspace(workspaceParam)
        case .toggleScratchpad:       action = .toggleScratchpad
        case .moveToScratchpad:       action = .moveToScratchpad
        case .resizeDirection:        action = .resizeDirection(directionParam)
        case .toggleTiling:           action = .toggleTiling
        case .runCommand:
            action = .runCommand(
                label: commandLabelParam.trimmingCharacters(in: .whitespaces),
                command: commandParam.trimmingCharacters(in: .whitespaces))
        case .saveLayout:             action = .saveLayout
        case .restoreLayout:          action = .restoreLayout
        }
        return Keybind(keyCode: recordedKeyCode, modifiers: mods, action: action)
    }
}
