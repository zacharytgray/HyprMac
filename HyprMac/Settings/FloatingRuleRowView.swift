// One row of Settings > General > Float and tile rules, and the popover
// that edits a title rule.

import SwiftUI

struct FloatingRuleRowView: View {
    let row: FloatingRuleRow
    @ObservedObject var config: UserConfig
    let isLast: Bool
    let appName: String
    @State private var editing = false

    var body: some View {
        HStack(spacing: HyprSpacing.md) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: row.bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "app").font(.system(size: 16)).foregroundStyle(Color.hyprTextTertiary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(appName).font(.hyprBody)
                HStack(spacing: 4) {
                    Text(row.matchDescription)
                        .font(.hyprMonoXs)
                        .foregroundStyle(Color.hyprTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if titleRule != nil {
                        Button("Edit") { editing = true }
                            .buttonStyle(.link)
                            .font(.hyprMonoXs)
                            .popover(isPresented: $editing, arrowEdge: .bottom) {
                                if let rule = titleRule {
                                    TitleRuleEditor(rule: rule) { edited in
                                        config.replaceFloatingRule(rule, with: edited)
                                        editing = false
                                    }
                                }
                            }
                    }
                }
            }
            Spacer()
            Picker("", selection: Binding(get: { row.action },
                                          set: { config.setAction($0, for: row) })) {
                Text("Float").tag(FloatingRule.Action.float)
                Text("Tile").tag(FloatingRule.Action.tile)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            Button {
                config.remove(row)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red.opacity(0.75))
            }
            .buttonStyle(.borderless)
            .help("Remove this rule")
        }
        .padding(.horizontal, HyprSpacing.md)
        .padding(.vertical, HyprSpacing.sm)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(Color.hyprSeparator)
                    .frame(height: 0.5)
                    .padding(.leading, HyprSpacing.md + 22 + HyprSpacing.md)
            }
        }
    }

    // a rule matched on the title, the one kind with text to edit
    private var titleRule: FloatingRule? {
        guard case let .rule(rule) = row.source else { return nil }
        switch rule.match {
        case .titleIs?, .titleContains?: return rule
        default: return nil
        }
    }
}

/// Edit a title rule: the captured text, and whether the title must be it
/// or only contain it. A meeting window's title carries the meeting's name,
/// so "contains" with the shared part is the usual edit.
private struct TitleRuleEditor: View {
    let rule: FloatingRule
    let save: (FloatingRule) -> Void
    @State private var contains: Bool
    @State private var text: String

    init(rule: FloatingRule, save: @escaping (FloatingRule) -> Void) {
        self.rule = rule
        self.save = save
        switch rule.match {
        case let .titleContains(value)?:
            _contains = State(initialValue: true)
            _text = State(initialValue: value)
        case let .titleIs(value)?:
            _contains = State(initialValue: false)
            _text = State(initialValue: value)
        default:
            _contains = State(initialValue: false)
            _text = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HyprSpacing.md) {
            Text("Match windows whose title")
                .font(.hyprBody)
            Picker("", selection: $contains) {
                Text("is exactly").tag(false)
                Text("contains").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Title text", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280)
            Text("Shorten the text to the part every such window shares, like “Meeting”.")
                .font(.hyprMonoXs)
                .foregroundStyle(Color.hyprTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Save") {
                    var edited = rule
                    edited.match = contains ? .titleContains(trimmed) : .titleIs(trimmed)
                    save(edited)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty)
            }
        }
        .padding(HyprSpacing.lg)
        .frame(width: 320)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespaces) }
}
