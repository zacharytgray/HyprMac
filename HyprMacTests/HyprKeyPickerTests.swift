import XCTest
@testable import HyprMac

final class HyprKeyPickerTests: XCTestCase {
    private let dropped: [HyprKey] = [
        .leftShift, .rightShift, .leftControl, .rightControl, .leftOption, .leftCommand
    ]

    // MARK: offered choices

    func testPickerOffersTheAgreedKeysInOrder() {
        XCTAssertEqual(HyprKey.pickerChoices, [
            .capsLock, .tab, .grave, .backslash,
            .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
            .rightOption, .rightCommand
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
        XCTAssertTrue(HyprKey.pickerRows(for: .rightShift).contains(.rightShift))
        XCTAssertFalse(HyprKey.pickerRows(for: .capsLock).contains(.rightShift))
        XCTAssertFalse(HyprKey.pickerRows(for: .rightOption).contains(.leftOption))
    }

    // MARK: note

    func testOfferedKeysHaveNoNote() {
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
            XCTAssertTrue(note.hasPrefix("\(key.displayName) is no longer recommended as the Hypr key because "), note)
            XCTAssertTrue(note.hasSuffix("."), note)
            XCTAssertEqual(note.filter { $0 == "." }.count, 1, "one sentence: \(note)")
        }
    }

    func testNoteGivesTheRightReason() {
        for key in [HyprKey.leftShift, .rightShift] {
            XCTAssertTrue(key.notRecommendedNote?.contains("add Shift to Hypr") == true, "\(key)")
        }
        for key in [HyprKey.leftControl, .rightControl] {
            XCTAssertTrue(key.notRecommendedNote?.contains("add Control to Hypr") == true, "\(key)")
        }
        XCTAssertTrue(HyprKey.leftOption.notRecommendedNote?.contains("⌥←") == true)
        XCTAssertTrue(HyprKey.leftCommand.notRecommendedNote?.contains("⌘W") == true)
    }

    // MARK: config decoding

    func testDroppedKeysKeepTheirRawValues() {
        XCTAssertEqual(dropped.map(\.rawValue), [
            "leftShift", "rightShift", "leftControl", "rightControl", "leftOption", "leftCommand"
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

    // why the cases stay: an unknown value fails the whole config decode
    func testUnknownHyprKeyFailsTheWholeDecode() {
        let json = """
        {"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true,"hyprKey":"leftHyper"}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8)))
    }
}
