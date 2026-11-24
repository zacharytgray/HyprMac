// "Monitors" section of Settings: one card per connected display, with
// tiling on or off, max splits, edge padding, the workspaces it holds and
// a live preview. Also the edge padding editor.

import SwiftUI

struct MonitorsSettingsView: View {
    @ObservedObject var config = UserConfig.shared
    @State private var screens: [NSScreen] = NSScreen.screens

    var body: some View {
        VStack(spacing: HyprSpacing.lg) {
            if workspaceMappingIgnored {
                notice("A display would have no workspace, so the default workspace homes apply on this setup.",
                       icon: "exclamationmark.triangle")
            }
            if !config.workspaceMonitors.isEmpty {
                notice("config.json also has a hand-written workspaceMonitors map. It applies to display setups with no choices saved here.",
                       icon: "doc.text")
            }
            ForEach(WorkspaceManager.leftToRight(screens), id: \.localizedName) { screen in
                MonitorCard(screen: screen,
                            tilingEnabled: tilingBinding(screen),
                            maxSplits: maxSplitsBinding(screen),
                            edgePadding: edgePaddingBinding(screen),
                            workspaces: workspacesBinding(screen),
                            gap: config.gapSize,
                            padding: config.outerPadding)
            }
            Text("Workspace choices are saved for this set of displays. Workspaces you don't put on a display keep their default home.")
                .font(.hyprCaption)
                .foregroundStyle(Color.settingsTextMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HyprSpacing.md)
            SectionResetFooter(title: "Reset Monitors to defaults",
                               message: "Turns tiling on for every display, sets max splits to 3, clears edge padding and puts every workspace back in its default home. A copy of your settings is kept beside monitor-config.json.") {
                config.resetToDefaults(.monitors)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
    }

    private func notice(_ text: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HyprSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.hyprMagenta)
            Text(text)
                .font(.hyprCaption)
                .foregroundStyle(Color.settingsTextMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, HyprSpacing.md)
    }

    // every connected display, disabled ones too: the set the mapping is saved for
    private var connectedNames: [String] { screens.map(\.localizedName) }

    // the mapping would leave an enabled monitor with nothing to show
    private var workspaceMappingIgnored: Bool {
        let enabled = WorkspaceManager.leftToRight(screens)
            .filter { !config.disabledMonitors.contains($0.localizedName) }
        let mapping = WorkspaceHomeResolver.mapping(forDisplays: connectedNames,
                                                    perSet: config.workspaceMonitorsPerDisplaySet,
                                                    fallback: config.workspaceMonitors)
        return WorkspaceHomeResolver.resolve(enabledNames: enabled.map(\.localizedName),
                                             mapping: mapping).mappingIgnored
    }

    private func tilingBinding(_ screen: NSScreen) -> Binding<Bool> {
        Binding(get: { !config.disabledMonitors.contains(screen.localizedName) },
                set: { enabled in
                    if enabled {
                        config.disabledMonitors.remove(screen.localizedName)
                    } else {
                        config.disabledMonitors.insert(screen.localizedName)
                    }
                })
    }

    private func maxSplitsBinding(_ screen: NSScreen) -> Binding<Int> {
        Binding(get: { config.maxSplitsPerMonitor[screen.localizedName] ?? TilingConfig.defaultMaxDepth },
                set: { newVal in
                    if newVal == TilingConfig.defaultMaxDepth {
                        config.maxSplitsPerMonitor.removeValue(forKey: screen.localizedName)
                    } else {
                        config.maxSplitsPerMonitor[screen.localizedName] = newVal
                    }
                })
    }

    private func edgePaddingBinding(_ screen: NSScreen) -> Binding<EdgePadding> {
        Binding(get: { config.outerPaddingPerMonitor[screen.localizedName] ?? EdgePadding() },
                set: { newVal in
                    config.outerPaddingPerMonitor[screen.localizedName] = newVal.isEmpty ? nil : newVal
                })
    }

    private func workspacesBinding(_ screen: NSScreen) -> Binding<Set<Int>> {
        Binding(get: { config.workspaces(on: screen.localizedName, connectedNames: connectedNames) },
                set: { config.setWorkspaces($0, on: screen.localizedName, connectedNames: connectedNames) })
    }
}

// MARK: - one display

private struct MonitorCard: View {
    let screen: NSScreen
    @Binding var tilingEnabled: Bool
    @Binding var maxSplits: Int
    // a nil side = the shared outer padding
    @Binding var edgePadding: EdgePadding
    // the workspaces put on this monitor; empty = default homes
    @Binding var workspaces: Set<Int>
    let gap: CGFloat
    let padding: CGFloat

    @State private var editingPadding = false

    var body: some View {
        let size = screen.frame.size
        SettingsCard {
            // name and size, with the live preview beside them
            HStack(spacing: HyprSpacing.md) {
                Image(systemName: "display")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.hyprCyan)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(screen.localizedName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.settingsText)
                    Text("\(Int(size.width)) × \(Int(size.height))")
                        .font(.hyprMonoXs)
                        .foregroundStyle(Color.settingsTextFaint)
                }
                Spacer()
                if tilingEnabled {
                    DwindlePreview(windowCount: maxSplits + 1, aspectRatio: size.width / size.height,
                                   gap: gap, padding: padding, edges: edgePadding)
                        .frame(width: 128, height: 72)
                        .background(
                            RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                                .fill(Color.settingsBackground)
                        )
                }
            }
            .padding(.horizontal, HyprSpacing.md)
            .padding(.vertical, HyprSpacing.sm + 2)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.settingsHairline.opacity(0.7)).frame(height: 1)
            }

            SettingsRow("Tile windows on this display", icon: "rectangle.split.2x2",
                        subtitle: tilingEnabled ? nil : "Off. Windows on this display float freely.",
                        divider: tilingEnabled) {
                Toggle("", isOn: $tilingEnabled)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
            if tilingEnabled {
                SettingsRow("Max splits", icon: "square.split.bottomrightquarter",
                            subtitle: "Up to \(RetileAllPlanner.workspaceCapacity(maxDepth: maxSplits)) tiles per workspace, by window size. When full, new windows use the next one.") {
                    NumberPills(range: Array(1...7), isOn: { $0 == maxSplits }, toggle: { maxSplits = $0 })
                }
                SettingsRow("Room for a bar or Dock", icon: "rectangle.inset.filled",
                            subtitle: edgePadding.isEmpty
                                ? "Same as the Screen edges gap, \(EdgePaddingSummary.pt(padding)) pt."
                                : EdgePaddingSummary.text(edgePadding, fallback: padding)) {
                    Button("Edit…") { editingPadding = true }
                        .buttonStyle(.settings)
                        .popover(isPresented: $editingPadding, arrowEdge: .bottom) {
                            EdgePaddingEditor(monitorName: screen.localizedName,
                                              aspect: size.width / size.height,
                                              edgePadding: $edgePadding,
                                              fallback: padding)
                        }
                }
                SettingsRow("Workspaces on this display", icon: "square.stack.3d.up",
                            subtitle: workspaces.isEmpty ? "None picked: default homes." : nil,
                            divider: false) {
                    EmptyView()
                } detail: {
                    NumberPills(range: Array(Constants.workspaceRange),
                                isOn: { workspaces.contains($0) },
                                toggle: { n in
                                    if workspaces.contains(n) { workspaces.remove(n) } else { workspaces.insert(n) }
                                })
                        .padding(.top, 4)
                }
            }
        }
    }
}

/// A row of numbered keys. The chosen ones get a cyan outline and text on
/// a faint cyan fill.
private struct NumberPills: View {
    let range: [Int]
    let isOn: (Int) -> Bool
    let toggle: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(range, id: \.self) { n in
                let on = isOn(n)
                Button { toggle(n) } label: {
                    Text("\(n)")
                        .font(.hyprMonoSm)
                        .frame(width: 26, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                                .fill(on ? Color.hyprCyan.opacity(0.16) : Color.settingsRaised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                                .strokeBorder(on ? Color.hyprCyan.opacity(0.6) : Color.settingsHairline,
                                              lineWidth: 0.5)
                        )
                        .foregroundStyle(on ? Color.hyprCyan : Color.settingsTextMuted)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .fixedSize()
    }
}

// MARK: - edge padding

enum EdgePaddingSummary {
    static func pt(_ value: CGFloat) -> String {
        String(format: "%g", Double(value))
    }

    // "Default (8 pt)", "Top 40 pt", "Top 40 pt, Left 0 pt"
    static func text(_ edges: EdgePadding, fallback: CGFloat) -> String {
        if edges.isEmpty { return "Default (\(pt(fallback)) pt)" }
        let sides = [("Top", edges.top), ("Left", edges.left), ("Bottom", edges.bottom), ("Right", edges.right)]
        let set = sides.compactMap { name, value in value.map { "\(name) \(pt($0)) pt" } }
        if set.count == 4, let top = edges.top,
           [edges.left, edges.bottom, edges.right].allSatisfy({ $0 == top }) {
            return "\(pt(top)) pt on every side"
        }
        return set.joined(separator: ", ")
    }
}

// popover: one field per screen edge around a small screen diagram
struct EdgePaddingEditor: View {
    let monitorName: String
    let aspect: CGFloat
    @Binding var edgePadding: EdgePadding
    let fallback: CGFloat
    @Environment(\.dismiss) private var dismiss

    // field text per side, so a half-typed number isn't reformatted
    @State private var top: String
    @State private var left: String
    @State private var bottom: String
    @State private var right: String

    init(monitorName: String, aspect: CGFloat, edgePadding: Binding<EdgePadding>, fallback: CGFloat) {
        self.monitorName = monitorName
        self.aspect = aspect
        self._edgePadding = edgePadding
        self.fallback = fallback
        let edges = edgePadding.wrappedValue
        _top = State(initialValue: edges.top.map(EdgePaddingSummary.pt) ?? "")
        _left = State(initialValue: edges.left.map(EdgePaddingSummary.pt) ?? "")
        _bottom = State(initialValue: edges.bottom.map(EdgePaddingSummary.pt) ?? "")
        _right = State(initialValue: edges.right.map(EdgePaddingSummary.pt) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HyprSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Edge padding")
                    .font(.hyprBody.weight(.semibold))
                Text(monitorName)
                    .font(.hyprCaption)
                    .foregroundStyle(Color.hyprTextTertiary)
            }

            VStack(spacing: HyprSpacing.sm) {
                field("Top", $top, \.top)
                HStack(spacing: HyprSpacing.sm) {
                    field("Left", $left, \.left)
                    screenDiagram
                    field("Right", $right, \.right)
                }
                field("Bottom", $bottom, \.bottom)
            }
            .frame(maxWidth: .infinity)

            Text("Space between tiled windows and each edge of this screen. "
                 + "Empty sides use the outer padding (\(EdgePaddingSummary.pt(fallback)) pt).")
                .font(.hyprCaption)
                .foregroundStyle(Color.hyprTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Reset") {
                    top = ""; left = ""; bottom = ""; right = ""
                    edgePadding = EdgePadding()
                }
                .disabled(edgePadding.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(HyprSpacing.lg)
        .frame(width: 360)
    }

    private var effective: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        (edgePadding.top ?? fallback, edgePadding.left ?? fallback,
         edgePadding.bottom ?? fallback, edgePadding.right ?? fallback)
    }

    // not to scale: big enough that 8 pt still shows
    private var screenDiagram: some View {
        let width: CGFloat = 150
        let height = width / max(aspect, 0.5)
        let cap = height * 0.35
        let inset = { (value: CGFloat) in min(value * 0.5, cap) }
        let e = effective
        return RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
            .fill(Color.hyprBackground)
            .overlay(
                RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                    .strokeBorder(Color.hyprSeparator, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.hyprCyan.opacity(0.35))
                    .padding(EdgeInsets(top: inset(e.top), leading: inset(e.left),
                                        bottom: inset(e.bottom), trailing: inset(e.right)))
            )
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }

    // empty = the outer padding, shown as the dimmed placeholder
    private func field(_ name: String, _ text: Binding<String>,
                       _ side: WritableKeyPath<EdgePadding, CGFloat?>) -> some View {
        HStack(spacing: HyprSpacing.xs) {
            TextField(name, text: text, prompt: Text(EdgePaddingSummary.pt(fallback)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
                .help(name)
                .onChange(of: text.wrappedValue) { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty {
                        edgePadding[keyPath: side] = nil
                    } else if let value = Double(trimmed) {
                        edgePadding[keyPath: side] = CGFloat(max(value, 0))
                    }
                }
            Text("pt")
                .font(.hyprCaption)
                .foregroundStyle(Color.hyprTextSecondary)
        }
    }
}
