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
            icon: "capslock",
            title: "Hypr Holds Through Control",
            description: "Letting go of Control during a Hypr shortcut no longer ends Hypr while Caps Lock is still held.",
            credit: "wbalbinot"
        ),
        WhatsNewFeature(
            icon: "rectangle.split.2x1",
            title: "New Windows Split the Focused Tile",
            description: "A new window now opens beside the tile you have focused instead of at the end of the layout. A window you close and reopen does the same.",
            credit: "wbalbinot"
        ),
        WhatsNewFeature(
            icon: "display.2",
            title: "Apps Open on the Monitor You're On",
            description: "An app's first window now opens on the monitor under your pointer, beside the focused tile. Pinned apps still go to their workspace."
        ),
        WhatsNewFeature(
            icon: "pin",
            title: "Pinned Apps Reopen on Their Workspace",
            description: "A pinned app's window that you close and reopen now goes back to its pinned workspace instead of the one on screen."
        ),
        WhatsNewFeature(
            icon: "bolt.horizontal",
            title: "No More Tiles Stuck in the Corner",
            description: "A tile whose app was busy during a workspace switch now appears as soon as the app answers, instead of staying hidden for seconds."
        ),
        WhatsNewFeature(
            icon: "ruler",
            title: "Size-Limited Windows Settle Sooner",
            description: "HyprMac no longer retries sizes it already learned an app refuses, so a window with a minimum size is placed with fewer resizes."
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
