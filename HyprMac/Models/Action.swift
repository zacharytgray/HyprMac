import Foundation

enum Direction: String, Codable {
    case left, right, up, down
}

enum Action: Equatable {
    case focusDirection(Direction)
    case swapDirection(Direction)
    case switchWorkspace(Int)
    case moveToWorkspace(Int)
    case moveWorkspaceToMonitor(Direction)  // move current workspace to adjacent monitor
    case toggleFloating
    case toggleSplit
    case showKeybinds
    case launchApp(bundleID: String)
    case focusMenuBar
    case focusFloating
    case closeWindow
    case cycleWorkspace(Int)  // +1 = next occupied, -1 = prev occupied (on current monitor)
}

// MARK: - Codable

// custom Codable preserving the v0.4.2 wire format byte-for-byte. the
// synthesized format (which user configs were written with) puts the case
// name at the outer key and the associated value under "_0" (or the
// parameter label for named associated values).
//
// JSON case keys are frozen at "switchDesktop" / "moveToDesktop" forever
// per §5.6 — the in-code rename to switchWorkspace / moveToWorkspace is
// purely internal. the decoder accepts both old and new alias names so a
// hand-edited config using the new spelling still loads; the encoder
// always writes the canonical (old) keys so user configs never see
// noisy churn.

extension Action: Codable {

    // CaseKey rawValues are the JSON wire-format keys, frozen at the v0.4.2
    // names — switchWorkspace/moveToWorkspace deliberately encode under their
    // legacy "switchDesktop"/"moveToDesktop" keys forever per §5.6.
    private enum CaseKey: String, CodingKey {
        case focusDirection
        case swapDirection
        case switchWorkspace        = "switchDesktop"
        case moveToWorkspace        = "moveToDesktop"
        case moveWorkspaceToMonitor
        case toggleFloating
        case toggleSplit
        case showKeybinds
        case launchApp
        case focusMenuBar
        case focusFloating
        case closeWindow
        case cycleWorkspace
    }

    // accepted-but-not-emitted aliases. lets a hand-edited config using the
    // new in-code spellings still decode; the encoder always writes the
    // canonical (legacy) key from CaseKey.rawValue.
    private static let aliases: [String: CaseKey] = [
        "switchWorkspace": .switchWorkspace,
        "moveToWorkspace": .moveToWorkspace,
    ]

    private enum PayloadKey: String, CodingKey {
        case _0
        case bundleID
    }

    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: AnyKey.self)
        guard let raw = outer.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Action: empty container, no case key"))
        }
        let resolved: CaseKey
        if let direct = CaseKey(stringValue: raw.stringValue) {
            resolved = direct
        } else if let aliased = Self.aliases[raw.stringValue] {
            resolved = aliased
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: raw, in: outer,
                debugDescription: "Action: unknown case key '\(raw.stringValue)'")
        }
        let inner = try outer.nestedContainer(keyedBy: PayloadKey.self, forKey: raw)

        switch resolved {
        case .focusDirection:
            self = .focusDirection(try Self.decodeDirection(inner, field: "focusDirection"))
        case .swapDirection:
            self = .swapDirection(try Self.decodeDirection(inner, field: "swapDirection"))
        case .moveWorkspaceToMonitor:
            self = .moveWorkspaceToMonitor(try Self.decodeDirection(inner, field: "moveWorkspaceToMonitor"))
        case .switchWorkspace:
            self = .switchWorkspace(try inner.decode(Int.self, forKey: ._0))
        case .moveToWorkspace:
            self = .moveToWorkspace(try inner.decode(Int.self, forKey: ._0))
        case .cycleWorkspace:
            self = .cycleWorkspace(try inner.decode(Int.self, forKey: ._0))
        case .launchApp:
            self = .launchApp(bundleID: try inner.decode(String.self, forKey: .bundleID))
        case .toggleFloating: self = .toggleFloating
        case .toggleSplit:    self = .toggleSplit
        case .showKeybinds:   self = .showKeybinds
        case .focusMenuBar:   self = .focusMenuBar
        case .focusFloating:  self = .focusFloating
        case .closeWindow:    self = .closeWindow
        }
    }

    // malformed direction strings used to crash via Direction(rawValue:)!.
    // log + fall back to .right (a neutral default) so a typo doesn't take
    // down the app.
    private static func decodeDirection(_ c: KeyedDecodingContainer<PayloadKey>,
                                        field: String) throws -> Direction {
        let raw = try c.decode(String.self, forKey: ._0)
        if let d = Direction(rawValue: raw) { return d }
        hyprLog(.warning, .config,
                "malformed direction '\(raw)' in \(field); falling back to .right")
        return .right
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CaseKey.self)
        switch self {
        case .focusDirection(let d):
            var p = c.nestedContainer(keyedBy: PayloadKey.self, forKey: .focusDirection)
            try p.encode(d.rawValue, forKey: ._0)
        case .swapDirection(let d):
            var p = c.nestedContainer(keyedBy: PayloadKey.self, forKey: .swapDirection)
            try p.encode(d.rawValue, forKey: ._0)
        case .moveWorkspaceToMonitor(let d):
            var p = c.nestedContainer(keyedBy: PayloadKey.self, forKey: .moveWorkspaceToMonitor)
            try p.encode(d.rawValue, forKey: ._0)
        case .switchWorkspace(let n):
            var p = c.nestedContainer(keyedBy: PayloadKey.self, forKey: .switchWorkspace)
            try p.encode(n, forKey: ._0)
        case .moveToWorkspace(let n):
            var p = c.nestedContainer(keyedBy: PayloadKey.self, forKey: .moveToWorkspace)
            try p.encode(n, forKey: ._0)
        case .cycleWorkspace(let n):
            var p = c.nestedContainer(keyedBy: PayloadKey.self, forKey: .cycleWorkspace)
            try p.encode(n, forKey: ._0)
        case .launchApp(let b):
            var p = c.nestedContainer(keyedBy: PayloadKey.self, forKey: .launchApp)
            try p.encode(b, forKey: .bundleID)
        case .toggleFloating:
            _ = c.nestedContainer(keyedBy: PayloadKey.self, forKey: .toggleFloating)
        case .toggleSplit:
            _ = c.nestedContainer(keyedBy: PayloadKey.self, forKey: .toggleSplit)
        case .showKeybinds:
            _ = c.nestedContainer(keyedBy: PayloadKey.self, forKey: .showKeybinds)
        case .focusMenuBar:
            _ = c.nestedContainer(keyedBy: PayloadKey.self, forKey: .focusMenuBar)
        case .focusFloating:
            _ = c.nestedContainer(keyedBy: PayloadKey.self, forKey: .focusFloating)
        case .closeWindow:
            _ = c.nestedContainer(keyedBy: PayloadKey.self, forKey: .closeWindow)
        }
    }
}

// dynamic key for reading the action's outer case-name key without
// pre-declaring every accepted alias as a CodingKey case.
private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
