// Data tables and reusable building blocks for the Welcome window.
// `FeaturePage` lives here because it is shared by onboarding and
// the welcome slideshow.

import SwiftUI

// MARK: - what's new feature list
// Update this array before each release with features from git log;
// see CLAUDE.md "Release Feature List" for the workflow.

/// One row in the "What's New" panel: icon, title, description.
struct WhatsNewFeature {
    let icon: String
    let title: String
    let description: String
}

enum WhatsNewFeatures {
    // update this before each release — see CLAUDE.md instructions
    static let current: [WhatsNewFeature] = [
        WhatsNewFeature(
            icon: "display.2",
            title: "Stable Across Monitor Changes",
            description: "Plugging in or unplugging a display no longer scrambles your layout. Workspace assignments and floating windows are preserved across monitor changes — your trees migrate to each workspace's home screen instead of being redistributed from scratch."
        ),
        WhatsNewFeature(
            icon: "rectangle.2.swap",
            title: "Send Windows Between Monitors",
            description: "Hypr + Ctrl + Left/Right now throws the focused window to the next monitor, landing on whatever workspace is showing there. (Workspaces are pinned to their monitors, so this replaces the old move-workspace shortcut that could no longer do anything.)"
        ),
        WhatsNewFeature(
            icon: "macwindow.on.rectangle",
            title: "Reliable Window Moves",
            description: "Sending a window to another workspace now places it correctly every time — floating windows that used to get stranded in the corner are carried to the right screen, and focus follows the move."
        ),
        WhatsNewFeature(
            icon: "checkmark.shield",
            title: "Smoother First Launch",
            description: "HyprMac now starts the instant you grant Accessibility access — no relaunch, no dead-end retry button. The permission screen also explains the duplicate-entry cleanup that trips people up after an update."
        ),
    ]
}

// MARK: - essential shortcuts shown on the welcome slideshow

enum WelcomeContent {
    static let essentialKeybinds: [(key: String, desc: String)] = [
        ("Hypr + Arrow",         "Focus window in direction"),
        ("Hypr + Shift + Arrow", "Swap window in direction"),
        ("Hypr + 1-9",           "Switch workspace"),
        ("Hypr + Shift + 1-9",   "Move window to workspace"),
        ("Hypr + Shift + T",     "Toggle floating"),
        ("Hypr + J",             "Toggle split direction"),
        ("Hypr + F",             "Cycle floating windows"),
        ("Hypr + K",             "Show keybind overlay"),
    ]

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}

// MARK: - shared single feature page (icon + title + description + detail)

struct FeaturePage: View {
    let icon: String
    let title: String
    let description: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(.accentColor)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(description)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - vibrancy wrapper

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
