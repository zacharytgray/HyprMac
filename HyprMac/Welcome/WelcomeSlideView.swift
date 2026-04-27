// Post-install / upgrade welcome slideshow.

import SwiftUI

/// Four-page welcome slideshow with headline features.
struct WelcomeSlideView: View {
    let onDismiss: () -> Void

    @State private var currentPage = 0
    private let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            // header
            VStack(spacing: 6) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 56, height: 56)
                }
                Text("Welcome to HyprMac")
                    .font(.system(size: 22, weight: .bold))
                Text("v\(WelcomeContent.appVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 24)
            .padding(.bottom, 12)

            // page content — manual swap, no TabView
            Group {
                switch currentPage {
                case 0: tilingPage
                case 1: workspacesPage
                case 2: shortcutsPage
                case 3: mousePage
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .id(currentPage)

            PaginationView(
                currentPage: $currentPage,
                totalPages: pageCount,
                showSkip: false,
                nextLabel: "Next",
                finishLabel: "Get Started",
                onFinish: onDismiss,
                onSkip: {}
            )
        }
    }

    // MARK: - pages

    private var tilingPage: some View {
        FeaturePage(
            icon: "rectangle.split.2x2.fill",
            title: "Automatic Tiling",
            description: "Windows tile automatically as you open them. BSP dwindle layout — full, half, quarter splits.",
            detail: "Smart insertion picks the best split point. Apps with large minimum sizes get extra room."
        )
    }

    private var workspacesPage: some View {
        FeaturePage(
            icon: "square.stack.3d.up.fill",
            title: "Virtual Workspaces",
            description: "9 workspaces per monitor. Switch instantly with no animation. Each workspace remembers its monitor.",
            detail: "Independent of macOS Spaces — use one Space per monitor and let HyprMac handle the rest."
        )
    }

    private var shortcutsPage: some View {
        VStack(spacing: 8) {
            Text("Essential Shortcuts")
                .font(.system(size: 15, weight: .semibold))

            Text("Caps Lock is your Hypr key")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Grid(alignment: .leading, verticalSpacing: 3) {
                ForEach(WelcomeContent.essentialKeybinds, id: \.key) { kb in
                    GridRow {
                        Text(kb.key)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.primary)
                        Text(kb.desc)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 24)

            Text("Press Hypr+K anytime to see all shortcuts")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.accentColor)
                .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }

    private var mousePage: some View {
        FeaturePage(
            icon: "cursorarrow.motionlines",
            title: "Mouse Features",
            description: "Focus follows mouse — hover over a tiled window to focus it. Drag a window onto another to swap positions.",
            detail: "Hypr+F cycles through and raises floating windows."
        )
    }
}
