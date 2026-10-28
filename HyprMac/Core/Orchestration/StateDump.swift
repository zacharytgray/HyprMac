// Pure formatting for `WindowManager.dumpState`. Takes plain values —
// screen names, id sets, the workspace map — so the block can be
// asserted line for line without AppKit or a live tree.

import CoreGraphics
import Foundation

/// Renders one on-demand state dump as a list of log lines.
///
/// Order is fixed: one line per enabled screen, then each workspace
/// 1...10 that has at least one assignment (ascending), then the
/// scratchpad, then learned minima, then recovery state, then cache
/// totals. Workspaces with no assignment are omitted entirely.
///
/// Window titles never enter these lines — ids only.
struct StateDumpFormatter {

    /// An enabled screen and the workspace currently shown on it.
    struct ScreenState {
        let name: String
        let visibleWorkspace: Int
    }

    let screens: [ScreenState]
    /// Workspace → static home screen name.
    let homeScreenNames: [Int: String]
    let visibleWorkspaces: Set<Int>
    /// Window → workspace. Workspace 0 (scratchpad) entries are skipped
    /// here; the scratchpad gets its own line.
    let assignments: [CGWindowID: Int]
    let hidden: Set<CGWindowID>
    let reserved: Set<CGWindowID>
    let floating: Set<CGWindowID>
    /// Workspace → leaf window ids of its tree on its home screen.
    let trees: [Int: [CGWindowID]]
    let scratchpad: Set<CGWindowID>
    let knownCount: Int
    /// Window → remembered min size and the evidence behind it, from
    /// `MinSizeMemory`. The source is printed because a seeded hint and a
    /// bound the app actually refused are not the same claim.
    var minima: [CGWindowID: MinSizeMemory.Entry] = [:]
    /// Per-app lengths windows kept on an axis, oldest first. Printed only
    /// when there are any.
    var fixedSizes: [FixedSize] = []
    /// Windows waiting on a bounded recovery attempt. Nothing produces
    /// these yet — the line is here so the shape is stable once
    /// admission recovery lands.
    var pendingRecovery: Set<CGWindowID> = []
    /// Windows whose on-screen geometry was never verified. Same: no
    /// producer yet, the line reports what exists.
    var unverifiedGeometry: Set<CGWindowID> = []

    private static let workspaceRange = Constants.workspaceRange

    func lines() -> [String] {
        var out = screens.map { "screen=\($0.name) visible=ws\($0.visibleWorkspace)" }

        var members: [Int: [CGWindowID]] = [:]
        for (id, workspace) in assignments where Self.workspaceRange.contains(workspace) {
            members[workspace, default: []].append(id)
        }

        for workspace in members.keys.sorted() {
            let assigned = members[workspace]!.sorted()
            let home = homeScreenNames[workspace] ?? "?"
            out.append("ws\(workspace) home=\(home)"
                + " visible=\(visibleWorkspaces.contains(workspace))"
                + " assigned=\(Self.list(assigned))"
                + " hidden=\(Self.list(assigned.filter(hidden.contains)))"
                + " reserved=\(Self.list(assigned.filter(reserved.contains)))"
                + " floating=\(Self.list(assigned.filter(floating.contains)))"
                + " tree(\(home))=\(Self.list(trees[workspace] ?? []))")
        }

        out.append("scratchpad=\(Self.list(scratchpad.sorted()))")
        out.append("minima=" + "[" + minima.keys.sorted().map {
            let entry = minima[$0]!
            return "\($0):" + Self.size(entry.size) + "(\(entry.provenance.rawValue))"
        }.joined(separator: ", ") + "]")
        if !fixedSizes.isEmpty {
            out.append("fixed=[" + fixedSizes.map {
                "\($0.bundleID ?? "none"):\($0.axis.rawValue)=\(String(format: "%g", Double($0.length)))"
            }.joined(separator: ", ") + "]")
        }
        out.append("recovery pending=\(Self.list(pendingRecovery.sorted()))"
            + " unverified=\(Self.list(unverifiedGeometry.sorted()))")
        out.append("known=\(knownCount) hidden=\(hidden.count)"
            + " reserved=\(reserved.count) floating=\(floating.count)")
        return out
    }

    private static func list(_ ids: [CGWindowID]) -> String {
        "[" + ids.map(String.init).joined(separator: ", ") + "]"
    }

    private static func size(_ size: CGSize) -> String {
        String(format: "%gx%g", Double(size.width), Double(size.height))
    }
}
