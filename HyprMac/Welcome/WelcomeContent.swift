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
            icon: "slider.horizontal.3",
            title: "Float and Tile Rules",
            description: "Always float or tile an app, or one kind of window. Press Hypr+I on a window to pick a rule.",
            tint: .magenta,
            credit: "tioan"
        ),
        WhatsNewFeature(
            icon: "cursorarrow.click",
            title: "Hypr+T Beats Rules",
            description: "Floating or tiling one window by hand now works even when a rule covers it. Retile All still tiles one you floated.",
            tint: .magenta
        ),
        WhatsNewFeature(
            icon: "display.2",
            title: "Workspace Homes per Display Setup",
            description: "Each set of connected displays keeps its own workspace-to-monitor mapping in Settings → Layout.",
            credit: "tioan"
        ),
        WhatsNewFeature(
            icon: "menubar.rectangle",
            title: "Workspace Names in Compact",
            description: "The Compact menu bar shows the workspace's name. A one-letter name goes in the badge.",
            credit: "dex157"
        ),
        WhatsNewFeature(
            icon: "keyboard",
            title: "F13–F20 and Backslash as Hypr",
            description: "Hypr chords work again with a function key or backslash as the Hypr key.",
            credit: "mikaraunio"
        ),
        WhatsNewFeature(
            icon: "arrow.down.circle",
            title: "Updates in the Settings Sidebar",
            description: "Check for updates, or restart to install one, from the bottom of the Settings sidebar."
        ),
        WhatsNewFeature(
            icon: "shippingbox",
            title: "Updates by a Package Manager",
            description: "A defaults key turns off the in-app updater when Homebrew or another tool updates HyprMac.",
            credit: "tioan"
        ),
        WhatsNewFeature(
            icon: "eye",
            title: "Windows Stay Visible",
            description: "A window no longer goes hidden for a minute when its app is slow to answer after it recovers.",
            credit: "tioan"
        ),
        WhatsNewFeature(
            icon: "scope",
            title: "Steadier Focus",
            description: "Hover focus pauses over HyprMac's menu, and windows that report a stale position get their border and clicks in the right place."
        ),
    ]
}

enum WelcomeContent {
    static let productURL = URL(string: "https://hyprmac.app/")!

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// The tour's pause line. Paused, a Hypr key that goes back to typing
    /// (Caps Lock, Tab, backtick, backslash) can't press the shortcut again.
    static func pauseInstruction(chord: String, hyprKey: HyprKey) -> String {
        let pause = "If things get in your way, press \(chord) to pause tiling."
        guard hyprKey.keepsShortcutsWhilePaused else {
            return pause + " \(hyprKey.displayName) is a normal key again while paused, so resume from the menu bar."
        }
        return pause + " Press it again when you’re ready."
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
