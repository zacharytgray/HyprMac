// Welcome window router and the NSWindow controller that hosts it.

import SwiftUI

/// Which welcome flow to render.
enum WelcomeMode {
    /// First-launch onboarding tutorial.
    case onboarding
    /// Post-install / upgrade slideshow.
    case welcome
    /// Post-update "What's New" panel.
    case whatsNew
}

/// Thin router that dispatches to one of three mode views inside a
/// vibrancy-backed frame. Each mode owns its own pagination state.
struct WelcomeView: View {
    let mode: WelcomeMode
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .onboarding: OnboardingView(onDismiss: onDismiss)
            case .welcome:    WelcomeSlideView(onDismiss: onDismiss)
            case .whatsNew:   WhatsNewView(onDismiss: onDismiss)
            }
        }
        .frame(width: 520, height: 440)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
        )
    }
}

// MARK: - Window management

/// NSWindow lifecycle for the welcome window. Built borderless with
/// a draggable background; pinned to `.floating` level so it shows
/// above tiled windows.
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
