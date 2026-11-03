// What the engine can't vouch for about each key's frames. Generic over the key
// so `TilingKey` stays private to the engine.

import CoreGraphics

struct GeometryLedger<Key: Hashable> {
    struct UnverifiedRecord: Equatable {
        var windowIDs: Set<CGWindowID>
        var insertedIDs: Set<CGWindowID>
        /// every attempt on this key since the last accepted layout put its
        /// own originals back, verified. False the moment one did not, and
        /// it never recovers until an accepted layout drops the record —
        /// because from then on nobody knows where the incumbents are.
        var restorationVerifiedThroughout: Bool
    }

    /// Keys whose last layout attempt did not produce verified geometry.
    /// Set by any non-accepted attempt, cleared by an accepted one or by
    /// lifecycle cleanup. `intendedTileRects` omits these keys; `intendedRect(for:)`
    /// and `scratchpadTileRects` do not.
    private var unverified: [Key: UnverifiedRecord] = [:]
    /// Keys a window left since their last accepted layout. Until one is
    /// accepted, the frames on screen still hold the gap it left.
    private var vacated: Set<Key> = []

    var unverifiedKeys: [Key] { Array(unverified.keys) }
    func isUnverified(_ key: Key) -> Bool { unverified[key] != nil }
    func unverifiedRecord(for key: Key) -> UnverifiedRecord? { unverified[key] }
    func isVacated(_ key: Key) -> Bool { vacated.contains(key) }

    mutating func noteVacated(_ key: Key) {
        vacated.insert(key)
    }

    /// A key's marks describe its tree, so they go when the tree does, and
    /// when a layout for it is accepted.
    mutating func clear(_ key: Key) {
        unverified.removeValue(forKey: key)
        vacated.remove(key)
    }

    /// Mark `key` unverified, folding this attempt's rollback into whatever
    /// earlier attempts on the same key already said. A single failed
    /// rollback anywhere in the run is enough: a restoration writes the
    /// frames it captured when it started, so once one of them leaves the
    /// incumbents somewhere unplanned, every later rollback faithfully
    /// restores that.
    mutating func mark(_ key: Key, windowIDs: Set<CGWindowID>,
                       insertedIDs: Set<CGWindowID>, restored: Bool) {
        if var existing = unverified[key] {
            existing.windowIDs.formUnion(windowIDs)
            existing.insertedIDs.formUnion(insertedIDs)
            existing.restorationVerifiedThroughout = existing.restorationVerifiedThroughout && restored
            unverified[key] = existing
            return
        }
        unverified[key] = UnverifiedRecord(windowIDs: windowIDs, insertedIDs: insertedIDs,
                                           restorationVerifiedThroughout: restored)
    }

    /// Drop the unverified mark unless a rollback along the way failed to
    /// verify. A key with no mark counts as cleared. The vacated mark stays.
    mutating func clearUnverifiedIfRestored(_ key: Key) -> Bool {
        guard let record = unverified[key] else { return true }
        guard record.restorationVerifiedThroughout else { return false }
        unverified.removeValue(forKey: key)
        return true
    }

    /// The marks belong to the tree, so they follow it to a new key, folding
    /// into any the new key already has.
    mutating func carry(from old: Key, to new: Key) {
        if let carried = unverified.removeValue(forKey: old) {
            mark(new, windowIDs: carried.windowIDs, insertedIDs: carried.insertedIDs,
                 restored: carried.restorationVerifiedThroughout)
        }
        if vacated.remove(old) != nil { vacated.insert(new) }
    }

    mutating func prune(keeping isLive: (Key) -> Bool) {
        unverified = unverified.filter { isLive($0.key) }
        vacated = vacated.filter(isLive)
    }
}
