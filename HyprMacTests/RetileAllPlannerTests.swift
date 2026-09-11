import XCTest
@testable import HyprMac

final class RetileAllPlannerTests: XCTestCase {
    func testEligibleWindowsIncludeHiddenWorkspaceAssignmentsInStableOrder() {
        let assignments: [Int: Set<CGWindowID>] = [
            1: [40, 10],
            2: [30],
            8: [20]
        ]

        let result = RetileAllPlanner.eligibleWindowIDs(
            workspaceAssignments: assignments,
            discoveredWindowIDs: [50, 10],
            excludedWindowIDs: [30]
        )

        XCTAssertEqual(result, [10, 20, 40, 50])
    }

    func testPackingUsesWorkspaceNumberOrderWithoutGaps() {
        let result = RetileAllPlanner.pack(
            windowIDs: [10, 20, 30, 40, 50, 60],
            workspaceCount: 5,
            capacityForWorkspace: { workspace in
                [1: 2, 2: 1, 3: 2, 4: 1, 5: 3][workspace] ?? 0
            }
        )

        XCTAssertEqual(result.assignments[1], [10, 20])
        XCTAssertEqual(result.assignments[2], [30])
        XCTAssertEqual(result.assignments[3], [40, 50])
        XCTAssertEqual(result.assignments[4], [60])
        XCTAssertNil(result.assignments[5])
        XCTAssertTrue(result.overflow.isEmpty)
    }

    func testPackingSkipsUnavailableWorkspaceWithoutLosingWindows() {
        let result = RetileAllPlanner.pack(
            windowIDs: [10, 20, 30],
            workspaceCount: 3,
            capacityForWorkspace: { $0 == 2 ? 0 : 1 }
        )

        XCTAssertEqual(result.assignments, [1: [10], 3: [20]])
        XCTAssertEqual(result.overflow, [30])
    }

    func testVisibleWorkspaceAndFocusDoNotChangePlan() {
        let first = RetileAllPlanner.eligibleWindowIDs(
            workspaceAssignments: [4: [90, 20], 8: [50]],
            discoveredWindowIDs: [90, 20, 50],
            excludedWindowIDs: []
        )
        let afterSwitchAndFocusChange = RetileAllPlanner.eligibleWindowIDs(
            workspaceAssignments: [1: [50], 2: [90], 3: [20]],
            discoveredWindowIDs: [20, 50, 90],
            excludedWindowIDs: []
        )

        XCTAssertEqual(first, [20, 50, 90])
        XCTAssertEqual(afterSwitchAndFocusChange, first)
        XCTAssertEqual(
            RetileAllPlanner.pack(windowIDs: first, workspaceCount: 9, capacityForWorkspace: { _ in 1 }).assignments,
            RetileAllPlanner.pack(windowIDs: afterSwitchAndFocusChange, workspaceCount: 9, capacityForWorkspace: { _ in 1 }).assignments
        )
    }

    func testNineWorkspaceCapacityAndOverflow() {
        let ids = (1...20).map(CGWindowID.init)
        let result = RetileAllPlanner.pack(
            windowIDs: ids,
            workspaceCount: 9,
            capacityForWorkspace: { $0.isMultiple(of: 2) ? 1 : 2 }
        )

        XCTAssertEqual(result.assignments.keys.sorted(), Array(1...9))
        XCTAssertEqual(result.assignments[1], [1, 2])
        XCTAssertEqual(result.assignments[2], [3])
        XCTAssertEqual(result.assignments[9], [13, 14])
        XCTAssertEqual(result.overflow, [15, 16, 17, 18, 19, 20])
    }

    func testDisabledMonitorWindowRemainsFloating() {
        XCTAssertTrue(RetileAllPlanner.shouldRemainFloating(isAutoFloat: false, isOnDisabledMonitor: true))
        XCTAssertTrue(RetileAllPlanner.shouldRemainFloating(isAutoFloat: true, isOnDisabledMonitor: false))
        XCTAssertFalse(RetileAllPlanner.shouldRemainFloating(isAutoFloat: false, isOnDisabledMonitor: false))
    }
}
