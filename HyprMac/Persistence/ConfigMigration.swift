// One-time data migrations and schema-version bookkeeping. Lives in
// Persistence so changes here do not touch the `@Published` surface
// in `UserConfig`. Today: the monitor-config split (per-machine
// settings extracted from the iCloud-synced file), the bracket color and
// the floating keybind moves. Future schema bumps land here too.

import Carbon
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

    /// Brackets shared the persistent focus-border color before they gained
    /// their own preference. Preserve an explicit legacy color; otherwise nil
    /// selects the new black default.
    static func resolveFocusBracketColor(saved: SavedConfig) -> String? {
        guard saved.focusBracketStyle == nil else { return saved.focusBracketColorHex }
        return saved.focusBracketColorHex ?? saved.focusBorderColorHex
    }

    // leave customized actions and occupied chords alone, including multiple float bindings.
    static func migrateToggleFloating(saved: [Keybind]) -> [Keybind] {
        let old = Keybind(keyCode: UInt16(kVK_ANSI_T), modifiers: [.hypr, .shift],
                          action: .toggleFloating)
        let replacement = Keybind(keyCode: UInt16(kVK_ANSI_T), modifiers: .hypr,
                                  action: .toggleFloating)
        guard saved.filter({ $0.action == .toggleFloating }) == [old],
              saved.filter({ $0.id == old.id }).count == 1,
              !saved.contains(where: { $0.id == replacement.id }),
              let index = saved.firstIndex(of: old) else { return saved }
        var migrated = saved
        migrated[index] = replacement
        return migrated
    }

    // Repurpose the old default only when it is unambiguously still the
    // shipped binding. Customized actions and occupied chords stay untouched.
    static func migrateFocusFloating(saved: [Keybind]) -> [Keybind] {
        let old = Keybind(keyCode: UInt16(kVK_ANSI_F), modifiers: .hypr,
                          action: .focusFloating)
        let replacement = Keybind(keyCode: UInt16(kVK_ANSI_T), modifiers: [.hypr, .shift],
                                  action: .focusFloating)
        guard saved.filter({ $0.action == .focusFloating }) == [old],
              saved.filter({ $0.id == old.id }).count == 1,
              !saved.contains(where: { $0.id == replacement.id }),
              !saved.contains(where: { $0.action == .moveToNextEmptyWorkspace }),
              let index = saved.firstIndex(of: old) else { return saved }
        var migrated = saved
        migrated[index] = replacement
        return migrated
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
