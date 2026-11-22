// The float and tile rule actions on the focused window, and what the menu
// bar shows about it. Edits the config only: WindowManager watches the rule
// lists and re-applies a change to the open windows it touches.

import Cocoa

/// What the menu bar's "Focused window" section shows.
struct FocusedWindowRuleInfo: Equatable {
    let windowID: CGWindowID
    let appName: String
    let bundleID: String
    /// what "windows like this" would match, nil when nothing tells this
    /// window apart (no title, normal layer)
    let likeThis: String?
    /// the rule deciding this window now, in words; nil when none does
    let currentRule: String?
    /// whether the whole app floats already (Never tile)
    let appFloats: Bool
}

/// Runs `floatWindowsLikeThis`, `tileWindowsLikeThis` and
/// `forgetWindowRule`, plus the menu's "always float the whole app".
///
/// A refusal gets the red shake and one notice line, like Toggle Floating:
/// a Quick Look preview, a window nothing tells apart, a tile rule for a
/// window HyprMac can't resize, a forget with no rule to forget.
///
/// Threading: main-thread only.
final class FloatingRuleCommands {
    private let config: UserConfig

    var focusedWindow: () -> HyprWindow? = { nil }
    /// red shake around the window, with this text
    var refuse: (HyprWindow, String) -> Void = { _, _ in }
    var bundleID: (HyprWindow) -> String? = {
        $0.bundleID ?? NSRunningApplication(processIdentifier: $0.ownerPID)?.bundleIdentifier
    }
    var appName: (HyprWindow) -> String? = {
        NSRunningApplication(processIdentifier: $0.ownerPID)?.localizedName
    }
    var title: (HyprWindow) -> String? = { $0.title }
    var isRaised: (HyprWindow) -> Bool = { $0.isAboveNormalLayer }
    var isSizeSettable: (HyprWindow) -> Bool? = { $0.isSizeSettable }

    static let nothingToMatchMessage = "Nothing tells this window apart. Use an app rule in Settings"
    static let noRuleMessage = "No rule covers this window"
    static let cannotTileMessage = "This window cannot be tiled"
    static let quickLookMessage = "Quick Look previews stay floating"

    init(config: UserConfig) {
        self.config = config
    }

    func perform(_ action: Action) {
        guard let window = focusedWindow() else {
            hyprLog(.notice, .floating, "rule action \(ActionDispatcher.discriminator(for: action)): no focused window")
            return
        }
        switch action {
        case .floatWindowsLikeThis: addLikeThis(window, action: .float)
        case .tileWindowsLikeThis: addLikeThis(window, action: .tile)
        case .forgetWindowRule: forget(window)
        default: break
        }
    }

    /// The menu's "Always float all <App> windows".
    func floatFocusedApp() {
        guard let window = focusedWindow(), let bundleID = bundleID(window) else { return }
        config.addFloatingRule(FloatingRule(bundleID: bundleID, action: .float))
        hyprLog(.notice, .floating, "rule added: float \(bundleID) all windows, from \(window.windowID)")
    }

    private func addLikeThis(_ window: HyprWindow, action: FloatingRule.Action) {
        if window.isQuickLookPanel {
            refuse(window, Self.quickLookMessage)
            hyprLog(.notice, .floating, "rule refused: \(window.windowID) is a quick look preview")
            return
        }
        guard let rule = FloatingRule.capture(bundleID: bundleID(window), title: title(window),
                                              isRaised: isRaised(window), action: action) else {
            refuse(window, Self.nothingToMatchMessage)
            hyprLog(.notice, .floating, "rule refused: \(window.windowID) has no title and sits on the normal layer")
            return
        }
        // same failure as Toggle Floating: a rule can't make this one tile
        if action == .tile, isSizeSettable(window) == false {
            refuse(window, Self.cannotTileMessage)
            hyprLog(.notice, .floating, "rule refused: tile for \(window.windowID), which is not resizable")
            return
        }
        config.addFloatingRule(rule)
        hyprLog(.notice, .floating, "rule added: \(rule.action.rawValue) \(rule.bundleID)"
                + " \(rule.matchDescription), from \(window.windowID)")
    }

    private func forget(_ window: HyprWindow) {
        guard let bundleID = bundleID(window),
              let verdict = window.floatingVerdict(config.floatingRuleBook, bundleID: bundleID,
                                                   title: title, isRaised: isRaised) else {
            refuse(window, Self.noRuleMessage)
            hyprLog(.notice, .floating, "rule forget: no rule covers \(window.windowID)")
            return
        }
        config.removeFloatingRule(decidedBy: verdict, bundleID: bundleID)
        hyprLog(.notice, .floating, "rule removed: \(bundleID) "
                + (verdict.rule.map { "\($0.action.rawValue) \($0.matchDescription)" } ?? "Never tile")
                + ", from \(window.windowID)")
    }

    /// The focused window as the menu describes it, nil with none.
    func focusedInfo() -> FocusedWindowRuleInfo? {
        guard let window = focusedWindow(), let bundleID = bundleID(window) else { return nil }
        let raised = isRaised(window)
        let windowTitle = title(window)
        let likeThis = window.isQuickLookPanel ? nil
            : FloatingRule.capture(bundleID: bundleID, title: windowTitle, isRaised: raised, action: .float)
        let verdict = window.floatingVerdict(config.floatingRuleBook, bundleID: bundleID,
                                             title: { _ in windowTitle }, isRaised: { _ in raised })
        return FocusedWindowRuleInfo(
            windowID: window.windowID,
            appName: appName(window) ?? bundleID,
            bundleID: bundleID,
            likeThis: likeThis?.matchDescription,
            currentRule: verdict.map(Self.describe),
            appFloats: config.excludedBundleIDs.contains(bundleID))
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
                         title: @escaping (HyprWindow) -> String?,
                         isRaised: @escaping (HyprWindow) -> Bool) -> FloatingRuleVerdict? {
        book.verdict(bundleID: bundleID, title: { title(self) }, isRaised: { isRaised(self) })
    }
}
