// Data tables for the Welcome / Tour window.

import SwiftUI

// MARK: - what's new feature list
// Update this array before each release with features from git log;
// see CLAUDE.md "Release Feature List" for the workflow.

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
    // update this before each release — see CLAUDE.md instructions
    static let current: [WhatsNewFeature] = [
        WhatsNewFeature(
            icon: "arrow.up.left.and.arrow.down.right",
            title: "Keyboard Window Resizing",
            description: "Resize the focused tiled window from the keyboard with Hypr+Ctrl+Shift+Arrow. Each press moves the window's edge on that axis one step in the arrow direction, wherever the window sits in the layout. Rebindable in Settings → Keybinds.",
            credit: "@joops"
        ),
        WhatsNewFeature(
            icon: "rectangle.roundedtop",
            title: "Configurable Window Corner Radius",
            description: "A new slider in Settings → Tiling → Focus Chrome sets the corner radius (0–32 px) used by focus borders, floating borders, focus brackets, and dim-overlay cut-outs. Existing setups keep the previous default (16 px on macOS 26 and later, 10 px before).",
            credit: "@Amin-El-Sayed"
        ),
    ]
}

enum WelcomeContent {
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
