import XCTest
import Cocoa
@testable import HyprMac

// pins TilingEngine.forceInsertWindow, the float→tile entry point. It works on
// a private candidate and reports a typed result, so a caller can tell a window
// that tiled from one that was already there from an outright refusal — the old
// optional return said "refused" and "nothing happened" with the same nil.
// Nothing is ever evicted to make room: an incoming window that does not fit is
// refused and the live tree is left exactly as it was.

final class ForceInsertWindowFallbackTests: XCTestCase {

    private var displayManager: DisplayManager!
    private var engine: TilingEngine!
    private var screen: NSScreen!

    override func setUpWithError() throws {
        displayManager = DisplayManager()
        engine = TilingEngine(displayManager: displayManager,
                              frameSizingIOFactory: acceptingFrameSizingIOFactory())
        screen = NSScreen.main ?? NSScreen.screens.first ?? ForceInsertTestScreen()
    }

    private func tree() -> BSPTree? {
        engine.existingTree(forWorkspace: 1, screen: screen)
    }

    // MARK: - empty tree

    func testForceInsertOnEmptyTreeFillsRoot() {
        let w = makeWindow(id: 1)
        XCTAssertEqual(engine.forceInsertWindow(w, toWorkspace: 1, on: screen), .inserted)
        XCTAssertEqual(tree()?.allWindows.map(\.windowID), [1])
        XCTAssertTrue(tree()?.root.isLeaf ?? false)
    }

    // MARK: - already in tree

    func testForceInsertAlreadyContainedReportsAlreadyPresentAndDoesNothing() {
        let w = makeWindow(id: 1)
        engine.forceInsertWindow(w, toWorkspace: 1, on: screen)
        XCTAssertEqual(tree()?.allWindows.count, 1)

        XCTAssertEqual(engine.forceInsertWindow(w, toWorkspace: 1, on: screen), .alreadyPresent)
        XCTAssertEqual(tree()?.allWindows.map(\.windowID), [1])
    }

    // MARK: - primary path: smartInsertFitting succeeds

    func testForceInsertTakesAFreeSlotWhenSpaceAllows() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.forceInsertWindow(w1, toWorkspace: 1, on: screen)

        XCTAssertEqual(engine.forceInsertWindow(w2, toWorkspace: 1, on: screen), .inserted)
        XCTAssertEqual(Set(tree()?.allWindows.map(\.windowID) ?? []), [1, 2])
    }

    // MARK: - path A: the tree is full at max depth

    func testForceInsertKeepsEveryIncumbentWhenAtMaxDepth() {
        // shrink maxDepth to force the smartInsertFitting precondition (depth < maxDepth) to fail.
        // with maxDepth=1, tree fills at 2 leaves (depth 1 each); a 3rd insert via
        // smartInsertFitting fails the depth check.
        engine.maxSplitsPerMonitor[screen.localizedName] = 1

        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        engine.forceInsertWindow(w1, toWorkspace: 1, on: screen)
        engine.forceInsertWindow(w2, toWorkspace: 1, on: screen)
        XCTAssertEqual(tree()?.allWindows.count, 2)

        // w3 is refused and both incumbents keep their slots.
        XCTAssertEqual(engine.forceInsertWindow(w3, toWorkspace: 1, on: screen), .failed(.noFittingSlot))
        XCTAssertEqual(Set(tree()?.allWindows.map(\.windowID) ?? []), [1, 2])
    }

    // MARK: - path B: the incoming window's own minimum refuses it

    func testForceInsertReportsFailureAndLeavesTheTreeAloneWhenIncomingDoesNotFit() {
        // smartInsertFitting also fails when the incoming window's min-size
        // exceeds every available rect. The candidate is discarded whole, so
        // the live tree never changed and needs no repair.
        engine.maxSplitsPerMonitor[screen.localizedName] = 1

        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.forceInsertWindow(w1, toWorkspace: 1, on: screen)
        engine.forceInsertWindow(w2, toWorkspace: 1, on: screen)
        let before = tree()?.structuralFingerprint()

        let w3 = makeWindow(id: 3)
        w3.observedMinSize = CGSize(width: 100_000, height: 100_000)

        XCTAssertEqual(engine.forceInsertWindow(w3, toWorkspace: 1, on: screen),
                       .failed(.noFittingSlot))
        XCTAssertEqual(Set(tree()?.allWindows.map(\.windowID) ?? []), [1, 2])
        XCTAssertEqual(tree()?.structuralFingerprint(), before)
        XCTAssertFalse(tree()?.contains(w3) ?? true)
    }

    // MARK: - explicit revalidation of learned minima

    /// Two tenants, so the deepest slot the incoming window can be offered is
    /// narrow enough for its minimum to argue with. With one tenant, the free
    /// half is wide enough that every minimum fits.
    private func seedTwoTenants() {
        engine.forceInsertWindow(makeWindow(id: 1), toWorkspace: 1, on: screen)
        engine.forceInsertWindow(makeWindow(id: 2), toWorkspace: 1, on: screen)
    }

    /// A window whose recorded minimum is wider than any slot the screen can
    /// offer. Screen-relative and under `usableMinSizeMaxPx`, so it is a real
    /// `MinSizeMemory` entry with a provenance rather than a sentinel the
    /// memory refuses to hold.
    private func windowRefusedByItsOwnBound(id: CGWindowID,
                                            provenance: MinSizeProvenance) -> HyprWindow {
        let w = makeWindow(id: id)
        let usable = engine.displayManager.cgRect(for: screen)
        w.observedMinSize = CGSize(width: usable.width * 1.2, height: 0)
        w.minSizeProvenance = provenance
        engine.primeMinimumSizes([w])
        return w
    }

    func testBypassingLearnedMinimaTakesASlotAStaleBoundRefused() throws {
        seedTwoTenants()
        let w3 = windowRefusedByItsOwnBound(id: 3, provenance: .observed)
        XCTAssertEqual(engine.forceInsertWindow(w3, toWorkspace: 1, on: screen),
                       .failed(.noFittingSlot))

        XCTAssertEqual(engine.forceInsertWindow(w3, toWorkspace: 1, on: screen,
                                                bypassingLearnedMinima: true),
                       .inserted)
        XCTAssertEqual(Set(tree()?.allWindows.map(\.windowID) ?? []), [1, 2, 3],
                       "both incumbents keep their slots: the room was there"
                       + " once the bound was set aside")
    }

    func testBypassingLearnedMinimaLeavesASeededHintStanding() throws {
        seedTwoTenants()
        let w3 = windowRefusedByItsOwnBound(id: 3, provenance: .seeded)

        XCTAssertEqual(engine.forceInsertWindow(w3, toWorkspace: 1, on: screen,
                                                bypassingLearnedMinima: true),
                       .failed(.noFittingSlot))
        XCTAssertFalse(tree()?.contains(w3) ?? true)
        XCTAssertEqual(Set(tree()?.allWindows.map(\.windowID) ?? []), [1, 2],
                       "the refusal discards the candidate whole")
    }

    func testBypassingLearnedMinimaStillObeysTheDepthCeiling() throws {
        engine.maxSplitsPerMonitor[screen.localizedName] = 1
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.forceInsertWindow(w1, toWorkspace: 1, on: screen)
        engine.forceInsertWindow(w2, toWorkspace: 1, on: screen)
        let before = tree()?.structuralFingerprint()

        let w3 = windowRefusedByItsOwnBound(id: 3, provenance: .observed)

        // the ceiling is structural: the bypass does not buy a deeper tree, so
        // the window can only get in by taking someone's place
        let result = engine.forceInsertWindow(w3, toWorkspace: 1, on: screen,
                                              bypassingLearnedMinima: true)
        XCTAssertEqual(result, .failed(.noFittingSlot))
        XCTAssertEqual(Set(tree()?.allWindows.map(\.windowID) ?? []), [1, 2])
        XCTAssertEqual(tree()?.structuralFingerprint(), before)
    }

    func testTheBypassDoesNotOutlastTheOneAttempt() throws {
        seedTwoTenants()
        let w3 = windowRefusedByItsOwnBound(id: 3, provenance: .observed)
        XCTAssertEqual(engine.forceInsertWindow(w3, toWorkspace: 1, on: screen,
                                                bypassingLearnedMinima: true),
                       .inserted)

        let w4 = windowRefusedByItsOwnBound(id: 4, provenance: .observed)
        XCTAssertEqual(engine.forceInsertWindow(w4, toWorkspace: 1, on: screen),
                       .failed(.noFittingSlot),
                       "the next insert is a new request and gets no bypass of its own")
    }

    // MARK: - a refusal applies nothing

    func testARefusedForceInsertDoesNotCancelAnInFlightLayout() throws {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.forceInsertWindow(w1, toWorkspace: 1, on: screen)
        engine.forceInsertWindow(w2, toWorkspace: 1, on: screen)
        engine.maxSplitsPerMonitor[screen.localizedName] = 1
        let generation = engine.beginLayoutGeneration()

        let w3 = makeWindow(id: 3)
        w3.observedMinSize = CGSize(width: 100_000, height: 100_000)
        XCTAssertEqual(engine.forceInsertWindow(w3, toWorkspace: 1, on: screen),
                       .failed(.noFittingSlot))

        XCTAssertEqual(engine.beginLayoutGeneration(), generation &+ 1,
                       "nothing was applied, so nothing in flight was cancelled")
    }

    // MARK: - the screen refuses the layout

    func testRefusedLayoutKeepsTheOldTree() throws {
        let trace = ForceInsertTrace()
        let engine = TilingEngine(displayManager: DisplayManager(),
                                  frameSizingIOFactory: { _, generation in trace.io(generation) })
        engine.maxSplitsPerMonitor[screen.localizedName] = 2
        let w1 = makeWindow(id: 401)
        let w2 = makeWindow(id: 402)
        let usable = engine.displayManager.cgRect(for: screen)
        for (index, window) in [w1, w2].enumerated() {
            trace.frames[window.windowID] = CGRect(x: usable.minX + 20 + CGFloat(index) * 150,
                                                   y: usable.minY + 20, width: 120, height: 120)
        }
        XCTAssertEqual(engine.forceInsertWindow(w1, toWorkspace: 1, on: screen), .inserted)
        XCTAssertEqual(engine.forceInsertWindow(w2, toWorkspace: 1, on: screen), .inserted)
        let live = try XCTUnwrap(engine.existingTree(forWorkspace: 1, screen: screen))
        let before = live.structuralFingerprint()

        // the layout that would seat the incoming window is refused
        let w3 = makeWindow(id: 403)
        trace.frames[w3.windowID] = CGRect(x: usable.minX + 20, y: usable.minY + 20,
                                           width: 120, height: 120)
        trace.rejectReadsFor = [w1.windowID]

        let result = engine.forceInsertWindow(w3, toWorkspace: 1, on: screen)

        guard case .failed(.layoutRejected) = result else {
            return XCTFail("expected a layout refusal, got \(result)")
        }
        XCTAssertEqual(engine.existingTree(forWorkspace: 1, screen: screen)?.structuralFingerprint(),
                       before, "the old tree survives untouched")
        XCTAssertEqual(Set(engine.windowIDs(inTreeForWorkspace: 1, screen: screen)), [401, 402])
    }
}

/// Minimal AX stand-in: setters land, reads answer with what landed, and
/// named windows can be made unreadable once a write has gone out.
private final class ForceInsertTrace {
    var frames: [CGWindowID: CGRect] = [:]
    var rejectReadsFor: Set<CGWindowID> = []
    private var wrote = false
    private var now: TimeInterval = 0

    func io(_ generation: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { [self] id, size, _ in wrote = true; frames[id]?.size = size; return .success },
            writePosition: { [self] id, position, _ in wrote = true; frames[id]?.origin = position; return .success },
            readPosition: { [self] id, _ in
                if wrote && rejectReadsFor.contains(id) { return (.cannotComplete, nil) }
                return (.success, frames[id]?.origin)
            },
            readSize: { [self] id, _ in (.success, frames[id]?.size) },
            now: { [self] in now }, sleep: { [self] in now += $0 },
            currentGeneration: generation)
    }
}

private final class ForceInsertTestScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 1600, height: 1000) }
    override var visibleFrame: NSRect { frame }
}
