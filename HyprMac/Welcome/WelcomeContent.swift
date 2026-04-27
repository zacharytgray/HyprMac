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
            icon: "rectangle.2.swap",
            title: "Smarter Swap Rejection",
            description: "Same-screen and cross-monitor swaps that would crush a window below its minimum size are now rejected with a flash and beep instead of producing a broken layout."
        ),
        WhatsNewFeature(
            icon: "cursorarrow.rays",
            title: "Sturdier Hover Focus",
            description: "Hover focus now hit-tests against the actual visible window region, so floating overlays and edge tiles no longer steal focus from the window underneath your cursor."
        ),
        WhatsNewFeature(
            icon: "square.dashed",
            title: "Cleaner Focus Borders",
            description: "Focus borders and dim overlays redraw against live tile rects and clip to the visible region, eliminating stale outlines after animations and z-order changes."
        ),
        WhatsNewFeature(
            icon: "wand.and.rays",
            title: "Animation Polish",
            description: "Window shadows now keep up with animated tiling, and click-triggered BSP corruption during quick focus switches has been fixed."
        ),
        WhatsNewFeature(
            icon: "checklist",
            title: "Release Test Gate",
            description: "Every release build now runs the full XCTest suite before signing and notarization, catching regressions before they ship."
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
