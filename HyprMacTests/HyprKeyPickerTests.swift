import XCTest
import Carbon
@testable import HyprMac

final class HyprKeyPickerTests: XCTestCase {
    private let dropped: [HyprKey] = [
        .tab, .grave, .leftShift, .rightShift, .leftControl, .rightControl
    ]

    // MARK: offered choices

    func testPickerOffersTheAgreedKeysInOrder() {
        XCTAssertEqual(HyprKey.pickerChoices, [
            .capsLock, .backslash,
            .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
            .leftOption, .rightOption, .leftCommand, .rightCommand
        ])
    }

    func testDefaultKeyIsOfferedFirst() {
        XCTAssertEqual(HyprKey.pickerChoices.first, UserConfigDefaults.hyprKey)
        XCTAssertTrue(UserConfigDefaults.hyprKey.isOffered)
    }

    func testDroppedKeysAreNotOffered() {
        for key in dropped {
            XCTAssertFalse(key.isOffered, "\(key) should not be offered")
        }
    }

    func testEveryCaseIsEitherOfferedOrDropped() {
        let offered = Set(HyprKey.pickerChoices)
        XCTAssertEqual(offered.count, HyprKey.pickerChoices.count, "no duplicate choices")
        XCTAssertTrue(offered.isDisjoint(with: dropped))
        XCTAssertEqual(offered.union(dropped), Set(HyprKey.allCases))
    }

    // MARK: picker rows

    func testOfferedKeyShowsOnlyTheChoices() {
        for key in HyprKey.pickerChoices {
            XCTAssertEqual(HyprKey.pickerRows(for: key), HyprKey.pickerChoices, "\(key)")
        }
    }

    func testDroppedKeyKeepsOneRowAtTheEnd() {
        for key in dropped {
            let rows = HyprKey.pickerRows(for: key)
            XCTAssertEqual(rows, HyprKey.pickerChoices + [key], "\(key)")
            XCTAssertEqual(rows.filter { $0 == key }.count, 1, "\(key)")
        }
    }

    func testDroppedRowGoesAwayOnceAnotherKeyIsPicked() {
        XCTAssertTrue(HyprKey.pickerRows(for: .tab).contains(.tab))
        XCTAssertFalse(HyprKey.pickerRows(for: .capsLock).contains(.tab))
        XCTAssertFalse(HyprKey.pickerRows(for: .leftOption).contains(.rightShift))
    }

    // MARK: not-recommended note

    func testOfferedKeysHaveNoNotRecommendedNote() {
        for key in HyprKey.pickerChoices {
            XCTAssertNil(key.notRecommendedNote, "\(key)")
        }
    }

    func testDroppedKeysHaveOnePlainSentence() {
        for key in dropped {
            guard let note = key.notRecommendedNote else {
                XCTFail("missing note for \(key)")
                continue
            }
            XCTAssertTrue(note.contains(" is no longer recommended as the Hypr key because "), note)
            XCTAssertTrue(note.hasSuffix("."), note)
            XCTAssertEqual(note.filter { $0 == "." }.count, 1, "one sentence: \(note)")
            XCTAssertNil(key.leftModifierNote, "\(key)")
        }
    }

    func testNoteGivesTheRightReason() {
        for key in [HyprKey.leftShift, .rightShift] {
            XCTAssertTrue(key.notRecommendedNote?.contains("add Shift to Hypr") == true, "\(key)")
        }
        for key in [HyprKey.leftControl, .rightControl] {
            XCTAssertTrue(key.notRecommendedNote?.contains("add Control to Hypr") == true, "\(key)")
        }
        XCTAssertEqual(HyprKey.tab.notRecommendedNote,
                       "Tab is no longer recommended as the Hypr key because it blocks the default Hypr+Tab and Hypr+Shift+Tab shortcuts that cycle workspaces.")
        XCTAssertEqual(HyprKey.grave.notRecommendedNote,
                       "Backtick (`) is no longer recommended as the Hypr key because it blocks the default Hypr+` shortcut that focuses the menu bar.")
    }

    // the tab and backtick notes name these binds, so they must stay defaults
    func testBindsNamedByTheTabAndBacktickNotesAreDefaults() {
        let defaults = Keybind.defaults
        XCTAssertTrue(defaults.contains(Keybind(keyCode: UInt16(kVK_Tab), modifiers: .hypr,
                                                action: .cycleWorkspace(1))))
        XCTAssertTrue(defaults.contains(Keybind(keyCode: UInt16(kVK_Tab), modifiers: [.hypr, .shift],
                                                action: .cycleWorkspace(-1))))
        XCTAssertTrue(defaults.contains(Keybind(keyCode: UInt16(kVK_ANSI_Grave), modifiers: .hypr,
                                                action: .focusMenuBar)))
    }

    // MARK: left-hand modifier note

    func testOnlyLeftOptionAndLeftCommandGetTheLeftModifierNote() {
        for key in HyprKey.allCases {
            if key == .leftOption || key == .leftCommand {
                XCTAssertNotNil(key.leftModifierNote, "\(key)")
            } else {
                XCTAssertNil(key.leftModifierNote, "\(key)")
            }
        }
    }

    func testLeftModifierNoteIsShortAndPointsToTheRightKey() {
        for (key, glyph) in [(HyprKey.leftOption, "⌥"), (.leftCommand, "⌘")] {
            let note = key.leftModifierNote ?? ""
            XCTAssertTrue(note.hasPrefix("With the left \(glyph) as Hypr, "), note)
            XCTAssertTrue(note.hasSuffix("Use the right \(glyph) for them."), note)
            XCTAssertEqual(note.filter { $0 == "." }.count, 2, "two sentences: \(note)")
            XCTAssertFalse(note.contains("no longer recommended"), note)
        }
    }

    // the named examples must be keys the defaults bind with plain Hypr,
    // or the note would promise a clash that isn't there
    func testLeftModifierExamplesAreBoundByTheDefaults() {
        let hyprOnly = Set(Keybind.defaults.filter { $0.modifiers == .hypr }.map(\.keyCode))
        let optionExamples: [(String, Int)] = [("⌥←", kVK_LeftArrow), ("⌥→", kVK_RightArrow)]
        let commandExamples: [(String, Int)] = [
            ("⌘S", kVK_ANSI_S), ("⌘T", kVK_ANSI_T), ("⌘W", kVK_ANSI_W),
            ("⌘1–9", kVK_ANSI_1), ("⌘1–9", kVK_ANSI_5), ("⌘1–9", kVK_ANSI_9)
        ]
        for (key, examples) in [(HyprKey.leftOption, optionExamples), (.leftCommand, commandExamples)] {
            let note = key.leftModifierNote ?? ""
            for (label, keyCode) in examples {
                XCTAssertTrue(note.contains(label), "\(label) missing from \(note)")
                XCTAssertTrue(hyprOnly.contains(UInt16(keyCode)), "\(label) is not a default Hypr bind")
            }
        }
    }

    // MARK: config decoding

    func testDroppedKeysKeepTheirRawValues() {
        XCTAssertEqual(dropped.map(\.rawValue), [
            "tab", "grave", "leftShift", "rightShift", "leftControl", "rightControl"
        ])
    }

    func testDroppedKeysStillDecodeAndRoundTrip() throws {
        for key in dropped {
            let json = """
            {"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true,"hyprKey":"\(key.rawValue)"}
            """
            let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
            XCTAssertEqual(saved.hyprKey, key)

            let encoded = try JSONEncoder().encode(saved)
            XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"hyprKey\":\"\(key.rawValue)\""))
            let again = try JSONDecoder().decode(SavedConfig.self, from: encoded)
            XCTAssertEqual(again.hyprKey, key)
        }
    }

    // why the cases stay: an unknown value falls back to the default Hypr
    // key, so removing a case would quietly move its users to Caps Lock
    func testUnknownHyprKeyFallsBackToTheDefaultKey() throws {
        let json = """
        {"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true,"hyprKey":"leftHyper"}
        """
        let saved = try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
        XCTAssertNil(saved.hyprKey)
        XCTAssertEqual(saved.hyprKey ?? UserConfigDefaults.hyprKey, .capsLock)
    }
}
