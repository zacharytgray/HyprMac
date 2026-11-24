// Top-level settings shell. NavigationSplitView with a custom sidebar of
// eight sections and a search field, and a detail pane; its window stays
// above tiles and passive overlays.

import SwiftUI

/// Top-level settings shell: sidebar of sections plus search, and a detail
/// pane. General is drawn in the navy style; the other sections show the
/// panels they took over, unchanged, until their own redesign.
struct SettingsView: View {
    let showTutorial: () -> Void
    @ObservedObject private var config = UserConfig.shared
    @State private var selected: SettingsSection
    @State private var search: String
    #if !HYPRMAC_DEBUG_VARIANT
    @Environment(\.updateController) private var updates
    #endif

    init(showTutorial: @escaping () -> Void,
         initialSection: SettingsSection = .general,
         initialSearch: String = "") {
        self.showTutorial = showTutorial
        _selected = State(initialValue: initialSection)
        _search = State(initialValue: initialSearch)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 188, ideal: 200, max: 230)
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(WindowLevelSetter())
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // one-row header: mark, name, version
            HStack(spacing: HyprSpacing.sm) {
                HyprMark(size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("HyprMac")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.settingsText)
                    Text(UpdatePresentation.versionLabel(version: appVersion, build: appBuild))
                        .font(.hyprMonoXs)
                        .foregroundStyle(Color.settingsTextFaint)
                }
            }
            .padding(.horizontal, HyprSpacing.md)
            .padding(.top, HyprSpacing.md)
            .padding(.bottom, HyprSpacing.sm + 2)

            SidebarSearchField(text: $search)
                .padding(.horizontal, HyprSpacing.sm + 2)
                .padding(.bottom, HyprSpacing.sm + 2)

            if searchQuery.isEmpty {
                VStack(spacing: 1) {
                    ForEach(SettingsSection.allCases, id: \.self) { section in
                        SidebarItem(section: section, isActive: selected == section) {
                            selected = section
                        }
                    }
                }
                .padding(.horizontal, HyprSpacing.xs)
            } else {
                searchResults
            }

            Spacer(minLength: 0)

            #if !HYPRMAC_DEBUG_VARIANT
            if let updates, !RuntimeVariant.updatesManagedExternally {
                SidebarUpdateRow(updates: updates)
                    .padding(.horizontal, HyprSpacing.lg)
                    .padding(.bottom, HyprSpacing.md)
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.settingsSidebar)
    }

    private var searchQuery: String { search.trimmingCharacters(in: .whitespaces) }

    private var searchResults: some View {
        let hits = SettingsSearchIndex.matches(searchQuery)
        return VStack(alignment: .leading, spacing: 1) {
            if hits.isEmpty {
                Text("No settings match “\(searchQuery)”.")
                    .font(.hyprCaption)
                    .foregroundStyle(Color.settingsTextMuted)
                    .padding(.horizontal, HyprSpacing.md)
                    .padding(.vertical, HyprSpacing.xs)
            }
            ForEach(hits.prefix(14)) { entry in
                Button {
                    selected = entry.section
                    search = ""
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                            .font(.hyprBody)
                            .foregroundStyle(Color.settingsText)
                            .lineLimit(1)
                        Text(entry.section.label)
                            .font(.hyprCaption)
                            .foregroundStyle(Color.settingsTextFaint)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, HyprSpacing.md)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, HyprSpacing.xs)
    }

    // MARK: detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(title: selected.label, summary: selected.summary)
                .padding(.horizontal, HyprSpacing.xl)
                .padding(.top, HyprSpacing.lg)
                .padding(.bottom, HyprSpacing.md)

            ScrollView {
                VStack(spacing: HyprSpacing.lg) {
                    if config.isConfigReadOnly { ReadOnlyConfigNotice() }
                    SettingsSectionContent(section: selected, showTutorial: showTutorial)
                }
                .padding(.horizontal, HyprSpacing.xl)
                .padding(.bottom, HyprSpacing.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(selected.isRedesigned ? Color.settingsBackground : Color.hyprBackground)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var appBuild: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }
}

// MARK: - section content

/// One section's panels, without the shell. Snapshot tests render it alone.
struct SettingsSectionContent: View {
    let section: SettingsSection
    let showTutorial: () -> Void

    var body: some View {
        switch section {
        case .general:
            GeneralSettingsView(showTutorial: showTutorial)
        case .keys:
            KeybindsSettingsView()
        case .tiling:
            TilingSettingsView()
        case .workspaces:
            WorkspacesSettingsView()
        case .monitors:
            MonitorsSettingsView()
        case .mouse:
            MouseSettingsView()
        case .appearance:
            MovedLayoutPanels(panels: [.focus])
            MovedGeneralPanels()
        case .advanced:
            AdvancedSettingsView()
        }
    }

}

// MARK: - sections

enum SettingsSection: String, CaseIterable, Hashable {
    case general, keys, tiling, workspaces, monitors, mouse, appearance, advanced

    var label: String {
        switch self {
        case .general:    return "General"
        case .keys:       return "Keys"
        case .tiling:     return "Tiling"
        case .workspaces: return "Workspaces"
        case .monitors:   return "Monitors"
        case .mouse:      return "Mouse"
        case .appearance: return "Appearance"
        case .advanced:   return "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .general:    return "gearshape"
        case .keys:       return "command"
        case .tiling:     return "rectangle.split.2x2"
        case .workspaces: return "square.stack.3d.up"
        case .monitors:   return "display.2"
        case .mouse:      return "cursorarrow.motionlines"
        case .appearance: return "paintpalette"
        case .advanced:   return "wrench.and.screwdriver"
        }
    }

    var summary: String {
        switch self {
        case .general:    return "Tiling on or paused, startup, the menu bar and Dock, and updates."
        case .keys:       return "The Hypr key and every shortcut."
        case .tiling:     return "Space between tiles, and which apps float or tile."
        case .workspaces: return "Workspace names, app pins and the scratchpad."
        case .monitors:   return "Tiling, splits, edge room and workspaces for each display."
        case .mouse:      return "Focus follows mouse, hover speed, the cursor on switches and Hypr+drag."
        case .appearance: return "Focus indicator, dimming, colors and overlays."
        case .advanced:   return "iCloud sync, other apps and status bars, files, logging and reset."
        }
    }

    // drawn in the navy style; the rest wait their turn
    var isRedesigned: Bool { [.general, .tiling, .workspaces, .monitors, .mouse, .advanced].contains(self) }
}

// MARK: - search index

/// Every control in Settings, by the words a user would type. One plain
/// list so a test can check nothing is left out.
struct SettingsSearchEntry: Identifiable {
    let title: String
    let keywords: String
    let section: SettingsSection
    var id: String { section.rawValue + "/" + title }
}

enum SettingsSearchIndex {
    static let entries: [SettingsSearchEntry] = [
        // general
        .init(title: "Tiling on or paused", keywords: "pause resume enable disable active status", section: .general),
        .init(title: "Accessibility access", keywords: "permission privacy grant", section: .general),
        .init(title: "Launch at login", keywords: "startup start sign in login item", section: .general),
        .init(title: "Restore saved layout at launch", keywords: "startup layout snapshot save", section: .general),
        .init(title: "Menu bar item", keywords: "menubar status item full compact hidden icon", section: .general),
        .init(title: "Show in Dock", keywords: "dock icon cmd tab command tab app switcher", section: .general),
        .init(title: "Check for updates automatically", keywords: "update sparkle version", section: .general),
        .init(title: "Install updates automatically", keywords: "update sparkle install", section: .general),
        .init(title: "Replay the tutorial", keywords: "tour help onboarding guide", section: .general),
        // keys
        .init(title: "Hypr key", keywords: "caps lock modifier hyper key", section: .keys),
        .init(title: "Double-tap Hypr to toggle Caps Lock", keywords: "caps lock double tap", section: .keys),
        .init(title: "Keybinds", keywords: "shortcut chord binding hotkey key", section: .keys),
        .init(title: "App launchers", keywords: "launch open app shortcut", section: .keys),
        .init(title: "Commands", keywords: "run command shell script", section: .keys),
        // tiling
        .init(title: "Gap between windows", keywords: "gaps inner spacing", section: .tiling),
        .init(title: "Gap at screen edges", keywords: "gaps outer padding margin", section: .tiling),
        .init(title: "Float and tile rules", keywords: "never tile exclude always float app rule window title", section: .tiling),
        // workspaces
        .init(title: "Workspace names", keywords: "rename label workspace", section: .workspaces),
        .init(title: "Pin apps", keywords: "assign app workspace rule open on", section: .workspaces),
        .init(title: "Tile windows in the scratchpad", keywords: "scratchpad tile sent floating layer", section: .workspaces),
        .init(title: "Scratchpad margin", keywords: "scratchpad layer padding inset", section: .workspaces),
        // monitors
        .init(title: "Tile windows on this display", keywords: "monitor display disable tiling screen", section: .monitors),
        .init(title: "Max splits", keywords: "monitor depth tiles dwindle", section: .monitors),
        .init(title: "Room for a bar or Dock", keywords: "monitor edge padding side sketchybar", section: .monitors),
        .init(title: "Workspaces on this display", keywords: "monitor home workspace screen", section: .monitors),
        // mouse
        .init(title: "Focus follows mouse", keywords: "hover pointer focus", section: .mouse),
        .init(title: "Hover speed", keywords: "hover response rate hz pointer", section: .mouse),
        .init(title: "Keep the cursor in place on workspace switches", keywords: "cursor pointer warp center", section: .mouse),
        .init(title: "Swap tiles by dragging", keywords: "hypr drag mouse swap gesture", section: .mouse),
        // appearance
        .init(title: "Dim inactive windows", keywords: "dim darken unfocused", section: .appearance),
        .init(title: "Dim intensity", keywords: "dim amount strength", section: .appearance),
        .init(title: "Focus indicator", keywords: "corners borders brackets marks outline focus", section: .appearance),
        .init(title: "Flash on focus change", keywords: "flash tint border", section: .appearance),
        .init(title: "Animate focus moves", keywords: "animation glide motion", section: .appearance),
        .init(title: "Mark roundness", keywords: "corner marks brackets radius", section: .appearance),
        .init(title: "Mark length", keywords: "corner marks brackets size", section: .appearance),
        .init(title: "Mark thickness", keywords: "corner marks brackets width stroke", section: .appearance),
        .init(title: "Corner color", keywords: "marks brackets color colour", section: .appearance),
        .init(title: "Tiled window color", keywords: "border color colour focus", section: .appearance),
        .init(title: "Floating window color", keywords: "outline floater color colour", section: .appearance),
        .init(title: "Window corner radius", keywords: "rounding corners windows", section: .appearance),
        .init(title: "Fade duration", keywords: "fade speed animation", section: .appearance),
        .init(title: "Overlay accent", keywords: "overlay color accent keybind sheet", section: .appearance),
        .init(title: "Overlay appearance", keywords: "overlay light dark theme", section: .appearance),
        .init(title: "Reset all appearance defaults", keywords: "reset appearance", section: .appearance),
        // advanced
        .init(title: "Sync settings via iCloud", keywords: "icloud sync share macs", section: .advanced),
        .init(title: "Allow other apps to control HyprMac", keywords: "hyprmac links url bettertouchtool external", section: .advanced),
        .init(title: "Status bar export", keywords: "sketchybar state json bar widget", section: .advanced),
        .init(title: "Run after each change", keywords: "status bar hook command sketchybar trigger", section: .advanced),
        .init(title: "Config files", keywords: "config json file finder path monitor", section: .advanced),
        .init(title: "Detailed logging", keywords: "verbose log debug bug report support", section: .advanced),
        .init(title: "Log file", keywords: "log debug finder", section: .advanced),
        .init(title: "Reset all settings", keywords: "reset defaults", section: .advanced),
    ]

    /// Every word must appear in the title, keywords or section name.
    static func matches(_ query: String) -> [SettingsSearchEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        return entries.filter { entry in
            let haystack = (entry.title + " " + entry.keywords + " " + entry.section.label).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}

// MARK: - sidebar parts

private struct SidebarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.settingsTextFaint)
            TextField("Search settings", text: $text)
                .textFieldStyle(.plain)
                .font(.hyprCaption)
                .foregroundStyle(Color.settingsText)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.settingsTextFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                .fill(Color.settingsSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                .strokeBorder(Color.settingsHairline, lineWidth: 0.5)
        )
    }
}

/// Sidebar row. Active: an inset pink-to-blue bar, a cyan icon and semibold
/// text. No row fill, active or hovered.
private struct SidebarItem: View {
    let section: SettingsSection
    let isActive: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: HyprSpacing.sm + 2) {
                Capsule()
                    .fill(isActive
                          ? AnyShapeStyle(LinearGradient(colors: [.hyprMagenta, .hyprCyan],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color.clear))
                    .frame(width: 3, height: 18)

                Image(systemName: section.icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isActive ? Color.hyprCyan : Color.settingsTextMuted)
                    .frame(width: 18)

                Text(section.label)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive || hovering ? Color.settingsText : Color.settingsTextMuted)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.trailing, HyprSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(HyprMotion.snap, value: hovering)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

#if !HYPRMAC_DEBUG_VARIANT
// MARK: - sidebar update row

/// "Check for Updates" at the bottom of the sidebar, replaced by the
/// pending update when there is one. Runs the same action as the menu's
/// update row, so it works with the menu bar item hidden. A pending update
/// gets a cyan icon and a heavier title, nothing more.
private struct SidebarUpdateRow: View {
    @ObservedObject var updates: UpdateController
    @ObservedObject private var updateState = UpdateState.shared

    @State private var hovering = false

    var body: some View {
        let row = UpdatePresentation.sidebarRow(for: updateState.notice,
                                                canCheckForUpdates: updates.canCheckForUpdates)
        Button { updates.activate() } label: {
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: row.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(row.highlighted ? Color.hyprCyan : Color.settingsTextMuted)
                    Text(row.title)
                        .font(.hyprCaption)
                        .fontWeight(row.highlighted ? .semibold : .regular)
                        .foregroundStyle(row.highlighted || hovering ? Color.settingsText : Color.settingsTextMuted)
                }
                if let detail = row.detail {
                    Text(detail)
                        .font(.hyprCaption)
                        .foregroundStyle(Color.settingsTextFaint)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .opacity(row.enabled ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(!row.enabled)
        .onHover { hovering = $0 }
    }
}
#endif

// keeps settings above passive overlays once its window is available
private struct WindowLevelSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> WLView { WLView() }
    func updateNSView(_ nsView: WLView, context: Context) {}

    class WLView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.level = Constants.interfaceWindowLevel
        }
    }
}
