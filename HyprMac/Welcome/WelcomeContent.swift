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
            icon: "macwindow.on.rectangle",
            title: "See Which Windows Float",
            description: "Floating windows now get a thin outline with a faint glow in Corners mode too, and it follows them while you drag. A focused floating window's corner marks turn the floating color.",
            tint: .magenta
        ),
        WhatsNewFeature(
            icon: "bolt.horizontal",
            title: "New Windows Tile Faster",
            description: "A new window no longer waits seconds for the next background check, including one opened right after you switch workspaces."
        ),
        WhatsNewFeature(
            icon: "rectangle.split.2x1",
            title: "Fewer Windows Float by Mistake",
            description: "When an app's minimum size rules out the first spot, HyprMac now tries the spot that fits instead of floating the window. Dia's first window after launch tiles again."
        ),
        WhatsNewFeature(
            icon: "hand.draw",
            title: "Steadier Dragging and Layouts",
            description: "A drop that can't fit is refused up front instead of resizing and snapping back, and busy apps no longer get windows mixed up or slow every check."
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
