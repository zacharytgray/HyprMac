// Per-display-configuration layout persistence. Saves the BSP tree
// shape of every regular workspace — not window frames — keyed by a
// fingerprint of the connected displays. Saved by the user
// (`Hypr+Ctrl+S`), automatically on the first notification of a
// display change, and restored on demand (`Hypr+Ctrl+R`), when a known
// display configuration returns, or at launch when
// `restoreLayoutOnLaunch` is on.
//
// The store never touches a tree. `TilingEngine.layoutTree` serialises,
// `LayoutMatcher` pairs saved leaves with live windows, and
// `WindowManager` moves the bytes between them.

import Cocoa

/// Identity of a tiled window that survives an app restart. CGWindowIDs
/// don't; bundle ID plus title is the most stable pair AX exposes. Two
/// windows can share a ref (two "zsh" Terminals) — `LayoutMatcher`
/// hands each leaf its own window.
struct SavedWindowRef: Codable, Hashable {
    let bundleID: String
    let title: String
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
    let root: LayoutNode
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
    /// - Returns: `false` when the save was skipped.
    @discardableResult
    func save(displayKey: String, workspaces: [WorkspaceLayout], manual: Bool) -> Bool {
        if !manual, let existing = snapshots[displayKey], existing.isManual {
            hyprLog(.debug, .lifecycle, "layout auto-save skipped — manual snapshot exists for '\(displayKey)'")
            return false
        }
        snapshots[displayKey] = LayoutSnapshot(
            schemaVersion: LayoutSnapshot.currentSchemaVersion,
            displayKey: displayKey,
            timestamp: Date(),
            isManual: manual,
            workspaces: workspaces
        )
        pruneOldest()
        persist()
        let windows = workspaces.reduce(0) { $0 + $1.root.leaves.count }
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
            guard let oldest = pool.min(by: { $0.value.timestamp < $1.value.timestamp }) else { break }
            snapshots.removeValue(forKey: oldest.key)
            hyprLog(.debug, .lifecycle, "pruned layout snapshot '\(oldest.key)' (manual=\(oldest.value.isManual))")
        }
    }

    // MARK: - persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded: [String: LayoutSnapshot]
        do {
            decoded = try decoder.decode([String: LayoutSnapshot].self, from: data)
        } catch {
            hyprLog(.warning, .lifecycle, "layout snapshots unreadable (\(fileURL.lastPathComponent)): \(error)")
            return
        }
        // a snapshot written by a newer schema is dropped rather than
        // guessed at; the next save rewrites the file at this version.
        snapshots = decoded.filter { $0.value.schemaVersion == LayoutSnapshot.currentSchemaVersion }
        let dropped = decoded.count - snapshots.count
        hyprLog(.debug, .lifecycle,
                "layout snapshots loaded: \(snapshots.count) configs"
                + (dropped > 0 ? " (\(dropped) dropped: schema mismatch)" : ""))
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(snapshots)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            hyprLog(.warning, .lifecycle, "layout snapshots not written: \(error)")
        }
    }
}
