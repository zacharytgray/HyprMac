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
            icon: "arrow.left.and.right",
            title: "Resize From the Gap",
            description: "Grab the gap between two tiles to resize them, the way macOS lets you grab just outside a window's edge.",
            credit: "dex157"
        ),
        WhatsNewFeature(
            icon: "circle.lefthalf.filled",
            title: "Cleaner Dim on Switch",
            description: "The old workspace's dim no longer fades over the new one's windows when you switch.",
            credit: "dex157"
        ),
        WhatsNewFeature(
            icon: "contextualmenu.and.cursorarrow",
            title: "Pop-Ups Stay Open",
            description: "Moving the pointer into an app's pop-up, like Outlook's color picker, no longer closes it.",
            credit: "kenmencher"
        ),
        WhatsNewFeature(
            icon: "macwindow.on.rectangle",
            title: "Floaters Come Back in Front",
            description: "Leave a workspace with a floating window focused, and it is focused and in front when you come back.",
            tint: .magenta
        ),
        WhatsNewFeature(
            icon: "arrow.up.left.and.arrow.down.right",
            title: "Full Screen Stays Put",
            description: "A switch no longer takes a busy app's window out of full screen."
        ),
    ]
}

enum WelcomeContent {
    static let productURL = URL(string: "https://hyprmac.app/")!

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
