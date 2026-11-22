// A one-time offer after HyprMac tried to tile a new window, kept failing,
// and left it floating: "<App> window couldn't tile. Always float windows
// like this?" Once per app, per Mac. HyprMac's own HUD, not a system
// notification, so it needs no permission and never takes focus.

import AppKit
import SwiftUI

/// Whether to offer the prompt, and the per-Mac record of apps asked.
/// Internal state in UserDefaults, not a setting.
struct FailedTilePromptPolicy {
    static let defaultsKey = "FailedTilePromptedApps"
    let defaults: UserDefaults

    /// Only for a window still floating after the failed tile, that no rule
    /// covers and the user hasn't floated or tiled by hand, of an app not
    /// asked before.
    func shouldPrompt(bundleID: String?, isFloating: Bool, coveredByRule: Bool,
                      hasManualChoice: Bool) -> Bool {
        guard let bundleID, !bundleID.isEmpty, isFloating, !coveredByRule, !hasManualChoice else { return false }
        return !asked.contains(bundleID)
    }

    func markAsked(_ bundleID: String) {
        defaults.set(Array(asked.union([bundleID])).sorted(), forKey: Self.defaultsKey)
    }

    private var asked: Set<String> {
        Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }
}

/// The prompt's panel. Clicks work without activating HyprMac; it hides on
/// its own after `lifetime`.
final class FailedTilePromptController {
    /// "Choose…": the window rules overlay on that window
    var chooseRules: (CGWindowID) -> Void = { _ in }
    var lifetime: TimeInterval = 10

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    var isShowing: Bool { panel != nil }

    /// Show it near `frame` (CG coordinates), over the top of the window.
    func show(windowID: CGWindowID, appName: String, frame: CGRect?) {
        mainThreadOnly()
        close()
        let view = FailedTilePromptView(appName: appName, choose: { [weak self] in
            self?.close()
            self?.chooseRules(windowID)
        }, dismiss: { [weak self] in
            self?.close()
        })
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let rect = Self.placement(size: size, over: frame)
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isFloatingPanel = true
        p.level = Constants.interfaceWindowLevel
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        hosting.frame = NSRect(origin: .zero, size: rect.size)
        p.contentView = hosting
        p.orderFrontRegardless()
        panel = p
        let work = DispatchWorkItem { [weak self] in self?.close() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime, execute: work)
        hyprLog(.notice, .floating, "failed-tile prompt: \(windowID) \(appName)")
    }

    func close() {
        hideWork?.cancel()
        hideWork = nil
        panel?.close()
        panel = nil
    }

    /// Centered on the window's top edge, a little inside, kept on its screen.
    static func placement(size: CGSize, over frame: CGRect?) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        guard let frame else {
            let visible = NSScreen.main?.visibleFrame ?? .zero
            return NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 40,
                          width: size.width, height: size.height)
        }
        let ns = NSRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        let visible = NSScreen.screens.first { $0.frame.contains(NSPoint(x: ns.midX, y: ns.midY)) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? ns
        var rect = NSRect(x: ns.midX - size.width / 2, y: ns.maxY - size.height - 24,
                          width: size.width, height: size.height)
        rect.origin.x = min(max(rect.minX, visible.minX), visible.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, visible.minY), visible.maxY - rect.height)
        return rect
    }
}

private struct FailedTilePromptView: View {
    let appName: String
    let choose: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: HyprSpacing.md) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.hyprCyan)
            Text("\(appName) window couldn't tile. Always float windows like this?")
                .font(.hyprBody)
                .foregroundStyle(Color.hyprTextPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260, alignment: .leading)
            Button("Choose…", action: choose).controlSize(.small)
            Button("Not now", action: dismiss).controlSize(.small)
        }
        .padding(HyprSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                .fill(Color.hyprBackground)
                .overlay(RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                    .stroke(Color.hyprSeparator, lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        )
    }
}
