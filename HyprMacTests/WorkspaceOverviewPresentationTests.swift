import XCTest
import SwiftUI
import Combine
@testable import HyprMac

final class WorkspaceOverviewPresentationTests: XCTestCase {
    func testOpenOverlayFollowsSystemAppearanceAndLiveOverrides() throws {
        guard ProcessInfo.processInfo.environment["HYPRMAC_HEADLESS_TESTS"] == "1" else {
            throw XCTSkip("requires isolated config")
        }
        let config = UserConfig.shared
        let previous = config.overlayAppearance
        defer { config.overlayAppearance = previous }
        let host = OverlayHostingView(rootView: Text("Appearance"))
        let panel = NSPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        panel.contentView = host
        defer { panel.close() }

        config.overlayAppearance = .system
        panel.appearance = NSAppearance(named: .aqua)
        XCTAssertNil(host.appearance)
        XCTAssertEqual(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        panel.appearance = NSAppearance(named: .darkAqua)
        XCTAssertEqual(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)

        config.overlayAppearance = .light
        XCTAssertEqual(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        config.overlayAppearance = .dark
        panel.appearance = NSAppearance(named: .aqua)
        XCTAssertEqual(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        config.overlayAppearance = .system
        XCTAssertNil(host.appearance)
        XCTAssertEqual(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
    }

    func testFilterMatchesWorkspaceMonitorWindowAndBundle() {
        let snapshots = [
            WorkspaceSnapshot(id: 1, monitorID: 10, monitorName: "Studio Display", isActive: true,
                              windows: [window(11, "Research Notes", "com.apple.TextEdit")]),
            WorkspaceSnapshot(id: 2, monitorID: 20, monitorName: "Built-in Display", isActive: false,
                              windows: [window(22, "Terminal", "com.apple.Terminal")])
        ]

        XCTAssertEqual(WorkspaceOverviewPresentation.visibleWorkspaces(snapshots, query: "studio", names: [:]).map(\.id), [1])
        XCTAssertEqual(WorkspaceOverviewPresentation.visibleWorkspaces(snapshots, query: "terminal", names: [:]).map(\.id), [2])
        XCTAssertEqual(WorkspaceOverviewPresentation.visibleWorkspaces(snapshots, query: "TextEdit", names: [:]).map(\.id), [1])
        XCTAssertEqual(WorkspaceOverviewPresentation.visibleWorkspaces(snapshots, query: "2", names: [:]).map(\.id), [2])
        XCTAssertEqual(WorkspaceOverviewPresentation.visibleWorkspaces(snapshots, query: "  ", names: [:]).map(\.id), [1, 2])
    }

    func testFilterMatchesACustomWorkspaceName() {
        let snapshots = [
            WorkspaceSnapshot(id: 1, monitorID: 10, monitorName: "Studio Display", isActive: true, windows: []),
            WorkspaceSnapshot(id: 4, monitorID: 10, monitorName: "Studio Display", isActive: false, windows: [])
        ]
        let names = ["4": "term", "1": "  "]
        XCTAssertEqual(WorkspaceOverviewPresentation.visibleWorkspaces(snapshots, query: "TER", names: names).map(\.id), [4])
        XCTAssertEqual(WorkspaceOverviewPresentation.visibleWorkspaces(snapshots, query: "term", names: [:]).map(\.id), [])
        // the number still matches when a name is set
        XCTAssertEqual(WorkspaceOverviewPresentation.visibleWorkspaces(snapshots, query: "4", names: names).map(\.id), [4])
    }

    func testCardShowsTheNameAfterTheNumberOnlyWhenSet() {
        XCTAssertEqual(WorkspaceOverviewPresentation.cardName(4, names: ["4": "term"]), "term")
        XCTAssertNil(WorkspaceOverviewPresentation.cardName(4, names: [:]))
        XCTAssertNil(WorkspaceOverviewPresentation.cardName(4, names: ["4": "   "]))
        XCTAssertNil(WorkspaceOverviewPresentation.cardName(5, names: ["4": "term"]))
    }

    func testSearchFindsAppNameWhenNeitherTitleNorBundleContainsIt() {
        let conversation = WorkspaceWindowSnapshot(
            id: 33, title: "Weekend plans", bundleID: "com.apple.MobileSMS", appName: "Messages",
            normalizedFrame: .zero, isFloating: false)
        XCTAssertTrue(WorkspaceOverviewPresentation.windowMatches(conversation, query: "messages"))
        XCTAssertFalse(WorkspaceOverviewPresentation.windowMatches(conversation, query: "Safari"))
    }

    func testOverviewShowsChatGPTAndSafariWithoutClosedWorkspaceGhosts() {
        let displayed = WorkspaceOverviewPresentation.displayedWindowIDs(
            assigned: [11, 12, 13, 14, 15],
            current: [11, 12],
            knownOrCached: [11, 12, 13, 14, 15],
            hidden: [13, 14],
            reservedHidden: [13])

        XCTAssertEqual(displayed, [11, 12, 13, 15],
                       "ChatGPT, Safari, a minimized window, and an unclassified cached window remain")
        XCTAssertFalse(displayed.contains(14),
                       "closed-but-app-alive assignments must not render as open windows")
    }

    func testOverviewPreservesWindowsDuringCompleteAXOutage() {
        XCTAssertEqual(WorkspaceOverviewPresentation.displayedWindowIDs(
            assigned: [21, 22], current: [], knownOrCached: [21, 22],
            hidden: [21, 22], reservedHidden: [21, 22]), [21, 22])
    }

    func testOverviewPreservesKnownUnhiddenWindowUntilDiscoveryVerdict() {
        XCTAssertEqual(WorkspaceOverviewPresentation.displayedWindowIDs(
            assigned: [31], current: [], knownOrCached: [31],
            hidden: [], reservedHidden: []), [31])
    }

    func testOverviewDoesNotRenderAssignmentWithOnlyStaleOwnerMetadata() {
        XCTAssertTrue(WorkspaceOverviewPresentation.displayedWindowIDs(
            assigned: [41], current: [], knownOrCached: [],
            hidden: [], reservedHidden: []).isEmpty)
    }

    func testFreshReopenedWindowOverridesStaleVerifiedClosedClassification() {
        XCTAssertEqual(WorkspaceOverviewPresentation.displayedWindowIDs(
            assigned: [51], current: [51], knownOrCached: [51],
            hidden: [51], reservedHidden: []), [51])
    }

    func testGeometryNormalizesAndClampsToSchematicBounds() {
        let screen = CGRect(x: 100, y: 200, width: 1000, height: 800)
        let result = WorkspaceOverviewPresentation.normalized(
            CGRect(x: 350, y: 400, width: 500, height: 400), in: screen)
        XCTAssertEqual(result, CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))

        let outside = WorkspaceOverviewPresentation.normalized(
            CGRect(x: -900, y: -800, width: 10, height: 10), in: screen)
        XCTAssertEqual(outside.minX, 0)
        XCTAssertEqual(outside.minY, 0)
        XCTAssertLessThanOrEqual(outside.maxX, 1)
        XCTAssertLessThanOrEqual(outside.maxY, 1)

        let overflowing = WorkspaceOverviewPresentation.normalized(
            CGRect(x: 900, y: 800, width: 500, height: 500), in: screen)
        XCTAssertLessThanOrEqual(overflowing.maxX, 1)
        XCTAssertLessThanOrEqual(overflowing.maxY, 1)
    }

    func testSwitchHUDNamesTheWorkspaceAndNothingElse() {
        let text = WorkspaceOverviewPresentation.switchHUDText(workspace: 7, names: [:])
        XCTAssertEqual(text.caption, "WORKSPACE")
        XCTAssertEqual(text.number, "7")
        XCTAssertEqual(WorkspaceOverviewPresentation.switchHUDText(workspace: 10, names: [:]).number, "10")
        // a custom name replaces the number; the caption stays
        let named = WorkspaceOverviewPresentation.switchHUDText(workspace: 4, names: ["4": "term"])
        XCTAssertEqual(named.caption, "WORKSPACE")
        XCTAssertEqual(named.number, "term")
        // no monitor name on the switch HUD in any topology — monitor names
        // stay in the overview grid and its type-to-filter.
        let fields = Mirror(reflecting: text).children.map { $0.label ?? "" }
        XCTAssertEqual(fields, ["caption", "number"])
        XCTAssertFalse(fields.contains { $0.localizedCaseInsensitiveContains("monitor") })
    }

    func testOnlyLatestHUDGenerationMayHide() {
        var generations = WorkspaceHUDGeneration()
        let first = generations.next()
        let second = generations.next()
        XCTAssertFalse(generations.shouldHide(first))
        XCTAssertTrue(generations.shouldHide(second))
    }

    func testPlainNumberSwitchesWorkspaceButModifiedNumberDoesNot() {
        XCTAssertEqual(WorkspaceOverviewPresentation.workspaceShortcut(characters: "7", modifiers: []), 7)
        XCTAssertNil(WorkspaceOverviewPresentation.workspaceShortcut(characters: "7", modifiers: .command))
        XCTAssertEqual(WorkspaceOverviewPresentation.workspaceShortcut(characters: "0", modifiers: []), 10)
        XCTAssertNil(WorkspaceOverviewPresentation.workspaceShortcut(characters: "0", modifiers: .shift))
        XCTAssertNil(WorkspaceOverviewPresentation.workspaceShortcut(characters: "77", modifiers: []))
    }

    func testOverviewHeightTracksRowsAndRemainsBounded() {
        XCTAssertEqual(WorkspaceOverviewPresentation.columnCount, 5)
        let oneRow = (1...5).map {
            WorkspaceSnapshot(id: $0, monitorID: 1, monitorName: "Studio", isActive: false,
                              windows: [window(CGWindowID($0), "Window", "com.apple.TextEdit")])
        }
        let twoRows = Constants.workspaceRange.map {
            WorkspaceSnapshot(id: $0, monitorID: 1, monitorName: "Studio", isActive: false,
                              windows: [window(CGWindowID($0), "Window", "com.apple.TextEdit")])
        }
        let short = WorkspaceOverviewPresentation.overviewHeight(
            snapshots: oneRow, scratchpadCount: 0, maximum: 900)
        let tall = WorkspaceOverviewPresentation.overviewHeight(
            snapshots: twoRows, scratchpadCount: 2, maximum: 900)
        XCTAssertGreaterThan(tall, short)
        XCTAssertLessThanOrEqual(tall, 900)
    }

    func testOverviewModelPublishesFreshSnapshotsAndSkipsEqualOnes() {
        let first = [WorkspaceSnapshot(id: 1, monitorID: 1, monitorName: "Studio", isActive: true,
                                       windows: [window(11, "Notes", "com.apple.TextEdit")])]
        let model = WorkspaceOverviewModel(snapshots: first)
        var publishes = 0
        let sink = model.objectWillChange.sink { publishes += 1 }
        defer { sink.cancel() }

        model.update(snapshots: first, scratchpad: [])
        XCTAssertEqual(publishes, 0, "a quiet poll must not redraw the overview")

        let opened = [WorkspaceSnapshot(id: 1, monitorID: 1, monitorName: "Studio", isActive: true,
                                        windows: [window(11, "Notes", "com.apple.TextEdit"),
                                                  window(12, "Terminal", "com.apple.Terminal")])]
        model.update(snapshots: opened, scratchpad: [window(13, "Scratch", "com.apple.Notes")])
        XCTAssertEqual(publishes, 2)
        XCTAssertEqual(model.snapshots.first?.windows.map(\.id), [11, 12])
        XCTAssertEqual(model.scratchpad.map(\.id), [13])
        XCTAssertEqual(WorkspaceOverviewPresentation.visibleWorkspaces(model.snapshots, query: "terminal", names: [:]).map(\.id), [1])
    }

    func testClosedOverviewSkipsSnapshotWork() {
        let controller = WorkspaceOverviewController()
        XCTAssertFalse(controller.isOpen)
        var walked = false
        controller.refreshIfOpen { walked = true; return ([], []) }
        XCTAssertFalse(walked, "a closed overview must not walk AX for snapshots")
    }

    @MainActor
    func testOpenOverviewViewRedrawsFromModelUpdates() throws {
        guard ProcessInfo.processInfo.environment["HYPRMAC_HEADLESS_TESTS"] == "1" else {
            throw XCTSkip("requires isolated config")
        }
        func workspaces(_ ids: ClosedRange<Int>) -> [WorkspaceSnapshot] {
            ids.map { WorkspaceSnapshot(id: $0, monitorID: 1, monitorName: "Studio", isActive: $0 == 1,
                                        windows: [window(CGWindowID($0), "Window", "com.apple.TextEdit")]) }
        }
        let model = WorkspaceOverviewModel(snapshots: workspaces(1...2))
        var frames: [Int: CGRect] = [:]
        let view = WorkspaceOverviewView(model: model,
                                         selectWorkspace: { _ in },
                                         selectWindow: { _, _ in },
                                         onCardFramesChange: { frames = $0 })
            .frame(width: 1400, height: 700)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1400, height: 700)

        func settle(until count: Int) {
            let deadline = Date().addingTimeInterval(0.5)
            host.layoutSubtreeIfNeeded()
            while frames.count != count, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                host.layoutSubtreeIfNeeded()
            }
        }
        settle(until: 2)
        XCTAssertEqual(Set(frames.keys), [1, 2])

        // same hosting view, no new rootView: the open panel's path
        model.update(snapshots: workspaces(1...3), scratchpad: [])
        settle(until: 3)
        XCTAssertEqual(Set(frames.keys), [1, 2, 3])
    }

    @MainActor
    func testRenderOverviewAtSupportedWidths() throws {
        guard ProcessInfo.processInfo.environment["HYPRMAC_RENDER_OVERVIEW"] == "1" else {
            throw XCTSkip("set HYPRMAC_RENDER_OVERVIEW=1 to render overview snapshots")
        }

        for populated in [false, true] {
            for width in [CGFloat(1400), 976, 852] {
                var frames: [Int: CGRect] = [:]
                let snapshots = Constants.workspaceRange.map { workspace in
                    WorkspaceSnapshot(
                        id: workspace,
                        monitorID: 1,
                        monitorName: "Studio Display",
                        isActive: workspace == 1,
                        windows: populated ? [window(
                            CGWindowID(workspace), "Workspace \(workspace) window",
                            "com.apple.TextEdit")] : [])
                }
                let view = WorkspaceOverviewView(
                    model: WorkspaceOverviewModel(snapshots: snapshots),
                    selectWorkspace: { _ in },
                    selectWindow: { _, _ in },
                    onCardFramesChange: { frames = $0 })
                    .frame(width: width, height: 700)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
                host.layoutSubtreeIfNeeded()

                let deadline = Date().addingTimeInterval(0.5)
                while frames.count < Constants.workspaceCount, Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                    host.layoutSubtreeIfNeeded()
                }

                XCTAssertEqual(frames.count, 10, "\(width)-point render did not lay out every card")
                let rows = Dictionary(grouping: frames.values) { Int(round($0.minY)) }
                XCTAssertEqual(rows.count, 2, "\(width)-point render must have two rows")
                XCTAssertEqual(rows.values.map(\.count).sorted(), [5, 5])
                XCTAssertTrue(frames.values.allSatisfy { $0.width > 0 })
                XCTAssertGreaterThanOrEqual(frames.values.map(\.minX).min() ?? -1, 24)
                XCTAssertLessThanOrEqual(frames.values.map(\.maxX).max() ?? width + 1, width - 24)

                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let suffix = populated ? "populated" : "empty"
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hyprmac-overview-\(Int(width))-\(suffix).png")
                try bitmap.representation(using: .png, properties: [:])?.write(to: url)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            }
        }
    }

    func testSwitchHUDOriginHugsTheChosenEdges() {
        let visible = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let size = CGSize(width: 200, height: 100)
        func origin(_ p: SwitchHUDPosition) -> CGPoint {
            WorkspaceOverviewPresentation.switchHUDOrigin(size: size, in: visible, position: p)
        }
        XCTAssertEqual(origin(.bottom), CGPoint(x: 500, y: 62))
        XCTAssertEqual(origin(.topLeft), CGPoint(x: 112, y: 738))
        XCTAssertEqual(origin(.topRight), CGPoint(x: 888, y: 738))
        XCTAssertEqual(origin(.center), CGPoint(x: 500, y: 400))
        XCTAssertEqual(origin(.bottomRight), CGPoint(x: 888, y: 62))
    }

    func testSwitchHUDCellsUseTheTargetsMonitorAndMoveActive() {
        let left = MenuBarMonitorSnapshot(id: 0, name: "L", currentWorkspace: 1, isPortrait: false,
            workspaces: [MenuBarWorkspaceBadge(id: 1, isActive: true, isOccupied: true, hasFloatingWindows: false),
                         MenuBarWorkspaceBadge(id: 2, isActive: false, isOccupied: false, hasFloatingWindows: false)])
        let right = MenuBarMonitorSnapshot(id: 1, name: "R", currentWorkspace: 6, isPortrait: false,
            workspaces: [MenuBarWorkspaceBadge(id: 6, isActive: true, isOccupied: true, hasFloatingWindows: false)])
        let cells = WorkspaceOverviewPresentation.switchHUDCells(workspace: 2, monitors: [left, right])
        XCTAssertEqual(cells.map(\.id), [1, 2])
        XCTAssertEqual(cells.map(\.isActive), [false, true])
        XCTAssertEqual(cells.map { WorkspaceOverviewPresentation.switchHUDGlyph($0, style: .squares) }, ["□", "■"])
        XCTAssertEqual(cells.map { WorkspaceOverviewPresentation.switchHUDGlyph($0, style: .dots) }, ["●", "●"])

        let lone = WorkspaceOverviewPresentation.switchHUDCells(workspace: 10, monitors: [])
        XCTAssertEqual(lone.map(\.id), [10])
        XCTAssertEqual(WorkspaceOverviewPresentation.switchHUDGlyph(lone[0], style: .numbers), "0")
    }

    private func window(_ id: CGWindowID, _ title: String, _ bundle: String) -> WorkspaceWindowSnapshot {
        WorkspaceWindowSnapshot(id: id, title: title, bundleID: bundle,
                                appName: bundle.components(separatedBy: ".").last ?? bundle,
                                normalizedFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
                                isFloating: false)
    }
}
