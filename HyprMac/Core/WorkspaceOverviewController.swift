import Cocoa
import SwiftUI

struct WorkspaceWindowSnapshot: Identifiable, Equatable {
    let id: CGWindowID
    let title: String
    let appName: String
    let bundleID: String?
    let normalizedFrame: CGRect
    let isFloating: Bool

    init(id: CGWindowID, title: String, bundleID: String?, appName: String? = nil,
         normalizedFrame: CGRect, isFloating: Bool) {
        self.id = id
        self.title = title
        self.appName = appName ?? title
        self.bundleID = bundleID
        self.normalizedFrame = normalizedFrame
        self.isFloating = isFloating
    }
}

struct WorkspaceSnapshot: Identifiable, Equatable {
    let id: Int
    let monitorID: Int
    let monitorName: String
    let isActive: Bool
    let windows: [WorkspaceWindowSnapshot]
}

enum WorkspaceOverviewPresentation {
    static let columnCount = 5

    /// Fresh windows always render. Known or cached unhidden windows survive
    /// a transient AX omission until discovery classifies them. Hidden windows
    /// render only while their tile is deliberately reserved (minimized,
    /// app-hidden, another Space, or an unresolved AX outage). A hidden id
    /// with no reservation has been verified closed and must not linger in UI.
    static func displayedWindowIDs(assigned: Set<CGWindowID>,
                                   current: Set<CGWindowID>,
                                   knownOrCached: Set<CGWindowID>,
                                   hidden: Set<CGWindowID>,
                                   reservedHidden: Set<CGWindowID>) -> [CGWindowID] {
        let awaitingDiscovery = knownOrCached.subtracting(hidden)
        return assigned.intersection(current.union(reservedHidden).union(awaitingDiscovery)).sorted()
    }

    static func windowMatches(_ window: WorkspaceWindowSnapshot, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty
            || window.title.localizedCaseInsensitiveContains(needle)
            || window.appName.localizedCaseInsensitiveContains(needle)
            || (window.bundleID?.localizedCaseInsensitiveContains(needle) ?? false)
    }

    static func visibleWorkspaces(_ snapshots: [WorkspaceSnapshot], query: String,
                                  names: [String: String]) -> [WorkspaceSnapshot] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return snapshots }
        return snapshots.filter { workspace in
            String(workspace.id).contains(needle)
                || (cardName(workspace.id, names: names)?.localizedCaseInsensitiveContains(needle) ?? false)
                || workspace.monitorName.localizedCaseInsensitiveContains(needle)
                || workspace.windows.contains { windowMatches($0, query: needle) }
        }
    }

    static func normalized(_ frame: CGRect?, in screen: CGRect) -> CGRect {
        guard let frame, screen.width > 0, screen.height > 0 else {
            return CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
        }
        let minX = max(0, min(1, (frame.minX - screen.minX) / screen.width))
        let minY = max(0, min(1, (frame.minY - screen.minY) / screen.height))
        let maxX = max(minX, min(1, (frame.maxX - screen.minX) / screen.width))
        let maxY = max(minY, min(1, (frame.maxY - screen.minY) / screen.height))
        return CGRect(x: minX, y: minY,
                      width: max(0, maxX - minX),
                      height: max(0, maxY - minY))
    }

    static func workspaceShortcut(characters: String?, modifiers: NSEvent.ModifierFlags) -> Int? {
        let blocked: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard modifiers.intersection(blocked).isEmpty,
              let characters, characters.count == 1,
              let digit = Int(characters) else { return nil }
        if digit == 0 { return Constants.workspaceCount }
        return Constants.workspaceRange.contains(digit) ? digit : nil
    }

    static func overviewHeight(snapshots: [WorkspaceSnapshot], scratchpadCount: Int,
                               maximum: CGFloat) -> CGFloat {
        let cardsPerRow = columnCount
        let rowHeights = stride(from: 0, to: snapshots.count, by: cardsPerRow).map { start in
            snapshots[start..<min(start + cardsPerRow, snapshots.count)]
                .map { CGFloat(170 + $0.windows.count * 19) }.max() ?? 170
        }
        let grid = rowHeights.reduce(0, +) + CGFloat(max(0, rowHeights.count - 1) * 12)
        let headerAndInsets: CGFloat = 55 + 16 + 44 + 48
        let scratchpad: CGFloat = scratchpadCount > 0 ? 62 : 0
        return min(maximum, max(320, grid + headerAndInsets + scratchpad))
    }

    /// The custom name an overview card shows after its number, or nil.
    static func cardName(_ workspace: Int, names: [String: String]) -> String? {
        let name = UserConfig.workspaceDisplayName(workspace, names: names, fallback: "")
        return name.isEmpty ? nil : name
    }

    /// Everything the workspace-switch HUD says. Caption and number (or the
    /// custom name) only — the monitor name belongs to the overview, not to
    /// the switch flash.
    static func switchHUDText(workspace: Int, names: [String: String]) -> (caption: String, number: String) {
        ("WORKSPACE", UserConfig.workspaceDisplayName(workspace, names: names, fallback: "\(workspace)"))
    }

    /// The switch HUD panel's origin (NSScreen coordinates) for `position`.
    /// The HUD view carries 64 pt of shadow padding, so 12 pt here puts the
    /// card 76 pt off each edge it hugs, as the bottom HUD always sat.
    static func switchHUDOrigin(size: CGSize, in visible: CGRect,
                                position: SwitchHUDPosition) -> CGPoint {
        let inset: CGFloat = 12
        let x: CGFloat
        switch position {
        case .topLeft, .bottomLeft: x = visible.minX + inset
        case .top, .center, .bottom: x = visible.midX - size.width / 2
        case .topRight, .bottomRight: x = visible.maxX - size.width - inset
        }
        let y: CGFloat
        switch position {
        case .topLeft, .top, .topRight: y = visible.maxY - size.height - inset
        case .center: y = visible.midY - size.height / 2
        case .bottomLeft, .bottom, .bottomRight: y = visible.minY + inset
        }
        return CGPoint(x: x, y: y)
    }

    /// The row a glyph-style switch HUD draws: the workspaces anchored to the
    /// monitor that holds `workspace`, with only `workspace` active. Occupancy
    /// is the last menu bar snapshot's. No snapshot holds it: just that one.
    static func switchHUDCells(workspace: Int,
                               monitors: [MenuBarMonitorSnapshot]) -> [MenuBarWorkspaceBadge] {
        let badges = monitors.first { $0.workspaces.contains { $0.id == workspace } }?.workspaces
            ?? [MenuBarWorkspaceBadge(id: workspace, isActive: true, isOccupied: false,
                                      hasFloatingWindows: false)]
        return badges.map {
            MenuBarWorkspaceBadge(id: $0.id, isActive: $0.id == workspace,
                                  isOccupied: $0.isOccupied, hasFloatingWindows: $0.hasFloatingWindows)
        }
    }

    static func switchHUDGlyph(_ cell: MenuBarWorkspaceBadge, style: SwitchHUDStyle) -> String {
        switch style {
        case .number, .numbers: return "\(cell.id == 10 ? 0 : cell.id)"
        case .squares: return cell.isActive ? "■" : (cell.isOccupied ? "□" : "·")
        case .dots: return cell.isActive || cell.isOccupied ? "●" : "○"
        }
    }
}

extension SwitchHUDFont {
    var design: Font.Design {
        switch self {
        case .rounded: return .rounded
        case .standard: return .default
        case .monospaced: return .monospaced
        case .serif: return .serif
        }
    }
}

/// What the open overview shows. Discovery pushes fresh snapshots in while
/// it is open; the view keeps its search text and focus across updates.
final class WorkspaceOverviewModel: ObservableObject {
    @Published private(set) var snapshots: [WorkspaceSnapshot]
    @Published private(set) var scratchpad: [WorkspaceWindowSnapshot]

    init(snapshots: [WorkspaceSnapshot], scratchpad: [WorkspaceWindowSnapshot] = []) {
        self.snapshots = snapshots
        self.scratchpad = scratchpad
    }

    // equal snapshots don't publish, so a quiet poll doesn't redraw the grid
    func update(snapshots: [WorkspaceSnapshot], scratchpad: [WorkspaceWindowSnapshot]) {
        if snapshots != self.snapshots { self.snapshots = snapshots }
        if scratchpad != self.scratchpad { self.scratchpad = scratchpad }
    }
}

struct WorkspaceHUDGeneration {
    private(set) var value = 0
    mutating func next() -> Int { value += 1; return value }
    func shouldHide(_ candidate: Int) -> Bool { candidate == value }
}

final class WorkspaceOverviewController {
    var onSelectWorkspace: (Int) -> Void = { _ in }
    var onSelectWindow: (Int, CGWindowID) -> Void = { _, _ in }

    private var overviewPanel: NSPanel?
    private var overviewModel: WorkspaceOverviewModel?
    private var hudPanel: NSPanel?
    private var keyMonitor: Any?
    private var hudGeneration = WorkspaceHUDGeneration()

    func toggle(snapshots: [WorkspaceSnapshot], scratchpad: [WorkspaceWindowSnapshot] = []) {
        if overviewPanel != nil { close(); return }
        showOverview(snapshots, scratchpad: scratchpad)
    }

    var isOpen: Bool { overviewPanel != nil }

    /// Push fresh snapshots into the open overview. `snapshots` is only
    /// called while it is open, so a closed overview costs no AX walk.
    /// The panel keeps its frame; the grid scrolls.
    func refreshIfOpen(_ snapshots: () -> (workspaces: [WorkspaceSnapshot], scratchpad: [WorkspaceWindowSnapshot])) {
        guard isOpen, let overviewModel else { return }
        let fresh = snapshots()
        overviewModel.update(snapshots: fresh.workspaces, scratchpad: fresh.scratchpad)
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard let panel = overviewPanel else { return }
        overviewPanel = nil
        overviewModel = nil
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.close()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            panel.animator().alphaValue = 0
        } completionHandler: { panel.close() }
    }

    func showSwitchHUD(workspace: Int, screen: NSScreen) {
        presentHUD(OverviewHostingView(rootView: WorkspaceSwitchHUD(workspace: workspace)), on: screen, for: 0.9)
    }

    /// The switch HUD's look for a short status, e.g. a layout save.
    func showStatusHUD(caption: String, title: String, detail: String?, failed: Bool, screen: NSScreen) {
        let view = StatusHUD(caption: caption, title: title, detail: detail, failed: failed)
        // a sentence takes longer to read than a number
        presentHUD(OverviewHostingView(rootView: view), on: screen, for: detail == nil ? 1.1 : 1.8)
    }

    private func presentHUD(_ hosting: NSView, on screen: NSScreen, for seconds: TimeInterval) {
        let generation = hudGeneration.next()
        hudPanel?.close()
        let size = hosting.fittingSize
        let origin = WorkspaceOverviewPresentation.switchHUDOrigin(
            size: size, in: screen.visibleFrame, position: UserConfig.shared.switchHUDPosition)
        let frame = NSRect(origin: origin, size: size)
        let panel = makePanel(frame: frame, canKey: false)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        // the caller is about to block the main thread in AX work, so the
        // panel has to be on screen before this returns. no fade-in: an
        // animation needs run-loop turns we are not going to get. draw the
        // layout, then push the frame to the window server by hand.
        hosting.layoutSubtreeIfNeeded()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hudPanel = panel
        panel.displayIfNeeded()
        CATransaction.flush()

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self, weak panel] in
            guard let self, self.hudGeneration.shouldHide(generation) else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                panel?.close()
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.14
                    panel?.animator().alphaValue = 0
                } completionHandler: { panel?.close() }
            }
            if self.hudPanel === panel { self.hudPanel = nil }
        }
    }

    private func showOverview(_ snapshots: [WorkspaceSnapshot], scratchpad: [WorkspaceWindowSnapshot]) {
        guard let screen = NSScreen.main else { return }
        let maxWidth = min(1400, screen.visibleFrame.width - 48)
        let maxHeight = screen.visibleFrame.height - 48
        let model = WorkspaceOverviewModel(snapshots: snapshots, scratchpad: scratchpad)
        let view = WorkspaceOverviewView(
            model: model,
            selectWorkspace: { [weak self] workspace in
                self?.close(); self?.onSelectWorkspace(workspace)
            },
            selectWindow: { [weak self] workspace, window in
                self?.close(); self?.onSelectWindow(workspace, window)
            })
        let hosting = OverviewHostingView(rootView: view)
        let contentHeight = WorkspaceOverviewPresentation.overviewHeight(
            snapshots: snapshots, scratchpadCount: scratchpad.count, maximum: maxHeight)
        let frame = NSRect(x: screen.visibleFrame.midX - maxWidth / 2,
                           y: screen.visibleFrame.midY - contentHeight / 2,
                           width: maxWidth, height: contentHeight)
        let panel = makePanel(frame: frame, canKey: true)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = animate ? 0 : 1
        panel.makeKeyAndOrderFront(nil)
        overviewPanel = panel
        overviewModel = model
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.close(); return nil }
            if UserConfig.shared.enabled,
               let workspace = WorkspaceOverviewPresentation.workspaceShortcut(
                characters: event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags) {
                self?.close()
                self?.onSelectWorkspace(workspace)
                return nil
            }
            return event
        }
    }

    private func makePanel(frame: NSRect, canKey: Bool) -> NSPanel {
        let panel = OverviewPanel(contentRect: frame,
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.acceptsKeyboard = canKey
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = Constants.interfaceWindowLevel
        panel.hidesOnDeactivate = false
        return panel
    }
}

private final class OverviewPanel: NSPanel {
    var acceptsKeyboard = false
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
}

private final class OverviewHostingView<Content: View>: OverlayHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

private struct StatusHUD: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: OverlayPalette { OverlayPalette(scheme: colorScheme) }
    let caption: String
    let title: String
    let detail: String?
    let failed: Bool
    var body: some View {
        VStack(spacing: 5) {
            Text(caption).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2).foregroundStyle(failed ? Color.red : Color.overlaySecondary)
            Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            if let detail {
                Text(detail).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 15)
        .background(RoundedRectangle(cornerRadius: 15).fill(palette.background))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.overlayPrimary.opacity(0.32)))
        .compositingGroup()
        .shadow(color: palette.shadow, radius: 18, y: 8).padding(64)
    }
}

private struct WorkspaceSwitchHUD: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: OverlayPalette { OverlayPalette(scheme: colorScheme) }
    let workspace: Int
    private var text: (caption: String, number: String) {
        WorkspaceOverviewPresentation.switchHUDText(workspace: workspace,
                                                    names: UserConfig.shared.workspaceNames)
    }
    private var config: UserConfig { UserConfig.shared }
    var body: some View {
        VStack(spacing: 5) {
            if config.switchHUDStyle == .number {
                Text(text.caption).font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2).foregroundStyle(Color.overlaySecondary)
                // a custom name has no length limit; keep the panel on screen
                Text(text.number).font(.system(size: 40, weight: .bold, design: config.switchHUDFont.design))
                    .lineLimit(1).frame(maxWidth: 480)
                    .foregroundStyle(.primary)
            } else {
                // the row says which number; the caption carries a custom name
                Text(text.number == "\(workspace)" ? "WORKSPACE \(workspace)" : text.number.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2).lineLimit(1).frame(maxWidth: 480)
                    .foregroundStyle(Color.overlaySecondary)
                HStack(spacing: 10) {
                    ForEach(WorkspaceOverviewPresentation.switchHUDCells(
                        workspace: workspace, monitors: MenuBarState.shared.monitors)) { cell in
                        Text(WorkspaceOverviewPresentation.switchHUDGlyph(cell, style: config.switchHUDStyle))
                            .font(.system(size: 24, weight: cell.isActive ? .bold : .medium,
                                          design: config.switchHUDFont.design))
                            .foregroundStyle(cell.isActive ? Color.overlayPrimary
                                             : (cell.isOccupied ? Color.primary : Color.secondary.opacity(0.5)))
                    }
                }
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 15)
        .background(RoundedRectangle(cornerRadius: 15).fill(palette.background))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.overlayPrimary.opacity(0.32)))
        .compositingGroup()
        .shadow(color: palette.shadow, radius: 18, y: 8).padding(64)
    }
}

struct WorkspaceOverviewView: View {
    @ObservedObject private var config = UserConfig.shared
    @Environment(\.colorScheme) private var colorScheme
    private var palette: OverlayPalette { OverlayPalette(scheme: colorScheme) }
    @ObservedObject var model: WorkspaceOverviewModel
    let selectWorkspace: (Int) -> Void
    let selectWindow: (Int, CGWindowID) -> Void
    var onCardFramesChange: (([Int: CGRect]) -> Void)? = nil
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    title
                    Spacer()
                    search
                }
                VStack(alignment: .leading, spacing: 10) {
                    title
                    search.frame(maxWidth: .infinity)
                }
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top), count: WorkspaceOverviewPresentation.columnCount), spacing: 12) {
                    ForEach(WorkspaceOverviewPresentation.visibleWorkspaces(model.snapshots, query: query,
                                                                                  names: config.workspaceNames)) { workspace in
                        WorkspaceCard(workspace: workspace,
                                      selectWorkspace: selectWorkspace,
                                      selectWindow: selectWindow)
                            .frame(maxWidth: .infinity)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(
                                    key: WorkspaceOverviewCardFramesKey.self,
                                    value: [workspace.id: proxy.frame(in: .named("workspaceOverview"))])
                            })
                    }
                }
            }
            .disabled(!config.enabled)
            if !filteredScratchpad.isEmpty { scratchpadFooter }
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 18).fill(palette.background))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.overlayPrimary.opacity(0.28)))
        .compositingGroup()
        .shadow(color: palette.shadow, radius: 18, y: 8).padding(24)
        .coordinateSpace(name: "workspaceOverview")
        .onPreferenceChange(WorkspaceOverviewCardFramesKey.self) { frames in
            onCardFramesChange?(frames)
        }
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("WORKSPACE OVERVIEW").font(.system(size: 17, weight: .semibold, design: .monospaced))
            Text(config.enabled ? "Keys 1–9, 0 to switch · Type to search · Esc to close" : "Tiling paused · Resume tiling to switch workspaces")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var search: some View {
        TextField("Find workspace or app", text: $query)
            .textFieldStyle(.roundedBorder)
            .frame(idealWidth: 230, maxWidth: 230)
            .focused($searchFocused)
    }

    private var scratchpadFooter: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("SCRATCHPAD")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(Color.overlaySecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)],
                      alignment: .leading, spacing: 7) {
                ForEach(filteredScratchpad) { window in
                    HStack(spacing: 5) {
                        WorkspaceAppIcon(bundleID: window.bundleID).frame(width: 16, height: 16)
                        Text(window.appName).font(.system(size: 11)).lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.surface))
    }

    private var filteredScratchpad: [WorkspaceWindowSnapshot] {
        model.scratchpad.filter { WorkspaceOverviewPresentation.windowMatches($0, query: query) }
    }
}

private struct WorkspaceOverviewCardFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct WorkspaceCard: View {
    @ObservedObject private var config = UserConfig.shared
    @Environment(\.colorScheme) private var colorScheme
    private var palette: OverlayPalette { OverlayPalette(scheme: colorScheme) }
    let workspace: WorkspaceSnapshot
    let selectWorkspace: (Int) -> Void
    let selectWindow: (Int, CGWindowID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { selectWorkspace(workspace.id) } label: {
                HStack {
                    let name = WorkspaceOverviewPresentation.cardName(workspace.id, names: config.workspaceNames)
                    // the number stays: the overview's digit keys switch by it
                    Text("\(workspace.id)").font(.system(size: 20, weight: .bold, design: .rounded))
                    if let name {
                        Text(name).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1)
                    }
                    Text(workspace.monitorName).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                        .foregroundStyle(name == nil ? HierarchicalShapeStyle.primary : .secondary)
                    Spacer()
                    if workspace.isActive { Text("ACTIVE").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Color.overlayPrimary) }
                }
            }.buttonStyle(.plain)
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 7).fill(palette.preview)
                    ForEach(workspace.windows) { window in
                        let frame = window.normalizedFrame
                        Button { selectWindow(workspace.id, window.id) } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4).fill(window.isFloating ? config.resolvedFloatingColor.opacity(0.45) : Color.overlayPrimary.opacity(0.22))
                                WorkspaceAppIcon(bundleID: window.bundleID).frame(width: 20, height: 20)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(window.title)
                        .frame(width: max(28, frame.width * proxy.size.width), height: max(24, frame.height * proxy.size.height))
                        .position(x: (frame.midX * proxy.size.width), y: (frame.midY * proxy.size.height))
                    }
                    if workspace.windows.isEmpty {
                        Text("Empty").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.clipped()
            }.frame(height: 112)
            if !workspace.windows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(workspace.windows) { window in
                        Button { selectWindow(workspace.id, window.id) } label: {
                            HStack(spacing: 6) {
                                WorkspaceAppIcon(bundleID: window.bundleID).frame(width: 15, height: 15)
                                Text(window.appName).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                Text(window.title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(window.title)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(workspace.isActive ? palette.activeSurface : palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(workspace.isActive ? Color.overlayPrimary.opacity(0.7) : palette.separator))
    }

}

private struct WorkspaceAppIcon: View {
    let bundleID: String?

    var body: some View {
        appIcon.resizable().aspectRatio(contentMode: .fit)
    }

    private var appIcon: Image {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return Image(systemName: "macwindow")
        }
        return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
    }
}
