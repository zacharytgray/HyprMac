// Per-app window rules. A rule pins an app to a workspace or the scratchpad:
// every new window of that app opens there, and Retile All moves the app's open
// windows back.

import Foundation

/// One app-to-workspace pin, keyed by bundle id. Settings keeps one rule per
/// app; a hand-edited config with two resolves to the first.
struct WindowRule: Codable, Equatable, Identifiable {
    var id: String { bundleID }

    let bundleID: String
    /// 1–10, or `WindowRule.scratchpad`
    var workspace: Int
}

extension WindowRule {
    static let scratchpad = ScratchpadController.workspace

    /// Whether the rules pin this app to the scratchpad. Builds without this
    /// option read the value as a workspace outside 1–10, which pins nothing.
    static func isPinnedToScratchpad(bundleID: String?, in rules: [WindowRule]) -> Bool {
        guard let bundleID else { return false }
        return rules.first(where: { $0.bundleID == bundleID })?.workspace == scratchpad
    }

    /// Workspace the rules pin this app to, or nil when none does. A rule
    /// naming a workspace outside 1–10 (a hand-edit) pins nothing.
    static func pinnedWorkspace(forBundleID bundleID: String?, in rules: [WindowRule]) -> Int? {
        guard let bundleID, let rule = rules.first(where: { $0.bundleID == bundleID }),
              Constants.workspaceRange.contains(rule.workspace) else { return nil }
        return rule.workspace
    }
}
