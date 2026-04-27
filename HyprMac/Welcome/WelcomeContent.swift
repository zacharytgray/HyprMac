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
            icon: "arrow.uturn.backward.circle",
            title: "Reopened Windows Land on the Right Workspace",
            description: "Apps that recycle window IDs across close-and-reopen (Teams, Mail, Music) no longer come back bound to the workspace they were closed on — the window now drifts to whatever workspace it actually opened on and tiles correctly."
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
