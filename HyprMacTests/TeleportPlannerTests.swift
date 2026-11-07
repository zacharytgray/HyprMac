import XCTest
@testable import HyprMac

final class TeleportPlannerTests: XCTestCase {
    private let left = CGRect(x: 8, y: 41, width: 744, height: 839)
    private let right = CGRect(x: 760, y: 41, width: 744, height: 839)

    func testSwapGivesBothMoves() {
        let moves = TeleportPlanner.moves(originals: [1: left, 2: right], targets: [(1, right), (2, left)])
        XCTAssertEqual(moves, [TeleportMove(windowID: 1, from: left, to: right),
                               TeleportMove(windowID: 2, from: right, to: left)])
    }

    func testWindowAlreadyOnTargetIsNoMove() {
        let nudged = left.offsetBy(dx: 2, dy: 0)
        XCTAssertTrue(TeleportPlanner.moves(originals: [1: left], targets: [(1, nudged)]).isEmpty)
    }

    // a window that rounds its width sits past its tile on every pass. the
    // engine calls that on target, so it is not a teleport either
    func testWindowSittingPastItsTileIsNoMove() {
        let rounded = CGRect(x: 8, y: 41, width: 751, height: 839)
        XCTAssertTrue(TeleportPlanner.moves(originals: [1: rounded], targets: [(1, left)]).isEmpty)
    }

    func testOnlyTheSwappedPairMovesNextToARoundedWindow() {
        let mail = CGRect(x: 8, y: 41, width: 751, height: 839)
        let top = CGRect(x: 760, y: 41, width: 744, height: 385)
        let bottom = CGRect(x: 760, y: 434, width: 744, height: 446)
        let moves = TeleportPlanner.moves(originals: [1: mail, 2: top, 3: bottom],
                                          targets: [(1, left), (2, bottom), (3, top)])
        XCTAssertEqual(moves.map(\.windowID), [2, 3])
    }

    func testWindowWithoutOriginalIsSkipped() {
        XCTAssertTrue(TeleportPlanner.moves(originals: [:], targets: [(1, right)]).isEmpty)
    }

    func testResizeOnlyCountsAsTravel() {
        let wider = CGRect(x: 8, y: 41, width: 1496, height: 839)
        XCTAssertEqual(TeleportPlanner.moves(originals: [1: left], targets: [(1, wider)]).count, 1)
    }

    func testRetileOfManyWindowsDoesNotAnimate() {
        let ids: [CGWindowID] = [1, 2, 3, 4, 5]
        let originals = Dictionary(uniqueKeysWithValues: ids.map { ($0, left) })
        XCTAssertTrue(TeleportPlanner.moves(originals: originals, targets: ids.map { ($0, right) }).isEmpty)
    }

    func testOnlyKeyboardFocusAndTeleportsGlide() {
        XCTAssertTrue(TeleportPlanner.animates(.swapDirection(.left)))
        XCTAssertTrue(TeleportPlanner.animates(.moveWindowToMonitor(.right)))
        XCTAssertTrue(TeleportPlanner.animates(.toggleSplit))
        XCTAssertTrue(TeleportPlanner.animates(.toggleMaximize))
        XCTAssertTrue(TeleportPlanner.animates(.toggleFloating))
        XCTAssertTrue(TeleportPlanner.animates(.focusDirection(.up)))
        XCTAssertFalse(TeleportPlanner.animates(.resizeDirection(.left)))
        XCTAssertFalse(TeleportPlanner.animates(.switchWorkspace(2)))
        XCTAssertFalse(TeleportPlanner.animates(.retileAll))
        XCTAssertFalse(TeleportPlanner.animates(.focusFloating))
    }

    // the glide is on unless config.json says otherwise, and a bad value
    // reads as unset instead of costing the rest of the config
    func testAnimateFocusIndicatorDecodesTolerantly() throws {
        func decode(_ value: String?) throws -> SavedConfig {
            let extra = value.map { #","animateFocusIndicator":\#($0)"# } ?? ""
            let json = #"{"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true\#(extra)}"#
            return try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
        }
        XCTAssertNil(try decode(nil).animateFocusIndicator)
        XCTAssertEqual(try decode("false").animateFocusIndicator, false)
        XCTAssertNil(try decode(#""yes""#).animateFocusIndicator)
        XCTAssertTrue(UserConfigDefaults.animateFocusIndicator)
    }
}
