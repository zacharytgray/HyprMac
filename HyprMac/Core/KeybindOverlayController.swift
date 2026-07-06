// HUD panel listing every active keybind, grouped by category. Toggled
// via `Hypr+K`. Spotlight-style borderless panel — takes keyboard input
// (type-to-filter, esc to close) without activating the app.

import Cocoa
import SwiftUI

/// Lifecycle for the keybind overlay HUD.
///
/// Holds a borderless `.nonactivatingPanel` at `.floating` level and a
/// local keyDown monitor for type-to-filter. `toggle` shows or hides.
///
/// Threading: main-thread only.
class KeybindOverlayController {

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
        panel?.close()
        panel = nil
    }

    private func show(keybinds: [Keybind]) {
        guard let screen = NSScreen.main else { return }

        filter.text = ""  // fresh filter on every show

        let maxHeight = screen.visibleFrame.height * 0.75

        let content = KeybindOverlayView(keybinds: keybinds)
            .environmentObject(filter)
        let hosting = NSHostingView(rootView: content)
        // force dark so dynamic accents resolve to their neon variants
        hosting.appearance = NSAppearance(named: .darkAqua)
        // card is 560 + 6px shadow margin each side; size panel to fit
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
        p.level = .floating
        p.hidesOnDeactivate = false
        p.appearance = NSAppearance(named: .darkAqua)

        hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting

        p.makeKeyAndOrderFront(nil)
        self.panel = p

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

// MARK: - overlay SwiftUI view

private struct KeybindOverlayView: View {
    let keybinds: [Keybind]
    @EnvironmentObject var filter: FilterModel
    @ObservedObject private var config = UserConfig.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            columns
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .frame(width: 560, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: NSColor(calibratedWhite: 24.0 / 255.0, alpha: 0.96)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 35, x: 0, y: 30)
        .padding(6)  // room for the shadow inside the clear panel
        .environment(\.colorScheme, .dark)  // HUD is dark in both appearances
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 9) {
                Text("Keybinds")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.hudPrimary)
                HStack(spacing: 3) {
                    KeyChip(config.hyprKey.badgeLabel)
                    KeyChip("K")
                }
            }
            Spacer()
            Text(hintText)
                .font(.system(size: 10, design: filter.text.isEmpty ? .default : .monospaced))
                .foregroundStyle(filter.text.isEmpty ? Color.hudFaint : Color.hyprCyan)
        }
    }

    private var hintText: String {
        filter.text.isEmpty ? "type to filter · esc to close" : "filter: \(filter.text)…"
    }

    // MARK: two-column grid

    private var columns: some View {
        HStack(alignment: .top, spacing: 14) {
            column(leftSections)
            column(rightSections)
        }
    }

    private func column(_ sections: [OverlaySection]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 0) {
                    Text(section.title)
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.hyprCyan)
                        .padding(.bottom, 6)
                    ForEach(section.rows) { row in
                        rowView(row)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func rowView(_ row: OverlayRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 4) {
                Text(row.description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.hudPrimary.opacity(0.85))
                if row.isFloating {
                    Text("◇")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.hyprMagenta)
                }
            }
            Spacer(minLength: 8)
            Text(row.chord)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.hudPrimary.opacity(0.6))
        }
        .padding(.vertical, 5)
    }

    // MARK: sections

    // left = Focus & Navigation, Workspaces
    private var leftSections: [OverlaySection] {
        [section(for: .focusNav), section(for: .workspaces)].compactMap { $0 }
    }

    // right = Window Management, then Apps + System merged as "APPS & SYSTEM"
    private var rightSections: [OverlaySection] {
        var result: [OverlaySection] = []
        if let wm = section(for: .windowManagement) { result.append(wm) }
        let appsRows = rows(for: .apps)
        let systemRows = rows(for: .system)
        let merged = appsRows + systemRows
        if !merged.isEmpty {
            result.append(OverlaySection(title: "Apps & System", rows: merged))
        }
        return result
    }

    private func section(for category: KeybindCategory) -> OverlaySection? {
        let r = rows(for: category)
        return r.isEmpty ? nil : OverlaySection(title: category.rawValue, rows: r)
    }

    // MARK: row building + coalescing

    private func rows(for category: KeybindCategory) -> [OverlayRow] {
        let binds = keybinds.filter { KeybindCategory.from($0.action) == category }
        return coalesce(binds).filter { matchesFilter($0.description) }
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
    private enum DirFamily { case focus, swap, monitor }

    private func dirFamily(_ action: Action) -> DirFamily? {
        switch action {
        case .focusDirection:      return .focus
        case .swapDirection:       return .swap
        case .moveWindowToMonitor: return .monitor
        default:                   return nil
        }
    }

    // try to merge `bind` with its sibling directions / workspace numbers
    private func coalescedRow(from bind: Keybind, in binds: [Keybind],
                              consuming consumed: inout Set<Int>) -> OverlayRow? {
        switch bind.action {
        case .focusDirection, .swapDirection, .moveWindowToMonitor:
            return directionRow(matching: bind, in: binds, consuming: &consumed)
        case .switchWorkspace, .moveToWorkspace:
            return workspaceRow(matching: bind, in: binds, consuming: &consumed)
        default:
            return nil
        }
    }

    // collect all same-family direction binds that share modifiers
    private func directionRow(matching seed: Keybind, in binds: [Keybind],
                              consuming consumed: inout Set<Int>) -> OverlayRow? {
        guard let family = dirFamily(seed.action) else { return nil }

        var arrows: [Direction] = []
        var indices: [Int] = []
        for (j, other) in binds.enumerated() where other.modifiers == seed.modifiers {
            guard dirFamily(other.action) == family else { continue }
            let dir: Direction?
            switch other.action {
            case .focusDirection(let d):      dir = d
            case .swapDirection(let d):       dir = d
            case .moveWindowToMonitor(let d): dir = d
            default:                          dir = nil
            }
            if let dir { arrows.append(dir); indices.append(j) }
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
        }
        return OverlayRow(description: desc, chord: chord, isFloating: false)
    }

    // collect the full 1-9 run of a workspace family sharing modifiers
    private func workspaceRow(matching seed: Keybind, in binds: [Keybind],
                              consuming consumed: inout Set<Int>) -> OverlayRow? {
        let isSwitch: Bool
        if case .switchWorkspace = seed.action { isSwitch = true }
        else { isSwitch = false }

        var numbers: [Int] = []
        var indices: [Int] = []
        for (j, other) in binds.enumerated() where other.modifiers == seed.modifiers {
            let n: Int?
            switch other.action {
            case .switchWorkspace(let v) where isSwitch:  n = v
            case .moveToWorkspace(let v) where !isSwitch: n = v
            default: n = nil
            }
            if let n { numbers.append(n); indices.append(j) }
        }
        guard numbers.count >= 2 else { return nil }
        indices.forEach { consumed.insert($0) }

        let sorted = numbers.sorted()
        let range = "\(sorted.first!)–\(sorted.last!)"
        let chord = chordString(modifiers: seed.modifiers, key: range)
        let desc = isSwitch ? "Go to workspace" : "Send window to workspace"
        return OverlayRow(description: desc, chord: chord, isFloating: false)
    }

    private func plainRow(_ bind: Keybind) -> OverlayRow {
        let chord = chordString(modifiers: bind.modifiers, key: bind.keyCodeName)
        return OverlayRow(description: bind.actionDescription,
                          chord: chord,
                          isFloating: isFloatingAction(bind.action))
    }

    // MARK: chord formatting

    // spaced-glyph chord: modifier glyphs then key, e.g. "⇪ ⇧ T"
    private func chordString(modifiers: ModifierFlags, key: String) -> String {
        var parts: [String] = []
        if modifiers.contains(.hypr)    { parts.append(config.hyprKey.badgeLabel) }
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

// MARK: - HUD text colors (fixed, appearance-independent)

private extension Color {
    // #ececf1 — the mockup's near-white HUD text
    static let hudPrimary = Color(red: 0xEC / 255.0, green: 0xEC / 255.0, blue: 0xF1 / 255.0)
    static let hudFaint   = Color(red: 0xEC / 255.0, green: 0xEC / 255.0, blue: 0xF1 / 255.0).opacity(0.35)
}
