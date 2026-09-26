// HUD panel listing every active keybind, grouped by category. Toggled
// via `Hypr+K`. Spotlight-style borderless panel — takes keyboard input
// (type-to-filter, arrows to scroll, esc to close) without activating the app.

import Cocoa
import Combine
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
    private let input = OverlayInput()

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

        input.text = ""  // fresh filter on every show

        let maxHeight = screen.visibleFrame.height * 0.75
        let cardWidth = min(KeybindOverlayView.preferredWidth, screen.visibleFrame.width - 160)

        // the list has a fixed height, so the card never changes size while
        // filtering. shorten the list on small screens so the card fits.
        var listHeight = OverlayListLayout.preferredHeight
        let hosting = KeybindOverlayHostingView(rootView: content(keybinds, cardWidth, listHeight))
        var fitted = hosting.fittingSize
        if fitted.height > maxHeight {
            listHeight = max(OverlayListLayout.minimumHeight, listHeight - (fitted.height - maxHeight))
            hosting.rootView = content(keybinds, cardWidth, listHeight)
            fitted = hosting.fittingSize
        }
        // leave transparent space around the card for the shadow to dissipate
        let panelWidth = fitted.width
        let panelHeight = max(fitted.height, 1)
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

    private func content(_ keybinds: [Keybind], _ cardWidth: CGFloat, _ listHeight: CGFloat) -> some View {
        KeybindOverlayView(keybinds: keybinds, cardWidth: cardWidth, listHeight: listHeight) { [weak self] in
            self?.openTutorial()
        }
        .environmentObject(input)
    }

    // MARK: - key monitor

    private func installMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel != nil else { return event }

            switch OverlayKeyCommand(keyCode: event.keyCode,
                                     characters: event.charactersIgnoringModifiers,
                                     modifiers: event.modifierFlags) {
            case .close:
                self.close()
                return nil
            case .deleteBackward:
                if !self.input.text.isEmpty { self.input.text.removeLast() }
                return nil
            case .scroll(let step):
                self.input.scrollSteps.send(step)
                return nil
            case .append(let chars):
                self.input.text.append(chars)
                return nil
            case .swallow:
                return nil
            case .passThrough:
                return event
            }
        }
    }

    private func removeMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }
}

/// What a keyDown does while the overlay is open.
enum OverlayKeyCommand: Equatable {
    case close
    case deleteBackward
    case scroll(Int)
    case append(String)
    case swallow
    case passThrough

    // esc closes, backspace trims, up/down scroll, printable chars append.
    // chords with cmd/ctrl are left for the system.
    init(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) {
        switch keyCode {
        case 53: self = .close; return            // escape
        case 51: self = .deleteBackward; return   // delete / backspace
        default: break
        }
        if modifiers.contains(.command) || modifiers.contains(.control) {
            self = .passThrough
            return
        }
        switch keyCode {
        case 125: self = .scroll(1); return    // down arrow
        case 126: self = .scroll(-1); return   // up arrow
        default: break
        }
        guard let chars = characters, chars.count == 1,
              let scalar = chars.unicodeScalars.first else {
            self = .passThrough
            return
        }
        // arrows, F-keys, home/end report private-use characters; never
        // let them into the filter
        if (0xF700...0xF8FF).contains(scalar.value) {
            self = .swallow
            return
        }
        if scalar.value >= 0x20, scalar.value != 0x7F {
            self = .append(chars)
            return
        }
        self = .passThrough
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

/// Typed filter and arrow-key scroll requests, fed by the key monitor.
final class OverlayInput: ObservableObject {
    @Published var text: String = ""
    let scrollSteps = PassthroughSubject<Int, Never>()

    var query: String { text.trimmingCharacters(in: .whitespaces) }
}

// MARK: - display row model

/// A single rendered row: description plus the chord as key-chip labels.
struct OverlayRow: Identifiable, Equatable {
    let id: String
    let description: String
    let chord: [String]
    let isFloating: Bool
}

/// A category section with its rows.
struct OverlaySection: Identifiable, Equatable {
    let category: KeybindCategory
    let rows: [OverlayRow]

    var id: String { category.rawValue }
    var title: String { category.rawValue }
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

// MARK: - row building

/// Builds the overlay's sections from the live keybinds: one section per
/// category in `KeybindCategory` order, direction and workspace runs folded
/// into single rows, then filtered by the typed query.
enum KeybindOverlayContent {
    static func sections(for keybinds: [Keybind], filter: String) -> [OverlaySection] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return KeybindCategory.allCases.compactMap { category in
            let rows = rows(for: category, in: keybinds).filter { matches($0.description, query: query) }
            return rows.isEmpty ? nil : OverlaySection(category: category, rows: rows)
        }
    }

    static func matches(_ description: String, query: String) -> Bool {
        query.isEmpty || matchRange(in: description, query: query) != nil
    }

    static func matchRange(in description: String, query: String) -> Range<String.Index>? {
        query.isEmpty ? nil : description.range(of: query, options: .caseInsensitive)
    }

    // ids come from the unfiltered position so they stay put while typing
    private static func rows(for category: KeybindCategory, in keybinds: [Keybind]) -> [OverlayRow] {
        let binds = keybinds.filter { KeybindCategory.from($0.action) == category }
        var rows = coalesce(binds)
        if category == .windowManagement {
            rows.append(("Swap tiles by dragging", ["HYPR", "drag"], false))
        }
        return rows.enumerated().map { i, row in
            OverlayRow(id: "\(category.rawValue)/\(i)", description: row.description,
                       chord: row.chord, isFloating: row.isFloating)
        }
    }

    private typealias RowParts = (description: String, chord: [String], isFloating: Bool)

    // fold direction binds and workspace-number binds into single rows
    // when the whole run shares modifiers; otherwise emit them plainly.
    private static func coalesce(_ binds: [Keybind]) -> [RowParts] {
        var rows: [RowParts] = []
        var consumed = Set<Int>()

        for (i, bind) in binds.enumerated() {
            if consumed.contains(i) { continue }

            if let coalesced = coalescedRow(from: bind, in: binds, consuming: &consumed) {
                rows.append(coalesced)
            } else {
                consumed.insert(i)
                rows.append((bind.actionDescription, bind.badgeLabels(), isFloatingAction(bind.action)))
            }
        }
        return rows
    }

    // direction-bind families that coalesce into one arrow row
    private enum DirFamily { case focus, swap, monitor, resize }

    private static func direction(of action: Action) -> (family: DirFamily, direction: Direction)? {
        switch action {
        case .focusDirection(let d):      return (.focus, d)
        case .swapDirection(let d):       return (.swap, d)
        case .moveWindowToMonitor(let d): return (.monitor, d)
        case .resizeDirection(let d):     return (.resize, d)
        default:                          return nil
        }
    }

    // try to merge `bind` with its sibling directions / workspace numbers
    private static func coalescedRow(from bind: Keybind, in binds: [Keybind],
                                     consuming consumed: inout Set<Int>) -> RowParts? {
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
    private static func directionRow(matching seed: Keybind, in binds: [Keybind],
                                     consuming consumed: inout Set<Int>) -> RowParts? {
        guard let seedMember = direction(of: seed.action),
              KeybindOverlayGrouping.usesCanonicalDirectionKey(
                seed, direction: seedMember.direction) else { return nil }

        var arrows: [Direction] = []
        var indices: [Int] = []
        for (j, other) in binds.enumerated() where other.modifiers == seed.modifiers {
            guard let member = direction(of: other.action), member.family == seedMember.family,
                  KeybindOverlayGrouping.usesCanonicalDirectionKey(other, direction: member.direction) else { continue }
            arrows.append(member.direction)
            indices.append(j)
        }
        // need at least two to justify coalescing
        guard arrows.count >= 2 else { return nil }
        indices.forEach { consumed.insert($0) }

        let desc: String
        switch seedMember.family {
        case .focus:   desc = "Focus direction"
        case .swap:    desc = "Swap direction"
        case .monitor: desc = "Move to monitor"
        case .resize:  desc = "Resize window"
        }
        return (desc, chordLabels(modifiers: seed.modifiers, key: arrowGlyphs(for: arrows)), false)
    }

    // collect the full workspace run sharing modifiers
    private static func workspaceRow(matching seed: Keybind, in binds: [Keybind],
                                     consuming consumed: inout Set<Int>) -> RowParts? {
        guard let run = KeybindOverlayGrouping.workspaceRun(seededBy: seed, in: binds) else { return nil }
        run.indices.forEach { consumed.insert($0) }
        return (run.family.title, chordLabels(modifiers: seed.modifiers, key: "N"), false)
    }

    // same modifier order as `Keybind.badgeLabels`
    private static func chordLabels(modifiers: ModifierFlags, key: String) -> [String] {
        var parts: [String] = []
        if modifiers.contains(.hypr)    { parts.append("HYPR") }
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option)  { parts.append("⌥") }
        if modifiers.contains(.shift)   { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(key)
        return parts
    }

    // arrows in canonical L↑↓R order, contiguous in one chip
    private static func arrowGlyphs(for dirs: [Direction]) -> String {
        let order: [Direction] = [.left, .up, .down, .right]
        let present = Set(dirs)
        return order.filter { present.contains($0) }.map { d -> String in
            switch d {
            case .left:  return "←"
            case .up:    return "↑"
            case .down:  return "↓"
            case .right: return "→"
            }
        }.joined()
    }

    // actions whose semantics touch the floating layer get the ◇ suffix
    private static func isFloatingAction(_ action: Action) -> Bool {
        switch action {
        case .toggleFloating, .focusFloating, .toggleScratchpad, .moveToScratchpad:
            return true
        default:
            return false
        }
    }
}

// MARK: - list geometry

/// Fixed row and header heights, and the scroll stops arrow keys move between.
enum OverlayListLayout {
    static let rowHeight: CGFloat = 34
    static let headerHeight: CGFloat = 30
    /// about eleven rows
    static let preferredHeight: CGFloat = 380
    static let minimumHeight: CGFloat = 160

    /// One scroll offset per row, putting that row just under the pinned
    /// section header. A section's first row shares its header's offset.
    static func scrollStops(for sections: [OverlaySection]) -> [CGFloat] {
        var stops: [CGFloat] = []
        var y: CGFloat = 0
        for section in sections {
            y += headerHeight
            for _ in section.rows {
                stops.append(y - headerHeight)
                y += rowHeight
            }
        }
        return stops
    }

    /// Space under the last row so the bottom of the list is also a stop,
    /// with no row half under a pinned header.
    static func bottomPadding(for sections: [OverlaySection], viewport: CGFloat) -> CGFloat {
        let content = sections.reduce(0) { $0 + headerHeight + CGFloat($1.rows.count) * rowHeight }
        let maxOffset = content - viewport
        guard maxOffset > 0,
              let stop = scrollStops(for: sections).first(where: { $0 >= maxOffset }) else { return 0 }
        return stop - maxOffset
    }

    /// Index of the stop `step` rows away from `offset`, or nil at either end.
    static func stopIndex(from offset: CGFloat, step: Int, in stops: [CGFloat]) -> Int? {
        guard step != 0, !stops.isEmpty else { return nil }
        if step > 0 {
            guard let next = stops.firstIndex(where: { $0 > offset + 0.5 }) else { return nil }
            return min(next + step - 1, stops.count - 1)
        }
        guard let previous = stops.lastIndex(where: { $0 < offset - 0.5 }) else { return nil }
        return max(previous + step + 1, 0)
    }
}

// MARK: - overlay SwiftUI view

struct KeybindOverlayView: View {
    static let preferredWidth: CGFloat = 620

    @Environment(\.colorScheme) private var colorScheme
    private var palette: OverlayPalette { OverlayPalette(scheme: colorScheme) }
    let keybinds: [Keybind]
    let cardWidth: CGFloat
    let listHeight: CGFloat
    let showTutorial: () -> Void
    @EnvironmentObject var input: OverlayInput
    @ObservedObject private var config = UserConfig.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            searchField
            list
            footer
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
        .frame(width: cardWidth, alignment: .topLeading)
        .background(
            // opaque, so the pinned section headers match it exactly
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.opaqueBackground)
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
        HStack(alignment: .center, spacing: 9) {
            Text("Keybinds")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.hudPrimary)
            HStack(spacing: 3) {
                KeyChip("HYPR")
                KeyChip("K")
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
        }
    }

    // drawn, not a text field: the key monitor feeds it so the panel never
    // has to activate the app
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Color.hudFaint)
            if input.text.isEmpty {
                caret
                Text("Type to search keybinds")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            } else {
                Text(input.text)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.hudPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
                caret.padding(.leading, -6)
            }
            Spacer(minLength: 8)
            Text("esc to close")
                .font(.system(size: 12))
                .foregroundStyle(Color.hudFaint)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.hyprCyan.opacity(0.45), lineWidth: 1)
        )
    }

    private var caret: some View {
        Rectangle()
            .fill(Color.hyprCyan)
            .frame(width: 2, height: 18)
    }

    private var footer: some View {
        Text("HYPR = \(config.hyprKey.displayName)  ·  N = workspace key (1–9, 0 for 10)  ·  ↑↓ to scroll")
            .font(.system(size: 12))
            .foregroundStyle(Color.hudFaint)
    }

    // MARK: list

    @ViewBuilder
    private var list: some View {
        let sections = KeybindOverlayContent.sections(for: keybinds, filter: input.text)
        if sections.isEmpty {
            Text("No keybinds match \u{201C}\(input.query)\u{201D}")
                .font(.system(size: 14))
                .foregroundStyle(Color.hudFaint)
                .frame(maxWidth: .infinity)
                .frame(height: listHeight)
        } else {
            OverlayList(sections: sections, query: input.query, height: listHeight,
                        palette: palette, scrollSteps: input.scrollSteps)
                // a new query starts back at the top
                .id(input.query)
        }
    }
}

/// Scrolling list with pinned section headers. Arrow keys step one row at a
/// time from wherever the list sits, including after a trackpad scroll.
private struct OverlayList: View {
    let sections: [OverlaySection]
    let query: String
    let height: CGFloat
    let palette: OverlayPalette
    let scrollSteps: PassthroughSubject<Int, Never>

    @StateObject private var scroller = OverlayScroller()

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            rowView(row)
                        }
                    } header: {
                        sectionHeader(section.title)
                    }
                }
            }
            .padding(.bottom, OverlayListLayout.bottomPadding(for: sections, viewport: height))
            .background(ScrollViewFinder(scroller: scroller))
        }
        .frame(height: height)
        .onReceive(scrollSteps) { step in
            scroller.step(step, through: OverlayListLayout.scrollStops(for: sections),
                          animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        .overlay(alignment: .bottom) {
            // more below
            if scroller.hasMoreBelow {
                LinearGradient(colors: [palette.opaqueBackground.opacity(0), palette.opaqueBackground],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 32)
                    .allowsHitTesting(false)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(Color.hyprCyan)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: OverlayListLayout.headerHeight)
            .background(palette.opaqueBackground)
    }

    private func rowView(_ row: OverlayRow) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                highlighted(row.description)
                    .font(.system(size: 14))
                    .foregroundColor(Color.hudPrimary.opacity(0.88))
                if row.isFloating {
                    Text("◇")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.hyprMagenta)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            HStack(spacing: 3) {
                ForEach(Array(row.chord.enumerated()), id: \.offset) { _, label in
                    KeyChip(label, fontSize: 11)
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)  // room for the overlay scroller
        .frame(height: OverlayListLayout.rowHeight)
    }

    // the matched part of the description in bold cyan
    private func highlighted(_ description: String) -> Text {
        guard let range = KeybindOverlayContent.matchRange(in: description, query: query) else {
            return Text(description)
        }
        return Text(description[..<range.lowerBound])
            + Text(description[range]).foregroundColor(.hyprCyan).fontWeight(.semibold)
            + Text(description[range.upperBound...])
    }
}

/// Drives the NSScrollView behind the SwiftUI list. SwiftUI on macOS 13 can
/// neither read a scroll offset reliably nor scroll to an arbitrary one.
final class OverlayScroller: ObservableObject {
    @Published private(set) var hasMoreBelow = false
    private weak var scrollView: NSScrollView?
    private var observer: NSObjectProtocol?
    // where a running scroll animation will land
    private var pendingTarget: CGFloat?

    /// Distance scrolled from the top. The document view is flipped.
    var offset: CGFloat { scrollView?.contentView.bounds.minY ?? 0 }

    /// Where the next arrow step counts from. Mid-animation that is the
    /// animation's target, so quick presses and key repeat each move a row.
    var stepOrigin: CGFloat { pendingTarget ?? offset }

    private var maxOffset: CGFloat {
        guard let sv = scrollView, let doc = sv.documentView else { return 0 }
        return max(0, doc.frame.height - sv.contentView.bounds.height)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func attach(_ sv: NSScrollView?) {
        guard let sv, sv !== scrollView else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        scrollView = sv
        // keep a legacy scroller's gutter even when the list fits, so the
        // chips don't shift sideways while filtering
        sv.autohidesScrollers = false
        sv.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: sv.contentView, queue: .main
        ) { [weak self] _ in self?.refresh() }
        refresh()
    }

    // called from layout, so publish on the next turn of the run loop
    func refresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let more = self.maxOffset - self.offset > 1
            if more != self.hasMoreBelow { self.hasMoreBelow = more }
        }
    }

    func step(_ step: Int, through stops: [CGFloat], animated: Bool) {
        guard let i = OverlayListLayout.stopIndex(from: stepOrigin, step: step, in: stops) else { return }
        scroll(to: stops[i], animated: animated)
    }

    func scroll(to y: CGFloat, animated: Bool) {
        guard let sv = scrollView else { return }
        let clip = sv.contentView
        let target = NSPoint(x: clip.bounds.minX, y: min(max(y, 0), maxOffset))
        guard animated else {
            pendingTarget = nil
            clip.scroll(to: target)
            sv.reflectScrolledClipView(clip)
            return
        }
        pendingTarget = target.y
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            clip.animator().setBoundsOrigin(target)
        } completionHandler: { [weak self] in
            sv.reflectScrolledClipView(clip)
            // a newer press may have retargeted the animation
            if self?.pendingTarget == target.y { self?.pendingTarget = nil }
        }
    }
}

/// Zero-size view inside the list that hands its enclosing NSScrollView to
/// the scroller, and refreshes it when the list's height changes.
private struct ScrollViewFinder: NSViewRepresentable {
    let scroller: OverlayScroller

    func makeNSView(context: Context) -> FinderView { FinderView(scroller: scroller) }
    func updateNSView(_ nsView: FinderView, context: Context) {}

    final class FinderView: NSView {
        private let scroller: OverlayScroller

        init(scroller: OverlayScroller) {
            self.scroller = scroller
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scroller.attach(enclosingScrollView)
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            scroller.attach(enclosingScrollView)
            scroller.refresh()
        }
    }
}

// MARK: - HUD text colors

private extension Color {
    static let hudPrimary = Color.primary
    static let hudFaint = Color.secondary
}
