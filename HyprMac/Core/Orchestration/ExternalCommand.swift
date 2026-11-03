// hyprmac:// links: the two status bar links (docs/status-bar.md) and
// `hyprmac://action/<name>` for other apps like BetterTouchTool
// (docs/external-control.md). Parsing only; WindowManager runs them.

import Cocoa

/// A `hyprmac://` link. Anything else, or a bad argument, is nil.
enum ExternalCommand: Equatable {
    /// `hyprmac://workspace?n=4`
    case workspace(Int)
    /// `hyprmac://focus?workspace=4`: switch there, or on a repeat call
    /// while already there, focus the next window of that workspace
    case focus(Int)
    /// `hyprmac://action/cycleWorkspace?delta=1`
    case action(Action)

    static func parse(_ url: URL) -> ExternalCommand? {
        guard url.scheme?.lowercased() == "hyprmac",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = parts.queryItems ?? []
        switch parts.host?.lowercased() {
        case "workspace":
            guard parts.path.isEmpty || parts.path == "/" else { return nil }
            return workspaceArgument("n", in: query).map(Self.workspace)
        case "focus":
            guard parts.path.isEmpty || parts.path == "/" else { return nil }
            return workspaceArgument("workspace", in: query).map(Self.focus)
        case "action":
            // exactly one path part, the action's name
            let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.count == 2, path[0].isEmpty,
                  let build = actionBuilders[path[1].lowercased()] else { return nil }
            return build(query).map(Self.action)
        default:
            return nil
        }
    }

    /// The names a link can run. Frozen once shipped, like the `Action`
    /// wire keys. These are the Swift case names, not the wire keys, so
    /// `switchWorkspace` is not the legacy `switchDesktop`.
    ///
    /// Left out on purpose: `runCommand`, `launchApp` and `saveLayout`. A web
    /// page can open a hyprmac:// link once the browser asks, so no link may
    /// run a program or overwrite saved state.
    static let actionNames: [String] = [
        "focusDirection", "swapDirection", "resizeDirection", "moveWindowToMonitor",
        "switchWorkspace", "moveToWorkspace", "moveToWorkspaceAndFollow",
        "cycleWorkspace",
        "toggleFloating", "toggleSplit", "showKeybinds", "showWorkspaceOverview",
        "focusMenuBar", "focusFloating", "moveToNextEmptyWorkspace", "closeWindow",
        "toggleScratchpad", "moveToScratchpad", "toggleTiling", "restoreLayout", "retileAll",
    ]

    private typealias Builder = ([URLQueryItem]) -> Action?

    // keyed by lowercased name
    private static let actionBuilders: [String: Builder] = {
        func direction(_ make: @escaping (Direction) -> Action) -> Builder {
            { query in single("dir", in: query).flatMap { Direction(rawValue: $0.lowercased()) }.map(make) }
        }
        func workspace(_ make: @escaping (Int) -> Action) -> Builder {
            { query in workspaceArgument("n", in: query).map(make) }
        }
        func plain(_ action: Action) -> Builder { { _ in action } }
        let builders: [String: Builder] = [
            "focusDirection": direction(Action.focusDirection),
            "swapDirection": direction(Action.swapDirection),
            "resizeDirection": direction(Action.resizeDirection),
            "moveWindowToMonitor": direction(Action.moveWindowToMonitor),
            "switchWorkspace": workspace(Action.switchWorkspace),
            "moveToWorkspace": workspace(Action.moveToWorkspace),
            "moveToWorkspaceAndFollow": workspace(Action.moveToWorkspaceAndFollow),
            "cycleWorkspace": { query in
                switch single("delta", in: query) {
                case "1": return .cycleWorkspace(1)
                case "-1": return .cycleWorkspace(-1)
                default: return nil
                }
            },
            "toggleFloating": plain(.toggleFloating),
            "toggleSplit": plain(.toggleSplit),
            "showKeybinds": plain(.showKeybinds),
            "showWorkspaceOverview": plain(.showWorkspaceOverview),
            "focusMenuBar": plain(.focusMenuBar),
            "focusFloating": plain(.focusFloating),
            "moveToNextEmptyWorkspace": plain(.moveToNextEmptyWorkspace),
            "closeWindow": plain(.closeWindow),
            "toggleScratchpad": plain(.toggleScratchpad),
            "moveToScratchpad": plain(.moveToScratchpad),
            "toggleTiling": plain(.toggleTiling),
            "restoreLayout": plain(.restoreLayout),
            "retileAll": plain(.retileAll),
        ]
        assert(Set(builders.keys) == Set(actionNames))
        return Dictionary(uniqueKeysWithValues: builders.map { ($0.key.lowercased(), $0.value) })
    }()

    // the one value of `key`, nil when missing or repeated
    private static func single(_ key: String, in query: [URLQueryItem]) -> String? {
        let values = query.filter { $0.name == key }
        guard values.count == 1 else { return nil }
        return values[0].value
    }

    // a whole number 1–10 in plain digits
    private static func workspaceArgument(_ key: String, in query: [URLQueryItem]) -> Int? {
        guard let raw = single(key, in: query),
              (1...2).contains(raw.count), raw.allSatisfy({ ("0"..."9").contains($0) }),
              let n = Int(raw), Constants.workspaceRange.contains(n) else { return nil }
        return n
    }

    /// The window a repeat `focus` call moves to: the one after the focused
    /// window on `workspace`, wrapping. nil when focus is not on a window of
    /// that workspace, and the call is an ordinary switch.
    static func nextFocusTarget(on workspace: Int, in snapshot: StatusSnapshot) -> CGWindowID? {
        guard snapshot.focusedWorkspace == workspace,
              let windows = snapshot.workspaces.first(where: { $0.id == workspace })?.windows,
              let index = windows.firstIndex(where: { $0.focused == true }) else { return nil }
        return windows[(index + 1) % windows.count].id
    }

    /// Which gate a command needs. The two status bar links also open with
    /// the status export on, so existing bar setups keep working.
    static func isAllowed(_ command: ExternalCommand, externalControl: Bool, statusExport: Bool) -> Bool {
        switch command {
        case .workspace, .focus: return externalControl || statusExport
        case .action: return externalControl
        }
    }
}
