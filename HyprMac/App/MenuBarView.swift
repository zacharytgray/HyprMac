// Menu bar dropdown contents and workspace label.

import SwiftUI

/// `MenuBarExtra` dropdown contents: status header, per-monitor
/// workspace state, and standard actions (Settings, Retile, Check
/// for Updates, Quit). Restyled to match the settings window — same
/// surface treatment, mono accent typography, cyan active-state
/// indicator. The label rendered in the menu bar itself is
/// `WorkspaceIndicatorLabel` (below).
struct MenuBarView: View {
    let appDelegate: AppDelegate
    @ObservedObject var config = UserConfig.shared
    @ObservedObject private var menuBarState = MenuBarState.shared
    @ObservedObject private var updateState = UpdateState.shared
    @Environment(\.openWindow) private var openWindow
    #if !HYPRMAC_DEBUG_VARIANT
    @ObservedObject var updates: UpdateController
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: HyprSpacing.md) {
            header
            workspacePanel
            focusedWindowPanel
            actions
        }
        .padding(HyprSpacing.md)
        .frame(width: 320)
        .background(Color.hyprBackground)
        // hover focus pauses while this panel is open (OwnPanelTracker)
        .background(HostingWindowReader { OwnPanelTracker.shared.track($0) })
        .onAppear { appDelegate.windowManager?.refreshFocusedWindowRuleInfo() }
    }

    // MARK: focused window

    /// The window that had focus when the menu opened, and its rules. The
    /// rows act on that window, whatever hover does while the menu is up.
    /// Settings lists every rule.
    @ViewBuilder
    private var focusedWindowPanel: some View {
        if config.enabled, let info = menuBarState.focusedWindowRule {
            HyprPanel("Focused window: \(info.appName)") {
                VStack(spacing: 1) {
                    Text(info.currentRule ?? "No rule: HyprMac decides")
                        .font(.hyprMonoXs)
                        .foregroundStyle(Color.hyprTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, HyprSpacing.md)
                        .padding(.vertical, HyprSpacing.xs)
                    MenuBarRow("Edit rule for this window…", icon: "slider.horizontal.3") {
                        appDelegate.windowManager?.showWindowRules(for: info.windowID)
                    } trailing: {
                        if let binding = config.keybinds.first(where: { $0.action == .showWindowRules }) {
                            KeybadgeView(bind: binding, fontSize: 11)
                        }
                    }
                    if !info.appFloats {
                        MenuBarRow("Always float all \(info.appName) windows", icon: "rectangle.on.rectangle") {
                            appDelegate.windowManager?.floatingRuleCommands.setAppRule(info.windowID, action: .float)
                        }
                    }
                    if !info.appTiles {
                        MenuBarRow("Always tile all \(info.appName) windows", icon: "rectangle.split.2x1") {
                            appDelegate.windowManager?.floatingRuleCommands.setAppRule(info.windowID, action: .tile)
                        }
                    }
                    if info.currentRule != nil {
                        MenuBarRow("Forget rule for this window", icon: "xmark.circle") {
                            appDelegate.windowManager?.floatingRuleCommands.forget(info.windowID)
                        }
                    }
                }
                .padding(.vertical, HyprSpacing.xs)
            }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: HyprSpacing.sm) {
            VStack(alignment: .leading, spacing: 4) {
                HyprLockup(markSize: 18)
                Text(config.enabled ? "Tiling active" : "Tiling paused")
                    .font(.hyprMonoXs)
                    .foregroundStyle(config.enabled ? Color.overlayPrimary : Color.hyprTextTertiary)
            }
            Spacer(minLength: HyprSpacing.sm)
            Toggle("", isOn: $config.enabled)
                .toggleStyle(HyprToggleStyle())
                .labelsHidden()
        }
        .padding(.horizontal, HyprSpacing.xs)
    }

    // MARK: workspace panel

    @ViewBuilder
    private var workspacePanel: some View {
        if MenuBarPresentation.showsWorkspaceState(
            enabled: config.enabled,
            indicatorEnabled: true,
            hasData: menuBarState.hasData,
            monitors: menuBarState.monitors,
            scratchpadCount: menuBarState.scratchpadCount) {
            HyprPanel("Workspaces") {
                ForEach(menuBarState.monitors) { monitor in
                    monitorRow(monitor)
                }
                if menuBarState.scratchpadCount > 0 {
                    Rectangle()
                        .fill(Color.hyprSeparator)
                        .frame(height: 0.5)
                    HStack(spacing: 3) {
                        Image(systemName: "tray")
                            .font(.system(size: 10))
                        Text("\(menuBarState.scratchpadCount) stashed")
                            .font(.hyprMonoXs)
                        Spacer()
                    }
                    .foregroundStyle(Color.overlaySecondary)
                    .padding(.horizontal, HyprSpacing.md)
                    .padding(.vertical, HyprSpacing.sm)
                }
            }
        }
    }

    private func monitorRow(_ monitor: MenuBarMonitorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: HyprSpacing.sm) {
            HStack(spacing: HyprSpacing.sm) {
                Image(systemName: monitor.isPortrait ? "rectangle.portrait" : "display")
                    .font(.system(size: 11))
                Text(monitor.name).font(.hyprBody).lineLimit(1).truncationMode(.middle)
                Spacer()
            }.foregroundStyle(Color.hyprTextSecondary)
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(25), spacing: 6), count: 5),
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(monitor.workspaces) { workspace in
                    Button {
                        guard config.enabled else { return }
                        appDelegate.windowManager?.handleAction(.switchWorkspace(workspace.id))
                    } label: {
                        Text(UserConfig.workspaceDisplayName(workspace.id, names: config.workspaceNames,
                                                             fallback: "\(workspace.id)"))
                            .font(.hyprMonoSm).lineLimit(1).minimumScaleFactor(0.5)
                            .frame(width: 25, height: 23)
                            .background(RoundedRectangle(cornerRadius: 4).fill(workspace.isActive ? Color.overlayPrimary : (workspace.isOccupied ? Color.overlaySecondary.opacity(0.24) : Color.white.opacity(0.06))))
                            .foregroundStyle(workspace.isActive ? Color.hyprBackground : Color.hyprTextPrimary)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(workspace.hasFloatingWindows ? config.resolvedFloatingColor : Color.clear, lineWidth: 1.5))
                    }.buttonStyle(.plain).disabled(!config.enabled).help("Switch to \(UserConfig.workspaceDisplayName(workspace.id, names: config.workspaceNames, fallback: "workspace \(workspace.id)"))")
                }
            }
        }
        .padding(.horizontal, HyprSpacing.md)
        .padding(.vertical, HyprSpacing.sm)
    }

    // MARK: actions

    private var actions: some View {
        VStack(spacing: 1) {
            MenuBarRow("Keybinds", icon: "keyboard") {
                appDelegate.windowManager?.handleAction(.showKeybinds)
            } trailing: {
                if let binding = config.keybinds.first(where: { $0.action == .showKeybinds }) {
                    KeybadgeView(bind: binding, fontSize: 11)
                }
            }
            MenuBarRow("Workspace overview", icon: "rectangle.grid.3x2") {
                appDelegate.windowManager?.handleAction(.showWorkspaceOverview)
            } trailing: {
                if let binding = config.keybinds.first(where: { $0.action == .showWorkspaceOverview }) {
                    KeybadgeView(bind: binding, fontSize: 11)
                }
            }
            MenuBarRow("Settings…", icon: "gearshape") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuBarRow("Tutorial", icon: "sparkles") {
                appDelegate.showTour()
            }
            MenuBarRow("Retile all spaces", icon: "rectangle.3.group") {
                NotificationCenter.default.post(name: .hyprMacRetileAll, object: nil)
            } trailing: {
                if let binding = config.keybinds.first(where: { $0.action == .retileAll }) {
                    KeybadgeView(bind: binding, fontSize: 11)
                }
            }
            #if !HYPRMAC_DEBUG_VARIANT
            if RuntimeVariant.updatesManagedByNix {
                MenuBarRow("Updates are managed by Nix", icon: "shippingbox", action: {}) {
                    versionLabel
                }
                .disabled(true)
            } else {
                let row = MenuBarPresentation.updateRow(for: updateState.notice, currentVersion: appVersion)
                MenuBarRow(row.title, icon: row.icon, accent: row.highlighted) {
                    updates.activate()
                } trailing: {
                    Text(row.version)
                        .font(.hyprMonoXs)
                        .foregroundStyle(row.highlighted ? Color.hyprCyan : Color.hyprTextTertiary)
                }
                .disabled(!UpdatePresentation.canActivate(notice: updateState.notice,
                                                          canCheckForUpdates: updates.canCheckForUpdates))
            }
            #endif
            Rectangle()
                .fill(Color.hyprSeparator)
                .frame(height: 0.5)
                .padding(.vertical, HyprSpacing.xs)
            MenuBarRow("Quit HyprMac", icon: "power", destructive: true) {
                NSApp.terminate(nil)
            }
        }
    }

    private var versionLabel: some View {
        Text("v\(appVersion)")
            .font(.hyprMonoXs)
            .foregroundStyle(Color.hyprTextTertiary)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}

// MARK: - menu row

private struct MenuBarRow<Trailing: View>: View {
    let label: String
    let icon: String
    let destructive: Bool
    /// colored icon and heavier label, for the one row that wants attention
    let accent: Bool
    let action: () -> Void
    let trailing: () -> Trailing

    @State private var hovering = false

    init(_ label: String,
         icon: String,
         destructive: Bool = false,
         accent: Bool = false,
         action: @escaping () -> Void,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.label = label
        self.icon = icon
        self.destructive = destructive
        self.accent = accent
        self.action = action
        self.trailing = trailing
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: HyprSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(destructive ? Color.red.opacity(0.85)
                                     : (accent ? Color.hyprCyan : Color.hyprTextSecondary))
                    .frame(width: 16)
                Text(label)
                    .font(accent ? .hyprBody.weight(.semibold) : .hyprBody)
                    .foregroundStyle(destructive ? Color.red.opacity(0.95) : Color.hyprTextPrimary)
                    // two lines, then an ellipsis: app names can be long
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer()
                trailing()
            }
            .padding(.horizontal, HyprSpacing.md)
            .padding(.vertical, HyprSpacing.sm - 1)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                    .fill(hovering ? Color.hyprTextTertiary.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(HyprMotion.snap, value: hovering)
    }
}

/// Opens the Settings window from AppKit code, such as a reopen of the app.
/// SwiftUI only hands out `openWindow` inside views, so the menu bar label
/// stores it when it first appears. The label is built even while the menu
/// bar item is hidden.
enum SettingsWindow {
    static var openWindow: OpenWindowAction?

    @discardableResult
    static func show() -> Bool {
        guard let openWindow else { return false }
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

// Bridge for the menu bar label between WindowManager (which knows the
// workspace state but is not available at app init) and the SwiftUI
// MenuBarExtra label (which is built before WindowManager exists).
// WorkspaceStatusPresenter.updateMenuBarState writes to .shared after every poll;
// WorkspaceIndicatorLabel observes it.
class MenuBarState: ObservableObject {
    static let shared = MenuBarState()
    @Published var labelText = ""
    /// A window fills a display showing now. The label swaps the glyphs for one icon.
    @Published var isFullscreen = false
    @Published var monitors: [MenuBarMonitorSnapshot] = []
    /// The compact style's one badge: the focused workspace, else the one
    /// on the cursor's screen. nil with no screens.
    @Published var compactWorkspace: MenuBarCompactWorkspace?
    @Published var hasData = false
    /// Number of windows in the scratchpad (0 = hide the tray glyph).
    @Published var scratchpadCount = 0
    /// Whether the scratchpad layer is currently summoned (filled tray).
    @Published var scratchpadVisible = false
    /// The focused window's rule state, read when the menu opens. nil hides
    /// the section.
    @Published var focusedWindowRule: FocusedWindowRuleInfo?
}

struct MenuBarMonitorSnapshot: Equatable, Identifiable {
    let id: Int
    let name: String
    let currentWorkspace: Int
    let isPortrait: Bool
    let workspaces: [MenuBarWorkspaceBadge]

    init(id: Int, name: String, currentWorkspace: Int, isPortrait: Bool,
         workspaces: [MenuBarWorkspaceBadge] = []) {
        self.id = id
        self.name = name
        self.currentWorkspace = currentWorkspace
        self.isPortrait = isPortrait
        self.workspaces = workspaces
    }
}

struct MenuBarWorkspaceBadge: Equatable, Identifiable {
    let id: Int
    let isActive: Bool
    let isOccupied: Bool
    let hasFloatingWindows: Bool
}

/// The workspace the Compact style shows, and what its badge marks.
struct MenuBarCompactWorkspace: Equatable {
    let id: Int
    let hasFloatingWindows: Bool
    let isMaximized: Bool
}

/// What the Compact style draws: a badge with the workspace's number, or
/// with its name when that is one Latin letter or digit; else the name as text,
/// beside the fullscreen icon while the workspace has a maximized window.
enum MenuBarCompactLabel: Equatable {
    case name(String, fullscreen: Bool)
    case symbol(String)
}

/// What the menu bar item shows. Per Mac, kept in UserDefaults.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case full
    case compact
    case hidden

    var id: Self { self }

    var displayName: String {
        switch self {
        case .full: return "Full"
        case .compact: return "Compact"
        case .hidden: return "Hidden"
        }
    }

    /// The stored style. Read only; `@AppStorage` does the writing.
    static var stored: MenuBarStyle {
        UserDefaults.standard.string(forKey: UserConfig.menuBarStyleKey).flatMap(MenuBarStyle.init) ?? .full
    }

    /// Style for a Mac that still has the two old settings.
    static func migrated(showIcon: Bool, showIndicator: Bool) -> MenuBarStyle {
        if !showIcon { return .hidden }
        return showIndicator ? .full : .compact
    }
}

enum MenuBarPresentation {
    static func workspaceBadgeRows(_ badges: [MenuBarWorkspaceBadge]) -> [[MenuBarWorkspaceBadge]] {
        stride(from: 0, to: badges.count, by: 5).map { start in
            Array(badges[start..<min(start + 5, badges.count)])
        }
    }

    static func workspaceGlyphs(active: Set<Int>, occupied: Set<Int>,
                                floating: Set<Int>) -> String {
        let lastWorkspace = max(active.max() ?? 1, occupied.max() ?? 1)
        return (1...lastWorkspace).map { workspace in
            if active.contains(workspace) {
                return floating.contains(workspace)
                    ? HyprGlyph.workspaceShownFloating : HyprGlyph.workspaceShown
            }
            if occupied.contains(workspace) {
                return floating.contains(workspace)
                    ? HyprGlyph.workspaceWaitingFloating : HyprGlyph.workspaceWaiting
            }
            return HyprGlyph.workspaceEmpty
        }.joined(separator: " ")
    }

    static func monitorSummary(_ monitors: [MenuBarMonitorSnapshot], names: [String: String]) -> String {
        monitors.map { "\($0.name): \(UserConfig.workspaceDisplayName($0.currentWorkspace, names: names))" }
            .joined(separator: "\n")
    }

    static func showsWorkspaceState(enabled: Bool, indicatorEnabled: Bool,
                                    hasData: Bool, monitors: [MenuBarMonitorSnapshot],
                                    scratchpadCount: Int) -> Bool {
        enabled && indicatorEnabled && hasData
            && (!monitors.isEmpty || scratchpadCount > 0)
    }

    /// The menu's update row: a plain check, or the pending update.
    struct UpdateRow: Equatable {
        let title: String
        let icon: String
        /// the version on the right: the pending one, else the running one
        let version: String
        let highlighted: Bool
    }

    static func updateRow(for notice: UpdateNotice?, currentVersion: String) -> UpdateRow {
        switch notice {
        case nil:
            return UpdateRow(title: "Check for updates…", icon: "arrow.down.circle",
                             version: "v\(currentVersion)", highlighted: false)
        case .available(let version):
            return UpdateRow(title: "Update available", icon: "arrow.down.circle.fill",
                             version: "v\(version)", highlighted: true)
        case .ready(let version):
            return UpdateRow(title: "Restart to update", icon: "arrow.clockwise.circle.fill",
                             version: "v\(version)", highlighted: true)
        }
    }

    /// Tooltip for the menu bar item's update dot.
    static func updateHelp(for notice: UpdateNotice) -> String {
        switch notice {
        case .available(let version): return "HyprMac \(version) is available"
        case .ready(let version): return "HyprMac \(version) is ready to install"
        }
    }

    static func showsIndicator(hasData: Bool, labelText: String, scratchpadCount: Int) -> Bool {
        hasData && (!labelText.isEmpty || scratchpadCount > 0)
    }

    /// The symbol glyph for a one-character name: a Latin (ASCII) letter or
    /// a digit, lowercased as symbol names are (`w.square` draws a capital W).
    /// nil for any other name: SF Symbols has letter badges only for a–z.
    static func badgeGlyph(_ name: String) -> String? {
        guard name.count == 1, let char = name.first, char.isASCII,
              char.isLetter || char.isNumber else { return nil }
        return name.lowercased()
    }

    // no name keeps the number; a Latin letter or a digit takes its place in
    // the badge; any other name is text, in full. A blank name counts as
    // none, as everywhere else.
    static func compactLabel(_ workspace: MenuBarCompactWorkspace, names: [String: String]) -> MenuBarCompactLabel {
        let name = UserConfig.workspaceDisplayName(workspace.id, names: names, fallback: "")
        guard let glyph = name.isEmpty ? String(workspace.id) : badgeGlyph(name) else {
            return .name(name, fullscreen: workspace.isMaximized)
        }
        // square, circle with floaters, filled when maximized
        let shape = workspace.hasFloatingWindows ? "circle" : "square"
        return .symbol("\(glyph).\(shape)\(workspace.isMaximized ? ".fill" : "")")
    }

    // 17 pt medium is about the size of the icons next to it
    static let compactPointSize: CGFloat = 17
    // square is 20x18 and circle 20x20 at that size, so draw both into one box
    static let compactCanvasSize = NSSize(width: 20, height: 20)

    // swiftui sizing is ignored in a menu bar label, so size the image itself
    static func compactImage(symbol: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: compactPointSize, weight: .medium)
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let canvas = NSImage(size: compactCanvasSize, flipped: false) { rect in
            let origin = NSPoint(x: rect.midX - glyph.size.width / 2,
                                 y: rect.midY - glyph.size.height / 2)
            glyph.draw(in: NSRect(origin: origin, size: glyph.size))
            return true
        }
        canvas.isTemplate = true
        return canvas
    }
}

/// The fullscreen icon, then the text, for the Full glyphs and a Compact
/// name; the HStack around it spaces them.
struct MenuBarLabelText: View {
    let fullscreen: Bool
    let text: String

    var body: some View {
        if fullscreen {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 12, weight: .regular))
        }
    }
}

// the label stays visible while tiling is paused
struct WorkspaceIndicatorLabel: View {
    @ObservedObject private var config = UserConfig.shared
    @ObservedObject private var state = MenuBarState.shared
    @AppStorage(UserConfig.menuBarStyleKey) private var style: MenuBarStyle = .full
    @Environment(\.openWindow) private var openWindow

    @ObservedObject private var updateState = UpdateState.shared

    var body: some View {
        HStack(spacing: 4) {
            content
            if let notice = updateState.notice {
                MenuBarUpdateDot()
                    .help(MenuBarPresentation.updateHelp(for: notice))
            }
        }
        .onAppear { SettingsWindow.openWindow = openWindow }
    }

    @ViewBuilder private var content: some View {
        if style == .compact, state.hasData, let workspace = state.compactWorkspace {
            Group {
                switch MenuBarPresentation.compactLabel(workspace, names: config.workspaceNames) {
                case .name(let name, let fullscreen):
                    HStack(spacing: 5) {
                        MenuBarLabelText(fullscreen: fullscreen, text: name)
                    }
                case .symbol(let symbol):
                    if let image = MenuBarPresentation.compactImage(symbol: symbol) {
                        Image(nsImage: image)
                    } else {
                        Image(systemName: symbol)
                    }
                }
            }
            .help(MenuBarPresentation.monitorSummary(state.monitors, names: config.workspaceNames))
        } else if style != .compact, MenuBarPresentation.showsIndicator(
            hasData: state.hasData,
            labelText: state.labelText,
            scratchpadCount: state.scratchpadCount) {
            HStack(spacing: 5) {
                // the icon stands in for the glyphs
                MenuBarLabelText(fullscreen: state.isFullscreen,
                                 text: state.isFullscreen ? "" : state.labelText)
                if state.scratchpadCount > 0 {
                    Image(systemName: state.scratchpadVisible ? "tray.fill" : "tray")
                    if state.scratchpadCount > 1 {
                        Text("\(state.scratchpadCount)")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
            }
            .help(MenuBarPresentation.monitorSummary(state.monitors, names: config.workspaceNames))
        } else {
            Image(systemName: "rectangle.split.2x2")
        }
    }
}

/// The "update pending" mark for the menu bar item: one bullet after the
/// label. A menu bar label is drawn as one image and one line of text in
/// the menu bar's own font, so a second image is dropped and a font size is
/// ignored; the mark has to be a small glyph. A compact fixed-width item
/// can append the same glyph, or draw its own dot when
/// `UpdateState.shared.notice` is set.
struct MenuBarUpdateDot: View {
    static let glyph = "•"

    var body: some View {
        Text(Self.glyph)
            .accessibilityLabel("Update available")
    }
}
