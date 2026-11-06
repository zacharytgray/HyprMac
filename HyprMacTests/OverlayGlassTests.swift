import XCTest
import SwiftUI
@testable import HyprMac

// the overlay glass: its tint constants and the pinned-header fade in Hypr+K
final class OverlayGlassTests: XCTestCase {

    func testGlassTintsStayNeutralAndSubtle() {
        XCTAssertGreaterThan(OverlayGlassTint.hud, 0)
        XCTAssertLessThan(OverlayGlassTint.hud, OverlayGlassTint.card)
        XCTAssertLessThanOrEqual(OverlayGlassTint.card, 0.4)
    }

    func testEdgeFadeClearsUnderTheHeaderAndKeepsRestingRowsSolid() throws {
        let viewport: CGFloat = 380
        let stops = OverlayListLayout.edgeFadeStops(viewport: viewport, moreBelow: false)
        XCTAssertEqual(stops.map(\.color), [.clear, .clear, .black, .black])
        let locations = stops.map(\.location)
        XCTAssertEqual(locations, locations.sorted())
        XCTAssertEqual(locations.first, 0)
        XCTAssertEqual(locations.last, 1)
        // clear through the header text, solid before a resting row's text
        let header = OverlayListLayout.headerHeight
        XCTAssertEqual(locations[1] * viewport, header - 4, accuracy: 0.001)
        XCTAssertEqual(locations[2] * viewport, header + 10, accuracy: 0.001)
        XCTAssertLessThan(locations[1] * viewport, header)
    }

    func testEdgeFadeKeepsTheMoreBelowCue() {
        let viewport: CGFloat = 380
        let stops = OverlayListLayout.edgeFadeStops(viewport: viewport, moreBelow: true)
        XCTAssertEqual(stops.map(\.color), [.clear, .clear, .black, .black, .clear])
        let locations = stops.map(\.location)
        XCTAssertEqual(locations, locations.sorted())
        XCTAssertEqual(locations[3] * viewport, viewport - OverlayListLayout.bottomFadeHeight, accuracy: 0.001)
        XCTAssertEqual(locations[4], 1)
    }

    func testHeadersFadeOnlyAtTheBottom() {
        let viewport: CGFloat = 380
        let more = OverlayListLayout.edgeFadeStops(viewport: viewport, moreBelow: true, underHeader: false)
        XCTAssertEqual(more.map(\.color), [.black, .black, .clear])
        XCTAssertEqual(more[1].location * viewport, viewport - OverlayListLayout.bottomFadeHeight, accuracy: 0.001)
        let none = OverlayListLayout.edgeFadeStops(viewport: viewport, moreBelow: false, underHeader: false)
        XCTAssertEqual(none.map(\.color), [.black, .black])
    }

    func testEdgeFadeStaysOrderedOnTheShortestList() {
        let stops = OverlayListLayout.edgeFadeStops(viewport: OverlayListLayout.minimumHeight, moreBelow: true)
        let locations = stops.map(\.location)
        XCTAssertEqual(locations, locations.sorted())
        XCTAssertTrue(OverlayListLayout.edgeFadeStops(viewport: 0, moreBelow: true).isEmpty)
    }
}
