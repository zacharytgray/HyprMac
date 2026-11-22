// Which of HyprMac's own panels are open right now, for hover focus. Holds
// the windows weakly and reads their live visibility, so a panel that
// closed without telling anyone can't leave hover focus switched off.

import AppKit
import SwiftUI

final class OwnPanelTracker {
    static let shared = OwnPanelTracker()

    private final class WeakWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }
    private var windows: [WeakWindow] = []

    /// Track `window` from now on. Adding one twice is harmless.
    func track(_ window: NSWindow) {
        windows.removeAll { $0.window == nil || $0.window === window }
        windows.append(WeakWindow(window))
    }

    var isAnyOpen: Bool {
        windows.contains { $0.window?.isVisible == true }
    }
}

/// Hands the hosting window of a SwiftUI view to `found`, once it has one.
struct HostingWindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.found = found
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var found: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { found?(window) }
        }
    }
}
