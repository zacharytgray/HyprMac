// "Tiling" section of Settings: the gaps with a live preview, and the
// float and tile rules. Also the dwindle preview Monitors shares.

import SwiftUI

/// "Tiling": space between tiles, and which apps float or tile.
struct TilingSettingsView: View {
    @ObservedObject var config = UserConfig.shared

    var body: some View {
        VStack(spacing: HyprSpacing.lg) {
            gapsCard
            floatingCard
            rulesCard
            SectionResetFooter(title: "Reset Tiling to defaults",
                               message: "Sets both gaps to \(Int(UserConfigDefaults.gapSize)) px, turns off Keep floating windows in front, and puts the rules back to the two defaults, FaceTime and System Settings floating. Rules you added are removed; a copy of your settings is kept beside config.json.") {
                config.resetToDefaults(.tiling)
            }
        }
    }

    // MARK: gaps: sliders left, live preview right

    private var gapsCard: some View {
        SettingsCard("Gaps") {
            HStack(alignment: .center, spacing: HyprSpacing.lg) {
                VStack(alignment: .leading, spacing: HyprSpacing.md) {
                    gapSlider("Between windows", icon: "rectangle.split.2x1", value: $config.gapSize)
                    gapSlider("Screen edges", icon: "rectangle.dashed", value: $config.outerPadding)
                    Text("Monitors can change the edges one side at a time.")
                        .font(.hyprCaption)
                        .foregroundStyle(Color.settingsTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                DwindlePreview(windowCount: 4, aspectRatio: 16.0 / 10.0,
                               gap: config.gapSize, padding: config.outerPadding)
                    .frame(width: 220, height: 138)
                    .background(
                        RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                            .fill(Color.settingsBackground)
                    )
            }
            .padding(HyprSpacing.md)
        }
    }

    private func gapSlider(_ title: String, icon: String, value: Binding<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: HyprSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.hyprCyan)
                    .frame(width: 18)
                Text(title)
                    .font(.hyprBody)
                    .foregroundStyle(Color.settingsText)
            }
            SettingsSlider(value: Binding(get: { Double(value.wrappedValue) },
                                          set: { value.wrappedValue = CGFloat($0) }),
                           range: 0...32, step: 2, label: { "\(Int($0)) px" }, width: 150)
                .padding(.leading, 18 + HyprSpacing.sm)
        }
    }

    // MARK: floating windows in front

    // read when the card draws: Settings reopens after a grant
    private var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    private var floatingCard: some View {
        SettingsCard("Floating windows") {
            SettingsRow("Keep floating windows in front", icon: "square.stack.3d.up",
                        subtitle: "Shows a live picture of a covered floating window. macOS asks for Screen Recording to do that.",
                        divider: false) {
                Toggle("", isOn: $config.keepFloatingWindowsInFront)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            } detail: {
                if config.keepFloatingWindowsInFront && !screenRecordingGranted {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Without Screen Recording it shows the app icon and title instead. After you allow it, quit and reopen HyprMac if the picture does not appear.")
                            .font(.hyprCaption)
                            .foregroundStyle(Color.settingsTextMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Screen Recording Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.settings)
                    }
                }
            }
        }
    }

    // MARK: float and tile rules

    // one list for every rule: an app in Never tile, an app tile rule, and
    // the rules for one kind of window, made from the menu bar or an action
    private var rulesCard: some View {
        SettingsCard("Float and tile rules",
                     footer: "A rule for one kind of window beats a rule for its app.") {
            let rows = FloatingRuleRow.rows(excludedBundleIDs: config.excludedBundleIDs,
                                            rules: config.floatingRules)
            if rows.isEmpty {
                SettingsRow("No rules", icon: "circle.dashed", tint: .settingsTextMuted,
                            subtitle: "HyprMac decides what floats.") { EmptyView() }
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { _, row in
                    FloatingRuleRowView(row: row, config: config, isLast: false,
                                        appName: appDisplayName(for: row.bundleID))
                }
            }
            SettingsRow("Always float an app", icon: "plus.circle", divider: false) {
                Button("Choose…") { pickAlwaysFloatApp() }
                    .buttonStyle(.settings)
            } detail: {
                ShortcutHint("Or a rule for the focused window with", action: .showWindowRules)
            }
        }
    }

    private func pickAlwaysFloatApp() {
        let panel = NSOpenPanel()
        panel.title = "Select Application to Exclude"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url,
           let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
            // through the rule path, so an app tile rule for it goes
            config.addAlwaysFloatApp(id)
        }
    }
}

// MARK: - dwindle preview

struct DwindlePreview: View {
    let windowCount: Int
    let aspectRatio: CGFloat
    let gap: CGFloat
    let padding: CGFloat
    // per-side overrides; a nil side uses `padding`
    var edges = EdgePadding()

    var body: some View {
        GeometryReader { geo in
            let previewSize = DwindleLayout.fitSize(in: geo.size, aspect: aspectRatio)
            let origin = CGPoint(
                x: (geo.size.width - previewSize.width) / 2,
                y: (geo.size.height - previewSize.height) / 2
            )
            let outerRect = CGRect(origin: origin, size: previewSize)

            let scale = previewSize.width / (aspectRatio * 1000)
            let scaledGap = max(gap * scale, 1)
            let pad = { (side: CGFloat?) in max((side ?? padding) * scale, 1) }
            let top = pad(edges.top), left = pad(edges.left)
            let bottom = pad(edges.bottom), right = pad(edges.right)

            let innerRect = CGRect(x: outerRect.minX + left, y: outerRect.minY + top,
                                   width: max(outerRect.width - left - right, 1),
                                   height: max(outerRect.height - top - bottom, 1))
            let rects = DwindleLayout.rects(count: windowCount, in: innerRect, gap: scaledGap)

            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.settingsHairline, lineWidth: 0.5)
                .frame(width: previewSize.width, height: previewSize.height)
                .position(x: outerRect.midX, y: outerRect.midY)

            ForEach(Array(rects.enumerated()), id: \.offset) { idx, rect in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.hyprCyan.opacity(0.45 - Double(idx) * 0.05))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }
}
