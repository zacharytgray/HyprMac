// Per-display-configuration layout persistence. Saves which windows
// live on which workspaces, keyed by display fingerprint. Auto-saves
// before a display change; auto-restores when a known config returns.

import Cocoa

/// One window's workspace assignment in a saved snapshot.
struct WindowAssignment: Codable, Equatable {
    let bundleID: String
    let windowTitle: String
    let workspace: Int
    let x: CGFloat?
    let y: CGFloat?
    let w: CGFloat?
    let h: CGFloat?
}

/// A frozen layout for one display configuration.
struct LayoutSnapshot: Codable {
    let displayKey: String
    let timestamp: Date
    let assignments: [WindowAssignment]
    let isManual: Bool
}

/// Persistence layer for display-keyed layout snapshots.
///
/// Snapshots are keyed by a deterministic fingerprint of the
/// connected displays (names + resolutions, sorted). Each display
/// config gets exactly one snapshot — saving overwrites the previous.
///
/// File: `~/Library/Application Support/HyprMac/layout-snapshots.json`
///
/// Threading: main-thread only (called from WindowManager).
final class LayoutSnapshotStore {

    static let shared = LayoutSnapshotStore()

    static let maxSnapshots = 10

    private let filePath: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HyprMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("layout-snapshots.json")
    }()

    /// In-memory cache of all snapshots, keyed by display fingerprint.
    private(set) var snapshots: [String: LayoutSnapshot] = [:]

    private init() { load() }

    // test-only initializer — avoids disk I/O and the singleton
    init(testSnapshots: [String: LayoutSnapshot]) {
        snapshots = testSnapshots
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

    /// Capture current window→workspace assignments for the active
    /// display configuration.
    func save(displayKey: String, assignments: [WindowAssignment], manual: Bool = false) {
        if !manual, let existing = snapshots[displayKey], existing.isManual {
            hyprLog(.debug, .lifecycle,
                    "skipping auto-save — manual snapshot exists for '\(displayKey)'")
            return
        }
        let snapshot = LayoutSnapshot(
            displayKey: displayKey,
            timestamp: Date(),
            assignments: assignments,
            isManual: manual
        )
        snapshots[displayKey] = snapshot
        pruneOldest()
        persist()
        hyprLog(.notice, .lifecycle,
                "layout snapshot saved: \(assignments.count) windows for '\(displayKey)'")
    }

    // MARK: - restore

    /// Retrieve a saved snapshot for `displayKey`, or `nil` when none
    /// exists.
    func snapshot(for displayKey: String) -> LayoutSnapshot? {
        snapshots[displayKey]
    }

    // MARK: - pruning

    private func pruneOldest() {
        while snapshots.count > Self.maxSnapshots {
            guard let oldest = snapshots
                .filter({ !$0.value.isManual })
                .min(by: { $0.value.timestamp < $1.value.timestamp })
                ?? snapshots.min(by: { $0.value.timestamp < $1.value.timestamp })
            else { break }
            snapshots.removeValue(forKey: oldest.key)
            hyprLog(.debug, .lifecycle,
                    "pruned oldest layout snapshot: '\(oldest.key)'")
        }
    }

    // MARK: - persistence

    private func load() {
        guard let data = try? Data(contentsOf: filePath) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([String: LayoutSnapshot].self, from: data) else { return }
        snapshots = decoded
        hyprLog(.debug, .lifecycle,
                "layout snapshots loaded: \(snapshots.count) configs")
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshots) else { return }
        try? data.write(to: filePath, options: .atomic)
    }
}
