// Data tables for the Welcome / Tour window.

import SwiftUI

// MARK: - what's new feature list
// Update this array before each release with features from git log;
// see docs/release.md for the workflow.

/// Accent used for a changelog row's icon tile.
enum WhatsNewTint {
    case cyan   // default
    case magenta // floating / scratchpad features
}

/// One row in the "What's New" page: icon, title, description, tint.
struct WhatsNewFeature {
    let icon: String
    let title: String
    let description: String
    var tint: WhatsNewTint = .cyan
    /// github handle of an outside contributor, shown under the description
    var credit: String? = nil
}

enum WhatsNewFeatures {
    // update this before each release — see docs/release.md
    static let current: [WhatsNewFeature] = [
        WhatsNewFeature(
            icon: "sparkle",
            title: "Turn Off the Focus Flash",
            description: "With window borders on, a new setting keeps the border but skips the brief tint when focus moves to a window.",
            credit: "Ealianis"
        ),
        WhatsNewFeature(
            icon: "cursorarrow.rays",
            title: "Overview Opens Where You Are",
            description: "The workspace overview and the keybind list now open on the monitor under your pointer, like every other Hypr action.",
            credit: "Thiago Goncalves"
        ),
        WhatsNewFeature(
            icon: "rectangle.split.2x1",
            title: "Windows Tile Beside Dia",
            description: "A window moved next to Dia now tiles beside it instead of floating on top. HyprMac no longer believes Dia when it wrongly reports a resize failed.",
            credit: "cipas"
        ),
        WhatsNewFeature(
            icon: "lock.doc",
            title: "Configs Managed by Other Tools",
            description: "When Nix, a dotfiles tool or a read-only file owns your config, Settings says so and HyprMac never overwrites it.",
            credit: "emilnymann"
        ),
        WhatsNewFeature(
            icon: "arrow.triangle.2.circlepath",
            title: "Config Edits Load Right Away",
            description: "Changes to config.json or monitor-config.json from an editor or another tool now apply within a couple of seconds."
        ),
        WhatsNewFeature(
            icon: "icloud",
            title: "Safer iCloud Sync",
            description: "Turning on sync now asks which settings to keep when this Mac and iCloud differ. It keeps a backup of the other and keeps private files private."
        ),
    ]
}

enum WelcomeContent {
    static let productURL = URL(string: "https://hyprmac.app/")!

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static func chord(
        in keybinds: [Keybind],
        hyprKey: HyprKey,
        matching predicate: (Action) -> Bool
    ) -> String? {
        guard let bind = keybinds.first(where: { predicate($0.action) }) else { return nil }
        return bind.badgeLabels().joined(separator: " ")
    }
}
