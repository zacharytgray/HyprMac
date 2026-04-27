// One-time data migrations and schema-version bookkeeping. Lives in
// Persistence so changes here do not touch the `@Published` surface
// in `UserConfig`. Today: the monitor-config split (per-machine
// settings extracted from the iCloud-synced file). Future schema
// bumps land here too.

import Foundation

/// One-time migrations and schema-version helpers for `SavedConfig`.
enum ConfigMigration {

    /// Current on-disk schema version. Bump in lockstep with the
    /// migration code that handles the new shape.
    static let currentVersion: Int = 1

    /// Schema version of a loaded `SavedConfig`. `nil` maps to v1 —
    /// the version when the field was introduced; every pre-existing
    /// config decodes as v1.
    static func schemaVersion(of saved: SavedConfig) -> Int {
        saved.version ?? 1
    }

    /// Resolve monitor config, preferring the local file and falling
    /// back to the monitor fields embedded in an older
    /// `SavedConfig`.
    ///
    /// `maxSplitsPerMonitor` and `disabledMonitors` used to live in
    /// the main (iCloud-synced) `config.json`; they now live in a
    /// local-only `monitor-config.json` so per-machine settings do
    /// not round-trip through iCloud and clobber each machine's
    /// setup.
    ///
    /// - Returns: the resolved values plus `needsLocalWrite`, which
    ///   indicates the caller should persist the local file because
    ///   the values were just migrated out of the synced config.
    static func resolveMonitorConfig(
        local: SavedMonitorConfig?,
        embedded saved: SavedConfig?
    ) -> (maxSplits: [String: Int], disabled: Set<String>, needsLocalWrite: Bool) {
        if let local {
            return (local.maxSplitsPerMonitor ?? [:],
                    Set(local.disabledMonitors ?? []),
                    false)
        }
        // no local file — adopt the embedded values from the synced config.
        // if either embedded set is non-empty we need to persist a local copy
        // so the next launch reads from the local file directly.
        let maxSplits = saved?.maxSplitsPerMonitor ?? [:]
        let disabled = Set(saved?.disabledMonitors ?? [])
        let needsWrite = !maxSplits.isEmpty || !disabled.isEmpty
        return (maxSplits, disabled, needsWrite)
    }
}
