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
    /// a button on the row, for a new setting that's off by default
    var action: WhatsNewAction? = nil
}

/// A row's button. Once `isDone`, the row shows `doneTitle` in its place,
/// and `doneDetail` under the description.
struct WhatsNewAction {
    let title: String
    let doneTitle: String
    let isDone: () -> Bool
    let perform: () -> Void
    var doneDetail: (() -> AnyView)? = nil
}

enum WhatsNewFeatures {
    // update this before each release — see docs/release.md
    static let current: [WhatsNewFeature] = [
        WhatsNewFeature(
            icon: "square.stack.3d.up",
            title: "Floating Windows Stay in Front",
            description: "Floating windows can now stay in front of your tiles, instead of slipping behind the window you're working in. Recommended. It needs Screen Recording, because macOS has no other way to do this, and HyprMac never saves the picture. Leave it off to keep the old behavior.",
            tint: .magenta,
            action: keepFloatersInFront()
        ),
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

extension WhatsNewFeatures {
    /// Turns on Keep floating windows in front. The switch asks macOS for
    /// Screen Recording as it goes on; the row then shows the grant.
    static func keepFloatersInFront(config: UserConfig = .shared,
                                    access: ScreenRecordingAccess = .shared) -> WhatsNewAction {
        WhatsNewAction(
            title: "Turn On",
            doneTitle: "On",
            isDone: { config.keepFloatingWindowsInFront },
            perform: {
                hyprLog(.notice, .lifecycle, "what's new: keep floating windows in front turned on")
                config.keepFloatingWindowsInFront = true
            },
            doneDetail: { AnyView(WhatsNewScreenRecordingStatus(access: access)) })
    }
}

enum WelcomeContent {
    static let productURL = URL(string: "https://hyprmac.app/")!

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
