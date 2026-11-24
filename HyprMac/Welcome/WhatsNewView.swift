// The What's New window an update shows once: the version, this release's
// rows from WhatsNewFeatures, and Continue.

import SwiftUI

struct WhatsNewView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            WhatsNewPage()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Spacer()
                CyanButton("Continue") { onDismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 520, height: 440)
        .background(Color.hyprBackground)
    }

    private var header: some View {
        HStack {
            HyprLockup(markSize: 20)
            Spacer()
            // cyan version chip
            Text(WelcomeContent.appVersion)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.hyprCyan)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                        .fill(Color.hyprCyan.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                        .strokeBorder(Color.hyprCyan.opacity(0.3), lineWidth: 1)
                )
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }
}

private struct CyanButton: View {
    let label: String
    let action: () -> Void
    init(_ label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color(red: 0x0b/255, green: 0x14/255, blue: 0x17/255))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                        .fill(Color.hyprCyan)
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }
}

private struct WhatsNewPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What's new")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.hyprTextPrimary)
                .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(WhatsNewFeatures.current, id: \.title) { feature in
                        changelogRow(feature)
                    }
                    Link("Explore HyprMac", destination: WelcomeContent.productURL)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.hyprCyan)
                        .padding(.top, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 24)
        .padding(.top, 18)
    }

    private func changelogRow(_ feature: WhatsNewFeature) -> some View {
        let tint: Color = feature.tint == .magenta ? .hyprMagenta : .hyprCyan
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: feature.icon)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(tint.opacity(0.3), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(feature.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.hyprTextPrimary)
                Text(feature.description)
                    .font(.system(size: 11))
                    .lineSpacing(3)
                    .foregroundStyle(Color.hyprTextPrimary.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                if let credit = feature.credit {
                    Text("Contributed by \(credit)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(tint.opacity(0.85))
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.hyprSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.hyprTextPrimary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - window

/// Titled with a transparent titlebar and a draggable background; pinned
/// above passive chrome so it stays readable over tiled windows.
final class WhatsNewWindowController {
    private var window: NSWindow?

    func show() {
        let view = WhatsNewView { [weak self] in self?.dismiss() }
        let win = NSWindow(contentViewController: NSHostingController(rootView: view))
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.title = "What's New in HyprMac"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.level = Constants.interfaceWindowLevel
        win.center()
        win.setContentSize(NSSize(width: 520, height: 440))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    func dismiss() {
        window?.close()
        window = nil
    }
}
