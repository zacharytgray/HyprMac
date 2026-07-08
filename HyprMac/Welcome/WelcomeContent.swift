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
            icon: "bolt",
            title: "Your Keyboard Never Waits",
            description: "Hotkey handling moved to its own dedicated thread, so typing anywhere on your Mac stays instant even while HyprMac is mid-retile or talking to a busy app. The system-wide input lag is gone.",
            tint: .cyan
        ),
        WhatsNewFeature(
            icon: "dot.radiowaves.left.and.right",
            title: "Event-Driven Window Detection",
            description: "Apps now tell HyprMac the moment a window opens, closes, or minimizes — replacing the once-per-second desktop sweep. New windows tile faster, and every other app on your Mac feels smoother with the constant background polling gone.",
            tint: .cyan
        ),
        WhatsNewFeature(
            icon: "hare",
            title: "Immune to Busy Apps",
            description: "A frozen or hard-working app (a compiling IDE, a hung Electron window) can no longer stall HyprMac — window queries are now strictly time-capped, matching how yabai and AeroSpace handle it.",
            tint: .cyan
        ),
    ]
}

enum WelcomeContent {
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
