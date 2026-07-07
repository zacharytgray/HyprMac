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
}

enum WhatsNewFeatures {
    // update this before each release — see CLAUDE.md instructions
    static let current: [WhatsNewFeature] = [
        WhatsNewFeature(
            icon: "square.grid.2x2",
            title: "Tile Sent Windows Automatically",
            description: "New in Layout settings: turn on \"Tile sent windows\" and anything you send to the scratchpad snaps into the tiled grid instead of floating. Windows that can't fit still float, so nothing gets lost.",
            tint: .magenta
        ),
        WhatsNewFeature(
            icon: "rectangle.center.inset.filled",
            title: "Adjustable Scratchpad Padding",
            description: "A new slider sets how far the scratchpad's tiled region insets from the screen edge — keep the dimmed border for framing, or take it to zero to use every last pixel.",
            tint: .magenta
        ),
        WhatsNewFeature(
            icon: "moon",
            title: "Steadier Dimming While Dragging",
            description: "With dimming on, the bright cutout around a dragged floating window now locks to it from the very first pixel — even on a fast flick — instead of trailing behind with an offset.",
            tint: .cyan
        ),
    ]
}

enum WelcomeContent {
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
