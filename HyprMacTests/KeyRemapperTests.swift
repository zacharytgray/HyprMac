import XCTest
@testable import HyprMac

// KeyRemapperTests pin how HyprMac shares hidutil's UserKeyMapping with the
// user's own mappings: it adds or removes only Caps Lock → F18, keeps every
// other entry in order, holds a foreign Caps Lock entry while ours replaces
// it, and writes nothing when it can't read the list.
//
// nothing here calls hidutil. the merge is pure, and update() runs with a
// fake read, a fake write and a throwaway defaults suite.

final class KeyRemapperTests: XCTestCase {

    private let ours = KeyMappingMerge.ours
    // harmless identity mappings a user might keep in a LaunchAgent
    private let f20 = HIDKeyMapping(src: 0x70000006F, dst: 0x70000006F)
    private let f19 = HIDKeyMapping(src: 0x70000006E, dst: 0x70000006E)
    // the user's own Caps Lock → Escape
    private let capsToEscape = HIDKeyMapping(src: 0x700000039, dst: 0x700000029)
    private let capsToControl = HIDKeyMapping(src: 0x700000039, dst: 0x7000000E0)

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "KeyRemapperTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // what IOKit hands back: an array of dictionaries of numbers
    private func raw(_ entries: [HIDKeyMapping]) -> Any {
        KeyMappingMerge.propertyList(entries) as NSArray
    }

    private func install(_ current: [HIDKeyMapping], held: [HIDKeyMapping] = []) -> KeyMappingMerge.Plan {
        KeyMappingMerge.install(current, held: held)
    }

    private func remove(_ current: [HIDKeyMapping], held: [HIDKeyMapping] = []) -> KeyMappingMerge.Plan {
        KeyMappingMerge.remove(current, held: held)
    }

    func testOurEntryIsCapsLockToF18() {
        XCTAssertEqual(ours, HIDKeyMapping(src: 0x700000039, dst: 0x70000006D))
    }

    // MARK: - parse

    func testMissingPropertyIsAnEmptyList() {
        XCTAssertEqual(KeyMappingMerge.parse(nil), [])
    }

    func testParseKeepsEntriesInOrder() {
        XCTAssertEqual(KeyMappingMerge.parse(raw([f20, ours, f19])), [f20, ours, f19])
        XCTAssertEqual(KeyMappingMerge.parse(NSArray()), [])
    }

    func testParseReadsTheJSONShapeHidutilTakes() throws {
        let json = #"[{"HIDKeyboardModifierMappingSrc":30064771183,"HIDKeyboardModifierMappingDst":30064771183}]"#
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertEqual(KeyMappingMerge.parse(object), [f20])
    }

    func testParseRejectsWhatItCannotWriteBackExactly() {
        let src = "HIDKeyboardModifierMappingSrc"
        let dst = "HIDKeyboardModifierMappingDst"
        let unreadable: [Any] = [
            "(null)",
            [src: 1, dst: 2] as NSDictionary,
            ["not a dictionary"] as NSArray,
            [[src: 0x700000039]] as NSArray,
            [[src: "0x700000039", dst: "0x70000006D"]] as NSArray,
            [[src: 0x700000039, dst: 0x70000006D, "HIDKeyboardModifierMappingFlags": 1]] as NSArray,
            [[src: 0x70000006F, dst: 0x70000006F], "trailing junk"] as NSArray,
            // numbers that would change on the write
            [[src: 1.5, dst: 0x70000006D]] as NSArray,
            [[src: 0x700000039, dst: -1]] as NSArray,
        ]
        for value in unreadable {
            XCTAssertNil(KeyMappingMerge.parse(value), "\(value)")
        }
    }

    func testPropertyListRoundTripsThroughParse() {
        let list = [f20, capsToEscape, ours]
        XCTAssertEqual(KeyMappingMerge.parse(raw(list)), list)
    }

    // MARK: - install

    func testInstallIntoAnEmptyList() {
        let plan = install([])
        XCTAssertEqual(plan.mapping, [ours])
        XCTAssertTrue(plan.changed)
        XCTAssertEqual(plan.held, [])
        XCTAssertEqual(plan.displaced, [])
    }

    func testInstallWithOnlyOursWritesNothing() {
        let plan = install([ours])
        XCTAssertEqual(plan.mapping, [ours])
        XCTAssertFalse(plan.changed)
    }

    func testInstallAppendsAfterForeignEntries() {
        let plan = install([f20, f19])
        XCTAssertEqual(plan.mapping, [f20, f19, ours])
        XCTAssertTrue(plan.changed)
        XCTAssertEqual(plan.held, [])
    }

    func testInstallWithForeignAndOursWritesNothing() {
        let plan = install([f20, ours, f19])
        XCTAssertEqual(plan.mapping, [f20, ours, f19])
        XCTAssertFalse(plan.changed)
    }

    func testInstallReplacesAForeignCapsLockEntryInPlaceAndHoldsIt() {
        let plan = install([f20, capsToEscape, f19])
        XCTAssertEqual(plan.mapping, [f20, ours, f19])
        XCTAssertTrue(plan.changed)
        XCTAssertEqual(plan.displaced, [capsToEscape])
        XCTAssertEqual(plan.held, [capsToEscape])
    }

    func testInstallHoldsEveryForeignCapsLockEntry() {
        let plan = install([capsToEscape, f20, capsToControl])
        XCTAssertEqual(plan.mapping, [ours, f20])
        XCTAssertEqual(plan.displaced, [capsToEscape, capsToControl])
        XCTAssertEqual(plan.held, [capsToEscape, capsToControl])

        let removed = remove(plan.mapping, held: plan.held)
        XCTAssertEqual(removed.mapping, [capsToEscape, capsToControl, f20])
        XCTAssertEqual(removed.restored, [capsToEscape, capsToControl])
    }

    func testInstallDropsDuplicateCopiesOfOurs() {
        let plan = install([ours, f20, ours])
        XCTAssertEqual(plan.mapping, [ours, f20])
        XCTAssertTrue(plan.changed)
    }

    func testInstallKeepsDuplicateForeignEntries() {
        let plan = install([f20, f20])
        XCTAssertEqual(plan.mapping, [f20, f20, ours])
    }

    func testInstallIsIdempotent() {
        let starts: [[HIDKeyMapping]] = [
            [], [ours], [f20], [f20, ours], [capsToEscape, f20], [ours, f20, ours], [f20, capsToEscape, ours],
        ]
        for start in starts {
            let first = install(start)
            let second = install(first.mapping, held: first.held)
            XCTAssertEqual(second.mapping, first.mapping, "\(start)")
            XCTAssertFalse(second.changed, "\(start)")
            XCTAssertEqual(second.held, first.held, "\(start)")
            XCTAssertEqual(first.mapping.filter { $0 == ours }.count, 1, "\(start)")
        }
    }

    func testInstallKeepsTheHoldWhenOursIsAlreadyInPlace() {
        // a relaunch after a crash: ours is still set, the hold is still valid
        let plan = install([f20, ours], held: [capsToEscape])
        XCTAssertFalse(plan.changed)
        XCTAssertEqual(plan.held, [capsToEscape])
    }

    func testInstallDropsAStaleHoldAfterTheListWasReset() {
        // a reboot clears UserKeyMapping; the old hold no longer describes it
        let plan = install([f20], held: [capsToEscape])
        XCTAssertEqual(plan.mapping, [f20, ours])
        XCTAssertEqual(plan.held, [])
    }

    // MARK: - remove

    func testRemoveFromOnlyOursWritesAnEmptyList() {
        let plan = remove([ours])
        XCTAssertEqual(plan.mapping, [])
        XCTAssertTrue(plan.changed)
    }

    func testRemoveTakesOutOnlyOurs() {
        let plan = remove([f20, ours, f19])
        XCTAssertEqual(plan.mapping, [f20, f19])
        XCTAssertTrue(plan.changed)
    }

    func testRemoveWithoutOursWritesNothing() {
        for start in [[], [f20], [f20, f19], [capsToEscape]] {
            let plan = remove(start)
            XCTAssertEqual(plan.mapping, start)
            XCTAssertFalse(plan.changed, "\(start)")
        }
    }

    func testRemovePutsTheHeldEntryBackWhereOursWas() {
        let plan = remove([f20, ours, f19], held: [capsToEscape])
        XCTAssertEqual(plan.mapping, [f20, capsToEscape, f19])
        XCTAssertEqual(plan.restored, [capsToEscape])
        XCTAssertEqual(plan.held, [])
    }

    func testInstallThenRemoveRestoresTheOriginalList() {
        let starts: [[HIDKeyMapping]] = [[], [f20], [f20, f19], [f20, capsToEscape, f19], [capsToEscape]]
        for start in starts {
            let installed = install(start)
            let removed = remove(installed.mapping, held: installed.held)
            XCTAssertEqual(removed.mapping, start, "\(start)")
            XCTAssertEqual(removed.held, [], "\(start)")
        }
    }

    func testRemoveDropsDuplicateCopiesOfOurs() {
        XCTAssertEqual(remove([ours, f20, ours]).mapping, [f20])
    }

    func testRemoveDoesNotPutTheHoldBackOverANewerCapsLockMapping() {
        // something mapped Caps Lock again after our install
        let plan = remove([capsToControl, ours], held: [capsToEscape])
        XCTAssertEqual(plan.mapping, [capsToControl])
        XCTAssertEqual(plan.restored, [])
        XCTAssertEqual(plan.held, [])
    }

    func testRemoveDropsAStaleHold() {
        let plan = remove([f20], held: [capsToEscape])
        XCTAssertEqual(plan.mapping, [f20])
        XCTAssertFalse(plan.changed)
        XCTAssertEqual(plan.held, [])
    }

    // MARK: - unreadable read

    func testUnreadableReadPlansNothing() {
        for op in [KeyMappingMerge.Operation.install, .remove] {
            XCTAssertNil(KeyMappingMerge.plan(op, read: "garbage", held: []))
            XCTAssertNil(KeyMappingMerge.plan(op, read: [["HIDKeyboardModifierMappingSrc": 1]] as NSArray, held: []))
        }
    }

    // MARK: - update with fake IO

    private final class FakeHID {
        var current: Any?
        var writes: [[HIDKeyMapping]] = []
        var writeSucceeds = true

        func read() -> Any? { current }

        func write(_ mapping: [HIDKeyMapping]) -> Bool {
            writes.append(mapping)
            guard writeSucceeds else { return false }
            current = KeyMappingMerge.propertyList(mapping) as NSArray
            return true
        }
    }

    private func update(_ op: KeyMappingMerge.Operation, _ hid: FakeHID) {
        KeyRemapper.update(op, read: hid.read, write: hid.write, defaults: defaults)
    }

    func testUpdateWritesNothingWhenTheReadIsUnreadable() {
        let hid = FakeHID()
        hid.current = [["HIDKeyboardModifierMappingSrc": 0x700000039]] as NSArray
        KeyRemapper.saveHeld([capsToEscape], to: defaults)

        update(.install, hid)
        update(.remove, hid)

        XCTAssertEqual(hid.writes, [])
        XCTAssertEqual(KeyRemapper.loadHeld(from: defaults), [capsToEscape])
    }

    func testUpdateSkipsTheWriteWhenTheListIsCurrent() {
        let hid = FakeHID()
        hid.current = raw([f20, ours])
        update(.install, hid)
        XCTAssertEqual(hid.writes, [])

        hid.current = raw([f20])
        update(.remove, hid)
        XCTAssertEqual(hid.writes, [])
    }

    func testUpdateRoundTripKeepsForeignEntriesAndBringsBackCapsLock() {
        let hid = FakeHID()
        hid.current = raw([f20, capsToEscape])

        update(.install, hid)
        XCTAssertEqual(KeyMappingMerge.parse(hid.current), [f20, ours])
        XCTAssertEqual(KeyRemapper.loadHeld(from: defaults), [capsToEscape])

        // a second launch with the mapping still set
        update(.install, hid)
        XCTAssertEqual(hid.writes.count, 1)

        update(.remove, hid)
        XCTAssertEqual(KeyMappingMerge.parse(hid.current), [f20, capsToEscape])
        XCTAssertEqual(KeyRemapper.loadHeld(from: defaults), [])
        XCTAssertEqual(hid.writes.count, 2)
    }

    func testUpdateStoresANewHoldBeforeTheWrite() {
        // a crash or failure mid-write must not lose the user's entry
        let hid = FakeHID()
        hid.current = raw([capsToEscape])
        hid.writeSucceeds = false

        update(.install, hid)

        XCTAssertEqual(hid.writes, [[ours]])
        XCTAssertEqual(KeyMappingMerge.parse(hid.current), [capsToEscape])
        XCTAssertEqual(KeyRemapper.loadHeld(from: defaults), [capsToEscape])

        // with ours never set, the next remove drops that hold and writes nothing
        hid.writeSucceeds = true
        update(.remove, hid)
        XCTAssertEqual(hid.writes, [[ours]])
        XCTAssertEqual(KeyMappingMerge.parse(hid.current), [capsToEscape])
        XCTAssertEqual(KeyRemapper.loadHeld(from: defaults), [])
    }

    func testFailedRemoveWriteKeepsTheHold() {
        let hid = FakeHID()
        hid.current = raw([f20, ours])
        hid.writeSucceeds = false
        KeyRemapper.saveHeld([capsToEscape], to: defaults)

        update(.remove, hid)

        XCTAssertEqual(hid.writes, [[f20, capsToEscape]])
        XCTAssertEqual(KeyMappingMerge.parse(hid.current), [f20, ours])
        XCTAssertEqual(KeyRemapper.loadHeld(from: defaults), [capsToEscape])

        hid.writeSucceeds = true
        update(.remove, hid)
        XCTAssertEqual(KeyMappingMerge.parse(hid.current), [f20, capsToEscape])
        XCTAssertEqual(KeyRemapper.loadHeld(from: defaults), [])
    }

    func testHeldEntriesPersistAcrossLoads() {
        XCTAssertEqual(KeyRemapper.loadHeld(from: defaults), [])
        KeyRemapper.saveHeld([capsToEscape, capsToControl], to: defaults)
        XCTAssertEqual(KeyRemapper.loadHeld(from: defaults), [capsToEscape, capsToControl])
        KeyRemapper.saveHeld([], to: defaults)
        XCTAssertNil(defaults.object(forKey: KeyRemapper.heldDefaultsKey))
    }
}
