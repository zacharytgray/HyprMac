import Carbon

// data-only file: the default keybind table that ships with HyprMac.
// extracted from Keybind.swift in phase 6 so the model file stays focused on
// the Keybind / ModifierFlags types and DefaultKeybindsTests can verify the
// table without reaching across multiple concerns.
//
// any new default action goes here. UserConfig.mergeNewDefaults() injects
// these into existing saved configs at load time, so users who upgrade pick
// up new defaults without resetting their customizations.

extension Keybind {
    static let defaults: [Keybind] = {
        var binds: [Keybind] = []

        // hypr (caps lock) + arrow: focus direction
        binds.append(Keybind(keyCode: UInt16(kVK_LeftArrow), modifiers: .hypr,
                             action: .focusDirection(.left)))
        binds.append(Keybind(keyCode: UInt16(kVK_RightArrow), modifiers: .hypr,
                             action: .focusDirection(.right)))
        binds.append(Keybind(keyCode: UInt16(kVK_UpArrow), modifiers: .hypr,
                             action: .focusDirection(.up)))
        binds.append(Keybind(keyCode: UInt16(kVK_DownArrow), modifiers: .hypr,
                             action: .focusDirection(.down)))

        // hypr + shift + arrow: swap direction
        binds.append(Keybind(keyCode: UInt16(kVK_LeftArrow), modifiers: [.hypr, .shift],
                             action: .swapDirection(.left)))
        binds.append(Keybind(keyCode: UInt16(kVK_RightArrow), modifiers: [.hypr, .shift],
                             action: .swapDirection(.right)))
        binds.append(Keybind(keyCode: UInt16(kVK_UpArrow), modifiers: [.hypr, .shift],
                             action: .swapDirection(.up)))
        binds.append(Keybind(keyCode: UInt16(kVK_DownArrow), modifiers: [.hypr, .shift],
                             action: .swapDirection(.down)))

        // hypr + 1-9: switch workspace N / hypr + shift + 1-9: move window to workspace N
        let numKeys: [UInt16] = [
            UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_3),
            UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_6),
            UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_9)
        ]
        for (i, key) in numKeys.enumerated() {
            binds.append(Keybind(keyCode: key, modifiers: .hypr,
                                 action: .switchWorkspace(i + 1)))
            binds.append(Keybind(keyCode: key, modifiers: [.hypr, .shift],
                                 action: .moveToWorkspace(i + 1)))
        }

        // hypr + ctrl + left/right: move current workspace to adjacent monitor
        binds.append(Keybind(keyCode: UInt16(kVK_LeftArrow), modifiers: [.hypr, .control],
                             action: .moveWorkspaceToMonitor(.left)))
        binds.append(Keybind(keyCode: UInt16(kVK_RightArrow), modifiers: [.hypr, .control],
                             action: .moveWorkspaceToMonitor(.right)))

        // hypr + shift + t: toggle floating
        binds.append(Keybind(keyCode: UInt16(kVK_ANSI_T), modifiers: [.hypr, .shift],
                             action: .toggleFloating))

        // hypr + j: toggle split direction (transpose)
        binds.append(Keybind(keyCode: UInt16(kVK_ANSI_J), modifiers: .hypr,
                             action: .toggleSplit))

        // hypr + k: show keybinds
        binds.append(Keybind(keyCode: UInt16(kVK_ANSI_K), modifiers: .hypr,
                             action: .showKeybinds))

        // hypr + f: focus/raise floating windows
        binds.append(Keybind(keyCode: UInt16(kVK_ANSI_F), modifiers: .hypr,
                             action: .focusFloating))

        // hypr + w: close window
        binds.append(Keybind(keyCode: UInt16(kVK_ANSI_W), modifiers: .hypr,
                             action: .closeWindow))

        // hypr + tab / hypr + shift + tab: cycle occupied workspaces on current monitor
        binds.append(Keybind(keyCode: UInt16(kVK_Tab), modifiers: .hypr,
                             action: .cycleWorkspace(1)))
        binds.append(Keybind(keyCode: UInt16(kVK_Tab), modifiers: [.hypr, .shift],
                             action: .cycleWorkspace(-1)))

        // hypr + ` (backtick): focus menu bar
        binds.append(Keybind(keyCode: UInt16(kVK_ANSI_Grave), modifiers: .hypr,
                             action: .focusMenuBar))

        // hypr + enter: launch terminal
        binds.append(Keybind(keyCode: UInt16(kVK_Return), modifiers: .hypr,
                             action: .launchApp(bundleID: "com.apple.Terminal")))

        return binds
    }()
}
