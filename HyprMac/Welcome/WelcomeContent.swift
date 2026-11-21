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
            icon: "capslock",
            title: "Caps Lock While Paused",
            description: "With Caps Lock as the Hypr key, it works as a normal Caps Lock while HyprMac is paused. Resume from the menu bar.",
            credit: "md2perpe"
        ),
        WhatsNewFeature(
            icon: "hand.tap",
            title: "Double-Tap Hypr for Caps Lock",
            description: "A new option in Settings → Keys: tap the Hypr key twice quickly to turn Caps Lock on or off."
        ),
        WhatsNewFeature(
            icon: "menubar.rectangle",
            title: "Menu Bar: Full, Compact or Hidden",
            description: "Pick a menu bar style in Settings → General. Compact is one badge for the focused workspace."
        ),
        WhatsNewFeature(
            icon: "arrow.down.circle",
            title: "Smoother Updates",
            description: "The update window comes to the front. Updates install after 5 minutes idle, and your windows and workspaces come back after the relaunch."
        ),
        WhatsNewFeature(
            icon: "macwindow.on.rectangle",
            title: "Native Tabs Stay Put",
            description: "Switching native tabs in Terminal and other apps no longer retiles the workspace or swaps tiles.",
            credit: "xiphos991"
        ),
        WhatsNewFeature(
            icon: "circle",
            title: "Circles Mark Floating Windows",
            description: "Floating windows show as circles instead of diamonds in the menu bar, the keybind list and Settings.",
            tint: .magenta
        ),
        WhatsNewFeature(
            icon: "shippingbox",
            title: "Nix Flake and Home Manager",
            description: "HyprMac ships a flake and a Home Manager module that package the signed release.",
            credit: "emilnymann"
        ),
        WhatsNewFeature(
            icon: "scope",
            title: "Steadier Focus",
            description: "Focus no longer bounces between two apps, and an app that re-creates its window no longer blocks focus or drags."
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
