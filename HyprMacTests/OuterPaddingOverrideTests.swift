import XCTest
import Cocoa
@testable import HyprMac

// OuterPaddingOverrideTests pin the per-monitor, per-side outer padding
// override: each overridden side moves only its own edge, a monitor or a
// side without an entry keeps outerPadding, and the engine's layout and its
// intended rects (what the drift monitor reads) agree on it. runs on
// synthetic screens so it executes headless.

final class OuterPaddingOverrideTests: XCTestCase {

    private let usable = CGRect(x: 0, y: 25, width: 2000, height: 1000)

    private func padded(_ rect: CGRect, outer: CGFloat) -> CGRect {
        rect.insetBy(dx: outer, dy: outer)
    }

    private func inner(_ padding: EdgePadding?, outer: CGFloat = 8) -> CGRect {
        padded(TilingEngine.tilingRect(usable, outerPadding: outer, padding: padding), outer: outer)
    }

    // MARK: - tilingRect

    func testNoOverrideKeepsTheUsableFrame() {
        XCTAssertEqual(TilingEngine.tilingRect(usable, outerPadding: 8, padding: nil), usable)
        XCTAssertEqual(TilingEngine.tilingRect(usable, outerPadding: 8, padding: EdgePadding()), usable)
    }

    func testLargerOverrideMovesOnlyTheTopEdge() {
        let inner = inner(EdgePadding(top: 40))
        XCTAssertEqual(inner.minY, usable.minY + 40)
        XCTAssertEqual(inner.maxY, usable.maxY - 8)
        XCTAssertEqual(inner.minX, usable.minX + 8)
        XCTAssertEqual(inner.maxX, usable.maxX - 8)
    }

    func testSmallerOverrideMovesOnlyTheTopEdge() {
        let inner = inner(EdgePadding(top: 2))
        XCTAssertEqual(inner.minY, usable.minY + 2)
        XCTAssertEqual(inner.maxY, usable.maxY - 8)
        XCTAssertEqual(inner.width, usable.width - 16)
    }

    func testLeftOverrideMovesOnlyTheLeftEdge() {
        let inner = inner(EdgePadding(left: 40))
        XCTAssertEqual(inner.minX, usable.minX + 40)
        XCTAssertEqual(inner.maxX, usable.maxX - 8)
        XCTAssertEqual(inner.minY, usable.minY + 8)
        XCTAssertEqual(inner.maxY, usable.maxY - 8)
    }

    func testRightOverrideMovesOnlyTheRightEdge() {
        let inner = inner(EdgePadding(right: 40))
        XCTAssertEqual(inner.maxX, usable.maxX - 40)
        XCTAssertEqual(inner.minX, usable.minX + 8)
        XCTAssertEqual(inner.minY, usable.minY + 8)
        XCTAssertEqual(inner.maxY, usable.maxY - 8)
    }

    // CG y grows down, so the bottom edge is maxY
    func testBottomOverrideMovesOnlyTheBottomEdge() {
        let inner = inner(EdgePadding(bottom: 40))
        XCTAssertEqual(inner.maxY, usable.maxY - 40)
        XCTAssertEqual(inner.minY, usable.minY + 8)
        XCTAssertEqual(inner.minX, usable.minX + 8)
        XCTAssertEqual(inner.maxX, usable.maxX - 8)
    }

    func testTwoOverridesMoveOnlyTheirEdges() {
        let inner = inner(EdgePadding(top: 37, right: 70))
        XCTAssertEqual(inner.minY, usable.minY + 37)
        XCTAssertEqual(inner.maxX, usable.maxX - 70)
        XCTAssertEqual(inner.minX, usable.minX + 8)
        XCTAssertEqual(inner.maxY, usable.maxY - 8)

        let opposite = self.inner(EdgePadding(left: 0, bottom: 60))
        XCTAssertEqual(opposite.minX, usable.minX)
        XCTAssertEqual(opposite.maxY, usable.maxY - 60)
        XCTAssertEqual(opposite.minY, usable.minY + 8)
        XCTAssertEqual(opposite.maxX, usable.maxX - 8)
    }

    func testOverrideEqualToOuterPaddingChangesNothing() {
        XCTAssertEqual(TilingEngine.tilingRect(usable, outerPadding: 8, padding: EdgePadding(top: 8)), usable)
        XCTAssertEqual(TilingEngine.tilingRect(usable, outerPadding: 8,
                                               padding: EdgePadding(top: 8, left: 8, bottom: 8, right: 8)), usable)
    }

    func testOutOfRangeOverrideIsClamped() {
        let negative = inner(EdgePadding(top: -30))
        XCTAssertEqual(negative.minY, usable.minY)
        let huge = inner(EdgePadding(top: 99_999))
        XCTAssertEqual(huge.minY, usable.minY + usable.height / 2)
        XCTAssertGreaterThan(huge.size.height, 0)

        let sides = inner(EdgePadding(left: -5, bottom: 99_999, right: 99_999))
        XCTAssertEqual(sides.minX, usable.minX)
        XCTAssertEqual(sides.maxX, usable.maxX - usable.width / 2)
        XCTAssertEqual(sides.maxY, usable.maxY - usable.height / 2)
        XCTAssertEqual(sides.minY, usable.minY + 8)
    }

    // size.width/height are raw; CGRect.width/height would hide an inverted rect
    func testOpposingMaxedOverridesNeverInvertTheRect() {
        let huge = EdgePadding(top: 99_999, left: 99_999, bottom: 99_999, right: 99_999)
        for outer: CGFloat in [0, 8, 40] {
            let rect = TilingEngine.tilingRect(usable, outerPadding: outer, padding: huge)
            XCTAssertGreaterThan(rect.size.width - 2 * outer, 0, "outer \(outer)")
            XCTAssertGreaterThan(rect.size.height - 2 * outer, 0, "outer \(outer)")
            XCTAssertGreaterThanOrEqual(rect.minX + outer, usable.minX)
            XCTAssertLessThanOrEqual(rect.maxX - outer, usable.maxX)
            XCTAssertGreaterThanOrEqual(rect.minY + outer, usable.minY)
            XCTAssertLessThanOrEqual(rect.maxY - outer, usable.maxY)
        }

        // an exact half on each side would meet in the middle
        let half = TilingEngine.tilingRect(usable, outerPadding: 8,
                                           padding: EdgePadding(top: 500, bottom: 500))
        XCTAssertGreaterThan(half.size.height - 16, 0)
    }

    // MARK: - engine

    private func engine(_ screens: [NSScreen]) -> TilingEngine {
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { screens }),
                                  frameSizingIOFactory: acceptingFrameSizingIOFactory())
        engine.gapSize = 8
        engine.outerPadding = 8
        return engine
    }

    private func engineAndScreen(_ screen: NSScreen = OuterPaddingTestScreen()) -> (TilingEngine, NSScreen) {
        (engine([screen]), screen)
    }

    func testVerifiedLayoutUsesTheOverrideForTheTopEdgeOnly() {
        let (engine, screen) = engineAndScreen()
        engine.outerPaddingPerMonitor = [screen.localizedName: EdgePadding(top: 40)]
        let window = makeWindow(id: 1)

        XCTAssertTrue(engine.tileWindows([window], onWorkspace: 1, screen: screen).published)
        // intendedTileRects is what the drift monitor compares against
        XCTAssertEqual(engine.intendedTileRects()[window.windowID],
                       CGRect(x: 8, y: 40, width: 2384, height: 1552))

        // a live change below outerPadding retiles too, and still verifies
        engine.outerPaddingPerMonitor = [screen.localizedName: EdgePadding(top: 2)]
        XCTAssertTrue(engine.tileWindows([window], onWorkspace: 1, screen: screen).published)
        XCTAssertEqual(engine.intendedTileRects()[window.windowID],
                       CGRect(x: 8, y: 2, width: 2384, height: 1590))
    }

    func testVerifiedLayoutMovesOnlyTheOverriddenSide() {
        let cases: [(EdgePadding, CGRect)] = [
            (EdgePadding(left: 40), CGRect(x: 40, y: 8, width: 2352, height: 1584)),
            (EdgePadding(bottom: 40), CGRect(x: 8, y: 8, width: 2384, height: 1552)),
            (EdgePadding(right: 40), CGRect(x: 8, y: 8, width: 2352, height: 1584)),
            (EdgePadding(top: 37, left: 60), CGRect(x: 60, y: 37, width: 2332, height: 1555)),
        ]
        for (padding, expected) in cases {
            let (engine, screen) = engineAndScreen()
            engine.outerPaddingPerMonitor = [screen.localizedName: padding]
            let window = makeWindow(id: 1)

            XCTAssertTrue(engine.tileWindows([window], onWorkspace: 1, screen: screen).published)
            XCTAssertEqual(engine.intendedTileRects()[window.windowID], expected, "\(padding)")
        }
    }

    // the tutorial's lesson card: room under one workspace's tiles only,
    // gone when cleared
    func testABottomInsetRaisesOnlyItsWorkspacesTiles() {
        let (engine, screen) = engineAndScreen()
        engine.workspaceBottomInsets[2] = 150
        let practice = makeWindow(id: 1)
        let own = makeWindow(id: 2)

        XCTAssertTrue(engine.tileWindows([practice], onWorkspace: 2, screen: screen).published)
        XCTAssertTrue(engine.tileWindows([own], onWorkspace: 1, screen: screen).published)
        XCTAssertEqual(engine.intendedTileRects()[practice.windowID], CGRect(x: 8, y: 8, width: 2384, height: 1434))
        XCTAssertEqual(engine.intendedTileRects()[own.windowID], CGRect(x: 8, y: 8, width: 2384, height: 1584))

        engine.workspaceBottomInsets[2] = nil
        XCTAssertTrue(engine.tileWindows([practice], onWorkspace: 2, screen: screen).published)
        XCTAssertEqual(engine.intendedTileRects()[practice.windowID], CGRect(x: 8, y: 8, width: 2384, height: 1584))
    }

    func testEngineWithoutAnOverrideKeepsOuterPadding() {
        let (engine, screen) = engineAndScreen()
        engine.outerPaddingPerMonitor = ["Some other monitor": EdgePadding(top: 40)]
        let window = makeWindow(id: 1)

        XCTAssertTrue(engine.tileWindows([window], onWorkspace: 1, screen: screen).published)
        XCTAssertEqual(engine.intendedTileRects()[window.windowID],
                       CGRect(x: 8, y: 8, width: 2384, height: 1584))
    }

    // the live setup from 2026-10-25: a 3440x1440 external with the menu
    // bar hidden, outerPadding 8, top override 37. the bottom keeps its 8
    func testWideExternalSingleWindowKeepsTheBottomPadding() {
        let (engine, screen) = engineAndScreen(WideTestScreen())
        engine.outerPaddingPerMonitor = [screen.localizedName: EdgePadding(top: 37)]
        let window = makeWindow(id: 1)

        XCTAssertTrue(engine.tileWindows([window], onWorkspace: 1, screen: screen).published)
        XCTAssertEqual(engine.intendedTileRects()[window.windowID],
                       CGRect(x: 8, y: 37, width: 3424, height: 1395))
    }

    func testWideExternalSplitKeepsTheBottomPadding() {
        let (engine, screen) = engineAndScreen(WideTestScreen())
        engine.outerPaddingPerMonitor = [screen.localizedName: EdgePadding(top: 37)]
        let left = makeWindow(id: 1), right = makeWindow(id: 2)

        XCTAssertTrue(engine.tileWindows([left, right], onWorkspace: 1, screen: screen).published)
        let rects = engine.intendedTileRects()
        XCTAssertEqual(rects[left.windowID], CGRect(x: 8, y: 37, width: 1708, height: 1395))
        XCTAssertEqual(rects[right.windowID], CGRect(x: 1724, y: 37, width: 1708, height: 1395))
    }

    // the override applies to its own screen only. the unpadded screen sits
    // to the right, so its frame never covers the padded screen's left strip
    func testOverrideOnOneScreenLeavesTheOtherUnchanged() {
        let padded = OuterPaddingTestScreen(), plain = RightOfPrimaryTestScreen()
        let engine = engine([padded, plain])
        engine.outerPaddingPerMonitor = [padded.localizedName: EdgePadding(left: 40)]
        let a = makeWindow(id: 1), b = makeWindow(id: 2)

        XCTAssertTrue(engine.tileWindows([a], onWorkspace: 1, screen: padded).published)
        XCTAssertTrue(engine.tileWindows([b], onWorkspace: 2, screen: plain).published)
        let rects = engine.intendedTileRects()
        XCTAssertEqual(rects[a.windowID], CGRect(x: 40, y: 8, width: 2352, height: 1584))
        XCTAssertEqual(rects[b.windowID], CGRect(x: 2408, y: 8, width: 2384, height: 1584))
    }

    // raising a padding moves the tiling rect off a window that still
    // stands in the old strip. a refused candidate must roll it back there
    // instead of calling the original off-screen
    private func assertRefusedLayoutRollsBack(original origin: CGPoint, on screen: NSScreen,
                                              screens: [NSScreen], overrides: [String: EdgePadding],
                                              file: StaticString = #filePath, line: UInt = #line) {
        var positions: [CGWindowID: CGPoint] = [:]
        let stuckSize = CGSize(width: 1200, height: 800)
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { screens }),
                                  frameSizingIOFactory: { _, generation in
            FrameSizingIO(
                setMessagingTimeout: { _, _ in .success },
                writeSize: { _, _, _ in .success },
                writePosition: { id, position, _ in positions[id] = position; return .success },
                readPosition: { id, _ in (.success, positions[id] ?? .zero) },
                readSize: { _, _ in (.success, stuckSize) },
                now: { 0 }, sleep: { _ in }, currentGeneration: generation)
        })
        engine.outerPadding = 8
        engine.outerPaddingPerMonitor = overrides
        let window = makeWindow(id: 7)
        let tree = BSPTree()
        tree.insert(window)
        let original = CGRect(origin: origin, size: stuckSize)
        positions[window.windowID] = original.origin
        let rect = TilingEngine.tilingRect(engine.displayManager.cgRect(for: screen),
                                           outerPadding: 8, padding: overrides[screen.localizedName])

        let outcome = engine.applyVerifiedLayout(tree, in: rect, generation: engine.beginLayoutGeneration(),
                                                 originalFrames: [window.windowID: original])

        guard case .rejectedRestored = outcome else {
            return XCTFail("expected the original to be restored, got \(outcome)", file: file, line: line)
        }
        XCTAssertEqual(positions[window.windowID], original.origin, file: file, line: line)
    }

    func testRefusedLayoutRollsBackAWindowAboveTheNewTopEdge() {
        let screen = OuterPaddingTestScreen()
        assertRefusedLayoutRollsBack(original: CGPoint(x: 8, y: 8), on: screen, screens: [screen],
                                     overrides: [screen.localizedName: EdgePadding(top: 40)])
    }

    func testRefusedLayoutRollsBackAWindowLeftOfTheNewLeftEdge() {
        let screen = OuterPaddingTestScreen()
        assertRefusedLayoutRollsBack(original: CGPoint(x: 8, y: 8), on: screen, screens: [screen],
                                     overrides: [screen.localizedName: EdgePadding(left: 40)])
    }

    // restorationRect must find the padded screen, not the other one or none
    func testRefusedLayoutRestoresAgainstTheRightScreen() {
        let padded = OuterPaddingTestScreen(), plain = RightOfPrimaryTestScreen()
        let overrides = [padded.localizedName: EdgePadding(left: 40)]
        assertRefusedLayoutRollsBack(original: CGPoint(x: 8, y: 8), on: padded,
                                     screens: [padded, plain], overrides: overrides)
        assertRefusedLayoutRollsBack(original: CGPoint(x: 2408, y: 8), on: plain,
                                     screens: [padded, plain], overrides: overrides)
    }

    // MARK: - monitor-config

    func testMonitorConfigRoundTripsOuterPadding() throws {
        let padding = ["DELL U3225QE": EdgePadding(top: 37, left: 8), "Built-in": EdgePadding(bottom: 4)]
        let original = SavedMonitorConfig(maxSplitsPerMonitor: ["A": 4], disabledMonitors: [],
                                          outerPaddingPerMonitor: padding)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SavedMonitorConfig.self, from: data)
        XCTAssertEqual(decoded.outerPaddingPerMonitor, padding)
        XCTAssertEqual(decoded.maxSplitsPerMonitor, ["A": 4])

        // a missing side is left out, not written as null
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let dell = try XCTUnwrap((json["outerPaddingPerMonitor"] as? [String: Any])?["DELL U3225QE"]
                                 as? [String: Any])
        XCTAssertEqual(Set(dell.keys), ["top", "left"])
        XCTAssertNil(json["topPaddingPerMonitor"])
    }

    // the unreleased top-only key from PR #51 still loads, and is never written back
    func testLegacyTopPaddingDecodesAsTopOverrides() throws {
        let json = #"{"maxSplitsPerMonitor":{"A":2},"topPaddingPerMonitor":{"A":37,"B":4}}"#
        let decoded = try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.outerPaddingPerMonitor, ["A": EdgePadding(top: 37), "B": EdgePadding(top: 4)])
        XCTAssertEqual(decoded.maxSplitsPerMonitor, ["A": 2])

        let written = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        XCTAssertFalse(written.contains("topPaddingPerMonitor"))
        XCTAssertTrue(written.contains("outerPaddingPerMonitor"))

        // the new key wins when both are there
        let both = #"{"outerPaddingPerMonitor":{"A":{"left":12}},"topPaddingPerMonitor":{"A":37}}"#
        let newer = try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(both.utf8))
        XCTAssertEqual(newer.outerPaddingPerMonitor, ["A": EdgePadding(left: 12)])
    }

    // monitor-config.json is hand-editable. one unreadable value must
    // cost only that field, or the next save writes the others away.
    func testUnreadableMonitorConfigValueCostsOnlyItsField() throws {
        let badSide = #"{"maxSplitsPerMonitor":{"A":2},"disabledMonitors":["B"],"outerPaddingPerMonitor":{"A":{"top":"37","left":8}}}"#
        let decoded = try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(badSide.utf8))
        XCTAssertEqual(decoded.maxSplitsPerMonitor, ["A": 2])
        XCTAssertEqual(decoded.disabledMonitors, ["B"])
        XCTAssertEqual(decoded.outerPaddingPerMonitor, ["A": EdgePadding(left: 8)])

        let badEntry = #"{"maxSplitsPerMonitor":{"A":2},"outerPaddingPerMonitor":{"A":37}}"#
        let entry = try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(badEntry.utf8))
        XCTAssertEqual(entry.maxSplitsPerMonitor, ["A": 2])
        XCTAssertNil(entry.outerPaddingPerMonitor)

        let badLegacy = #"{"maxSplitsPerMonitor":{"A":2},"disabledMonitors":["B"],"topPaddingPerMonitor":{"A":"37"}}"#
        let legacy = try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(badLegacy.utf8))
        XCTAssertEqual(legacy.maxSplitsPerMonitor, ["A": 2])
        XCTAssertEqual(legacy.disabledMonitors, ["B"])
        XCTAssertNil(legacy.outerPaddingPerMonitor)

        let badSplits = #"{"maxSplitsPerMonitor":{"A":null},"outerPaddingPerMonitor":{"A":{"top":37}}}"#
        let other = try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(badSplits.utf8))
        XCTAssertNil(other.maxSplitsPerMonitor)
        XCTAssertEqual(other.outerPaddingPerMonitor, ["A": EdgePadding(top: 37)])
    }

    func testMonitorConfigWithoutPaddingLoadsUnchanged() throws {
        let json = #"{"maxSplitsPerMonitor":{"A":2},"disabledMonitors":["B"]}"#
        let decoded = try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(json.utf8))
        XCTAssertNil(decoded.outerPaddingPerMonitor)
        XCTAssertEqual(decoded.maxSplitsPerMonitor, ["A": 2])
        XCTAssertEqual(decoded.disabledMonitors, ["B"])
    }

    func testEdgePaddingIsEmptyOnlyWithNoSideSet() {
        XCTAssertTrue(EdgePadding().isEmpty)
        XCTAssertFalse(EdgePadding(top: 0).isEmpty)
        XCTAssertFalse(EdgePadding(right: 12).isEmpty)
    }
}

private final class OuterPaddingTestScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 2400, height: 1600) }
    override var visibleFrame: NSRect { frame }
}

private final class RightOfPrimaryTestScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 2400, y: 0, width: 2400, height: 1600) }
    override var visibleFrame: NSRect { frame }
}

private final class WideTestScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 3440, height: 1440) }
    override var visibleFrame: NSRect { frame }
}
