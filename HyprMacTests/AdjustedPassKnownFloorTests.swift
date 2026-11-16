import XCTest
import Cocoa
@testable import HyprMac

// the adjusted pass after a refusal must honor the floors earlier passes
// already taught, not only the ones its own pass just observed. the live
// report: Fantastical arriving beside Orca and Teams on a 1496x835 frame
// went out at 427 tall and 136 wide after its 480x541 floor was known.

final class AdjustedPassKnownFloorTests: XCTestCase {

    private let orcaID: CGWindowID = 52
    private let teamsID: CGWindowID = 1040
    private let fantasticalID: CGWindowID = 55

    // the 2026-11-15 22:16 admission: Teams 414x414, Fantastical 541x480,
    // Orca 600x400 on a 1496x835 usable frame with an 8 pt gap
    func testTheAdjustedPassNeverWritesBelowAKnownFloor() throws {
        let screen = KnownFloorScreen()
        let app = FloorApp(floors: [
            teamsID: CGSize(width: 414, height: 414),
            fantasticalID: CGSize(width: 541, height: 480),
            orcaID: CGSize(width: 600, height: 400)
        ])
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { [screen] }),
                                  frameSizingIOFactory: { _, generation in app.io(generation) })
        let rect = engine.displayManager.cgRect(for: screen)
            .insetBy(dx: engine.outerPadding, dy: engine.outerPadding)
        XCTAssertEqual(rect.size, CGSize(width: 1496, height: 835))
        XCTAssertEqual(engine.gapSize, 8)

        let orca = makeWindow(id: orcaID)
        let teams = makeWindow(id: teamsID)
        let fantastical = makeWindow(id: fantasticalID)
        let incumbents = engine.tileWindows([orca, teams], onWorkspace: 2, screen: screen)
        XCTAssertNil(incumbents.failure, "744x835 each is above every incumbent floor")
        app.frames[fantasticalID] = CGRect(x: rect.midX - 300, y: rect.minY + 100, width: 600, height: 500)
        app.reset()

        var floated: [CGWindowID] = []
        let recovery = recovery(for: engine, screen: screen,
                                windows: [orca, teams, fantastical]) { floated.append($0.windowID) }
        let admission = engine.tileWindows([orca, teams, fantastical], onWorkspace: 2, screen: screen)
        XCTAssertNotNil(admission.failure, "every slot for Fantastical crosses a floor")
        recovery.note(admission)
        recovery.fire()

        XCTAssertEqual(floated, [fantasticalID], "the fallback is still float in place")
        XCTAssertEqual(Set(engine.windowIDs(inTreeForWorkspace: 2, screen: screen)), [orcaID, teamsID])
        XCTAssertEqual(app.belowKnownFloor, [], "a write went out below a floor already recorded")
        // four slots, each a candidate and a rollback, plus the one adjusted
        // pass that cleared every floor known then. the old code also wrote
        // Fantastical at 744x427 under Orca and 136x835 beside it: 11 batches
        XCTAssertEqual(app.batches.count, 9, "\(app.batches)")
    }

    // a refusal whose adjusted layout clears every floor already known still
    // writes it, and that write is accepted
    func testAnAdjustedPassThatHonorsEveryKnownFloorStillWrites() throws {
        let screen = KnownFloorScreen()
        let app = FloorApp(floors: [
            teamsID: CGSize(width: 414, height: 414),
            orcaID: CGSize(width: 900, height: 0)
        ])
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { [screen] }),
                                  frameSizingIOFactory: { _, generation in app.io(generation) })
        let rect = engine.displayManager.cgRect(for: screen)
            .insetBy(dx: engine.outerPadding, dy: engine.outerPadding)
        app.frames = [orcaID: CGRect(x: rect.minX, y: rect.minY, width: 1000, height: 835),
                      teamsID: CGRect(x: rect.minX + 1008, y: rect.minY, width: 488, height: 835)]
        let orca = makeWindow(id: orcaID)
        let teams = makeWindow(id: teamsID)
        // Teams' floor is known before the pass; Orca's is not
        teams.observedMinSize = CGSize(width: 414, height: 414)
        teams.minSizeProvenance = .observed
        engine.primeMinimumSizes([teams])

        let result = engine.tileWindows([orca, teams], onWorkspace: 2, screen: screen)

        XCTAssertNil(result.failure, "900 + 8 + 588 fits, and 588 clears Teams' 414")
        XCTAssertEqual(app.batches.count, 2, "the candidate, then the adjusted pass")
        let adjusted = try XCTUnwrap(app.batches.last)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(adjusted[orcaID]).width, 900)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(adjusted[teamsID]).width, 414)
        XCTAssertEqual(app.belowKnownFloor, [])
    }

    /// The production recovery wiring, with the engine's own retry behind it.
    private func recovery(for engine: TilingEngine, screen: NSScreen, windows: [HyprWindow],
                          floated: @escaping (HyprWindow) -> Void) -> FiringRecovery {
        let firing = FiringRecovery()
        let recovery = firing.recovery
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        recovery.workspaceFor = { _ in 2 }
        recovery.homeScreenForWorkspace = { _ in screen }
        recovery.isWorkspaceVisible = { $0 == 2 }
        recovery.liveWindow = { byID[$0] }
        recovery.isReadable = { _ in true }
        recovery.isTiled = { engine.windowIDs(inTreeForWorkspace: 2, screen: screen).contains($0) }
        recovery.attempt = { workspace, screen, bypass, keepOnTimeout in
            let result = engine.retryAdmission(windows, onWorkspace: workspace, screen: screen,
                                               bypassingMinimaBefore: bypass,
                                               refusingImpossibleArrangements: true,
                                               keepingUnverifiedOnTimeout: keepOnTimeout)
            return AdmissionRecovery.AttemptResult(placed: result.publishedIDs.intersection(bypass.keys),
                                                   failure: result.failure, admission: result)
        }
        recovery.sharingOneBudget = { engine.sharingOnePassBudget($0) }
        recovery.budgetLeft = { engine.passBudgetLeft }
        recovery.floatInPlace = { window, _ in floated(window) }
        return firing
    }
}

/// An admission recovery whose timers run when the test says so.
private final class FiringRecovery {
    let recovery = AdmissionRecovery()
    private var timers: [() -> Void] = []

    init() {
        recovery.schedule = { [weak self] _, body in self?.timers.append(body) }
    }

    func note(_ result: TilingEngine.AdmissionResult) { recovery.note(result) }

    func fire() {
        while !timers.isEmpty { timers.removeFirst()() }
    }
}

/// Windows that refuse to shrink below a floor on either axis: a smaller
/// write reads back at the floor. Every batch of writes is recorded, and a
/// write below a floor an earlier batch already ran into is flagged.
private final class FloorApp {
    var frames: [CGWindowID: CGRect] = [:]
    /// the sizes written in each batch, by window
    private(set) var batches: [[CGWindowID: CGSize]] = []
    private(set) var belowKnownFloor: [String] = []
    private let floors: [CGWindowID: CGSize]
    // floors a refused write has shown, as of the batch before this one
    private var known: [CGWindowID: CGSize] = [:]
    private var learning: [CGWindowID: CGSize] = [:]
    private var readSinceWrite = true
    private var time: TimeInterval = 0

    init(floors: [CGWindowID: CGSize]) { self.floors = floors }

    func reset() {
        batches = []
        belowKnownFloor = []
        readSinceWrite = true
    }

    func io(_ generation: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { [self] id, size, _ in
                startBatchIfNeeded()
                batches[batches.count - 1][id] = size
                let floor = floors[id] ?? .zero
                if let seen = known[id],
                   size.width < seen.width - 1 || size.height < seen.height - 1 {
                    belowKnownFloor.append("batch \(batches.count) wid=\(id) size=\(size) floor=\(seen)")
                }
                // only a refusal past the readback tolerance teaches the engine a floor
                let tolerance = TilingConfig.frameToleranceXPx
                var learned = learning[id] ?? known[id] ?? .zero
                if floor.width - size.width > tolerance { learned.width = max(learned.width, floor.width) }
                if floor.height - size.height > tolerance { learned.height = max(learned.height, floor.height) }
                learning[id] = learned
                var frame = frames[id] ?? .zero
                frame.size = CGSize(width: max(size.width, floor.width), height: max(size.height, floor.height))
                frames[id] = frame
                return .success
            },
            writePosition: { [self] id, position, _ in
                startBatchIfNeeded()
                var frame = frames[id] ?? CGRect(origin: .zero, size: CGSize(width: 100, height: 100))
                frame.origin = position
                frames[id] = frame
                return .success
            },
            readPosition: { [self] id, _ in
                readSinceWrite = true
                return (.success, frames[id]?.origin ?? .zero)
            },
            readSize: { [self] id, _ in
                readSinceWrite = true
                return (.success, frames[id]?.size ?? CGSize(width: 100, height: 100))
            },
            now: { [self] in time }, sleep: { [self] in time += $0 }, currentGeneration: generation)
    }

    private func startBatchIfNeeded() {
        guard readSinceWrite else { return }
        readSinceWrite = false
        known.merge(learning) { _, new in new }
        learning = [:]
        batches.append([:])
    }
}

private final class KnownFloorScreen: SyntheticScreen {
    // 1496x835 once the 8 pt outer padding is taken
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 1512, height: 851) }
    override var visibleFrame: NSRect { frame }
}
