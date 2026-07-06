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
            icon: "tray.full",
            title: "Scratchpad for Floating Windows",
            description: "Hypr + S summons a scratchpad — a layer of floating windows over a dimmed backdrop, with no tiling rules. Send the focused window there with Hypr + Shift + S, click anywhere else to dismiss, and Hypr + Shift + T pulls a window back into tiling. Perfect for a drop-down terminal, music, or chat you want on hand but out of the way."
        ),
        WhatsNewFeature(
            icon: "moon.zzz",
            title: "Survives Sleep & Wake",
            description: "Waking your Mac from sleep no longer rearranges windows across your monitors. Discovery pauses through the wake, transient display configurations are ignored until things settle, and stray windows re-park themselves instead of piling onto your layout."
        ),
        WhatsNewFeature(
            icon: "rectangle.3.group",
            title: "Layouts Stay Put",
            description: "Closing, hiding, or minimizing a window no longer reshuffles everything around it — the neighbor simply grows into the space, and your split directions and sizes are kept. Rebuilds are now deterministic, so the tree stops decomposing in the wrong order."
        ),
        WhatsNewFeature(
            icon: "rectangle.badge.checkmark",
            title: "Windows Open Where Expected",
            description: "New and reopened windows land on the right screen instead of teleporting to another monitor. Apps that recycle window IDs (Teams, Mail) come back to where they belong, and a window crammed across a monitor edge no longer bounces to its neighbor."
        ),
        WhatsNewFeature(
            icon: "menubar.rectangle",
            title: "Scratchpad in the Menu Bar",
            description: "A tray glyph in the menu bar shows how many windows are stashed in the scratchpad — filled while the layer is open, with a count when it holds more than one."
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
