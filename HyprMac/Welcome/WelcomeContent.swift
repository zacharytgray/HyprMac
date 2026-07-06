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
            icon: "tray.full",
            title: "Scratchpad for Floating Windows",
            description: "Hypr + S summons a scratchpad — a layer of floating windows over a dimmed backdrop, with no tiling rules. Send the focused window there with Hypr + Shift + S, click anywhere else to dismiss, and Hypr + Shift + S again pulls a window back into tiling. Perfect for a drop-down terminal, music, or chat you want on hand but out of the way.",
            tint: .magenta
        ),
        WhatsNewFeature(
            icon: "moon.zzz",
            title: "Survives Sleep & Wake",
            description: "Waking your Mac from sleep no longer rearranges windows across your monitors. Discovery pauses through the wake, transient display configurations are ignored until things settle, and stray windows re-park themselves instead of piling onto your layout."
        ),
        WhatsNewFeature(
            icon: "rectangle.3.group",
            title: "Layouts Stay Put",
            description: "Closing, hiding, or minimizing a window no longer reshuffles everything around it — the neighbor simply grows into the space, and your split directions and sizes are kept. Rebuilds are now deterministic, so the tree stops decomposing in the wrong order."
        ),
        WhatsNewFeature(
            icon: "rectangle.badge.checkmark",
            title: "Windows Open Where Expected",
            description: "New and reopened windows land on the right screen instead of teleporting to another monitor. Apps that recycle window IDs (Teams, Mail) come back to where they belong, and a window crammed across a monitor edge no longer bounces to its neighbor."
        ),
        WhatsNewFeature(
            icon: "menubar.rectangle",
            title: "Scratchpad in the Menu Bar",
            description: "A tray glyph in the menu bar shows how many windows are stashed in the scratchpad — filled while the layer is open, with a count when it holds more than one.",
            tint: .magenta
        ),
    ]
}

enum WelcomeContent {
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
