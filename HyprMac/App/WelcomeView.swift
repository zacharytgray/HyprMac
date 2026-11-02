// Welcome window router and the NSWindow controller that hosts it.

import SwiftUI

/// Which Tour flow to render.
enum WelcomeMode {
    /// First-launch tutorial (7 pages).
    case firstRun
    /// Post-update / legacy "What's New" page.
    case whatsNew
}

/// Thin router: both modes render the single `TourView` shell.
struct WelcomeView: View {
    let mode: WelcomeMode
    let onDismiss: () -> Void

    var body: some View {
        TourView(mode: mode, onDismiss: onDismiss)
    }
}

// MARK: - Window management

/// NSWindow lifecycle for the welcome window. Titled with a transparent
/// titlebar and a draggable background; pinned above passive chrome so it stays
/// readable over tiled windows.
class WelcomeWindowController {
    private var window: NSWindow?

    func show(mode: WelcomeMode) {
        let view = WelcomeView(mode: mode) { [weak self] in
            self?.dismiss()
        }

        let hostingController = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hostingController)
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.title = mode == .firstRun ? "HyprMac Tutorial" : "What's New in HyprMac"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.level = Constants.interfaceWindowLevel
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
