import CoreGraphics

struct RetileAllPlan {
    let assignments: [Int: [CGWindowID]]
    let overflow: [CGWindowID]
}

enum RetileAllPlanner {
    static func shouldRemainFloating(isAutoFloat: Bool, isOnDisabledMonitor: Bool) -> Bool {
        isAutoFloat || isOnDisabledMonitor
    }

    static func eligibleWindowIDs(
        workspaceAssignments: [Int: Set<CGWindowID>],
        discoveredWindowIDs: Set<CGWindowID>,
        excludedWindowIDs: Set<CGWindowID>
    ) -> [CGWindowID] {
        let trackedWindowIDs = workspaceAssignments.values.reduce(into: Set<CGWindowID>()) {
            $0.formUnion($1)
        }
        return trackedWindowIDs
            .union(discoveredWindowIDs)
            .subtracting(excludedWindowIDs)
            .sorted()
    }

    static func pack(
        windowIDs: [CGWindowID],
        workspaceCount: Int,
        capacityForWorkspace: (Int) -> Int
    ) -> RetileAllPlan {
        var assignments: [Int: [CGWindowID]] = [:]
        var nextWindow = 0

        for workspace in 1...workspaceCount {
            let capacity = max(0, capacityForWorkspace(workspace))
            guard capacity > 0, nextWindow < windowIDs.count else { continue }
            let end = min(nextWindow + capacity, windowIDs.count)
            assignments[workspace] = Array(windowIDs[nextWindow..<end])
            nextWindow = end
        }

        return RetileAllPlan(
            assignments: assignments,
            overflow: Array(windowIDs[nextWindow...])
        )
    }
}
