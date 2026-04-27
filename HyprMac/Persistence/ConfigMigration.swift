import Foundation

// ConfigMigration owns one-time data migrations + (eventually) schema-version
// bumps. lives in Persistence so changes here don't touch the @Published
// surface in UserConfig.
//
// today this houses the monitor-config split: maxSplitsPerMonitor and
// disabledMonitors used to live in the main (iCloud-synced) config.json.
// they're now in a local-only monitor-config.json so per-machine settings
// don't roundtrip through iCloud and clobber each machine's setup. when a
// pre-split config is loaded, we extract the monitor data, write it locally,
// and stop using the synced fields.
//
// future schema bumps land here too — bump SavedConfig.version and add a
// case in migrate(...) that mutates the loaded SavedConfig in place.

enum ConfigMigration {

    // current on-disk schema version. bump this in lockstep with the
    // migration code that handles the new shape.
    static let currentVersion: Int = 1

    // resolve the schema version of a loaded SavedConfig. nil maps to v1
    // (the version when the field was introduced — every pre-existing
    // user config decodes as v1).
    static func schemaVersion(of saved: SavedConfig) -> Int {
        saved.version ?? 1
    }

    // load monitor config — preferring the local file, falling back to the
    // monitor fields embedded in an older SavedConfig.
    //
    // returns the resolved (maxSplitsPerMonitor, disabledMonitors) pair, plus
    // a flag indicating whether the local monitor file needs to be written
    // (i.e. we just migrated the data out of the synced config).
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
