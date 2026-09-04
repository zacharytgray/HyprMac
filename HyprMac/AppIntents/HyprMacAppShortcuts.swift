// Makes HyprMac's central activation action discoverable across the system.

import AppIntents

/// App Shortcut phrases include both a generic entry point and parameterized
/// variants. The generic phrase remains useful for apps outside the suggested
/// entity set; Spotlight asks for the required application interactively.
@available(macOS 15.0, *)
struct HyprMacAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenApplicationWithHyprMacIntent(),
            phrases: [
                "Open an app with \(.applicationName)",
                "Open \(\.$application) with \(.applicationName)",
                "Launch \(\.$application) with \(.applicationName)",
                "Use \(.applicationName) to open \(\.$application)",
            ],
            shortTitle: "Open App",
            systemImageName: "macwindow"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .blue
}
