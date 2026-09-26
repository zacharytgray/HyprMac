import XCTest
import Carbon
@testable import HyprMac

final class KeybindOverlayContentTests: XCTestCase {
    private func sections(_ binds: [Keybind] = Keybind.defaults, filter: String = "") -> [OverlaySection] {
        KeybindOverlayContent.sections(for: binds, filter: filter)
    }

    private func rows(_ category: KeybindCategory, in sections: [OverlaySection]) -> [OverlayRow] {
        sections.first { $0.category == category }?.rows ?? []
    }

    func testDefaultSectionsFollowTheSettingsOrder() {
        XCTAssertEqual(sections().map(\.title),
                       ["Focus & Navigation", "Window Management", "Workspaces", "Apps", "System"])
    }

    func testWorkspaceFamiliesFoldIntoNRows() {
        let workspaces = rows(.workspaces, in: sections())
        XCTAssertEqual(workspaces.prefix(3).map(\.description), [
            "Switch to workspace N",
            "Move window to workspace N",
            "Move window to workspace N and follow",
        ])
        XCTAssertEqual(workspaces.prefix(3).map(\.chord), [
            ["HYPR", "N"],
            ["HYPR", "⇧", "N"],
            ["HYPR", "⌃", "⇧", "N"],
        ])
        let everyRow = sections().flatMap(\.rows)
        XCTAssertFalse(everyRow.contains { $0.description.last?.isNumber == true },
                       "no workspace number is listed on its own")
    }

    func testDirectionFamiliesFoldIntoArrowRows() {
        let all = Dictionary(sections().flatMap(\.rows).map { ($0.description, $0.chord) },
                             uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(all["Focus direction"], ["HYPR", "←↑↓→"])
        XCTAssertEqual(all["Swap direction"], ["HYPR", "⇧", "←↑↓→"])
        XCTAssertEqual(all["Resize window"], ["HYPR", "⌃", "⇧", "←↑↓→"])
        XCTAssertEqual(all["Move to monitor"], ["HYPR", "⌃", "←→"])
    }

    func testDragSwapClosesWindowManagement() {
        let last = rows(.windowManagement, in: sections()).last
        XCTAssertEqual(last?.description, "Swap tiles by dragging")
        XCTAssertEqual(last?.chord, ["HYPR", "drag"])
        XCTAssertEqual(sections(filter: "dragging").map(\.category), [.windowManagement])
    }

    func testFilterKeepsMatchingRowsInSectionOrder() {
        let filtered = sections(filter: "work")
        XCTAssertEqual(filtered.map(\.category), [.workspaces, .system])
        XCTAssertEqual(rows(.workspaces, in: filtered).map(\.description), [
            "Switch to workspace N",
            "Move window to workspace N",
            "Move window to workspace N and follow",
            "Move to dedicated workspace",
            "Next Workspace",
            "Previous Workspace",
        ])
        XCTAssertEqual(rows(.system, in: filtered).map(\.description), ["Show Workspace Overview"])
        XCTAssertEqual(sections(filter: " WORK "), filtered, "case and outer spaces are ignored")
    }

    func testFilterWithNoMatchIsEmpty() {
        XCTAssertTrue(sections(filter: "zzz").isEmpty)
    }

    func testMatchRangeCoversTheTypedText() throws {
        let text = "Next Workspace"
        let range = try XCTUnwrap(KeybindOverlayContent.matchRange(in: text, query: "WORK"))
        XCTAssertEqual(String(text[range]), "Work")
        XCTAssertNil(KeybindOverlayContent.matchRange(in: text, query: ""))
    }

    func testRowIDsStayPutWhileFiltering() throws {
        let all = sections().flatMap(\.rows)
        let filtered = sections(filter: "next").flatMap(\.rows)
        let next = try XCTUnwrap(filtered.first { $0.description == "Next Workspace" })
        XCTAssertEqual(all.first { $0.description == "Next Workspace" }?.id, next.id)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "ids are unique")
    }

    func testAddedLaunchersOnlyGrowTheAppsSection() {
        var binds = Keybind.defaults
        let bundles = ["com.apple.Safari", "com.apple.mail", "com.apple.Notes", "com.apple.finder"]
        let keys = [kVK_ANSI_S, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_F]
        for (bundle, key) in zip(bundles, keys) {
            binds.append(Keybind(keyCode: UInt16(key), modifiers: [.hypr, .option],
                                 action: .launchApp(bundleID: bundle)))
        }
        let before = sections()
        let after = sections(binds)
        XCTAssertEqual(after.map(\.category), before.map(\.category))
        XCTAssertEqual(rows(.apps, in: after).count, rows(.apps, in: before).count + 4)
        for category in [KeybindCategory.focusNav, .windowManagement, .workspaces, .system] {
            XCTAssertEqual(rows(category, in: after), rows(category, in: before), category.rawValue)
        }
    }

    func testCustomizedFollowBindListsOnlyThatFamilyBindByBind() throws {
        var binds = Keybind.defaults
        let index = try XCTUnwrap(binds.firstIndex { $0.action == .moveToWorkspaceAndFollow(4) })
        binds[index] = Keybind(keyCode: UInt16(kVK_ANSI_Q), modifiers: [.hypr, .control, .shift],
                               action: .moveToWorkspaceAndFollow(4))

        let workspaces = rows(.workspaces, in: sections(binds)).map(\.description)
        XCTAssertTrue(workspaces.contains("Switch to workspace N"))
        XCTAssertTrue(workspaces.contains("Move window to workspace N"))
        XCTAssertFalse(workspaces.contains("Move window to workspace N and follow"))
        XCTAssertEqual(workspaces.filter { $0.hasSuffix("and Follow") }.count, 10)
    }

    // MARK: scrolling

    private func layoutSections(_ counts: [Int]) -> [OverlaySection] {
        zip(KeybindCategory.allCases, counts).map { category, count in
            OverlaySection(category: category, rows: (0..<count).map {
                OverlayRow(id: "\($0)", description: "row \($0)", chord: ["HYPR", "X"], isFloating: false)
            })
        }
    }

    func testScrollStopsPutEachRowUnderThePinnedHeader() {
        // header 30, rows 34: a first row shares its header's offset
        XCTAssertEqual(OverlayListLayout.scrollStops(for: layoutSections([3, 2])), [0, 34, 68, 132, 166])
    }

    func testArrowStepsMoveOneStopFromTheCurrentOffset() {
        let stops = OverlayListLayout.scrollStops(for: layoutSections([3, 2]))
        XCTAssertEqual(OverlayListLayout.stopIndex(from: 0, step: 1, in: stops), 1)
        XCTAssertEqual(OverlayListLayout.stopIndex(from: 34, step: 1, in: stops), 2)
        XCTAssertEqual(OverlayListLayout.stopIndex(from: 40, step: 1, in: stops), 2, "after a trackpad scroll")
        XCTAssertEqual(OverlayListLayout.stopIndex(from: 40, step: -1, in: stops), 1)
        XCTAssertEqual(OverlayListLayout.stopIndex(from: 200, step: -1, in: stops), 4)
        XCTAssertNil(OverlayListLayout.stopIndex(from: 0, step: -1, in: stops), "already at the top")
        XCTAssertNil(OverlayListLayout.stopIndex(from: 166, step: 1, in: stops), "already at the last row")
        XCTAssertNil(OverlayListLayout.stopIndex(from: 0, step: 0, in: stops))
        XCTAssertNil(OverlayListLayout.stopIndex(from: 0, step: 1, in: []))
    }

    func testBottomPaddingMakesTheLastScrollPositionAStop() {
        let sections = layoutSections([3, 2])  // 230 tall, stops 0 34 68 132 166
        XCTAssertEqual(OverlayListLayout.bottomPadding(for: sections, viewport: 100), 2)
        XCTAssertEqual(OverlayListLayout.bottomPadding(for: sections, viewport: 64), 0)
        XCTAssertEqual(OverlayListLayout.bottomPadding(for: sections, viewport: 300), 0, "fits, no scrolling")
    }

    private func attachedScroller() -> (OverlayScroller, NSScrollView) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        scrollView.documentView = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        let scroller = OverlayScroller()
        scroller.attach(scrollView)
        return (scroller, scrollView)
    }

    func testQuickArrowPressesCountFromThePendingTarget() {
        let (scroller, scrollView) = attachedScroller()
        let stops: [CGFloat] = [0, 34, 68, 132, 166]
        scroller.step(1, through: stops, animated: true)
        scroller.step(1, through: stops, animated: true)
        XCTAssertEqual(scroller.stepOrigin, 68, "the second press is not lost mid-animation")
        withExtendedLifetime(scrollView) {}
    }

    func testUnanimatedStepsScrollAtOnce() {
        let (scroller, scrollView) = attachedScroller()
        let stops: [CGFloat] = [0, 34, 68, 132, 166]
        scroller.step(1, through: stops, animated: false)
        XCTAssertEqual(scroller.offset, 34)
        scroller.step(1, through: stops, animated: false)
        scroller.step(-1, through: stops, animated: false)
        XCTAssertEqual(scroller.offset, 34)
        XCTAssertEqual(scroller.stepOrigin, 34)
        withExtendedLifetime(scrollView) {}
    }

    // MARK: keys

    private func command(_ keyCode: Int, _ chars: String?,
                         _ modifiers: NSEvent.ModifierFlags = []) -> OverlayKeyCommand {
        OverlayKeyCommand(keyCode: UInt16(keyCode), characters: chars, modifiers: modifiers)
    }

    func testKeysCloseTrimScrollAndType() {
        XCTAssertEqual(command(kVK_Escape, "\u{1B}"), .close)
        XCTAssertEqual(command(kVK_Delete, "\u{7F}"), .deleteBackward)
        XCTAssertEqual(command(kVK_DownArrow, "\u{F701}", [.function, .numericPad]), .scroll(1))
        XCTAssertEqual(command(kVK_UpArrow, "\u{F700}", [.function, .numericPad]), .scroll(-1))
        XCTAssertEqual(command(kVK_ANSI_A, "a"), .append("a"))
        XCTAssertEqual(command(kVK_ANSI_A, "A", .shift), .append("A"))
        XCTAssertEqual(command(kVK_Space, " "), .append(" "))
    }

    func testFunctionKeysNeverReachTheFilter() {
        XCTAssertEqual(command(kVK_LeftArrow, "\u{F702}", [.function, .numericPad]), .swallow)
        XCTAssertEqual(command(kVK_F18, "\u{F715}", .function), .swallow)
        XCTAssertEqual(command(kVK_Home, "\u{F729}", .function), .swallow)
    }

    func testCommandAndControlChordsPassThrough() {
        XCTAssertEqual(command(kVK_ANSI_C, "c", .command), .passThrough)
        XCTAssertEqual(command(kVK_DownArrow, "\u{F701}", .control), .passThrough)
        XCTAssertEqual(command(kVK_Tab, "\t"), .passThrough)
        XCTAssertEqual(command(kVK_ANSI_A, nil), .passThrough)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
