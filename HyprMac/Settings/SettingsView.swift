// Top-level settings shell. NavigationSplitView with a custom sidebar
// and a detail pane; the hosting NSWindow is bumped to `.floating`
// level so it stays above tiled HyprMac-managed windows.

import SwiftUI

/// Top-level settings shell with a custom sidebar of tabs and a
/// detail pane.
struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable, Hashable {
        case general, keybinds, appLauncher, tiling

        var label: String {
            switch self {
            case .general:     return "General"
            case .keybinds:    return "Keybinds"
            case .appLauncher: return "App Launcher"
            case .tiling:      return "Tiling"
            }
        }

        var icon: String {
            switch self {
            case .general:     return "gearshape"
            case .keybinds:    return "command"
            case .appLauncher: return "square.grid.2x2"
            case .tiling:      return "rectangle.split.3x1"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 192, max: 220)
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(WindowLevelSetter())
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            // header
            VStack(alignment: .leading, spacing: 4) {
                Text("HYPRMAC")
                    .font(.hyprMono)
                    .kerning(2)
                    .foregroundStyle(Color.hyprTextPrimary)
                Text("v\(appVersion)")
                    .font(.hyprMonoXs)
                    .foregroundStyle(Color.hyprTextTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, HyprSpacing.lg)
            .padding(.top, HyprSpacing.lg)
            .padding(.bottom, HyprSpacing.lg)

            // tabs
            VStack(spacing: 2) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    SidebarItem(
                        tab: tab,
                        isActive: selectedTab == tab,
                        onTap: { selectedTab = tab }
                    )
                }
            }
            .padding(.horizontal, HyprSpacing.sm)

            Spacer()

            // footer — config path
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([configURL])
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc")
                        .font(.system(size: 9))
                    Text(configPathDisplay)
                        .font(.hyprMonoXs)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(Color.hyprTextTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(configURL.path)
            .padding(.horizontal, HyprSpacing.lg)
            .padding(.vertical, HyprSpacing.md)
        }
        .frame(maxHeight: .infinity)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            // page title
            Text(selectedTab.label)
                .font(.hyprTitle)
                .foregroundStyle(Color.hyprTextPrimary)
                .padding(.horizontal, HyprSpacing.xl)
                .padding(.top, HyprSpacing.lg)
                .padding(.bottom, HyprSpacing.md)

            // body
            ScrollView {
                VStack(spacing: HyprSpacing.lg) {
                    switch selectedTab {
                    case .general:     GeneralSettingsView()
                    case .keybinds:    KeybindsSettingsView()
                    case .appLauncher: AppLauncherSettingsView()
                    case .tiling:      TilingSettingsView()
                    }
                }
                .padding(.horizontal, HyprSpacing.xl)
                .padding(.bottom, HyprSpacing.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.hyprBackground)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var configURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("HyprMac/config.json")
    }

    private var configPathDisplay: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = configURL.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - sidebar item

private struct SidebarItem: View {
    let tab: SettingsView.SettingsTab
    let isActive: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: HyprSpacing.md) {
                // active indicator: 2pt cyan left edge
                Rectangle()
                    .fill(isActive ? Color.hyprCyan : Color.clear)
                    .frame(width: 2, height: 16)

                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isActive ? Color.hyprTextPrimary : Color.hyprTextSecondary)
                    .frame(width: 16)

                Text(tab.label)
                    .font(.hyprBody)
                    .foregroundStyle(isActive ? Color.hyprTextPrimary : Color.hyprTextSecondary)

                Spacer()
            }
            .padding(.vertical, HyprSpacing.xs + 2)
            .padding(.trailing, HyprSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                    .fill(hovering && !isActive
                          ? Color.hyprTextTertiary.opacity(0.10)
                          : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(HyprMotion.snap, value: hovering)
    }
}

// sets the hosting NSWindow to floating level once it's available
private struct WindowLevelSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> WLView { WLView() }
    func updateNSView(_ nsView: WLView, context: Context) {}

    class WLView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.level = .floating
        }
    }
}
