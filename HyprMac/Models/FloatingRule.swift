// Float and tile rules: the user's word on whether an app, or one kind of
// window inside it, floats or tiles. Plain values in and out, so tests drive
// the precedence without live AX.

import Foundation

/// One rule. With no `match` it covers the whole app; with one, only the
/// app's windows that match it.
///
/// An app's "Always float" is not stored here: it stays in
/// `excludedBundleIDs`, the list Never tile has always used, so configs and
/// Nix modules that set it keep working unchanged. A hand-written app float
/// rule here means the same thing.
struct FloatingRule: Codable, Equatable, Hashable, Identifiable {
    enum Action: String, Codable, CaseIterable {
        case float, tile
    }

    /// Which windows of the app a rule covers. One criterion per rule.
    enum Match: Equatable, Hashable {
        /// the title, exactly
        case titleIs(String)
        /// the title contains this text, ignoring case
        case titleContains(String)
        /// the window sits above normal windows (CG layer above 0): a
        /// picture-in-picture, a call pop-up, a mini player
        case raised
    }

    let bundleID: String
    var action: Action
    var match: Match?

    var id: String { "\(bundleID)|\(match.map(Self.key) ?? "app")" }

    /// Whether `match` covers a window with this title and layer. `isRaised`
    /// is asked only for a `.raised` rule: it costs a window-list read.
    static func matches(_ match: Match, title: String?, isRaised: () -> Bool) -> Bool {
        switch match {
        case let .titleIs(text):
            return title == text
        case let .titleContains(text):
            guard let title, !text.isEmpty else { return false }
            return title.range(of: text, options: .caseInsensitive) != nil
        case .raised:
            return isRaised()
        }
    }

    private static func key(_ match: Match) -> String {
        switch match {
        case let .titleIs(text): return "titleIs:\(text)"
        case let .titleContains(text): return "titleContains:\(text)"
        case .raised: return "raised"
        }
    }
}

// MARK: - wire format

// {"bundleID":"us.zoom.xos","action":"float","match":{"titleIs":"Zoom Meeting"}}
// {"bundleID":"com.apple.FaceTime","action":"float","match":{"raised":true}}
// {"bundleID":"com.apple.FaceTime","action":"tile"}
//
// a match with no known criterion, two criteria, empty text or raised:false
// throws, and so does "match": null, so the tolerant config decoder drops
// that one rule instead of reading it as a whole-app rule.
extension FloatingRule.Match: Codable {
    private enum Key: String, CodingKey {
        case titleIs, titleContains, raised
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let keys = c.allKeys
        guard keys.count == 1, let key = keys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "match needs exactly one criterion"))
        }
        switch key {
        case .titleIs, .titleContains:
            let text = try c.decode(String.self, forKey: key)
            guard !text.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "empty title")
            }
            self = key == .titleIs ? .titleIs(text) : .titleContains(text)
        case .raised:
            guard try c.decode(Bool.self, forKey: .raised) else {
                throw DecodingError.dataCorruptedError(forKey: .raised, in: c,
                                                       debugDescription: "raised must be true")
            }
            self = .raised
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case let .titleIs(text): try c.encode(text, forKey: .titleIs)
        case let .titleContains(text): try c.encode(text, forKey: .titleContains)
        case .raised: try c.encode(true, forKey: .raised)
        }
    }
}

extension FloatingRule {
    private enum CodingKeys: String, CodingKey {
        case bundleID, action, match
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let bundleID = try c.decode(String.self, forKey: .bundleID)
        guard !bundleID.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .bundleID, in: c, debugDescription: "empty bundle id")
        }
        self.bundleID = bundleID
        self.action = try c.decode(Action.self, forKey: .action)
        // "match": null is a bad match, not a whole-app rule: a Nix
        // `match = null` must not widen a window rule to the app
        if c.contains(.match), try c.decodeNil(forKey: .match) {
            throw DecodingError.dataCorruptedError(forKey: .match, in: c, debugDescription: "null match")
        }
        self.match = try c.decodeIfPresent(Match.self, forKey: .match)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bundleID, forKey: .bundleID)
        try c.encode(action, forKey: .action)
        try c.encodeIfPresent(match, forKey: .match)
    }
}

// MARK: - precedence

/// What the rules say about one window, and which rule said it.
enum FloatingRuleVerdict: Equatable {
    /// floats. `rule` is nil when the app is in `excludedBundleIDs`
    case float(FloatingRule?)
    case tile(FloatingRule)

    var floats: Bool {
        if case .float = self { return true }
        return false
    }

    /// The rule that decided, as Settings and the menu name it. nil for the
    /// plain app float, which lives in `excludedBundleIDs`.
    var rule: FloatingRule? {
        switch self {
        case let .float(rule): return rule
        case let .tile(rule): return rule
        }
    }

    /// true when a window-kind rule decided, false for an app rule
    var isWindowKind: Bool { rule?.match != nil }
}

/// Every float and tile rule, read together.
///
/// Precedence, highest first: a window-kind rule (first match in list
/// order), then the app's rule, then nothing (HyprMac's automatic logic
/// decides). For the app rule, an app in `excludedBundleIDs` floats even if
/// a hand edit also gave it an app tile rule: that is what it did before
/// tile rules existed.
struct FloatingRuleBook: Equatable {
    var rules: [FloatingRule] = []
    var excludedBundleIDs: Set<String> = []

    static let empty = FloatingRuleBook()

    /// `title` and `isRaised` are live reads: each is asked once at most,
    /// and only when one of the app's rules needs it.
    func verdict(bundleID: String?, title: () -> String?, isRaised: () -> Bool) -> FloatingRuleVerdict? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        var readTitle: String??
        var readRaised: Bool?
        let raised: () -> Bool = {
            if let readRaised { return readRaised }
            let value = isRaised()
            readRaised = value
            return value
        }
        for rule in rules where rule.bundleID == bundleID {
            guard let match = rule.match else { continue }
            if match != .raised, readTitle == nil { readTitle = .some(title()) }
            guard FloatingRule.matches(match, title: readTitle ?? nil, isRaised: raised) else { continue }
            return rule.action == .float ? .float(rule) : .tile(rule)
        }
        if excludedBundleIDs.contains(bundleID) { return .float(nil) }
        if let appRule = rules.first(where: { $0.bundleID == bundleID && $0.match == nil }) {
            return appRule.action == .float ? .float(appRule) : .tile(appRule)
        }
        return nil
    }

    /// Whether the app has a rule a title can decide, so a window whose
    /// title arrives late is worth asking again.
    func hasTitleRules(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return rules.contains { rule in
            guard rule.bundleID == bundleID, let match = rule.match else { return false }
            if case .raised = match { return false }
            return true
        }
    }
}

// MARK: - one-click capture

extension FloatingRule {
    /// The rule "windows like this" makes from the focused window. A window
    /// above normal windows is matched by that, since pop-ups often share
    /// the main window's title. Otherwise its exact title, which Settings
    /// can loosen to "contains". nil when nothing tells the window apart:
    /// no title and a normal layer.
    static func capture(bundleID: String?, title: String?, isRaised: Bool,
                        action: Action) -> FloatingRule? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if isRaised { return FloatingRule(bundleID: bundleID, action: action, match: .raised) }
        guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return FloatingRule(bundleID: bundleID, action: action, match: .titleIs(title))
    }

    /// `rule` added to `rules`: it replaces any rule for the same app and
    /// the same windows, whatever that one's action. A new one goes ahead
    /// of the app's other rules, so the newest choice wins where two match.
    static func upserting(_ rule: FloatingRule, into rules: [FloatingRule]) -> [FloatingRule] {
        var out = rules
        if let index = out.firstIndex(where: { $0.bundleID == rule.bundleID && $0.match == rule.match }) {
            out[index] = rule
        } else if let first = out.firstIndex(where: { $0.bundleID == rule.bundleID }) {
            out.insert(rule, at: first)
        } else {
            out.append(rule)
        }
        return out
    }

    /// Which windows it covers, in words for Settings and the menu.
    var matchDescription: String {
        switch match {
        case nil: return "All windows"
        case let .titleIs(text)?: return "Windows titled “\(text)”"
        case let .titleContains(text)?: return "Windows with “\(text)” in the title"
        case .raised?: return "Windows that stay on top"
        }
    }
}

// MARK: - config edits

extension UserConfig {
    var floatingRuleBook: FloatingRuleBook {
        FloatingRuleBook(rules: floatingRules, excludedBundleIDs: excludedBundleIDs)
    }

    /// Add `rule`, replacing any rule for the same app and windows. An app
    /// float goes to `excludedBundleIDs`, where Never tile always lived; an
    /// app tile takes the app out of it, so the two never disagree.
    func addFloatingRule(_ rule: FloatingRule) {
        if rule.match == nil {
            if rule.action == .float {
                if floatingRules.contains(where: { $0.bundleID == rule.bundleID && $0.match == nil }) {
                    floatingRules.removeAll { $0.bundleID == rule.bundleID && $0.match == nil }
                }
                excludedBundleIDs.insert(rule.bundleID)
                return
            }
            if excludedBundleIDs.contains(rule.bundleID) {
                excludedBundleIDs.remove(rule.bundleID)
            }
        }
        let updated = FloatingRule.upserting(rule, into: floatingRules)
        if updated != floatingRules { floatingRules = updated }
    }

    /// Put `new` where `old` was, keeping its place in the order. An edit
    /// that now matches the same windows as another rule of the app replaces
    /// that one.
    func replaceFloatingRule(_ old: FloatingRule, with new: FloatingRule) {
        guard old != new else { return }
        if new.match == nil {
            floatingRules.removeAll { $0 == old }
            addFloatingRule(new)
            return
        }
        var rules = floatingRules.filter { $0 == old || !($0.bundleID == new.bundleID && $0.match == new.match) }
        if let index = rules.firstIndex(of: old) {
            rules[index] = new
        } else {
            rules = FloatingRule.upserting(new, into: rules)
        }
        floatingRules = rules
    }

    /// Settings' "Always float an app" and the menu's "Always float all
    /// <App> windows": Never tile for the app, and its app tile rule gone.
    func addAlwaysFloatApp(_ bundleID: String) {
        addFloatingRule(FloatingRule(bundleID: bundleID, action: .float))
    }

    /// Remove the rule a verdict named: a window-kind or app rule from
    /// `floatingRules`, or the app from `excludedBundleIDs` when that list
    /// decided.
    func removeFloatingRule(decidedBy verdict: FloatingRuleVerdict, bundleID: String) {
        if let rule = verdict.rule {
            floatingRules.removeAll { $0 == rule }
        } else {
            excludedBundleIDs.remove(bundleID)
        }
    }
}

// MARK: - Settings rows

/// One row of the Settings rule list: an app in Never tile, or a rule.
struct FloatingRuleRow: Identifiable, Equatable {
    enum Source: Equatable {
        /// the app is in `excludedBundleIDs`
        case neverTile
        case rule(FloatingRule)
    }

    let bundleID: String
    let source: Source

    var id: String {
        switch source {
        case .neverTile: return "\(bundleID)|neverTile"
        case let .rule(rule): return rule.id
        }
    }

    var action: FloatingRule.Action {
        if case let .rule(rule) = source { return rule.action }
        return .float
    }

    var matchDescription: String {
        if case let .rule(rule) = source { return rule.matchDescription }
        return "All windows"
    }

    /// Every row, grouped by app in bundle id order: the app's own rule
    /// first, then its window rules in the order they are asked.
    static func rows(excludedBundleIDs: Set<String>, rules: [FloatingRule]) -> [FloatingRuleRow] {
        let apps = Set(rules.map(\.bundleID)).union(excludedBundleIDs).sorted()
        return apps.flatMap { bundleID -> [FloatingRuleRow] in
            var out: [FloatingRuleRow] = []
            if excludedBundleIDs.contains(bundleID) {
                out.append(FloatingRuleRow(bundleID: bundleID, source: .neverTile))
            }
            let own = rules.filter { $0.bundleID == bundleID }
            out += own.filter { $0.match == nil }.map { FloatingRuleRow(bundleID: bundleID, source: .rule($0)) }
            out += own.filter { $0.match != nil }.map { FloatingRuleRow(bundleID: bundleID, source: .rule($0)) }
            return out
        }
    }
}

extension UserConfig {
    /// Settings' Float/Tile switch on one row.
    func setAction(_ action: FloatingRule.Action, for row: FloatingRuleRow) {
        guard action != row.action else { return }
        switch row.source {
        case .neverTile:
            addFloatingRule(FloatingRule(bundleID: row.bundleID, action: action))
        case let .rule(rule):
            var changed = rule
            changed.action = action
            replaceFloatingRule(rule, with: changed)
        }
    }

    /// Settings' remove button on one row.
    func remove(_ row: FloatingRuleRow) {
        switch row.source {
        case .neverTile: excludedBundleIDs.remove(row.bundleID)
        case let .rule(rule): floatingRules.removeAll { $0 == rule }
        }
    }
}
