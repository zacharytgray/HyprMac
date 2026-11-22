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
    enum Row: Equatable, Hashable {
        /// float or tile it once, as Hypr+T does
        case once
        case floatApp, tileApp
        case floatTitle, tileTitle
        case forget
    }

    let target: FocusedWindowRuleInfo
    @Published var selection: Row
    @Published var contains = false
    @Published var text: String {
        didSet {
            // typing is about the title rule: follow it there
            guard text != oldValue, !isTitleRow(selection) else { return }
            selection = .floatTitle
        }
    }

    init(target: FocusedWindowRuleInfo) {
        self.target = target
        self.text = target.title
        self.selection = .once
    }

    /// The rows in order. The app rule already in effect isn't offered
    /// again, and Forget only shows when a rule covers the window.
    var rows: [Row] {
        var out: [Row] = [.once]
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
            selection = all.first ?? .once
            return
        }
        selection = all[(index + step + all.count) % all.count]
    }

    func label(_ row: Row) -> String {
        switch row {
        case .once: return target.isFloating ? "Tile this window" : "Float this window"
        case .floatApp: return "Always float all \(target.appName) windows"
        case .tileApp: return "Always tile all \(target.appName) windows"
        case .floatTitle: return "Always float windows whose title matches"
        case .tileTitle: return "Always tile windows whose title matches"
        case .forget: return "Forget the rule: \(target.currentRule ?? "")"
        }
    }

    func detail(_ row: Row) -> String? {
        switch row {
        case .once: return "Just this window, until it closes. Same as Hypr+T"
        default: return nil
        }
    }
}

/// The overlay's card.
struct WindowRulesOverlayView: View {
    @ObservedObject var model: WindowRulesOverlayModel
    let icon: NSImage?
    let choose: (WindowRulesOverlayModel.Row) -> Void
    @FocusState private var editingTitle: Bool

    static let width: CGFloat = 440

    var body: some View {
        VStack(alignment: .leading, spacing: HyprSpacing.sm) {
            header
            Rectangle().fill(Color.hyprSeparator).frame(height: 0.5)
            row(.once)
            if model.rows.contains(.floatApp) { row(.floatApp) }
            if model.rows.contains(.tileApp) { row(.tileApp) }
            titleEditor
            row(.floatTitle)
            row(.tileTitle)
            if model.rows.contains(.forget) { row(.forget) }
            Text("↑↓ choose · Return apply · Esc close")
                .font(.hyprMonoXs)
                .foregroundStyle(Color.hyprTextTertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(HyprSpacing.md)
        .frame(width: Self.width)
        .background(
            RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                .fill(Color.hyprBackground)
                .overlay(RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                    .stroke(Color.hyprSeparator, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        )
    }

    private var header: some View {
        HStack(spacing: HyprSpacing.sm) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.target.appName).font(.hyprBody.weight(.semibold))
                Text(model.target.title.isEmpty ? "No title" : model.target.title)
                    .font(.hyprMonoXs)
                    .foregroundStyle(Color.hyprTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.target.currentRule ?? "No rule: HyprMac decides")
                    .font(.hyprMonoXs)
                    .foregroundStyle(Color.hyprTextTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }

    private var titleEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: $model.contains) {
                Text("Title is exactly").tag(false)
                Text("Title contains").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Title text", text: $model.text)
                .textFieldStyle(.roundedBorder)
                .focused($editingTitle)
                // typing edits the title at once; the arrows, Return and Esc
                // still go to the rows through the key monitor
                .onAppear { DispatchQueue.main.async { editingTitle = true } }
            Text("Trim it to the part every such window shares, like “Meeting”.")
                .font(.hyprMonoXs)
                .foregroundStyle(Color.hyprTextTertiary)
        }
        .padding(.horizontal, HyprSpacing.sm)
        .padding(.top, HyprSpacing.xs)
    }

    private func row(_ row: WindowRulesOverlayModel.Row) -> some View {
        let selected = model.selection == row
        let enabled = model.isEnabled(row)
        return Button {
            guard enabled else { return }
            model.selection = row
            choose(row)
        } label: {
            HStack(spacing: HyprSpacing.sm) {
                // an inset accent bar marks the pick, not a full-row fill
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(selected ? Color.hyprCyan : Color.clear)
                    .frame(width: 3, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.label(row))
                        .font(selected ? .hyprBody.weight(.semibold) : .hyprBody)
                        .foregroundStyle(enabled ? Color.hyprTextPrimary : Color.hyprTextTertiary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    if let detail = model.detail(row) {
                        Text(detail).font(.hyprMonoXs).foregroundStyle(Color.hyprTextTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
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
