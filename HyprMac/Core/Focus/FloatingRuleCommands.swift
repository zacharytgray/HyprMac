// What the window rules overlay, the menu bar's focused-window section and
// the failed-tile prompt do to one window. They act on the window they were
// opened for, never on whatever has focus when the user clicks. Edits the
// config only: WindowManager watches the rule lists and re-applies a change.

import Cocoa
import Combine

/// One window as the menu bar and the overlay show it, taken when they open.
struct FocusedWindowRuleInfo: Equatable {
    let windowID: CGWindowID
    let appName: String
    let bundleID: String
    /// the window's title when it was taken; "" when it has none
    let title: String
    /// the rule deciding this window now, in words; nil when none does
    let currentRule: String?
    /// whether the whole app floats already (Never tile)
    let appFloats: Bool
    /// whether the app has an app tile rule
    let appTiles: Bool
    let isFloating: Bool
}

/// The rule edits, on a window the caller names. Floating or tiling one
/// window once is Hypr+T, not a rule.
///
/// Every edit made for a window also drops the user's earlier hand choice
/// for it: the newest word about that window is the rule. A refusal gets
/// the red shake and one notice line: a Quick Look preview, a tile rule
/// for a window HyprMac can't resize, a forget with no rule to forget.
///
/// Threading: main-thread only.
final class FloatingRuleCommands {
    private let config: UserConfig

    /// the window still open under this id, nil when it's gone
    var window: (CGWindowID) -> HyprWindow? = { _ in nil }
    var isFloating: (CGWindowID) -> Bool = { _ in false }
    /// red shake around the window, with this text
    var refuse: (HyprWindow, String) -> Void = { _, _ in }
    /// the user's latest word about this window is a rule: forget the hand choice
    var clearManualChoice: (CGWindowID) -> Void = { _ in }
    var bundleID: (HyprWindow) -> String? = {
        $0.bundleID ?? NSRunningApplication(processIdentifier: $0.ownerPID)?.bundleIdentifier
    }
    var appName: (HyprWindow) -> String? = {
        NSRunningApplication(processIdentifier: $0.ownerPID)?.localizedName
    }
    var title: (HyprWindow) -> String? = { $0.title }
    var isSizeSettable: (HyprWindow) -> Bool? = { $0.isSizeSettable }

    static let noRuleMessage = "No rule covers this window"
    static let cannotTileMessage = "This window cannot be tiled"
    static let quickLookMessage = "Quick Look previews stay floating"
    static let goneMessage = "That window is gone"

    init(config: UserConfig) {
        self.config = config
    }

    /// The window under `id` as the menu and the overlay describe it.
    func info(for id: CGWindowID) -> FocusedWindowRuleInfo? {
        guard let window = window(id), !window.isQuickLookPanel,
              let bundleID = bundleID(window) else { return nil }
        let windowTitle = title(window) ?? ""
        let verdict = window.floatingVerdict(config.floatingRuleBook, bundleID: bundleID,
                                             title: { _ in windowTitle })
        return FocusedWindowRuleInfo(
            windowID: id,
            appName: appName(window) ?? bundleID,
            bundleID: bundleID,
            title: windowTitle,
            currentRule: verdict.map(Self.describe),
            appFloats: config.excludedBundleIDs.contains(bundleID),
            appTiles: config.floatingRules.contains { $0.bundleID == bundleID && $0.match == nil && $0.action == .tile },
            isFloating: isFloating(id))
    }

    /// "Always float all <App> windows" or "Always tile all <App> windows".
    func setAppRule(_ id: CGWindowID, action: FloatingRule.Action) {
        guard let window = live(id), let bundleID = bundleID(window) else { return }
        if action == .tile, isSizeSettable(window) == false {
            refuse(window, Self.cannotTileMessage)
            hyprLog(.notice, .floating, "rule refused: tile for \(id), which is not resizable")
            return
        }
        clearManualChoice(id)
        config.addFloatingRule(FloatingRule(bundleID: bundleID, action: action))
        hyprLog(.notice, .floating, "rule added: \(action.rawValue) \(bundleID) all windows, for \(id)")
    }

    /// "Always float/tile windows titled …", from the title the user edited.
    func setTitleRule(_ id: CGWindowID, match: FloatingRule.Match, action: FloatingRule.Action) {
        guard let window = live(id), let bundleID = bundleID(window) else { return }
        if action == .tile, isSizeSettable(window) == false {
            refuse(window, Self.cannotTileMessage)
            hyprLog(.notice, .floating, "rule refused: tile for \(id), which is not resizable")
            return
        }
        let rule = FloatingRule(bundleID: bundleID, action: action, match: match)
        clearManualChoice(id)
        config.addFloatingRule(rule)
        hyprLog(.notice, .floating, "rule added: \(action.rawValue) \(bundleID) \(rule.matchDescription), for \(id)")
    }

    /// Remove the rule that decides this window: a title rule, the app's
    /// tile rule, or the app from Never tile.
    func forget(_ id: CGWindowID) {
        guard let window = live(id), let bundleID = bundleID(window) else { return }
        guard let verdict = window.floatingVerdict(config.floatingRuleBook, bundleID: bundleID,
                                                   title: title) else {
            refuse(window, Self.noRuleMessage)
            hyprLog(.notice, .floating, "rule forget: no rule covers \(id)")
            return
        }
        clearManualChoice(id)
        config.removeFloatingRule(decidedBy: verdict, bundleID: bundleID)
        hyprLog(.notice, .floating, "rule removed: \(bundleID) "
                + (verdict.rule.map { "\($0.action.rawValue) \($0.matchDescription)" } ?? "Never tile")
                + ", for \(id)")
    }

    private func live(_ id: CGWindowID) -> HyprWindow? {
        guard let window = window(id) else {
            hyprLog(.notice, .floating, "rule edit for \(id) dropped: the window is gone")
            return nil
        }
        if window.isQuickLookPanel {
            refuse(window, Self.quickLookMessage)
            hyprLog(.notice, .floating, "rule edit refused: \(id) is a quick look preview")
            return nil
        }
        return window
    }

    static func describe(_ verdict: FloatingRuleVerdict) -> String {
        guard let rule = verdict.rule else { return "Never tile: all windows" }
        let action = rule.action == .float ? "Always float" : "Always tile"
        return "\(action): \(rule.matchDescription.lowercasedFirst)"
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

extension HyprWindow {
    /// `floatingVerdict` with the reads injected, for callers that already
    /// have them or tests that fake them.
    func floatingVerdict(_ book: FloatingRuleBook, bundleID: String?,
                         title: @escaping (HyprWindow) -> String?) -> FloatingRuleVerdict? {
        book.verdict(bundleID: bundleID, title: { title(self) })
    }
}

/// Routes rule changes: an edit made on this Mac reaches the open windows,
/// a reload or a reset only moves the baseline the next edit is measured
/// from, so nothing open moves (as Never tile edits behaved before rules).
///
/// Both go through one `schedule`, a turn after the write, so they keep
/// their order and a Settings binding is not mid-update when windows move.
final class FloatingRuleSync {
    private var subscriptions: [AnyCancellable] = []

    init(config: UserConfig,
         schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         applyLocalEdit: @escaping () -> Void,
         rebase: @escaping () -> Void) {
        subscriptions = [
            config.floatingRulesEdited.sink { schedule(applyLocalEdit) },
            config.floatingRulesReloaded.sink { schedule(rebase) },
        ]
    }

    /// The open windows a rule edit is measured against. The cache holds
    /// only windows on visible workspaces, so a fresh walk adds the ones
    /// parked on hidden workspaces; a walk's newer element wins. Known
    /// windows only: one discovery hasn't admitted yet is admitted under the
    /// new rules anyway.
    static func windowsToReapply(cached: [HyprWindow], walked: [HyprWindow],
                                 known: Set<CGWindowID>) -> [HyprWindow] {
        var byID: [CGWindowID: HyprWindow] = [:]
        for window in cached + walked where known.contains(window.windowID) {
            byID[window.windowID] = window
        }
        return byID.keys.sorted().compactMap { byID[$0] }
    }
}
