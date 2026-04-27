import Cocoa
import SwiftUI

// manages the keybind overlay HUD panel
class KeybindOverlayController {

    private var panel: NSPanel?

    var isShowing: Bool { panel != nil }

    func toggle(keybinds: [Keybind]) {
        mainThreadOnly()
        if let panel = panel {
            panel.close()
            self.panel = nil
            return
        }
        show(keybinds: keybinds)
    }

    func close() {
        mainThreadOnly()
        panel?.close()
        panel = nil
    }

    private func show(keybinds: [Keybind]) {
        guard let screen = NSScreen.main else { return }

        let panelWidth: CGFloat = 480
        let panelHeight: CGFloat = min(560, screen.visibleFrame.height * 0.75)
        let panelX = screen.frame.midX - panelWidth / 2
        let panelY = screen.frame.midY - panelHeight / 2

        let p = NSPanel(
            contentRect: NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered, defer: false)
        p.title = "HyprMac Keybinds"
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false

        let view = NSHostingView(rootView: KeybindOverlayView(keybinds: keybinds))
        view.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight - 28)
        view.autoresizingMask = [.width, .height]
        p.contentView = view

        p.makeKeyAndOrderFront(nil)
        self.panel = p
    }
}

// MARK: - overlay SwiftUI view

private struct KeybindOverlayView: View {
    let keybinds: [Keybind]

    private var grouped: [(category: KeybindCategory, binds: [Keybind])] {
        let pairs = keybinds.map { ($0, KeybindCategory.from($0.action)) }
        return KeybindCategory.allCases.compactMap { cat in
            let binds = pairs.filter { $0.1 == cat }.map(\.0)
            return binds.isEmpty ? nil : (cat, binds)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(grouped, id: \.category) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.category.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.leading, 4)

                        VStack(spacing: 1) {
                            ForEach(group.binds) { bind in
                                HStack(spacing: 10) {
                                    Image(systemName: bind.actionIcon)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)

                                    Text(bind.actionDescription)
                                        .font(.system(size: 13))
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    KeybadgeView(bind: bind)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                        )
                    }
                }
            }
            .padding(16)
        }
    }

}
