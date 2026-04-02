import SwiftUI

// dual-purpose: first-launch welcome slideshow + post-update "what's new"
enum WelcomeMode {
    case welcome
    case whatsNew
}

struct WelcomeView: View {
    let mode: WelcomeMode
    let onDismiss: () -> Void

    @State private var currentPage = 0
    private let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .welcome:
                welcomeContent
            case .whatsNew:
                whatsNewContent
            }
        }
        .frame(width: 520, height: 440)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
        )
    }

    // MARK: - Welcome slideshow

    private var welcomeContent: some View {
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
                Text("v\(appVersion)")
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

            // dots + button
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { i in
                        Circle()
                            .fill(i == currentPage ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { currentPage = i } }
                    }
                }

                Spacer()

                if currentPage < pageCount - 1 {
                    Button("Next") {
                        withAnimation(.easeInOut(duration: 0.2)) { currentPage += 1 }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Get Started") { onDismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 20)
            .padding(.top, 8)
        }
    }

    // MARK: - Slideshow pages

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
                ForEach(essentialKeybinds, id: \.key) { kb in
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

    // MARK: - What's new

    private var whatsNewContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("What's New in HyprMac")
                    .font(.system(size: 22, weight: .bold))
                Text("v\(appVersion)")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 28)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(WhatsNewFeatures.current, id: \.title) { feature in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: feature.icon)
                                .font(.system(size: 14))
                                .foregroundColor(.accentColor)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.title)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(feature.description)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 32)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Continue") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var essentialKeybinds: [(key: String, desc: String)] {
        [
            ("Hypr + Arrow", "Focus window in direction"),
            ("Hypr + Shift + Arrow", "Swap window in direction"),
            ("Hypr + 1-9", "Switch workspace"),
            ("Hypr + Shift + 1-9", "Move window to workspace"),
            ("Hypr + Shift + T", "Toggle floating"),
            ("Hypr + J", "Toggle split direction"),
            ("Hypr + F", "Cycle floating windows"),
            ("Hypr + K", "Show keybind overlay"),
        ]
    }
}

// single feature page for the slideshow
private struct FeaturePage: View {
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

// nsvisualeffectview wrapper for vibrancy
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

// MARK: - What's new feature list
// agents: update this array before each release with features from git log

struct WhatsNewFeature {
    let icon: String
    let title: String
    let description: String
}

struct WhatsNewFeatures {
    // update this before each release — see CLAUDE.md instructions
    static let current: [WhatsNewFeature] = [
        WhatsNewFeature(
            icon: "square.grid.3x3.square",
            title: "Workspace Spillover",
            description: "Windows automatically spill into the next workspace when a monitor fills up, instead of floating."
        ),
        WhatsNewFeature(
            icon: "ladybug",
            title: "Startup Tiling Fix",
            description: "Fixed a race condition where windows would incorrectly float on startup instead of being distributed across workspaces."
        ),
    ]
}

// MARK: - Window management

class WelcomeWindowController {
    private var window: NSWindow?

    func show(mode: WelcomeMode) {
        let view = WelcomeView(mode: mode) { [weak self] in
            self?.dismiss()
        }

        let hostingController = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hostingController)
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.level = .floating
        win.center()
        win.setContentSize(NSSize(width: 520, height: 440))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win
    }

    func dismiss() {
        window?.close()
        window = nil
    }
}
