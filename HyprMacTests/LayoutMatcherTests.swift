import XCTest
@testable import HyprMac

// LayoutMatcherTests pin the assignment policy that decides which live
// window takes which saved leaf: bundle ID is required, an exact
// non-empty title is worth more than sitting on the right workspace,
// every window is claimed at most once, and ties are deterministic.

final class LayoutMatcherTests: XCTestCase {

    private func ref(_ bundleID: String, _ title: String = "") -> SavedWindowRef {
        SavedWindowRef(bundleID: bundleID, title: title)
    }

    private func candidate(_ id: CGWindowID, _ bundleID: String, _ title: String = "",
                           ws: Int = 1) -> LayoutMatcher.Candidate {
        LayoutMatcher.Candidate(windowID: id, bundleID: bundleID, title: title, workspace: ws)
    }

    private func snapshot(_ workspaces: [WorkspaceLayout]) -> LayoutSnapshot {
        LayoutSnapshot(schemaVersion: LayoutSnapshot.currentSchemaVersion, displayKey: "k",
                       timestamp: Date(), isManual: true, workspaces: workspaces)
    }

    private func leaf(_ workspace: Int, _ ref: SavedWindowRef) -> WorkspaceLayout {
        WorkspaceLayout(workspace: workspace, root: .leaf(ref))
    }

    func testTitleMatchBeatsWorkspaceMatch() {
        let plan = LayoutMatcher.plan(
            snapshot([leaf(2, ref("com.t", "A"))]),
            candidates: [candidate(1, "com.t", "A", ws: 1), candidate(2, "com.t", "B", ws: 2)])
        XCTAssertEqual(plan.workspaceByWindow, [1: 2])
    }

    func testWorkspaceMatchBreaksTitleTie() {
        let plan = LayoutMatcher.plan(
            snapshot([leaf(2, ref("com.t", "A"))]),
            candidates: [candidate(1, "com.t", "A", ws: 1), candidate(2, "com.t", "A", ws: 2)])
        XCTAssertEqual(plan.workspaceByWindow, [2: 2])
    }

    func testDuplicateRefsGetDistinctWindows() {
        let zsh = ref("com.t", "zsh")
        let tree = LayoutNode.split(override: nil, ratio: 0.5, userSet: false,
                                    left: .leaf(zsh), right: .leaf(zsh))
        let plan = LayoutMatcher.plan(
            snapshot([WorkspaceLayout(workspace: 1, root: tree)]),
            candidates: [candidate(7, "com.t", "zsh"), candidate(3, "com.t", "zsh")])
        XCTAssertEqual(plan.workspaceByWindow, [3: 1, 7: 1])
        XCTAssertEqual(plan.windowsByRef[1]?[zsh], [3, 7], "one window per leaf, lowest ID first")
        XCTAssertTrue(plan.unmatchedRefs.isEmpty)
    }

    func testEmptyTitleGetsNoTitleBonus() {
        // an empty saved title must not score against an empty live title —
        // otherwise every untitled window "matches" every untitled leaf.
        let plan = LayoutMatcher.plan(
            snapshot([leaf(2, ref("com.t", ""))]),
            candidates: [candidate(1, "com.t", "", ws: 1), candidate(2, "com.t", "X", ws: 2)])
        XCTAssertEqual(plan.workspaceByWindow, [2: 2])
    }

    func testTieBreaksOnLowestWindowID() {
        let plan = LayoutMatcher.plan(
            snapshot([leaf(1, ref("com.t", "A"))]),
            candidates: [candidate(9, "com.t", "A"), candidate(3, "com.t", "A")])
        XCTAssertEqual(plan.workspaceByWindow, [3: 1])
    }

    func testWindowIsClaimedOnce() {
        let plan = LayoutMatcher.plan(
            snapshot([leaf(1, ref("com.t", "A")), leaf(2, ref("com.t", "B"))]),
            candidates: [candidate(1, "com.t", "A")])
        XCTAssertEqual(plan.workspaceByWindow, [1: 1])
        XCTAssertEqual(plan.unmatchedRefs, [ref("com.t", "B")])
    }

    func testBundleIDIsRequired() {
        let plan = LayoutMatcher.plan(
            snapshot([leaf(1, ref("com.a", "A"))]),
            candidates: [candidate(1, "com.b", "A")])
        XCTAssertTrue(plan.workspaceByWindow.isEmpty)
        XCTAssertEqual(plan.unmatchedRefs, [ref("com.a", "A")])
    }

    func testExtraCandidatesStayUnassigned() {
        let plan = LayoutMatcher.plan(
            snapshot([leaf(1, ref("com.t", "A"))]),
            candidates: [candidate(1, "com.t", "A"), candidate(2, "com.t", "B")])
        XCTAssertEqual(plan.workspaceByWindow, [1: 1])
        XCTAssertNil(plan.workspaceByWindow[2])
    }

    func testEmptySnapshotProducesEmptyPlan() {
        let plan = LayoutMatcher.plan(snapshot([]), candidates: [candidate(1, "com.t", "A")])
        XCTAssertEqual(plan, LayoutMatcher.Plan())
    }
}
