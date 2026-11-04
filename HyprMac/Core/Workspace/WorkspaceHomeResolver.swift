// Which monitor each workspace lives on. Pure: the enabled monitor names,
// left to right, and the user's workspaceMonitors mapping in, one home per
// workspace out. With no mapping the answer is the formula
// enabledScreens[(N - 1) % enabledScreens.count].

import Foundation

enum WorkspaceHomeResolver {
    struct Resolution: Equatable {
        // homes[n - 1] indexes the enabled screens for workspace n
        let homes: [Int]
        // the mapping left a monitor with no workspace, so the formula ran
        let mappingIgnored: Bool
    }

    /// Workspace number → monitor name. A number listed under two monitors
    /// goes to the name that sorts first and is reported in `duplicates`.
    /// Numbers outside `1...workspaceCount` are dropped.
    static func owners(_ mapping: [String: [Int]],
                       workspaceCount: Int = Constants.workspaceCount) -> (owners: [Int: String], duplicates: [Int]) {
        var owners: [Int: String] = [:]
        var duplicates: Set<Int> = []
        for name in mapping.keys.sorted() {
            for n in Set(mapping[name] ?? []) where (1...workspaceCount).contains(n) {
                if owners[n] == nil { owners[n] = name } else { duplicates.insert(n) }
            }
        }
        return (owners, duplicates.sorted())
    }

    /// A workspace mapped to a connected, enabled monitor lives there.
    /// Every other one uses the formula over the enabled screens. When that
    /// would leave a monitor with nothing to show, the whole mapping is
    /// ignored for this layout.
    static func resolve(enabledNames: [String], mapping: [String: [Int]],
                        workspaceCount: Int = Constants.workspaceCount) -> Resolution {
        let count = enabledNames.count
        guard count > 0 else { return Resolution(homes: [], mappingIgnored: false) }
        let formula = (1...workspaceCount).map { ($0 - 1) % count }
        let owners = owners(mapping, workspaceCount: workspaceCount).owners
        guard !owners.isEmpty else { return Resolution(homes: formula, mappingIgnored: false) }

        // two displays of one model share a name; the leftmost takes the mapping
        let homes = (1...workspaceCount).map { n in
            owners[n].flatMap { enabledNames.firstIndex(of: $0) } ?? formula[n - 1]
        }
        // more monitors than workspaces leaves some empty under the formula too
        if Set(homes).count < min(count, workspaceCount) {
            return Resolution(homes: formula, mappingIgnored: true)
        }
        return Resolution(homes: homes, mappingIgnored: false)
    }

    /// `mapping` with `name` owning exactly `workspaces`. A number it takes
    /// leaves every other monitor; monitors left with nothing drop out.
    static func setting(_ workspaces: Set<Int>, for name: String,
                        in mapping: [String: [Int]]) -> [String: [Int]] {
        var next = mapping.mapValues { $0.filter { !workspaces.contains($0) } }
        next[name] = workspaces.sorted()
        return next.filter { !$0.value.isEmpty }
    }
}
