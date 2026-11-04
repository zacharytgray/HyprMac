// Per-display-configuration layout persistence. Saves the BSP tree
// shape of every regular workspace — not window frames — keyed by a
// fingerprint of the connected displays. Saved by the user
// (`Hypr+Ctrl+S`), automatically on the first notification of a
// display change, and restored on demand (`Hypr+Ctrl+R`), when a known
// display configuration returns, or at launch when
// `restoreLayoutOnLaunch` is on.
//
// The store never touches a tree. `LayoutRestorer.capture` gathers what
// `TilingEngine.layoutTree` serialises, `WindowManager` hands the result to
// the store, and `LayoutRestorer` matches, moves and rebuilds on the way back.

import Cocoa

/// Identity of a tiled window that survives an app restart. CGWindowIDs
/// don't; bundle ID plus title is the most stable pair AX exposes. Two
/// windows can share a ref (two "zsh" Terminals) — `LayoutMatcher`
/// hands each leaf its own window.
struct SavedWindowRef: Codable, Hashable {
    let bundleID: String
    let title: String
}

extension SavedWindowRef {
    /// Terminal ends its titles with the window size ("zsh — 120×30"),
    /// which changes on every retile. Drop it so a resized window still
    /// matches its saved leaf exactly.
    static func normalizedTitle(_ title: String) -> String {
        guard let range = title.range(of: #"\s—\s\d+×\d+$"#, options: .regularExpression) else { return title }
        return String(title[..<range.lowerBound])
    }
}

/// Serialised BSP subtree. Mirrors `BSPNode` field for field so a
/// restore reproduces the saved tree exactly — including a `nil`
/// override where dwindle picked the axis from the rect, which a
/// resolved direction would wrongly freeze.
indirect enum LayoutNode: Equatable {
    case leaf(SavedWindowRef)
    case split(override: SplitDirection?, ratio: CGFloat, userSet: Bool,
               left: LayoutNode, right: LayoutNode)

    /// Every leaf, left-to-right (depth-first).
    var leaves: [SavedWindowRef] {
        switch self {
        case .leaf(let ref):
            return [ref]
        case .split(_, _, _, let left, let right):
            return left.leaves + right.leaves
        }
    }
}

extension LayoutNode: Codable {
    // frozen wire keys — same discipline as `Action`
    private enum CaseKey: String, CodingKey { case leaf, split }
    private enum SplitKey: String, CodingKey { case override, ratio, userSet, left, right }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CaseKey.self)
        if let ref = try c.decodeIfPresent(SavedWindowRef.self, forKey: .leaf) {
            self = .leaf(ref)
            return
        }
        let s = try c.nestedContainer(keyedBy: SplitKey.self, forKey: .split)
        let override = try s.decodeIfPresent(SplitDirection.self, forKey: .override)
        let ratio = try s.decode(CGFloat.self, forKey: .ratio)
        let userSet = try s.decode(Bool.self, forKey: .userSet)
        let left = try s.decode(LayoutNode.self, forKey: .left)
        let right = try s.decode(LayoutNode.self, forKey: .right)
        self = .split(override: override, ratio: ratio, userSet: userSet, left: left, right: right)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CaseKey.self)
        switch self {
        case .leaf(let ref):
            try c.encode(ref, forKey: .leaf)
        case .split(let override, let ratio, let userSet, let left, let right):
            var s = c.nestedContainer(keyedBy: SplitKey.self, forKey: .split)
            try s.encodeIfPresent(override, forKey: .override)
            try s.encode(ratio, forKey: .ratio)
            try s.encode(userSet, forKey: .userSet)
            try s.encode(left, forKey: .left)
            try s.encode(right, forKey: .right)
        }
    }
}

/// One regular workspace's tree. The screen is not stored: under the
/// same display key the workspace's static home is the same screen.
struct WorkspaceLayout: Codable, Equatable {
    let workspace: Int
    /// `nil` when none of the workspace's windows has joined its tree yet
    let root: LayoutNode?
    /// windows on the workspace that are not in its tree yet. a window sent
    /// to a hidden workspace joins the tree only when the workspace is shown.
    var unplaced: [SavedWindowRef] = []

    /// every saved window on the workspace, tree leaves first
    var refs: [SavedWindowRef] { (root?.leaves ?? []) + unplaced }

    init(workspace: Int, root: LayoutNode?, unplaced: [SavedWindowRef] = []) {
        self.workspace = workspace
        self.root = root
        self.unplaced = unplaced
    }

    private enum CodingKeys: String, CodingKey { case workspace, root, unplaced }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspace = try c.decode(Int.self, forKey: .workspace)
        root = try c.decodeIfPresent(LayoutNode.self, forKey: .root)
        unplaced = try c.decodeIfPresent([SavedWindowRef].self, forKey: .unplaced) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(workspace, forKey: .workspace)
        try c.encodeIfPresent(root, forKey: .root)
        if !unplaced.isEmpty { try c.encode(unplaced, forKey: .unplaced) }
    }
}

/// A frozen layout for one display configuration.
struct LayoutSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let displayKey: String
    let timestamp: Date
    let isManual: Bool
    let workspaces: [WorkspaceLayout]
}

/// Persistence for display-keyed layout snapshots.
///
/// One snapshot per display key. Manual saves are never overwritten by
/// automatic ones and are the last to be pruned. All file I/O goes
/// through `fileURL`, injected so tests run against a temp file; the
/// shared instance uses
/// `~/Library/Application Support/HyprMac/layout-snapshots.json`.
///
/// Display keys are monitor name plus size only. Two setups with the
/// same monitors at the same sizes share one key, whatever their
/// arrangement or position, and so do two physical monitors of the
/// same model. They save over and restore from the same snapshot.
///
/// The file is plain JSON on this Mac and holds each tiled window's
/// raw title (document names, page titles, terminal commands). Nothing
/// leaves the machine. To clear every snapshot, quit HyprMac and delete
/// the file (and any `.unreadable` copy next to it); a new one is
/// written on the next save.
///
/// A save only reports success after the atomic write lands; on a
/// failed write it throws and memory is rolled back to match the disk.
/// Entries this build can't read (a newer schema) are kept verbatim
/// when the file is rewritten. A file that can't be parsed at all is
/// moved aside to `layout-snapshots.json.unreadable` on load.
///
/// Threading: main-thread only.
final class LayoutSnapshotStore {

    static let shared = LayoutSnapshotStore(fileURL: defaultFileURL)

    static let maxSnapshots = 10

    static var defaultFileURL: URL {
        ConfigStore.configDir.appendingPathComponent("layout-snapshots.json")
    }

    let fileURL: URL

    /// Every snapshot on disk, keyed by display fingerprint.
    private(set) var snapshots: [String: LayoutSnapshot] = [:]

    /// Raw JSON of entries this build can't decode, written back as-is.
    private var unreadable: [String: Any] = [:]

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - display fingerprint

    /// Deterministic key for the current monitor topology. Sorted by
    /// name so the order is stable across `NSScreen.screens` shuffles.
    static func displayKey(screens: [NSScreen]) -> String {
        screens
            .map { "\($0.localizedName):\(Int($0.frame.width))x\(Int($0.frame.height))" }
            .sorted()
            .joined(separator: "|")
    }

    // MARK: - save

    /// Store `workspaces` under `displayKey`. An automatic save never
    /// replaces a manual one.
    ///
    /// - Returns: `false` when an automatic save was skipped: a manual or
    ///   unreadable snapshot holds the key, or manual snapshots fill every slot.
    /// - Throws: the write error. Memory is left as it was before the call.
    @discardableResult
    func save(displayKey: String, workspaces: [WorkspaceLayout], manual: Bool) throws -> Bool {
        if !manual, let existing = snapshots[displayKey], existing.isManual {
            hyprLog(.debug, .lifecycle, "layout auto-save skipped — manual snapshot exists for '\(displayKey)'")
            return false
        }
        // an entry this build can't read may be a newer build's manual save
        if !manual, unreadable[displayKey] != nil {
            hyprLog(.debug, .lifecycle, "layout auto-save skipped — unreadable snapshot kept for '\(displayKey)'")
            return false
        }
        let previous = (snapshots, unreadable)
        // whole seconds, since iso8601 on disk drops the rest
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        snapshots[displayKey] = LayoutSnapshot(
            schemaVersion: LayoutSnapshot.currentSchemaVersion,
            displayKey: displayKey,
            timestamp: now,
            isManual: manual,
            workspaces: workspaces
        )
        unreadable[displayKey] = nil
        pruneOldest()
        // every slot held by a manual snapshot: pruning took this auto-save
        guard snapshots[displayKey] != nil else {
            (snapshots, unreadable) = previous
            hyprLog(.debug, .lifecycle, "layout auto-save skipped — no room beside manual snapshots for '\(displayKey)'")
            return false
        }
        do {
            try persist()
        } catch {
            (snapshots, unreadable) = previous
            hyprLog(.warning, .lifecycle, "layout snapshot not written for '\(displayKey)': \(error)")
            throw error
        }
        let windows = workspaces.reduce(0) { $0 + $1.refs.count }
        hyprLog(.notice, .lifecycle,
                "layout \(manual ? "saved" : "auto-saved"): \(workspaces.count) workspaces, \(windows) windows for '\(displayKey)'")
        return true
    }

    // MARK: - restore

    func snapshot(for displayKey: String) -> LayoutSnapshot? {
        snapshots[displayKey]
    }

    // MARK: - pruning

    /// Evict down to `maxSnapshots`: oldest automatic snapshots first,
    /// manual ones only once no automatic snapshot is left.
    private func pruneOldest() {
        while snapshots.count > Self.maxSnapshots {
            let automatic = snapshots.filter { !$0.value.isManual }
            let pool = automatic.isEmpty ? snapshots : automatic
            // timestamps are whole seconds, so ties fall back to the key
            guard let oldest = pool.min(by: {
                ($0.value.timestamp, $0.key) < ($1.value.timestamp, $1.key)
            }) else { break }
            snapshots.removeValue(forKey: oldest.key)
            hyprLog(.debug, .lifecycle, "pruned layout snapshot '\(oldest.key)' (manual=\(oldest.value.isManual))")
        }
    }

    // MARK: - persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            moveAside()
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for (key, value) in raw {
            // a newer schema or a shape this build doesn't know is kept
            // raw rather than guessed at, so a downgrade doesn't eat it
            if let entry = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
               let snap = try? decoder.decode(LayoutSnapshot.self, from: entry),
               snap.schemaVersion == LayoutSnapshot.currentSchemaVersion {
                snapshots[key] = snap
            } else {
                unreadable[key] = value
            }
        }
        hyprLog(.debug, .lifecycle,
                "layout snapshots loaded: \(snapshots.count) configs"
                + (unreadable.isEmpty ? "" : " (\(unreadable.count) kept unread: schema mismatch)"))
    }

    /// Keep a file we can't parse instead of overwriting it on the next save.
    private func moveAside() {
        let aside = URL(fileURLWithPath: fileURL.path + ".unreadable")
        try? FileManager.default.removeItem(at: aside)
        do {
            try FileManager.default.moveItem(at: fileURL, to: aside)
            hyprLog(.warning, .lifecycle, "layout snapshots unreadable, moved to \(aside.lastPathComponent)")
        } catch {
            hyprLog(.warning, .lifecycle, "layout snapshots unreadable and not moved aside: \(error)")
        }
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var raw = try JSONSerialization.jsonObject(with: encoder.encode(snapshots)) as? [String: Any] ?? [:]
        for (key, value) in unreadable where raw[key] == nil { raw[key] = value }
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fileURL, options: .atomic)
    }
}
