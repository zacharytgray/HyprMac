import XCTest
@testable import HyprMac

final class SettingsSearchIndexTests: XCTestCase {
    func testEverySectionHasEntries() {
        for section in SettingsSection.allCases {
            XCTAssertFalse(SettingsSearchIndex.entries.filter { $0.section == section }.isEmpty,
                           "\(section) has no search entries")
        }
    }

    func testIDsAreUnique() {
        let ids = SettingsSearchIndex.entries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testKeywordFindsTheSetting() {
        XCTAssertEqual(SettingsSearchIndex.matches("dock").first?.title, "Show in Dock")
        XCTAssertTrue(SettingsSearchIndex.matches("caps").contains { $0.title == "Hypr key" })
    }

    func testEveryWordMustMatch() {
        XCTAssertEqual(SettingsSearchIndex.matches("layer padding").map(\.title), ["Scratchpad margin"])
        XCTAssertTrue(SettingsSearchIndex.matches("zzz").isEmpty)
        XCTAssertTrue(SettingsSearchIndex.matches("   ").isEmpty)
    }
}
