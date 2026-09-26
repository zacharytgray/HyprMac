import XCTest
@testable import HyprMac

final class HyprKeySystemGuidanceTests: XCTestCase {
    private let expected: [HyprKey: (String, String)] = [
        .capsLock: ("Caps Lock", "⇪ Caps Lock"),
        .leftControl: ("Control", "⌃ Control"),
        .rightControl: ("Control", "⌃ Control"),
        .leftOption: ("Option", "⌥ Option"),
        .rightOption: ("Option", "⌥ Option"),
        .leftCommand: ("Command", "⌘ Command"),
        .rightCommand: ("Command", "⌘ Command")
    ]

    func testGuidanceExistsOnlyForKeysMacOSCanRemap() {
        for key in HyprKey.allCases {
            let guidance = HyprKeySystemGuidance.forKey(key)
            if let (keyName, requiredAction) = expected[key] {
                XCTAssertEqual(guidance?.keyName, keyName, "expected guidance for \(key)")
                XCTAssertEqual(guidance?.requiredAction, requiredAction, "expected action for \(key)")
            } else {
                XCTAssertNil(guidance, "\(key) should need no Modifier Keys guidance")
            }
        }
    }

    func testEveryNonModifierKeyIsCovered() {
        let needsNothing: [HyprKey] = [
            .tab, .grave, .backslash,
            .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
            .leftShift, .rightShift
        ]
        for key in needsNothing {
            XCTAssertNil(HyprKeySystemGuidance.forKey(key), "\(key) should need no guidance")
        }
        XCTAssertEqual(needsNothing.count + expected.count, HyprKey.allCases.count)
    }

    // backslash and F13–F20 are not in the Modifier Keys pane
    func testOfferedKeysNeedingGuidanceAreCapsLockOptionAndCommand() {
        let needing = HyprKey.pickerChoices.filter { HyprKeySystemGuidance.forKey($0) != nil }
        XCTAssertEqual(needing, [.capsLock, .leftOption, .rightOption, .leftCommand, .rightCommand])
    }

    // the pane remaps Option and Command for both sides at once, so the
    // wording names the modifier, not the side
    func testLeftAndRightKeysShareTheSameWording() {
        XCTAssertEqual(HyprKeySystemGuidance.forKey(.leftOption), HyprKeySystemGuidance.forKey(.rightOption))
        XCTAssertEqual(HyprKeySystemGuidance.forKey(.leftCommand), HyprKeySystemGuidance.forKey(.rightCommand))
        XCTAssertEqual(HyprKeySystemGuidance.forKey(.leftOption)?.title,
                       "Keep Option set to \"⌥ Option\" in Modifier Keys on each keyboard.")
        XCTAssertEqual(HyprKeySystemGuidance.forKey(.leftCommand)?.title,
                       "Keep Command set to \"⌘ Command\" in Modifier Keys on each keyboard.")
    }

    func testCapsLockGuidanceWording() {
        let guidance = HyprKeySystemGuidance.forKey(.capsLock)
        XCTAssertEqual(guidance?.title,
                       "Keep Caps Lock set to \"⇪ Caps Lock\" in Modifier Keys on each keyboard.")
        XCTAssertEqual(guidance?.detail,
                       "Check System Settings → Keyboard → Keyboard Shortcuts… → Modifier Keys for each keyboard you use. \"No Action\" or any other choice hides Caps Lock from HyprMac. HyprMac can't check it for you.")
    }

    func testTitleNamesTheKeyAndTheRequiredAction() {
        for (key, (keyName, requiredAction)) in expected {
            guard let guidance = HyprKeySystemGuidance.forKey(key) else {
                XCTFail("missing guidance for \(key)")
                continue
            }
            XCTAssertTrue(guidance.title.contains(keyName), guidance.title)
            XCTAssertTrue(guidance.title.contains(requiredAction), guidance.title)
            XCTAssertTrue(guidance.title.contains("Modifier Keys"), guidance.title)
        }
    }

    func testDetailWarnsAboutNoActionAndEveryKeyboard() {
        for (key, (keyName, _)) in expected {
            guard let guidance = HyprKeySystemGuidance.forKey(key) else {
                XCTFail("missing guidance for \(key)")
                continue
            }
            XCTAssertTrue(guidance.detail.contains(keyName), guidance.detail)
            XCTAssertTrue(guidance.detail.contains("No Action"), guidance.detail)
            XCTAssertTrue(guidance.detail.contains("each keyboard"), guidance.detail)
            XCTAssertTrue(guidance.detail.contains(HyprKeySystemGuidance.settingsPath), guidance.detail)
        }
    }

    func testSettingsPathSpellsOutTheWholeRoute() {
        XCTAssertEqual(
            HyprKeySystemGuidance.settingsPath,
            "System Settings → Keyboard → Keyboard Shortcuts… → Modifier Keys")
    }

    func testKeyboardSettingsURLMatchesTheKeyboardPaneDeepLink() {
        XCTAssertEqual(
            HyprKeySystemGuidance.keyboardSettingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?CustomizeModifierKeys")
    }

    func testOpenKeyboardSettingsPassesTheDeepLinkToTheOpener() {
        var opened: [URL] = []
        let result = HyprKeySystemGuidance.openKeyboardSettings { url in
            opened.append(url)
            return true
        }
        XCTAssertTrue(result)
        XCTAssertEqual(opened, [HyprKeySystemGuidance.keyboardSettingsURL])
    }

    func testOpenKeyboardSettingsReportsRefusal() {
        var opened: [URL] = []
        let result = HyprKeySystemGuidance.openKeyboardSettings { url in
            opened.append(url)
            return false
        }
        XCTAssertFalse(result)
        XCTAssertEqual(opened, [HyprKeySystemGuidance.keyboardSettingsURL])
    }

    func testOpenButtonTitleIsPlain() {
        XCTAssertEqual(HyprKeySystemGuidance.openButtonTitle, "Open Keyboard Settings")
    }
}
