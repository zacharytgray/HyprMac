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
            icon: "keyboard",
            title: "Caps Lock After Sleep",
            description: "Caps Lock works as the Hypr key again after a wake, and on keyboards you plug in.",
            credit: "omeraloni"
        ),
        WhatsNewFeature(
            icon: "arrow.up.left.and.arrow.down.right",
            title: "Full Screen Sticks",
            description: "Native full screen holds the first time, and HyprMac leaves full-screen windows alone.",
            credit: "rangelkoli"
        ),
        WhatsNewFeature(
            icon: "macwindow.on.rectangle",
            title: "Outlines Follow Floaters",
            description: "A floating window's outline stays on it as it moves. A refused Hypr+T puts it back where it was.",
            tint: .magenta
        ),
        WhatsNewFeature(
            icon: "rectangle.split.2x1",
            title: "Shake on Refused Layout Keys",
            description: "When togglesplit, a resize or a swap can't fit a window, that window shakes.",
            credit: "dex157"
        ),
        WhatsNewFeature(
            icon: "photo",
            title: "No Wallpaper Flash",
            description: "Switching between workspaces with windows no longer flashes the desktop.",
            credit: "emilnymann"
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
