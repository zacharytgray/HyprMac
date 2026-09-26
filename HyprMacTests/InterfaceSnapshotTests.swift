import XCTest
import SwiftUI
import Carbon
@testable import HyprMac

// renders the settings, tour, gate and menu views offscreen into 2x pngs.
// opt-in: set HYPRMAC_RENDER_UI to an output directory. needs the isolated
// home from scripts/test-isolated.sh because it flips the saved hypr key.
@MainActor
final class InterfaceSnapshotTests: XCTestCase {
    private var outputDir: URL!
    private var savedHyprKey: HyprKey!
    private var savedKeybinds: [Keybind] = []

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["HYPRMAC_RENDER_UI"], !dir.isEmpty else {
            throw XCTSkip("set HYPRMAC_RENDER_UI to an output directory to render ui snapshots")
        }
        guard env["HYPRMAC_HEADLESS_TESTS"] == "1" else {
            throw XCTSkip("requires isolated config")
        }
        outputDir = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        savedHyprKey = UserConfig.shared.hyprKey
        savedKeybinds = UserConfig.shared.keybinds
        UserConfig.shared.keybinds = Keybind.defaults
    }

    override func tearDown() async throws {
        guard outputDir != nil else { return }
        UserConfig.shared.hyprKey = savedHyprKey
        UserConfig.shared.keybinds = savedKeybinds
    }

    func testRenderSettingsTabs() throws {
        UserConfig.shared.hyprKey = .capsLock
        try render("keys-capslock-dark", tab(KeybindsSettingsView()))
        try render("keys-capslock-light", tab(KeybindsSettingsView()), dark: false)
        try render("general-dark", tab(GeneralSettingsView(showTutorial: {})))
        try render("layout-dark", tab(TilingSettingsView()))
        try render("settings-window-dark", SettingsView(showTutorial: {}), size: CGSize(width: 760, height: 600))

        UserConfig.shared.hyprKey = .tab
        try render("keys-tab-dark", tab(KeybindsSettingsView()))

        // tab above and these two are no longer offered: the note shows, plus
        // Modifier Keys guidance where the pane can remap the key
        UserConfig.shared.hyprKey = .rightShift
        try render("keys-rightshift-dark", tab(KeybindsSettingsView()))
        UserConfig.shared.hyprKey = .leftControl
        try render("keys-leftcontrol-dark", tab(KeybindsSettingsView()))

        // left-hand modifier: the use-the-right-key note plus guidance
        UserConfig.shared.hyprKey = .leftCommand
        try render("keys-leftcommand-dark", tab(KeybindsSettingsView()))
    }

    func testRenderTourGateAndMenu() throws {
        UserConfig.shared.hyprKey = .capsLock
        try render("tour-hypr-key-dark", TourView(mode: .firstRun, onDismiss: {}),
                   size: CGSize(width: 520, height: 440))
        try render("tour-hypr-key-light", TourView(mode: .firstRun, onDismiss: {}),
                   size: CGSize(width: 520, height: 440), dark: false)
        try render("whats-new-dark", TourView(mode: .whatsNew, onDismiss: {}),
                   size: CGSize(width: 520, height: 440))
        try render("permissions-gate-dark",
                   PermissionsGateView(model: PermissionsGateModel(), onQuit: {}),
                   size: CGSize(width: 520, height: 530))
        // the release variant builds the menu with a sparkle updater; the
        // debug variant has none, so only render it there
        #if HYPRMAC_DEBUG_VARIANT
        try render("menu-bar-dark", MenuBarView(appDelegate: AppDelegate()), width: 320)
        #endif

        UserConfig.shared.hyprKey = .tab
        try render("tour-tab-dark", TourView(mode: .firstRun, onDismiss: {}),
                   size: CGSize(width: 520, height: 440))
    }

    func testRenderKeybindChips() throws {
        UserConfig.shared.hyprKey = .capsLock
        let binds = [
            Keybind(keyCode: UInt16(kVK_ANSI_K), modifiers: .hypr, action: .showKeybinds),
            Keybind(keyCode: UInt16(kVK_LeftArrow), modifiers: [.hypr, .shift], action: .swapDirection(.left)),
            Keybind(keyCode: UInt16(kVK_ANSI_T), modifiers: [.hypr, .control, .option, .shift, .command],
                    action: .toggleFloating),
            Keybind(keyCode: UInt16(kVK_ANSI_Q), modifiers: [.command, .shift], action: .closeWindow),
        ]
        let rows = VStack(alignment: .trailing, spacing: 8) {
            ForEach(Array(binds.enumerated()), id: \.offset) { _, bind in
                HStack {
                    Text(bind.actionDescription).font(.hyprBody)
                    Spacer()
                    KeybadgeView(bind: bind)
                }
            }
        }
        .padding(16)
        .background(Color.hyprBackground)
        try render("keybind-chips-dark", rows, width: 420)

        let editor = KeybindEditorSheet(existingBind: binds[1]) { _ in }
            .background(Color.hyprBackground)
        try render("keybind-editor-dark", editor, width: 480)
    }

    // MARK: helpers

    // mimics the settings detail pane: 568pt wide with 24pt side padding
    private func tab<V: View>(_ content: V) -> some View {
        VStack(spacing: HyprSpacing.lg) { content }
            .padding(.horizontal, HyprSpacing.xl)
            .padding(.vertical, HyprSpacing.lg)
            .frame(width: 568)
            .background(Color.hyprBackground)
    }

    private func render<V: View>(_ name: String, _ view: V, width: CGFloat = 568, dark: Bool = true) throws {
        try render(name, view, size: CGSize(width: width, height: 0), dark: dark)
    }

    private func render<V: View>(_ name: String, _ view: V, size: CGSize, dark: Bool = true) throws {
        let fixedHeight = size.height > 0
        let root = AnyView(fixedHeight
            ? AnyView(view.frame(width: size.width, height: size.height))
            : AnyView(view.frame(width: size.width).fixedSize(horizontal: false, vertical: true)))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: max(size.height, 100)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }

        host.frame = NSRect(x: 0, y: 0, width: size.width, height: max(size.height, 100))
        host.layoutSubtreeIfNeeded()
        // let onAppear, state and short animations settle
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        if !fixedHeight {
            let height = ceil(host.fittingSize.height)
            window.setContentSize(NSSize(width: size.width, height: height))
            host.frame = NSRect(x: 0, y: 0, width: size.width, height: height)
        }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.display()

        let bounds = host.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: outputDir.appendingPathComponent("\(name).png"))
    }
}
