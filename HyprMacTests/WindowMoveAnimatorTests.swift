import XCTest
@testable import HyprMac

final class WindowMoveAnimatorTests: XCTestCase {

    func testEveryStyleIsClampedAndMonotonic() {
        for style in WindowAnimationStyle.allCases {
            XCTAssertEqual(WindowMoveAnimator.eased(-1, style: style), 0, accuracy: 0.0001, "\(style)")
            XCTAssertEqual(WindowMoveAnimator.eased(0, style: style), 0, accuracy: 0.0001, "\(style)")
            XCTAssertEqual(WindowMoveAnimator.eased(1, style: style), 1, accuracy: 0.0001, "\(style)")
            XCTAssertEqual(WindowMoveAnimator.eased(2, style: style), 1, accuracy: 0.0001, "\(style)")
            var previous = 0.0
            for step in 1...10 {
                let value = WindowMoveAnimator.eased(Double(step) / 10, style: style)
                XCTAssertGreaterThanOrEqual(value, previous, "\(style)")
                previous = value
            }
        }
    }

    func testStylesDifferAtTheMidpoint() {
        let mids = WindowAnimationStyle.allCases.map { WindowMoveAnimator.eased(0.25, style: $0) }
        XCTAssertEqual(Set(mids.map { Int($0 * 1000) }).count, mids.count)
    }

    func testDurationClampsToTheRange() {
        XCTAssertEqual(UserConfig.clampedAnimationDuration(nil), UserConfigDefaults.windowAnimationDurationMs)
        XCTAssertEqual(UserConfig.clampedAnimationDuration(5), 80)
        XCTAssertEqual(UserConfig.clampedAnimationDuration(9000), 400)
        XCTAssertEqual(UserConfig.clampedAnimationDuration(200), 200)
    }

    func testFrameInterpolatesPositionAndSize() {
        let from = CGRect(x: 0, y: 0, width: 100, height: 100)
        let to = CGRect(x: 200, y: 100, width: 300, height: 50)
        XCTAssertEqual(WindowMoveAnimator.frame(from: from, to: to, progress: 0), from)
        XCTAssertEqual(WindowMoveAnimator.frame(from: from, to: to, progress: 1), to)
        let mid = WindowMoveAnimator.frame(from: from, to: to, progress: 0.5)
        XCTAssertGreaterThan(mid.minX, 0)
        XCTAssertLessThan(mid.minX, 200)
        XCTAssertGreaterThan(mid.width, 100)
        XCTAssertLessThan(mid.width, 300)
    }

    func testAnimationFlagDefaultsOffAndRoundTrips() throws {
        XCTAssertFalse(UserConfigDefaults.animateWindowMoves)
        let base = #"{"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true"#
        let missing = try JSONDecoder().decode(SavedConfig.self, from: Data((base + "}").utf8))
        XCTAssertNil(missing.animateWindowMoves)
        let on = try JSONDecoder().decode(SavedConfig.self,
            from: Data((base + #","animateWindowMoves":true}"#).utf8))
        XCTAssertEqual(on.animateWindowMoves, true)
        let styled = try JSONDecoder().decode(SavedConfig.self,
            from: Data((base + #","windowAnimationStyle":"snappy","windowAnimationDurationMs":240}"#).utf8))
        XCTAssertEqual(styled.windowAnimationStyle, .snappy)
        XCTAssertEqual(styled.windowAnimationDurationMs, 240)
        let unknown = try JSONDecoder().decode(SavedConfig.self,
            from: Data((base + #","windowAnimationStyle":"bouncy"}"#).utf8))
        XCTAssertNil(unknown.windowAnimationStyle)
        let again = try JSONDecoder().decode(SavedConfig.self, from: JSONEncoder().encode(styled))
        XCTAssertEqual(again.windowAnimationStyle, .snappy)
    }
}
