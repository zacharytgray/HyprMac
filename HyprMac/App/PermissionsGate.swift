// Launch permissions gate: the non-modal floating window shown when
// Accessibility is missing at startup.
//
// Accessibility is required — the app can't function without it, so the
// only exits are granting it (auto-close + live start) or Quit.

import SwiftUI

// MARK: - grant flow

/// Fire the system Accessibility prompt and open the deep link as a
/// fallback in case the prompt was dismissed. Also adds HyprMac to the
/// Accessibility list so the toggle is there to flip.
enum AccessibilityGrantFlow {
    static func promptThenOpen() {
        AccessibilityManager.promptForAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - permission row

/// One permission line: icon tile · name + requirement tag + live detail ·
/// granted check or Grant button. Styled on the tour's boxed-row language.
struct PermissionStatusRow: View {
    let icon: String
    let title: String
    let required: Bool
    let detail: String
    let granted: Bool
    let onGrant: () -> Void

    private var tint: Color { granted ? .hyprCyan : .hyprTextSecondary }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tint.opacity(0.3), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.hyprTextPrimary)
                    Text(required ? "REQUIRED" : "OPTIONAL")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(required ? Color.hyprCyan : Color.hyprTextTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill((required ? Color.hyprCyan : Color.hyprTextTertiary).opacity(0.12))
                        )
                }
                Text(detail)
                    .font(.system(size: 11))
                    .lineSpacing(2)
                    .foregroundStyle(Color.hyprTextPrimary.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if granted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                    Text("Granted")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(Color.hyprCyan)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.hyprCyan.opacity(0.1)))
                .overlay(Capsule().strokeBorder(Color.hyprCyan.opacity(0.5), lineWidth: 1))
            } else {
                Button("Grant", action: onGrant)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
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

// MARK: - modifier keys check row

/// The Modifier Keys reminder. Same tile language as `PermissionStatusRow`,
/// but it is a manual check: macOS gives us no way to read that setting, so
/// this never shows a granted state.
struct ModifierKeysCheckRow: View {
    let guidance: HyprKeySystemGuidance

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "keyboard")
                .font(.system(size: 14))
                .foregroundStyle(Color.hyprTextSecondary)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.hyprTextSecondary.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.hyprTextSecondary.opacity(0.3), lineWidth: 1)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Modifier Keys")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.hyprTextPrimary)
                    Text("CHECK")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(Color.hyprTextTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.hyprTextTertiary.opacity(0.12)))
                }
                Text("\(guidance.title) \(HyprKeySystemGuidance.cannotCheckNote)")
                    .font(.system(size: 11))
                    .lineSpacing(2)
                    .foregroundStyle(Color.hyprTextPrimary.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help(guidance.detail)

            Spacer(minLength: 8)

            Button("Open") { HyprKeySystemGuidance.openKeyboardSettings() }
                .controlSize(.small)
                .accessibilityLabel(HyprKeySystemGuidance.openButtonTitle)
        }
        .padding(12)
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

// MARK: - launch gate

/// Live permission state for the launch gate. Updated by the view's own
/// 1 Hz poll and stamped granted by the AppDelegate poll when AX lands.
final class PermissionsGateModel: ObservableObject {
    @Published var axGranted = AccessibilityManager.isAccessibilityEnabled()
    /// nil when the selected Hypr key can't be remapped in Modifier Keys
    @Published var modifierGuidance = HyprKeySystemGuidance.forKey(UserConfig.shared.hyprKey)

    func refresh() {
        axGranted = AccessibilityManager.isAccessibilityEnabled()
        modifierGuidance = HyprKeySystemGuidance.forKey(UserConfig.shared.hyprKey)
    }
}

/// Non-modal floating gate shown at launch when Accessibility is missing.
/// Accessibility must be granted (or the app quit) to leave. AppDelegate
/// owns the poll that live-starts and dismisses this once AX lands.
struct PermissionsGateView: View {
    @ObservedObject var model: PermissionsGateModel
    let onQuit: () -> Void

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 520, height: 530)
        .background(Color.hyprBackground)
        .onReceive(poll) { _ in model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    // MARK: header — lockup

    private var header: some View {
        HStack {
            HyprLockup(markSize: 20)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    // MARK: content

    private var content: some View {
        VStack(spacing: 0) {
            shieldGlyph
                .padding(.bottom, 16)

            Text("Grant access to get started")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.hyprTextPrimary)

            Text("HyprMac needs Accessibility to manage your windows. It starts automatically the moment access is granted — no relaunch needed.")
                .font(.system(size: 12.5))
                .lineSpacing(4)
                .foregroundStyle(Color.hyprTextPrimary.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .padding(.top, 8)

            PermissionStatusRow(
                icon: "accessibility",
                title: "Accessibility",
                required: true,
                detail: model.axGranted
                    ? "HyprMac can manage your windows."
                    : "HyprMac can't manage windows without it.",
                granted: model.axGranted,
                onGrant: { AccessibilityGrantFlow.promptThenOpen() }
            )
            .frame(maxWidth: 420)
            .padding(.top, 18)

            if let guidance = model.modifierGuidance {
                ModifierKeysCheckRow(guidance: guidance)
                    .frame(maxWidth: 420)
                    .padding(.top, 10)
            }

            // rebuilds/updates invalidate the grant; the stale-toggle caveat
            // is shown as a caption.
            Text("Toggle already on? Turn it off and back on — macOS invalidates the grant when the app is updated. Remove stale HyprMac entries with the − button.")
                .font(.system(size: 10.5))
                .lineSpacing(3)
                .foregroundStyle(Color.hyprTextPrimary.opacity(0.35))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .padding(.top, 14)
        }
        .padding(.horizontal, 40)
    }

    private var shieldGlyph: some View {
        Image(systemName: "lock.shield")
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(Color.hyprCyan)
            .frame(width: 52, height: 52)
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                    .fill(Color.hyprCyan.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                    .strokeBorder(Color.hyprCyan.opacity(0.3), lineWidth: 1)
            )
    }

    // MARK: footer — quit + status hint

    private var footer: some View {
        HStack {
            Button("Quit", action: onQuit)
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.hyprTextPrimary.opacity(0.4))

            Spacer()

            if !model.axGranted {
                Text("Accessibility is required to continue")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.hyprTextPrimary.opacity(0.35))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}

// MARK: - gate window controller

/// NSWindow lifecycle for the launch gate. Same recipe as the welcome
/// window minus a close button — the only exits are granting Accessibility
/// (auto-close) or Quit.
final class PermissionsGateWindowController {
    private var window: NSWindow?
    let model = PermissionsGateModel()

    func show(onQuit: @escaping () -> Void) {
        let view = PermissionsGateView(model: model, onQuit: onQuit)
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.titled, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.level = .floating
        win.center()
        win.setContentSize(NSSize(width: 520, height: 530))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    /// AX landed: reflect it, then close after a short beat so the check
    /// is visible before the window goes away.
    func markAccessibilityGrantedAndDismiss() {
        model.axGranted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.dismiss()
        }
    }

    func dismiss() {
        window?.close()
        window = nil
    }
}
