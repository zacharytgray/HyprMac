// Which monitor each workspace lives on. Pure: the enabled monitor names,
// left to right, and the user's workspace mapping in, one home per
// workspace out. With no mapping the answer is the formula
// enabledScreens[(N - 1) % enabledScreens.count].
//
// The mapping in force is the one saved for the connected set of displays
// (`workspaceMonitorsPerDisplaySet`), else `workspaceMonitors`.

import Foundation

enum WorkspaceHomeResolver {
    struct Resolution: Equatable {
        // homes[n - 1] indexes the enabled screens for workspace n
        let homes: [Int]
        // the mapping left a monitor with no workspace, so the formula ran
        let mappingIgnored: Bool
    }

    /// Workspace number → monitor name. With `among`, only those monitors
    /// count, so a number under a missing monitor and a present one goes to
    /// the present one. A number still listed under two of them goes to
    /// the name that sorts first and is reported in `duplicates`.
    /// Numbers outside `1...workspaceCount` are dropped.
    static func owners(_ mapping: [String: [Int]], among names: [String]? = nil,
                       workspaceCount: Int = Constants.workspaceCount) -> (owners: [Int: String], duplicates: [Int]) {
        let present = names.map(Set.init)
        var owners: [Int: String] = [:]
        var duplicates: Set<Int> = []
        for name in mapping.keys.sorted() where present?.contains(name) ?? true {
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
        let owners = owners(mapping, among: enabledNames, workspaceCount: workspaceCount).owners
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
    /// leaves the other monitors in `connected` (every monitor when nil);
    /// a monitor that isn't connected keeps its numbers. Monitors left
    /// with nothing drop out.
    static func setting(_ workspaces: Set<Int>, for name: String,
                        in mapping: [String: [Int]],
                        connected: Set<String>? = nil) -> [String: [Int]] {
        var next = mapping
        for (other, numbers) in mapping where connected?.contains(other) ?? true {
            next[other] = numbers.filter { !workspaces.contains($0) }
        }
        next[name] = workspaces.sorted()
        return next.filter { !$0.value.isEmpty }
    }

    // MARK: - per display set

    /// The display set a list of connected display names makes: every
    /// connected display, disabled ones too, by name only, in sorted
    /// order. Two displays of one model are listed twice.
    static func displaySet(_ connectedNames: [String]) -> [String] {
        connectedNames.sorted()
    }

    /// The mapping in force for these connected displays: the entry saved
    /// for exactly this set, else `fallback` (`workspaceMonitors`).
    static func mapping(forDisplays connectedNames: [String],
                        perSet: [DisplaySetWorkspaces],
                        fallback: [String: [Int]]) -> [String: [Int]] {
        let key = displaySet(connectedNames)
        return perSet.first { displaySet($0.displays) == key }?.workspaceMonitors ?? fallback
    }

    /// `perSet` after Settings puts exactly `workspaces` on `name` while
    /// `connectedNames` are connected. Only this set's entry changes. A
    /// set with no entry gets one, seeded from the mapping in force for
    /// its monitors, so every other checkbox keeps its home. `nil` when
    /// nothing would change, so nothing is written.
    static func editing(_ workspaces: Set<Int>, for name: String,
                        connectedNames: [String],
                        perSet: [DisplaySetWorkspaces],
                        fallback: [String: [Int]]) -> [DisplaySetWorkspaces]? {
        let current = mapping(forDisplays: connectedNames, perSet: perSet, fallback: fallback)
        guard Set(current[name] ?? []) != workspaces else { return nil }
        let connected = Set(connectedNames)
        let key = displaySet(connectedNames)
        var next = perSet
        if let index = next.firstIndex(where: { displaySet($0.displays) == key }) {
            next[index].workspaceMonitors = setting(workspaces, for: name, in: next[index].workspaceMonitors,
                                                    connected: connected)
        } else {
            let seed = fallback.filter { connected.contains($0.key) }
            next.append(DisplaySetWorkspaces(
                displays: key,
                workspaceMonitors: setting(workspaces, for: name, in: seed, connected: connected)))
        }
        return next
    }
}
