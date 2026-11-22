// The window rules overlay (Hypr+I): a small keyboard-driven card over one
// window. Float or tile it once, always for its app, or for windows whose
// title matches an edited version of its own, or forget the rule that
// covers it. The window is fixed when the overlay opens.

import AppKit
import Combine
import SwiftUI

/// What the overlay offers and which row is picked. Plain values, so the
/// keyboard behavior is tested without a panel.
final class WindowRulesOverlayModel: ObservableObject {
    /// Permanent rules only: floating or tiling one window once is Hypr+T.
    enum Row: Equatable, Hashable {
        case floatApp, tileApp
        case floatTitle, tileTitle
        case forget
    }

    let target: FocusedWindowRuleInfo
    @Published var selection: Row
    @Published var contains = false
    /// the title rule's text: the window's title, which the user trims.
    /// edited only while a title row is picked
    @Published var text: String

    init(target: FocusedWindowRuleInfo) {
        self.target = target
        self.text = target.title
        self.selection = Self.rows(for: target)[0]
    }

    /// The rows in order. The app rule already in effect isn't offered
    /// again, and Forget only shows when a rule covers the window.
    var rows: [Row] { Self.rows(for: target) }

    private static func rows(for target: FocusedWindowRuleInfo) -> [Row] {
        var out: [Row] = []
        if !target.appFloats { out.append(.floatApp) }
        if !target.appTiles { out.append(.tileApp) }
        out += [.floatTitle, .tileTitle]
        if target.currentRule != nil { out.append(.forget) }
        return out
    }

    /// The title rule as edited, nil while the text is empty.
    var titleMatch: FloatingRule.Match? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return contains ? .titleContains(trimmed) : .titleIs(trimmed)
    }

    func isEnabled(_ row: Row) -> Bool {
        isTitleRow(row) ? titleMatch != nil : true
    }

    func isTitleRow(_ row: Row) -> Bool { row == .floatTitle || row == .tileTitle }

    /// Up (-1) or down (+1), wrapping, over the rows.
    func move(_ step: Int) {
        let all = rows
        guard let index = all.firstIndex(of: selection) else {
            selection = all.first ?? .floatTitle
            return
        }
        selection = all[(index + step + all.count) % all.count]
    }

    func label(_ row: Row) -> String {
        switch row {
        case .floatApp: return "Always float \(target.appName)"
        case .tileApp: return "Always tile \(target.appName)"
        case .floatTitle: return "Always float windows with this title"
        case .tileTitle: return "Always tile windows with this title"
        case .forget: return "Forget the rule"
        }
    }

    /// The quiet second half of a row, nil when the label says it all.
    func detail(_ row: Row) -> String? {
        switch row {
        case .floatApp, .tileApp: return "every window"
        case .forget: return target.currentRule
        default: return nil
        }
    }

    /// SF Symbol for the row, beside its label.
    func symbol(_ row: Row) -> String {
        switch row {
        case .floatApp, .floatTitle: return "macwindow.on.rectangle"
        case .tileApp, .tileTitle: return "rectangle.split.2x1"
        case .forget: return "arrow.uturn.backward"
        }
    }

    /// The rule as a short chip for the header.
    var ruleChip: String {
        guard let rule = target.currentRule else { return "No rule" }
        if rule.hasPrefix("Never tile") { return "Always float" }
        return rule.components(separatedBy: ":").first ?? rule
    }
}

/// The overlay's card: the same glass, type and chips as Hypr+K, compact.
struct WindowRulesOverlayView: View {
    @ObservedObject var model: WindowRulesOverlayModel
    let icon: NSImage?
    let choose: (WindowRulesOverlayModel.Row) -> Void
    @Environment(\.colorScheme) private var colorScheme
    private var palette: OverlayPalette { OverlayPalette(scheme: colorScheme) }
    @FocusState private var editingTitle: Bool

    static let width: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            VStack(spacing: 2) {
                ForEach(model.rows, id: \.self) { row in
                    rowView(row)
                    if row == model.selection, model.isTitleRow(row) { titleEditor }
                }
            }
            footer
        }
        .padding(EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14))
        .frame(width: Self.width, alignment: .topLeading)
        .overlayCard(cornerRadius: 14, glassTint: OverlayGlassTint.card)
        .onChange(of: model.selection) { row in
            // the field takes the keys while a title row is picked
            editingTitle = model.isTitleRow(row)
        }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.target.appName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(model.target.title.isEmpty ? "No title" : model.target.title)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(model.ruleChip)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(model.target.currentRule == nil ? Color.secondary : Color.overlayPrimary)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(palette.surface, in: Capsule())
        }
        .padding(.horizontal, 4)
    }

    // MARK: rows

    private func rowView(_ row: WindowRulesOverlayModel.Row) -> some View {
        let selected = model.selection == row
        return Button {
            model.selection = row
            if model.isEnabled(row) { choose(row) }
        } label: {
            HStack(spacing: 9) {
                // the pick: an inset accent bar, a colored icon and heavier
                // text. never a filled row
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(selected ? Color.overlayPrimary : Color.clear)
                    .frame(width: 3, height: 16)
                Image(systemName: model.symbol(row))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? Color.overlayPrimary : Color.secondary)
                    .frame(width: 16)
                HStack(spacing: 6) {
                    // the label keeps its width; the quiet detail gives way first
                    Text(model.label(row))
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundColor(Color.primary.opacity(model.isEnabled(row) ? 0.9 : 0.4))
                        .layoutPriority(1)
                    if let detail = model.detail(row) {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 6)
                if selected { KeyChip("↩", fontSize: 10, onGlass: true) }
            }
            .padding(.trailing, 4)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // under the picked title row only: is / contains, and the text
    private var titleEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                matchChip("is", selected: !model.contains) { model.contains = false }
                matchChip("contains", selected: model.contains) { model.contains = true }
                Spacer()
                Text("tab switches")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondary)
            }
            TextField("Title text", text: $model.text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.primary)
                .focused($editingTitle)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: HyprRadius.md))
                .overlay(RoundedRectangle(cornerRadius: HyprRadius.md)
                    .strokeBorder(Color.overlayPrimary.opacity(editingTitle ? 0.6 : 0), lineWidth: 1))
            Text("Trim it to what every such window shares, like “Meeting”.")
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary)
        }
        .padding(.leading, 37)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .onAppear { DispatchQueue.main.async { editingTitle = true } }
    }

    private func matchChip(_ label: String, selected: Bool, _ pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            Text(label)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.overlayPrimary : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(selected ? palette.activeSurface : palette.surface, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 12) {
            hint(["↑", "↓"], "choose")
            hint(["↩"], "apply")
            hint(["esc"], "close")
            Spacer()
            hint(["HYPR", "I"], "")
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { KeyChip($0, fontSize: 9, onGlass: true) }
            if !label.isEmpty {
                Text(label).font(.system(size: 10)).foregroundStyle(Color.secondary)
            }
        }
    }
}

/// Opens and closes the overlay panel, and owns its keys.
final class WindowRulesOverlayController {
    /// run the row for the window the overlay was opened on
    var perform: (WindowRulesOverlayModel.Row, FloatingRule.Match?, CGWindowID) -> Void = { _, _, _ in }
    /// The window goes back to the front on close. The panel itself is a
    /// non-activating key panel and never activates HyprMac: on macOS 27 an
    /// activation HyprMac isn't allowed takes key status off the panel, and
    /// the typing goes to the app behind it.
    var restoreFocus: (CGWindowID) -> Void = { _ in }

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var model: WindowRulesOverlayModel?
    private var selectionWatch: AnyCancellable?
    /// the app that owns the window the overlay is about
    private var targetPID: pid_t?

    var isShowing: Bool { panel != nil }
    /// the window it was opened on, while it is open
    var targetWindowID: CGWindowID? { model?.target.windowID }

    // MARK: closing when the user moves on

    /// A click anywhere outside the overlay. Clicks on the overlay are
    /// HyprMac's own and never reach this.
    func noteClickElsewhere() {
        guard isShowing else { return }
        hyprLog(.notice, .floating, "window rules overlay closed: click elsewhere")
        close(restoringFocus: false)
    }

    /// An app came forward. The window's own app doesn't count: closing a
    /// sheet or the toggle's own focus pass can activate it.
    func noteAppActivated(pid: pid_t) {
        guard isShowing, pid != targetPID, pid != getpid() else { return }
        hyprLog(.notice, .floating, "window rules overlay closed: app switch to pid \(pid)")
        close(restoringFocus: false)
    }

    /// Any HyprMac action other than Hypr+I: a workspace switch, a move,
    /// a focus change. The window may not be where the overlay is about.
    func noteOtherAction() {
        guard isShowing else { return }
        hyprLog(.notice, .floating, "window rules overlay closed: another action")
        close(restoringFocus: false)
    }

    /// Windows that closed, hid or left this poll.
    func noteWindowsGone(_ ids: Set<CGWindowID>) {
        guard let target = targetWindowID, ids.contains(target) else { return }
        hyprLog(.notice, .floating, "window rules overlay closed: \(target) went away")
        close(restoringFocus: false)
    }

    /// Show the overlay for `info`, centered over `frame` (CG coordinates)
    /// when there is one, else on the main screen.
    func show(_ info: FocusedWindowRuleInfo, ownerPID: pid_t? = nil, over frame: CGRect?, icon: NSImage?) {
        mainThreadOnly()
        close(restoringFocus: false)
        let model = WindowRulesOverlayModel(target: info)
        self.model = model
        targetPID = ownerPID
        let hosting = NSHostingView(rootView: WindowRulesOverlayView(model: model, icon: icon) { [weak self] row in
            self?.run(row)
        })
        let size = hosting.fittingSize
        let panelFrame = Self.placement(size: size, over: frame)
        let p = WindowRulesPanel(contentRect: panelFrame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isFloatingPanel = true
        p.level = Constants.interfaceWindowLevel
        p.hidesOnDeactivate = false
        hosting.frame = NSRect(origin: .zero, size: panelFrame.size)
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting
        p.makeKeyAndOrderFront(nil)
        panel = p
        OwnPanelTracker.shared.track(p)
        installMonitor()
        // the title editor opens under a title row: grow or shrink, top fixed
        selectionWatch = model.$selection.dropFirst().removeDuplicates().sink { [weak self, weak hosting] _ in
            DispatchQueue.main.async {
                guard let self, let hosting, let panel = self.panel else { return }
                let size = hosting.fittingSize
                var frame = panel.frame
                frame.origin.y += frame.height - size.height
                frame.size = size
                panel.setFrame(frame, display: true)
            }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.noteClickElsewhere()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.noteAppActivated(pid: app.processIdentifier)
        }
        hyprLog(.notice, .floating, "window rules overlay: \(info.windowID) \(info.bundleID)"
                + " rule=\(info.currentRule ?? "none")")
    }

    /// Close it. Unless a row's action takes over, focus goes back to the
    /// window it was opened on.
    func close(restoringFocus: Bool = true) {
        mainThreadOnly()
        for monitor in [keyMonitor, clickMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = nil
        clickMonitor = nil
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activationObserver = nil
        }
        targetPID = nil
        selectionWatch = nil
        let target = model?.target.windowID
        panel?.close()
        panel = nil
        model = nil
        if restoringFocus, let target { restoreFocus(target) }
    }

    private func run(_ row: WindowRulesOverlayModel.Row) {
        guard let model, model.isEnabled(row) else { return }
        let match = model.titleMatch
        let id = model.target.windowID
        // focus back first, so the action runs on the window in front
        close()
        perform(row, match, id)
    }

    private func installMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model else { return event }
            switch event.keyCode {
            case 53: self.close(); return nil                // escape
            case 125: model.move(1); return nil              // down
            case 126: model.move(-1); return nil             // up
            case 36, 76: self.run(model.selection); return nil // return, enter
            case 48 where model.isTitleRow(model.selection):  // tab: is / contains
                model.contains.toggle(); return nil
            default: return event                            // typing goes to the title field
            }
        }
    }

    /// Centered over the window, kept inside the screen it is on.
    static func placement(size: CGSize, over frame: CGRect?) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        guard let frame else {
            let visible = NSScreen.main?.visibleFrame ?? .zero
            return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
        // CG (top-left origin) to AppKit (bottom-left origin)
        let ns = NSRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        let center = NSPoint(x: ns.midX, y: ns.midY)
        let visible = NSScreen.screens.first { $0.frame.contains(center) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? ns
        var rect = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                          width: size.width, height: size.height)
        rect.origin.x = min(max(rect.minX, visible.minX), visible.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, visible.minY), visible.maxY - rect.height)
        return rect
    }
}

private final class WindowRulesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
