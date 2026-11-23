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
    private var pending: PendingOwnMappings!

    override func setUp() {
        super.setUp()
        suiteName = "KeyRemapperTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        pending = PendingOwnMappings()
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

    /// the release build quitting beside the debug build takes the shared
    /// remap with it; the check after a wake puts it back, and writes
    /// nothing while it is there
    func testReassertWritesOnlyWhenOurEntryIsMissing() {
        let defaults = UserDefaults(suiteName: "KeyRemapperTests.reassert")!
        defaults.removePersistentDomain(forName: "KeyRemapperTests.reassert")
        var written: [[HIDKeyMapping]] = []
        let present: Any = KeyMappingMerge.propertyList([KeyMappingMerge.ours])

        XCTAssertFalse(KeyRemapper.reassertHyprKey(.capsLock, enabled: true, read: { present },
                                                   write: { written.append($0); return true },
                                                   defaults: defaults, capsLockOff: {},
                                                   keyboards: { [] }, pushToKeyboard: { _, _ in false }))
        XCTAssertTrue(written.isEmpty, "present: nothing to write")

        XCTAssertTrue(KeyRemapper.reassertHyprKey(.capsLock, enabled: true, read: { nil },
                                                  write: { written.append($0); return true },
                                                  defaults: defaults, capsLockOff: {},
                                                  keyboards: { [] }, pushToKeyboard: { _, _ in false }))
        XCTAssertEqual(written, [[KeyMappingMerge.ours]], "gone: put back")

        written = []
        XCTAssertFalse(KeyRemapper.reassertHyprKey(.capsLock, enabled: true, read: { [["bogus": 1]] },
                                                   write: { written.append($0); return true },
                                                   defaults: defaults, capsLockOff: {},
                                                   keyboards: { [] }, pushToKeyboard: { _, _ in false }))
        XCTAssertTrue(written.isEmpty, "unreadable: untouched")
    }

    func testReassertDoesNothingForAHyprKeyWithoutTheRemap() {
        var written = 0
        let other = HyprKey.allCases.first { !$0.usesCapsLockRemap }
        guard let other else { return }
        XCTAssertFalse(KeyRemapper.reassertHyprKey(other, enabled: true, read: { nil },
                                                   write: { _ in written += 1; return true },
                                                   capsLockOff: {}, keyboards: { [] },
                                                   pushToKeyboard: { _, _ in false }))
        XCTAssertEqual(written, 0)
    }

    /// paused, the remap is gone on purpose (#94); a wake must not put it back
    func testReassertDoesNothingWhilePaused() {
        var written = 0
        XCTAssertFalse(KeyRemapper.reassertHyprKey(.capsLock, enabled: false, read: { nil },
                                                   write: { _ in written += 1; return true },
                                                   capsLockOff: {}, keyboards: { [] },
                                                   pushToKeyboard: { _, _ in false }))
        XCTAssertEqual(written, 0)
    }

    // MARK: - keyboards without a copy of the list (#103)

    private struct KeyboardPush: Equatable {
        let id: UInt64
        let mapping: [HIDKeyMapping]
    }

    private func reassert(list: [HIDKeyMapping], keyboards: [HIDKeyboardMapping],
                          key: HyprKey = .capsLock, enabled: Bool = true,
                          pushSucceeds: Bool = true,
                          written: inout [[HIDKeyMapping]], pushes: inout [KeyboardPush],
                          keyboardReads: inout Int) -> Bool {
        let raw = raw(list)
        var w: [[HIDKeyMapping]] = []
        var p: [KeyboardPush] = []
        var reads = 0
        let result = KeyRemapper.reassertHyprKey(
            key, enabled: enabled, read: { raw }, write: { w.append($0); return true },
            defaults: defaults, capsLockOff: {},
            keyboards: { reads += 1; return keyboards },
            pushToKeyboard: { p.append(KeyboardPush(id: $0, mapping: $1)); return pushSucceeds },
            pending: pending)
        written += w
        pushes += p
        keyboardReads += reads
        return result
    }

    /// the issue's wake: the list still has ours, the keyboards from before
    /// the sleep keep their copy, and the one the system made on wake has
    /// none. only that keyboard gets the list, and the list isn't rewritten
    func testReassertGivesTheListToAKeyboardWithoutOne() {
        var written: [[HIDKeyMapping]] = []
        var pushes: [KeyboardPush] = []
        var reads = 0
        let keyboards = [HIDKeyboardMapping(id: 0x100000953, name: "old", hasList: true),
                         HIDKeyboardMapping(id: 0x10000516C, name: "new", hasList: false)]
        XCTAssertTrue(reassert(list: [f20, ours], keyboards: keyboards,
                               written: &written, pushes: &pushes, keyboardReads: &reads))
        XCTAssertEqual(pushes, [KeyboardPush(id: 0x10000516C, mapping: [f20, ours])])
        XCTAssertTrue(written.isEmpty, "the system list is already right")
    }

    /// a keyboard with any list of its own, even one without ours, was set by
    /// someone (hidutil --matching, another tool). it is left alone
    func testReassertLeavesKeyboardsWithTheirOwnList() {
        var written: [[HIDKeyMapping]] = []
        var pushes: [KeyboardPush] = []
        var reads = 0
        let keyboards = [HIDKeyboardMapping(id: 1, name: "a", hasList: true),
                         HIDKeyboardMapping(id: 2, name: "b", hasList: true)]
        XCTAssertFalse(reassert(list: [ours], keyboards: keyboards,
                                written: &written, pushes: &pushes, keyboardReads: &reads))
        XCTAssertTrue(pushes.isEmpty)
        XCTAssertTrue(written.isEmpty)
    }

    /// a failed push counts as nothing written; the next check tries again
    func testReassertReportsAFailedKeyboardPush() {
        var written: [[HIDKeyMapping]] = []
        var pushes: [KeyboardPush] = []
        var reads = 0
        let keyboards = [HIDKeyboardMapping(id: 7, name: "new", hasList: false)]
        XCTAssertFalse(reassert(list: [ours], keyboards: keyboards, pushSucceeds: false,
                                written: &written, pushes: &pushes, keyboardReads: &reads))
        XCTAssertEqual(pushes.count, 1)
    }

    /// paused or another Hypr key: keyboards aren't read. a missing entry
    /// reads them once, before the system-wide write, to keep any keyboard's
    /// own mapping; a keyboard without a copy needs no push, the write
    /// reaches it
    func testReassertReadsKeyboardsOnlyWhenTheRemapIsWanted() {
        var written: [[HIDKeyMapping]] = []
        var pushes: [KeyboardPush] = []
        var reads = 0
        let keyboards = [HIDKeyboardMapping(id: 7, name: "new", hasList: false)]
        _ = reassert(list: [ours], keyboards: keyboards, enabled: false,
                     written: &written, pushes: &pushes, keyboardReads: &reads)
        if let other = HyprKey.allCases.first(where: { !$0.usesCapsLockRemap }) {
            _ = reassert(list: [ours], keyboards: keyboards, key: other,
                         written: &written, pushes: &pushes, keyboardReads: &reads)
        }
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(reassert(list: [f20], keyboards: keyboards,
                               written: &written, pushes: &pushes, keyboardReads: &reads))
        XCTAssertEqual(written, [[f20, ours]])
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(pushes.isEmpty)
    }

    /// the one live read here: it only reads. a service is only usable
    /// while the event system client that listed it is alive; reading one
    /// after the client went away aborted the app on the first wake check
    func testLiveKeyboardReadOutlivesItsClient() {
        let first = KeyRemapper.readKeyboardMappings()
        let second = KeyRemapper.readKeyboardMappings()
        XCTAssertEqual(first.map(\.id), second.map(\.id))
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

    // the system list plus each keyboard's own copy. a system-wide write
    // replaces every keyboard's copy, own mappings included: measured with
    // hidutil on macOS 15.8 (architecture.md, "Each keyboard's copy")
    private final class FakeHID {
        var current: Any?
        var writes: [[HIDKeyMapping]] = []
        var writeSucceeds = true
        var capsLockOffCalls = 0
        var keyboards: [HIDKeyboardMapping] = []
        var pushes: [KeyboardPush] = []
        /// pushes each keyboard refuses before it takes one
        var refusals: [UInt64: Int] = [:]

        func read() -> Any? { current }

        func write(_ mapping: [HIDKeyMapping]) -> Bool {
            writes.append(mapping)
            guard writeSucceeds else { return false }
            current = KeyMappingMerge.propertyList(mapping) as NSArray
            keyboards = keyboards.map { HIDKeyboardMapping(id: $0.id, name: $0.name, hasList: true, list: mapping) }
            return true
        }

        func readKeyboards() -> [HIDKeyboardMapping] { keyboards }

        func push(_ id: UInt64, _ mapping: [HIDKeyMapping]) -> Bool {
            pushes.append(KeyboardPush(id: id, mapping: mapping))
            guard keyboards.contains(where: { $0.id == id }) else { return false }
            if let left = refusals[id], left > 0 {
                refusals[id] = left - 1
                return false
            }
            keyboards = keyboards.map {
                $0.id == id ? HIDKeyboardMapping(id: id, name: $0.name, hasList: true, list: mapping) : $0
            }
            return true
        }

        func keyboard(_ id: UInt64) -> [HIDKeyMapping]? {
            keyboards.first { $0.id == id }?.list
        }
    }

    private func update(_ op: KeyMappingMerge.Operation, _ hid: FakeHID) {
        KeyRemapper.update(op, read: hid.read, write: hid.write, defaults: defaults,
                           capsLockOff: { hid.capsLockOffCalls += 1 },
                           keyboards: hid.readKeyboards, pushToKeyboard: hid.push, pending: pending)
    }

    private func apply(_ key: HyprKey, enabled: Bool, _ hid: FakeHID) {
        KeyRemapper.applyHyprKey(key, enabled: enabled, read: hid.read, write: hid.write,
                                 defaults: defaults, capsLockOff: { hid.capsLockOffCalls += 1 },
                                 keyboards: hid.readKeyboards, pushToKeyboard: hid.push, pending: pending)
    }

    // MARK: - a keyboard's own mapping

    // keyboard 1 follows the list; keyboard 2 has its own, set with
    // hidutil --matching or another tool
    private func keyboards(following list: [HIDKeyMapping], own: [HIDKeyMapping]) -> [HIDKeyboardMapping] {
        [HIDKeyboardMapping(id: 1, name: "follows", hasList: true, list: list),
         HIDKeyboardMapping(id: 2, name: "own", hasList: true, list: own)]
    }

    /// another HyprMac quit and took ours out of the list; a keyboard then
    /// arrives and the check puts ours back with a system-wide write. that
    /// write must not take keyboard 2's own mapping with it
    func testPuttingTheEntryBackKeepsAKeyboardsOwnMapping() {
        let hid = FakeHID()
        hid.current = raw([f20])
        hid.keyboards = keyboards(following: [f20], own: [f19])
        XCTAssertTrue(KeyRemapper.reassertHyprKey(.capsLock, enabled: true, read: hid.read, write: hid.write,
                                                  defaults: defaults, capsLockOff: {},
                                                  keyboards: hid.readKeyboards, pushToKeyboard: hid.push,
                                                  pending: pending))
        XCTAssertEqual(KeyMappingMerge.parse(hid.current), [f20, ours])
        XCTAssertEqual(hid.keyboard(1), [f20, ours])
        XCTAssertEqual(hid.keyboard(2), [f19], "own mapping put back as it was")
        XCTAssertEqual(hid.pushes, [KeyboardPush(id: 2, mapping: [f19])])
    }

    /// the same for every write: launch, pause, resume, quit
    func testInstallAndRemoveKeepAKeyboardsOwnMapping() {
        let hid = FakeHID()
        hid.current = raw([f20])
        hid.keyboards = keyboards(following: [f20], own: [capsToEscape])
        apply(.capsLock, enabled: true, hid)
        XCTAssertEqual(hid.keyboard(1), [f20, ours])
        XCTAssertEqual(hid.keyboard(2), [capsToEscape])
        apply(.capsLock, enabled: false, hid)
        XCTAssertEqual(hid.keyboard(1), [f20])
        XCTAssertEqual(hid.keyboard(2), [capsToEscape])
    }

    /// no write, nothing replaced, nothing to put back
    func testACurrentListTouchesNoKeyboard() {
        let hid = FakeHID()
        hid.current = raw([f20, ours])
        hid.keyboards = keyboards(following: [f20, ours], own: [f19])
        update(.install, hid)
        XCTAssertTrue(hid.writes.isEmpty)
        XCTAssertTrue(hid.pushes.isEmpty)
    }

    private func check(_ hid: FakeHID, enabled: Bool = true) {
        KeyRemapper.reassertHyprKey(.capsLock, enabled: enabled, read: hid.read, write: hid.write,
                                    defaults: defaults, capsLockOff: {},
                                    keyboards: hid.readKeyboards, pushToKeyboard: hid.push, pending: pending)
    }

    /// keyboard 2 refuses its own mapping once after the install's write.
    /// it now holds the list, so it looks like any other keyboard; the next
    /// check must still give its mapping back
    func testARefusedPutBackIsRetriedOnTheNextCheck() {
        let hid = FakeHID()
        hid.current = raw([f20])
        hid.keyboards = keyboards(following: [f20], own: [f19])
        hid.refusals = [2: 1]
        apply(.capsLock, enabled: true, hid)
        XCTAssertEqual(hid.keyboard(2), [f20, ours], "refused: it has the list for now")
        check(hid)
        XCTAssertEqual(hid.keyboard(2), [f19])
        XCTAssertTrue(pending.isEmpty)
        let pushes = hid.pushes.count
        check(hid)
        XCTAssertEqual(hid.pushes.count, pushes, "put back once, then left alone")
    }

    /// refused again by the pause's write: still kept, and the check while
    /// paused puts it back
    func testARefusedPutBackSurvivesAnotherWrite() {
        let hid = FakeHID()
        hid.current = raw([f20])
        hid.keyboards = keyboards(following: [f20], own: [f19])
        hid.refusals = [2: 2]
        apply(.capsLock, enabled: true, hid)
        apply(.capsLock, enabled: false, hid)
        XCTAssertEqual(hid.keyboard(2), [f20], "refused twice")
        check(hid, enabled: false)
        XCTAssertEqual(hid.keyboard(2), [f19])
        XCTAssertTrue(pending.isEmpty)
    }

    /// an unplugged keyboard's own mapping went with it; nothing to retry
    func testAPendingPutBackForAGoneKeyboardIsDropped() {
        let hid = FakeHID()
        hid.current = raw([f20])
        hid.keyboards = keyboards(following: [f20], own: [f19])
        hid.refusals = [2: 1]
        apply(.capsLock, enabled: true, hid)
        hid.keyboards.removeAll { $0.id == 2 }
        let pushes = hid.pushes.count
        check(hid)
        XCTAssertEqual(hid.pushes.count, pushes)
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - keyboard arrivals

    /// a keyboard plugged in between the launch write and the watcher's
    /// registration is no arrival; starting the watcher checks once. the
    /// registration is an IOKit registry notification, no permission
    func testStartingTheWatcherChecksOnce() {
        var reasons: [String] = []
        let watcher = KeyboardArrivalWatcher(schedule: { _, _ in }, onCheck: { reasons.append($0) })
        watcher.start()
        watcher.stop()
        XCTAssertEqual(reasons.count, 1)
    }

    /// a keyboard the event system hasn't listed yet at the first check, or
    /// one that refused the list, gets one more look a few seconds later
    func testAnArrivalBurstChecksTwice() {
        var scheduled: [(TimeInterval, DispatchWorkItem)] = []
        var checks = 0
        let watcher = KeyboardArrivalWatcher(schedule: { scheduled.append(($0, $1)) },
                                             onCheck: { _ in checks += 1 })
        watcher.noteArrivals()
        watcher.noteArrivals()
        XCTAssertEqual(scheduled.map(\.0), [1, 4, 1, 4])
        scheduled.forEach { if !$0.1.isCancelled { $0.1.perform() } }
        XCTAssertEqual(checks, 2, "the second burst replaces the first one's checks")
    }


    // MARK: - paused (#94)

    func testOnlyAnActiveCapsLockHyprKeyWantsTheRemap() {
        for key in HyprKey.allCases {
            XCTAssertEqual(KeyRemapper.wantsRemap(key, enabled: true), key == .capsLock, key.rawValue)
            XCTAssertFalse(KeyRemapper.wantsRemap(key, enabled: false), key.rawValue)
        }
    }

    func testPausingRemovesTheRemapAndResumingPutsItBack() {
        let hid = FakeHID()
        hid.current = raw([f20])

        apply(.capsLock, enabled: true, hid)
        XCTAssertEqual(KeyMappingMerge.parse(hid.current), [f20, ours])

        apply(.capsLock, enabled: false, hid)
        XCTAssertEqual(KeyMappingMerge.parse(hid.current), [f20], "paused: Caps Lock is Caps Lock again")

        apply(.capsLock, enabled: true, hid)
        XCTAssertEqual(KeyMappingMerge.parse(hid.current), [f20, ours])
        XCTAssertEqual(hid.writes.count, 3)
    }

    func testPausingGivesBackTheUsersOwnCapsLockMapping() {
        let hid = FakeHID()
        hid.current = raw([f20, capsToEscape, f19])

        apply(.capsLock, enabled: true, hid)
        XCTAssertEqual(KeyMappingMerge.parse(hid.current), [f20, ours, f19])

        apply(.capsLock, enabled: false, hid)
        XCTAssertEqual(KeyMappingMerge.parse(hid.current), [f20, capsToEscape, f19])
        XCTAssertEqual(KeyRemapper.loadHeld(from: defaults), [])

        apply(.capsLock, enabled: true, hid)
        XCTAssertEqual(KeyMappingMerge.parse(hid.current), [f20, ours, f19])
        XCTAssertEqual(KeyRemapper.loadHeld(from: defaults), [capsToEscape])
    }

    func testLaunchingPausedClearsARemapLeftByAKilledCopy() {
        let hid = FakeHID()
        hid.current = raw([f20, ours])
        apply(.capsLock, enabled: false, hid)
        XCTAssertEqual(KeyMappingMerge.parse(hid.current), [f20])
    }

    func testAnotherHyprKeyNeverInstallsTheRemap() {
        let hid = FakeHID()
        hid.current = raw([f20])
        apply(.f13, enabled: true, hid)
        apply(.f13, enabled: false, hid)
        apply(.rightCommand, enabled: true, hid)
        XCTAssertEqual(hid.writes, [])
        XCTAssertEqual(hid.capsLockOffCalls, 0)
    }

    /// with the remap in, the key can't turn a lock off any more, so one
    /// left on while paused is turned off as the remap goes back
    func testCapsLockIsTurnedOffOnlyWhenTheRemapIsWritten() {
        let hid = FakeHID()

        apply(.capsLock, enabled: true, hid)
        XCTAssertEqual(hid.capsLockOffCalls, 1, "installed")

        apply(.capsLock, enabled: true, hid)
        XCTAssertEqual(hid.capsLockOffCalls, 1, "already current: the lock is left alone")

        apply(.capsLock, enabled: false, hid)
        XCTAssertEqual(hid.capsLockOffCalls, 1, "removed: the key is the user's again")

        hid.writeSucceeds = false
        apply(.capsLock, enabled: true, hid)
        XCTAssertEqual(hid.capsLockOffCalls, 1, "a failed write leaves Caps Lock working, so the lock stays")
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
