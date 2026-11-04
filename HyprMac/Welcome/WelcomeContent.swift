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
            icon: "arrow.up.left.and.arrow.down.right",
            title: "Maximize a Window",
            description: "Hypr+F now fills the screen with the focused window, and pressing it again puts the window back. The old move to an empty workspace is still in Settings → Keys."
        ),
        WhatsNewFeature(
            icon: "pin",
            title: "Pin Apps to the Scratchpad",
            description: "Pin an app to the scratchpad instead of a workspace, and its windows go there when they open.",
            tint: .magenta
        ),
        WhatsNewFeature(
            icon: "cursorarrow",
            title: "Keep the Cursor in Place",
            description: "A new setting in General leaves the cursor where it is when you switch workspaces."
        ),
        WhatsNewFeature(
            icon: "paintpalette",
            title: "Overlay Accent Color",
            description: "Pick the color of the workspace HUD, overview, keybind sheet and menu bar in Settings → Layout.",
            credit: "y0b1"
        ),
        WhatsNewFeature(
            icon: "macwindow",
            title: "Windows That Keep Their Own Size",
            description: "A window that can't fit its tile, like a Screen Sharing session, now floats instead of retrying. HyprMac remembers this across restarts.",
            tint: .magenta,
            credit: "zalewskigrzegorz"
        ),
        WhatsNewFeature(
            icon: "bolt",
            title: "Quicker Workspace Switching",
            description: "Quick presses of the workspace keys skip to where you're going instead of playing every step.",
            credit: "zalewskigrzegorz"
        ),
        WhatsNewFeature(
            icon: "macwindow.on.rectangle",
            title: "Floating Windows Stack the Same in Every App",
            description: "The focused window now sits above a floating window where they overlap, whichever app it is.",
            tint: .magenta
        ),
        WhatsNewFeature(
            icon: "rectangle.split.2x1",
            title: "Faster Gap Filling",
            description: "Closing a window now fills the gap right away, including in apps like Teams that reuse their windows."
        ),
        WhatsNewFeature(
            icon: "arrow.left.arrow.right",
            title: "Hypr Is the Drag Swap",
            description: "Holding Option during a tiled drag no longer swaps windows. Hold Hypr instead."
        ),
        WhatsNewFeature(
            icon: "checkmark.shield",
            title: "Safer Settings",
            description: "A settings file that can't be read is now kept instead of overwritten."
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
