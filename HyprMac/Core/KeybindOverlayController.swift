// HUD panel listing every active keybind, grouped by category. Toggled
// via `Hypr+K`. Spotlight-style borderless panel — takes keyboard input
// (type-to-filter, esc to close) without activating the app.

import Cocoa
import SwiftUI

/// Lifecycle for the keybind overlay HUD.
///
/// Holds a borderless `.nonactivatingPanel` above passive chrome and a
/// local keyDown monitor for type-to-filter. `toggle` shows or hides.
///
/// Threading: main-thread only.
class KeybindOverlayController {

    var onShowTutorial: () -> Void = {}

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private let filter = FilterModel()

    /// `true` when the overlay panel is on screen.
    var isShowing: Bool { panel != nil }

    /// Show the overlay, or close it if already visible.
    func toggle(keybinds: [Keybind]) {
        mainThreadOnly()
        if panel != nil {
            close()
            return
        }
        show(keybinds: keybinds)
    }

    /// Close the overlay if it is showing. Idempotent. Tears down the
    /// key monitor on every close path.
    func close() {
        mainThreadOnly()
        removeMonitor()
        guard let closing = panel else { return }
        panel = nil
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            closing.close()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            closing.animator().alphaValue = 0
        } completionHandler: { closing.close() }
    }

    func openTutorial() {
        close()
        onShowTutorial()
    }

    private func show(keybinds: [Keybind]) {
        guard let screen = NSScreen.main else { return }

        filter.text = ""  // fresh filter on every show

        let maxHeight = screen.visibleFrame.height * 0.75

        let content = KeybindOverlayView(keybinds: keybinds, cardWidth: min(1000, screen.visibleFrame.width - 160)) { [weak self] in
            self?.openTutorial()
        }
            .environmentObject(filter)
        let hosting = KeybindOverlayHostingView(rootView: content)
        // leave transparent space around the card for the shadow to dissipate
        let fitted = hosting.fittingSize
        let panelWidth = fitted.width
        let panelHeight = min(max(fitted.height, 1), maxHeight)
        let panelX = screen.frame.midX - panelWidth / 2
        let panelY = screen.frame.midY - panelHeight / 2

        let p = KeybindOverlayPanel(
            contentRect: NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false  // shadow drawn in SwiftUI
        p.isFloatingPanel = true
        p.level = Constants.interfaceWindowLevel
        p.hidesOnDeactivate = false

        hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting

        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        p.alphaValue = animate ? 0 : 1
        p.makeKeyAndOrderFront(nil)
        self.panel = p
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                p.animator().alphaValue = 1
            }
        }

        installMonitor()
    }

    // MARK: - key monitor

    // local keyDown monitor: esc closes, backspace trims, printable chars
    // append. chords with cmd/ctrl are ignored (let the system have them).
    private func installMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel != nil else { return event }

            if event.keyCode == 53 {  // escape
                self.close()
                return nil
            }
            if event.keyCode == 51 {  // delete / backspace
                if !self.filter.text.isEmpty { self.filter.text.removeLast() }
                return nil
            }
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                return event
            }
            if let chars = event.charactersIgnoringModifiers,
               let scalar = chars.unicodeScalars.first,
               chars.count == 1,
               scalar.value >= 0x20, scalar.value != 0x7F {
                self.filter.text.append(chars)
                return nil
            }
            return event
        }
    }

    private func removeMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }
}

// a nonactivating HUD should respond to the first click
private final class KeybindOverlayHostingView<Content: View>: OverlayHostingView<Content> {
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless panel that can still become key so it receives typed
/// characters without activating the app (Spotlight style).
private final class KeybindOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Observable filter string, published to the SwiftUI content.
private final class FilterModel: ObservableObject {
    @Published var text: String = ""
}

// MARK: - display row model

/// A single rendered row: description + already-formatted chord glyphs.
private struct OverlayRow: Identifiable {
    let id = UUID()
    let description: String
    let chord: String
    let isFloating: Bool
}

/// A category section with its display header and rows.
private struct OverlaySection: Identifiable {
    let id = UUID()
    let title: String
    let rows: [OverlayRow]
}

enum KeybindOverlayGrouping {
    /// Workspace-number actions that fold into one "… workspace N" row.
    /// The raw value is the Settings disclosure id.
    enum WorkspaceFamily: String, CaseIterable {
        case switchTo = "switch"
        case move
        case moveAndFollow

        var title: String {
            switch self {
            case .switchTo:      return "Switch to workspace N"
            case .move:          return "Move window to workspace N"
            case .moveAndFollow: return "Move window to workspace N and follow"
            }
        }
    }

    static func workspaceFamily(of action: Action) -> (family: WorkspaceFamily, number: Int)? {
        switch action {
        case .switchWorkspace(let n):          return (.switchTo, n)
        case .moveToWorkspace(let n):          return (.move, n)
        case .moveToWorkspaceAndFollow(let n): return (.moveAndFollow, n)
        default:                               return nil
        }
    }

    /// Indices of the binds that fold into one row with `seed`: the same
    /// family and modifiers, each on its own number key, covering every
    /// workspace. nil when the run is incomplete or `seed` is customized.
    static func workspaceRun(seededBy seed: Keybind,
                             in binds: [Keybind]) -> (family: WorkspaceFamily, indices: [Int])? {
        guard let seedMember = workspaceFamily(of: seed.action),
              usesCanonicalWorkspaceKey(seed, number: seedMember.number) else { return nil }
        var numbers: [Int] = []
        var indices: [Int] = []
        for (j, other) in binds.enumerated() where other.modifiers == seed.modifiers {
            guard let member = workspaceFamily(of: other.action), member.family == seedMember.family,
                  usesCanonicalWorkspaceKey(other, number: member.number) else { continue }
            numbers.append(member.number)
            indices.append(j)
        }
        guard isCompleteWorkspaceRange(numbers) else { return nil }
        return (seedMember.family, indices)
    }

    static func usesCanonicalWorkspaceKey(_ bind: Keybind, number: Int) -> Bool {
        bind.keyCodeName == (number == Constants.workspaceCount ? "0" : String(number))
    }

    static func usesCanonicalDirectionKey(_ bind: Keybind, direction: Direction) -> Bool {
        let expected: String
        switch direction {
        case .left: expected = "←"
        case .up: expected = "↑"
        case .down: expected = "↓"
        case .right: expected = "→"
        }
        return bind.keyCodeName == expected
    }

    static func isCompleteWorkspaceRange(_ numbers: [Int]) -> Bool {
        numbers.sorted() == Array(Constants.workspaceRange)
    }
}

// MARK: - overlay SwiftUI view

private struct KeybindOverlayView: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: OverlayPalette { OverlayPalette(scheme: colorScheme) }
    let keybinds: [Keybind]
    let cardWidth: CGFloat
    let showTutorial: () -> Void
    @EnvironmentObject var filter: FilterModel
    @ObservedObject private var config = UserConfig.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            columns
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
        .frame(width: cardWidth, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.separator, lineWidth: 1)
        )
        .compositingGroup()
        .shadow(color: palette.shadow, radius: 18, x: 0, y: 8)
        .padding(64)
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                HStack(spacing: 9) {
                    Text("Keybinds")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.hudPrimary)
                    HStack(spacing: 3) {
                        KeyChip("HYPR")
                        KeyChip("K")
                    }
                }
                Spacer()
                Button(action: showTutorial) {
                    Text("Tutorial")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.hyprCyan)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .background(Color.hyprCyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                Text(hintText)
                    .font(.system(size: 12, design: filter.text.isEmpty ? .default : .monospaced))
                    .foregroundStyle(filter.text.isEmpty ? Color.hudFaint : Color.hyprCyan)
            }
            Text("HYPR = \(config.hyprKey.displayName)  ·  N = workspace key (1–9, 0 for 10)")
                .font(.system(size: 12))
                .foregroundStyle(Color.hudFaint)
        }
    }

    private var hintText: String {
        filter.text.isEmpty ? "type to filter · esc to close" : "filter: \(filter.text)…"
    }

    // MARK: three-column grid

    private var columns: some View {
        HStack(alignment: .top, spacing: 14) {
            column(leftSections)
            column(centerSections)
            column(rightSections)
        }
    }

    private func column(_ sections: [OverlaySection]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 0) {
                    Text(section.title)
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.hyprCyan)
                        .padding(.bottom, 8)
                    ForEach(section.rows) { row in
                        rowView(row)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func rowView(_ row: OverlayRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(spacing: 4) {
                Text(row.description)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.hudPrimary.opacity(0.85))
                if row.isFloating {
                    Text("◇")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.hyprMagenta)
                }
            }
            Spacer(minLength: 10)
            Text(row.chord)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.hudPrimary.opacity(0.8))
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 6)
    }

    // MARK: sections

    // left = Window Management, center = Apps + System,
    // right = Workspaces, then Focus & Navigation
    private var leftSections: [OverlaySection] {
        [section(for: .windowManagement)].compactMap { $0 }
    }

    private var centerSections: [OverlaySection] {
        let merged = rows(for: .apps) + rows(for: .system)
        return merged.isEmpty ? [] : [OverlaySection(title: "Apps & System", rows: merged)]
    }

    private var rightSections: [OverlaySection] {
        [section(for: .workspaces), section(for: .focusNav)].compactMap { $0 }
    }

    private func section(for category: KeybindCategory) -> OverlaySection? {
        let r = rows(for: category)
        return r.isEmpty ? nil : OverlaySection(title: category.rawValue, rows: r)
    }

    // MARK: row building + coalescing

    private func rows(for category: KeybindCategory) -> [OverlayRow] {
        let binds = keybinds.filter { KeybindCategory.from($0.action) == category }
        var result = coalesce(binds)
        if category == .windowManagement {
            result.append(OverlayRow(description: "Swap tiles by dragging", chord: "HYPR + drag", isFloating: false))
        }
        return result.filter { matchesFilter($0.description) }
    }

    private func matchesFilter(_ description: String) -> Bool {
        let q = filter.text.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        return description.lowercased().contains(q.lowercased())
    }

    // fold direction binds and workspace-number binds into single rows
    // when the whole run shares modifiers; otherwise emit them plainly.
    private func coalesce(_ binds: [Keybind]) -> [OverlayRow] {
        var rows: [OverlayRow] = []
        var consumed = Set<Int>()

        for (i, bind) in binds.enumerated() {
            if consumed.contains(i) { continue }

            if let coalesced = coalescedRow(from: bind, in: binds, consuming: &consumed) {
                rows.append(coalesced)
            } else {
                consumed.insert(i)
                rows.append(plainRow(bind))
            }
        }
        return rows
    }

    // direction-bind families that coalesce into one arrow row
    private enum DirFamily { case focus, swap, monitor, resize }

    private func dirFamily(_ action: Action) -> DirFamily? {
        switch action {
        case .focusDirection:      return .focus
        case .swapDirection:       return .swap
        case .moveWindowToMonitor: return .monitor
        case .resizeDirection:     return .resize
        default:                   return nil
        }
    }

    // try to merge `bind` with its sibling directions / workspace numbers
    private func coalescedRow(from bind: Keybind, in binds: [Keybind],
                              consuming consumed: inout Set<Int>) -> OverlayRow? {
        switch bind.action {
        case .focusDirection, .swapDirection, .moveWindowToMonitor, .resizeDirection:
            return directionRow(matching: bind, in: binds, consuming: &consumed)
        case .switchWorkspace, .moveToWorkspace, .moveToWorkspaceAndFollow:
            return workspaceRow(matching: bind, in: binds, consuming: &consumed)
        default:
            return nil
        }
    }

    // collect all same-family direction binds that share modifiers
    private func directionRow(matching seed: Keybind, in binds: [Keybind],
                              consuming consumed: inout Set<Int>) -> OverlayRow? {
        guard let family = dirFamily(seed.action) else { return nil }
        let seedDirection: Direction
        switch seed.action {
        case .focusDirection(let d), .swapDirection(let d),
             .moveWindowToMonitor(let d), .resizeDirection(let d): seedDirection = d
        default: return nil
        }
        guard KeybindOverlayGrouping.usesCanonicalDirectionKey(
            seed, direction: seedDirection) else { return nil }

        var arrows: [Direction] = []
        var indices: [Int] = []
        for (j, other) in binds.enumerated() where other.modifiers == seed.modifiers {
            guard dirFamily(other.action) == family else { continue }
            let dir: Direction?
            switch other.action {
            case .focusDirection(let d):      dir = d
            case .swapDirection(let d):       dir = d
            case .moveWindowToMonitor(let d): dir = d
            case .resizeDirection(let d):     dir = d
            default:                          dir = nil
            }
            if let dir, KeybindOverlayGrouping.usesCanonicalDirectionKey(other, direction: dir) {
                arrows.append(dir)
                indices.append(j)
            }
        }
        // need at least two to justify coalescing
        guard arrows.count >= 2 else { return nil }
        indices.forEach { consumed.insert($0) }

        let glyphs = arrowGlyphs(for: arrows)
        let chord = chordString(modifiers: seed.modifiers, key: glyphs)
        let desc: String
        switch family {
        case .focus:   desc = "Focus direction"
        case .swap:    desc = "Swap direction"
        case .monitor: desc = "Move to monitor"
        case .resize:  desc = "Resize window"
        }
        return OverlayRow(description: desc, chord: chord, isFloating: false)
    }

    // collect the full workspace run sharing modifiers
    private func workspaceRow(matching seed: Keybind, in binds: [Keybind],
                              consuming consumed: inout Set<Int>) -> OverlayRow? {
        guard let run = KeybindOverlayGrouping.workspaceRun(seededBy: seed, in: binds) else { return nil }
        run.indices.forEach { consumed.insert($0) }

        let chord = chordString(modifiers: seed.modifiers, key: "N")
        return OverlayRow(description: run.family.title, chord: chord, isFloating: false)
    }

    private func plainRow(_ bind: Keybind) -> OverlayRow {
        let chord = bind.overlayChord
        return OverlayRow(description: bind.actionDescription,
                          chord: chord,
                          isFloating: isFloatingAction(bind.action))
    }

    // MARK: chord formatting

    // textual Hypr modifier followed by standard modifier glyphs and key
    private func chordString(modifiers: ModifierFlags, key: String) -> String {
        var parts: [String] = []
        if modifiers.contains(.hypr)    { parts.append("HYPR") }
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option)  { parts.append("⌥") }
        if modifiers.contains(.shift)   { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(key)
        return parts.joined(separator: " ")
    }

    // arrows in canonical L↑↓R order, contiguous (no spaces) per mockup
    private func arrowGlyphs(for dirs: [Direction]) -> String {
        let order: [Direction] = [.left, .up, .down, .right]
        let present = Set(dirs)
        return order.filter { present.contains($0) }
            .map { glyph(for: $0) }.joined()
    }

    private func glyph(for d: Direction) -> String {
        switch d {
        case .left:  return "←"
        case .up:    return "↑"
        case .down:  return "↓"
        case .right: return "→"
        }
    }

    // actions whose semantics touch the floating layer get the ◇ suffix
    private func isFloatingAction(_ action: Action) -> Bool {
        switch action {
        case .toggleFloating, .focusFloating, .toggleScratchpad, .moveToScratchpad:
            return true
        default:
            return false
        }
    }
}

// MARK: - HUD text colors

private extension Color {
    static let hudPrimary = Color.primary
    static let hudFaint = Color.secondary
}
