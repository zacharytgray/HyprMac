// Where every window was when HyprMac quit to install an update, for the
// launch that follows. A normal launch spreads the open windows across
// workspaces from scratch; after an update the user should find the desk
// as they left it.
//
// The other apps keep running across HyprMac's own relaunch, so their
// window ids stay valid. Each window is saved by id and owning pid, which
// is exact where a layout snapshot's bundle id and title are a best guess.

import Cocoa

/// One relaunch's worth of window state. Written once, read once.
struct RelaunchHandoff: Codable, Equatable {
    static let currentSchemaVersion = 1
    /// an install and relaunch takes seconds. past this the file is from
    /// some other quit and the ids may belong to other windows
    static let maxAge: TimeInterval = 10 * 60

    struct WindowKey: Codable, Hashable {
        let id: CGWindowID
        let pid: pid_t
    }

    struct Floater: Codable, Equatable {
        let window: WindowKey
        let workspace: Int
        /// where the user last had it; nil when no frame could be read
        let frame: CGRect?
    }

    var schemaVersion = RelaunchHandoff.currentSchemaVersion
    let savedAt: Date
    let displayKey: String
    /// the workspace each monitor was showing
    let visibleWorkspaces: [Int]
    let focused: WindowKey?
    /// tiled windows: each workspace's tree, leaves written with `ref`
    let workspaces: [WorkspaceLayout]
    let floaters: [Floater]
    let scratchpad: [WindowKey]

    /// The leaf written for a window, so `LayoutRestorer` matches it exactly.
    static func ref(id: CGWindowID, pid: pid_t) -> SavedWindowRef {
        SavedWindowRef(bundleID: "pid:\(pid)", title: "wid:\(id)")
    }

    /// Fresh, from this build's schema, and for the displays connected now.
    func isUsable(now: Date, displayKey: String) -> Bool {
        let age = now.timeIntervalSince(savedAt)
        return schemaVersion == Self.currentSchemaVersion
            && age >= 0 && age <= Self.maxAge
            && displayKey == self.displayKey
    }

    /// The tiled part in the form `LayoutRestorer.restore` takes.
    var layoutSnapshot: LayoutSnapshot {
        LayoutSnapshot(schemaVersion: LayoutSnapshot.currentSchemaVersion,
                       displayKey: displayKey, timestamp: savedAt,
                       isManual: false, workspaces: workspaces)
    }
}

/// File for the handoff, next to the config. Main-thread only.
struct RelaunchHandoffStore {
    static let shared = RelaunchHandoffStore(
        fileURL: ConfigStore.configDir.appendingPathComponent("relaunch-handoff.json"))

    let fileURL: URL

    func write(_ handoff: RelaunchHandoff) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(handoff).write(to: fileURL, options: .atomic)
    }

    /// Read the handoff and delete the file, so it applies to one launch
    /// only. Returns nil when there is none or it no longer fits.
    func take(now: Date = Date(), displayKey: String) -> RelaunchHandoff? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        try? FileManager.default.removeItem(at: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let handoff = try? decoder.decode(RelaunchHandoff.self, from: data) else {
            hyprLog(.notice, .lifecycle, "relaunch handoff: unreadable, ignored")
            return nil
        }
        guard handoff.isUsable(now: now, displayKey: displayKey) else {
            hyprLog(.notice, .lifecycle, "relaunch handoff: ignored, saved \(Int(now.timeIntervalSince(handoff.savedAt)))s ago"
                    + " for '\(handoff.displayKey)', now '\(displayKey)'")
            return nil
        }
        return handoff
    }
}
