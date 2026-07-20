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
            icon: "lock.shield",
            title: "A Friendlier Permissions Setup",
            description: "Granting Accessibility on first launch now happens in a clean, non-blocking window that tracks your permission status live — HyprMac starts the moment you grant access, with no alert to dismiss and no relaunch needed.",
            tint: .cyan
        ),
    ]
}

enum WelcomeContent {
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
