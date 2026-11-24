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
            icon: "graduationcap",
            title: "New Tutorial",
            description: "Seven short lessons, about 5 minutes, on practice windows, so yours aren't touched. Open it from the menu bar, Hypr+K or Settings → General."
        ),
        WhatsNewFeature(
            icon: "gearshape",
            title: "New Settings",
            description: "Eight sections with search: General, Keys, Tiling, Workspaces, Monitors, Mouse, Appearance and Advanced."
        ),
        WhatsNewFeature(
            icon: "hand.draw",
            title: "Drag to Grant Access",
            description: "Grant Accessibility by dragging HyprMac into the list that opens. No hunting for the app.",
            credit: "dex157"
        ),
        WhatsNewFeature(
            icon: "arrow.counterclockwise",
            title: "Resets That Ask First",
            description: "Each section has its own reset. Every reset asks first, keeps a copy of your settings and matches a new install."
        ),
        WhatsNewFeature(
            icon: "pause.circle",
            title: "Resume Keeps Windows",
            description: "Resuming from Pause keeps every window where it was, even with a full-screen video in front."
        ),
    ]
}

enum WelcomeContent {
    static let productURL = URL(string: "https://hyprmac.app/")!

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
