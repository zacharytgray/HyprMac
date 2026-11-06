import XCTest
import SwiftUI
@testable import HyprMac

// the glass/classic switch for the transient overlays: where the accent
// goes, the pinned-header fade, and that an open overlay follows the setting
final class OverlayStyleTests: XCTestCase {

    // MARK: palette mapping

    func testClassicKeepsTheBrandAccentsAndOpaqueHeaders() {
        for scheme in [ColorScheme.dark, .light] {
            let palette = OverlayPalette(scheme: scheme)
            XCTAssertEqual(palette.style, .classic)
            XCTAssertEqual(palette.listSectionHeaderFill, palette.opaqueBackground)
            XCTAssertTrue(palette.accentLabels)
            XCTAssertEqual(palette.fieldBorder, Color.overlayPrimary.opacity(0.45))
            XCTAssertEqual(palette.buttonFill, Color.overlayPrimary.opacity(0.12))
            XCTAssertEqual(palette.tiledWindowFill, Color.overlayPrimary.opacity(0.22))
            XCTAssertEqual(palette.floatingWindowOpacity, 0.45)
            XCTAssertEqual(palette.workspaceCardBorder(isActive: true), Color.overlayPrimary.opacity(0.7))
            XCTAssertEqual(palette.workspaceCardBorder(isActive: false), palette.separator)
        }
        XCTAssertEqual(OverlayPalette(scheme: .dark).preview, Color.black.opacity(0.35))
        XCTAssertEqual(OverlayPalette(scheme: .light).preview, Color.white.opacity(0.65))
    }

    func testGlassIsNeutralWithTheAccentOnlyOnSmallMarks() {
        for scheme in [ColorScheme.dark, .light] {
            let palette = OverlayPalette(scheme: scheme, style: .glass)
            XCTAssertTrue(palette.isGlass)
            // no second material behind pinned headers
            XCTAssertNil(palette.listSectionHeaderFill)
            // captions, section headers and ACTIVE are system labels, for vibrancy
            XCTAssertFalse(palette.accentLabels)
            // no colored borders or fills
            XCTAssertEqual(palette.fieldBorder, palette.separator)
            XCTAssertEqual(palette.buttonFill, palette.surface)
            XCTAssertEqual(palette.tiledWindowFill, Color.primary.opacity(0.12))
            XCTAssertEqual(palette.workspaceCardBorder(isActive: true), palette.separator)
            XCTAssertEqual(palette.workspaceCardBorder(isActive: false), palette.separator)
        }
    }

    func testGlassTintsStayNeutralAndSubtle() {
        XCTAssertGreaterThan(OverlayGlassTint.hud, 0)
        XCTAssertLessThan(OverlayGlassTint.hud, OverlayGlassTint.card)
        XCTAssertLessThanOrEqual(OverlayGlassTint.card, 0.4)
    }

    func testOverlayStyleEnvironmentDefaultsToClassicOutsideAnOverlay() {
        XCTAssertEqual(EnvironmentValues().overlayStyle, .classic)
    }

    // MARK: pinned-header fade

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

    // MARK: live apply

    func testOpenOverlayFollowsTheStyleSetting() throws {
        guard ProcessInfo.processInfo.environment["HYPRMAC_HEADLESS_TESTS"] == "1" else {
            throw XCTSkip("requires isolated config")
        }
        _ = NSApplication.shared
        let config = UserConfig.shared
        let previous = config.overlayStyle
        defer { config.overlayStyle = previous }
        config.overlayStyle = .classic

        let seen = StyleLog()
        let host = OverlayHostingView(rootView: StyleProbe(log: seen).overlayStyleFromConfig())
        let panel = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: 40, height: 40),
                            styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        defer { panel.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(seen.values.last, .classic)

        config.overlayStyle = .glass
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(seen.values.last, .glass)

        config.overlayStyle = .classic
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(seen.values.last, .classic)
    }
}

private final class StyleLog {
    var values: [OverlayStyle] = []
}

private struct StyleProbe: View {
    let log: StyleLog
    @Environment(\.overlayStyle) private var style

    var body: some View {
        log.values.append(style)
        return Color.clear.frame(width: 40, height: 40)
    }
}
