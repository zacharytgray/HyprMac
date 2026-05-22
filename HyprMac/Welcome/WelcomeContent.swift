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
            icon: "viewfinder",
            title: "Focus Brackets",
            description: "Hold the Hypr key and rounded corner brackets snap inward around the focused window — a screenshot-tool-style visual cue showing which window your next action will target. The brackets match your window corner radius, use your focus color, and adapt their outline (white on dark colors, black on light) so they stay visible on any background. Shown always, regardless of whether the persistent focus border is on."
        ),
        WhatsNewFeature(
            icon: "moon.haze",
            title: "Smoother Dimming",
            description: "The dim overlay now runs as one layer per window instead of one shape per display. On every focus traversal, the window you're leaving fades in and the window you're entering fades out — in parallel — instead of the whole mask repainting at once. Window moves and resizes no longer cause the dim to flicker."
        ),
        WhatsNewFeature(
            icon: "timer",
            title: "Animation Duration Slider",
            description: "New control in Tiling settings to set how fast the focus border and dim overlay fade in and out. They animate in lockstep, so chrome always appears and disappears together. Drag it to 0 for instant, snap-cut chrome."
        ),
        WhatsNewFeature(
            icon: "rectangle.inset.filled.on.rectangle",
            title: "Quiet During Fullscreen",
            description: "Focus border, floating outlines, dim overlay, and brackets all auto-hide when a macOS native fullscreen window is frontmost — full-screen movies, Safari HTML5 fullscreen, Cmd-Ctrl-F apps. No more HyprMac chrome drawing over your content."
        ),
        WhatsNewFeature(
            icon: "rectangle.split.2x1",
            title: "Better Multi-Monitor FFM",
            description: "Focus-follows-mouse now works correctly on monitors stacked above the primary display. The dead-zone check at the top of each screen is anchored to that screen rather than to the primary, fixing a regression where FFM was effectively dead across the full height of a monitor positioned above your main one."
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
