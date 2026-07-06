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
            icon: "sparkles",
            title: "One Design System, Everywhere",
            description: "Settings, the guided tour, and the Hypr + K overlay finally speak one language. Cyan means focus and active; magenta means the floating layer. There's a new app icon to match.",
            tint: .cyan
        ),
        WhatsNewFeature(
            icon: "keyboard",
            title: "Redesigned Keybind Overlay",
            description: "Hypr + K opens a cleaner two-column cheat sheet. Type to filter, press Esc to close, and floating-window actions are marked with a magenta ◇ so they're easy to spot."
        ),
        WhatsNewFeature(
            icon: "slider.horizontal.3",
            title: "Settings, Reorganized",
            description: "Three tabs now — General, Keys, and Layout. App launchers live right alongside your keybinds in one searchable list, and the Layout tab previews your gaps live as you drag."
        ),
        WhatsNewFeature(
            icon: "square.grid.2x2",
            title: "Tile Windows in the Scratchpad",
            description: "Summon the scratchpad and press Hypr + Shift + T to tile a floating window into a grid within the layer — then Shift + T again to pop it back to free-floating.",
            tint: .magenta
        ),
        WhatsNewFeature(
            icon: "hand.wave",
            title: "A Refreshed Welcome",
            description: "The first-run tour now teaches the Hypr key with a live \"try it\" prompt, and what's-new notes share the same window — all restyled to match the rest of the app."
        ),
    ]
}

enum WelcomeContent {
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
