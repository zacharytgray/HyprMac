// Full-screen tutorial shell: a navy stage with the step rail on top and
// exit / next at the bottom. One step at a time sits in the middle, with
// its tasks on a navy glass card.

import SwiftUI

// MARK: - steps

/// A step on a stage rail. Onboarding and the tutorial each have their own.
protocol StageStep: Hashable, CaseIterable where AllCases == [Self] {
    var railLabel: String { get }
}

/// Onboarding: required, runs once, no skip.
enum OnboardingStep: Int, StageStep {
    case access, hyprKey, makeItYours

    var railLabel: String {
        switch self {
        case .access: return "Access"
        case .hyprKey: return "Hypr key"
        case .makeItYours: return "Make it yours"
        }
    }

    var counterLabel: String { "Setup · \(rawValue + 1) of \(Self.allCases.count)" }
}

/// The tutorial: optional, replayable, done on real keys.
enum TutorialLesson: Int, StageStep {
    case hyprKey, moveAround, workspaces, floating, fixWindow, menuBarAndKeys, pause, finish

    var railLabel: String {
        switch self {
        case .hyprKey: return "Hypr key"
        case .moveAround: return "Move around"
        case .workspaces: return "Workspaces"
        case .floating: return "Floating"
        case .fixWindow: return "Fix a window"
        case .menuBarAndKeys: return "Menu bar & keys"
        case .pause: return "Pause"
        case .finish: return "Finish"
        }
    }

    var next: TutorialLesson? { TutorialLesson(rawValue: rawValue + 1) }

    var counterLabel: String {
        self == .finish ? "Tutorial" : "Lesson \(rawValue + 1) of \(TutorialLesson.finish.rawValue)"
    }

    var nextTitle: String { next.map { "Next: \($0.railLabel)" } ?? "Finish Tutorial" }
}

/// A labeled bottom-bar action.
struct StageAction {
    let title: String
    var shortcut: KeyboardShortcut? = nil
    let action: () -> Void
}

// MARK: - stage colors

/// The stage is navy in both appearances, like the showreel's desktop.
/// Everything on it, cards included, uses the dark-mode brand values.
enum TutorialStageColor {
    static let navyTop = Color(red: 0x0A/255, green: 0x10/255, blue: 0x24/255)
    static let navyBottom = Color(red: 0x13/255, green: 0x1B/255, blue: 0x3A/255)
    static let glassTop = Color(red: 0x1D/255, green: 0x28/255, blue: 0x55/255)
    static let glassBottom = Color(red: 0x16/255, green: 0x1F/255, blue: 0x45/255)
    static let cyan = Color(red: 0x56/255, green: 0xD8/255, blue: 0xF0/255)
    static let magenta = Color(red: 0xE8/255, green: 0x4B/255, blue: 0xCB/255)
    static let text = Color.white
    static let quiet = Color.white.opacity(0.62)
    static let faint = Color.white.opacity(0.38)
    static let line = Color.white.opacity(0.10)
    static let surface = Color.white.opacity(0.06)
}

// MARK: - backdrop

/// Navy with a faint cyan and magenta glow in opposite corners. Alone, it is
/// the desktop behind the practice windows.
struct StageBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [TutorialStageColor.navyTop, TutorialStageColor.navyBottom],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [TutorialStageColor.cyan.opacity(0.16), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 700)
            RadialGradient(colors: [TutorialStageColor.magenta.opacity(0.14), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 760)
        }
        .ignoresSafeArea()
    }
}

// MARK: - shell

struct TutorialStage<Step: StageStep, Content: View>: View {
    let step: Step
    let completed: Set<Step>
    /// top right, e.g. "Lesson 2 of 7"
    let counter: String
    /// e.g. "1 of 3 done", in mono beside the buttons
    var progress: String? = nil
    /// a quiet sentence beside the buttons
    var note: String? = nil
    let canContinue: Bool
    /// bottom left: Quit, Back or Skip Tutorial
    var exit: StageAction? = nil
    /// shown while the step isn't done
    var skip: StageAction? = nil
    /// a quiet button before the primary one
    var secondary: StageAction? = nil
    let next: StageAction
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottomBar
        }
        .background(StageBackdrop())
        // one look in light and dark: system controls on the stage draw dark
        .environment(\.colorScheme, .dark)
    }

    // MARK: top: lockup · step rail · counter

    private var topBar: some View {
        HStack(spacing: 24) {
            HyprLockup(markSize: 20)
            Spacer(minLength: 0)
            rail
            Spacer(minLength: 0)
            Text(counter)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(TutorialStageColor.faint)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(TutorialStageColor.line).frame(height: 1)
        }
    }

    // the current step gets an inset accent bar, a colored icon and
    // heavier text, never a filled chip
    private var rail: some View {
        HStack(spacing: 18) {
            ForEach(Step.allCases, id: \.self) { item in
                let current = item == step
                let done = completed.contains(item)
                VStack(spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: done ? "checkmark.circle.fill"
                              : current ? "circle.inset.filled" : "circle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(done || current ? TutorialStageColor.cyan : TutorialStageColor.faint)
                        Text(item.railLabel)
                            .font(.system(size: 11.5, weight: current ? .semibold : .regular))
                            .foregroundStyle(current ? TutorialStageColor.text
                                             : done ? TutorialStageColor.quiet : TutorialStageColor.faint)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(current ? TutorialStageColor.cyan : .clear)
                        .frame(height: 3)
                }
                // the bar matches the label; without this each step stretches
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.railLabel), \(done ? "done" : current ? "current step" : "not started")")
            }
        }
    }

    // MARK: bottom: exit · note · progress · skip · secondary · next

    private var bottomBar: some View {
        HStack(spacing: 16) {
            if let exit {
                Button(action: exit.action) {
                    HStack(spacing: 6) {
                        Text(exit.title)
                        if exit.shortcut == .cancelAction { StageKeyHint("esc") }
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(TutorialStageColor.quiet)
                .keyboardShortcut(exit.shortcut)
            }

            Spacer()

            if let note {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(TutorialStageColor.faint)
            }
            if let progress {
                Text(progress)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(canContinue ? TutorialStageColor.cyan : TutorialStageColor.faint)
            }
            if !canContinue, let skip {
                Button(skip.title, action: skip.action)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(TutorialStageColor.quiet)
            }
            if let secondary {
                Button(secondary.title, action: secondary.action)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(TutorialStageColor.quiet)
                    .padding(.horizontal, 6)
            }
            StagePrimaryButton(next.title, enabled: canContinue, action: next.action)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .overlay(alignment: .top) {
            Rectangle().fill(TutorialStageColor.line).frame(height: 1)
        }
    }
}

// MARK: - task card

/// One thing to do in a step. It ticks itself off from what HyprMac sees.
struct TutorialTask {
    let title: String
    let detail: String
    let done: Bool
    var trailing: AnyView? = nil
}

/// The step's to-do list on navy glass, the Hypr+I look on the stage. The
/// next task gets the inset accent bar and heavier text; done tasks a check.
struct TutorialTaskCard<Accessory: View>: View {
    var heading = "Do these to continue"
    let tasks: [TutorialTask]
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tasks.allSatisfy(\.done) ? "All done" : heading)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TutorialStageColor.text)
                Spacer()
                accessory
            }
            .padding(.horizontal, 4)

            VStack(spacing: 2) {
                ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
                    row(task, current: index == currentIndex)
                }
            }
        }
        .padding(EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .tutorialGlass(cornerRadius: 14)
    }

    private var currentIndex: Int? { tasks.firstIndex { !$0.done } }

    private func row(_ task: TutorialTask, current: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(current ? TutorialStageColor.cyan : Color.clear)
                .frame(width: 3, height: 16)
                .padding(.top, 2)
            Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(task.done || current ? TutorialStageColor.cyan : TutorialStageColor.faint)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 13, weight: current ? .semibold : .regular))
                    .foregroundStyle(task.done ? TutorialStageColor.quiet : TutorialStageColor.text)
                Text(task.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(TutorialStageColor.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let trailing = task.trailing {
                trailing
            } else if task.done {
                Text("Done")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TutorialStageColor.cyan)
                    .padding(.top, 1)
            }
        }
        .padding(.vertical, 6)
        .padding(.trailing, 4)
        .accessibilityElement(children: .combine)
        .accessibilityValue(task.done ? "done" : current ? "to do next" : "to do")
    }
}

extension TutorialTaskCard where Accessory == EmptyView {
    init(heading: String = "Do these to continue", tasks: [TutorialTask]) {
        self.init(heading: heading, tasks: tasks) { EmptyView() }
    }
}

// MARK: - navy glass

extension View {
    /// Translucent navy with a light top edge: the overlay glass, tinted to
    /// the stage. Drawn, not blurred, so it looks the same in a snapshot.
    /// `opaque` for the lesson bar, which sits over windows: nothing behind
    /// it, like a tile's focus marks, may show through.
    func tutorialGlass(cornerRadius: CGFloat, opaque: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let alpha = opaque ? 1 : 0.86
        return self
            .background(
                shape.fill(LinearGradient(colors: [TutorialStageColor.glassTop.opacity(alpha),
                                                   TutorialStageColor.glassBottom.opacity(alpha)],
                                          startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.18), Color.white.opacity(0.06)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
    }
}

// MARK: - stage controls

/// Cyan filled button with dark text. Not yet allowed, it is an outline
/// with quiet text, so it can't read as pressable.
struct StagePrimaryButton: View {
    let title: String
    let enabled: Bool
    var showsArrow = true
    /// Return presses it; only the bottom bar's Next should claim that
    var isDefault = true
    let action: () -> Void

    init(_ title: String, enabled: Bool = true, showsArrow: Bool = true, isDefault: Bool = true,
         action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.showsArrow = showsArrow
        self.isDefault = isDefault
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if showsArrow {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(enabled ? TutorialStageColor.navyTop : TutorialStageColor.faint)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.md + 1, style: .continuous)
                    .fill(enabled ? TutorialStageColor.cyan : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HyprRadius.md + 1, style: .continuous)
                    .strokeBorder(enabled ? .clear : TutorialStageColor.faint, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(isDefault ? .defaultAction : nil)
    }
}

/// Outlined cyan button for actions inside a card.
struct StageSecondaryButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(TutorialStageColor.cyan)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .overlay(
                    RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                        .strokeBorder(TutorialStageColor.cyan.opacity(0.6), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// A plain quiet text button, for "Not Now" and the like.
struct StageQuietButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(TutorialStageColor.quiet)
            .fixedSize()
    }
}

/// A small key label on the stage, like the overlay footers' hints.
struct StageKeyHint: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(TutorialStageColor.quiet)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                    .strokeBorder(TutorialStageColor.faint, lineWidth: 1)
            )
    }
}

/// A chord as key chips, with the user's own Hypr key in the cyan chip
/// (e.g. "Right Option" "T"), so every lesson shows the key they picked.
struct StageChord: View {
    let bind: Keybind
    let hyprKey: HyprKey

    private var otherLabels: [String] {
        let labels = bind.badgeLabels()
        return bind.modifiers.contains(.hypr) ? Array(labels.dropFirst()) : labels
    }

    var body: some View {
        HStack(spacing: 3) {
            if bind.modifiers.contains(.hypr) {
                Text(hyprKey.displayName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(TutorialStageColor.cyan)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(TutorialStageColor.cyan.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                        .strokeBorder(TutorialStageColor.cyan.opacity(0.5), lineWidth: 1))
            }
            ForEach(Array(otherLabels.enumerated()), id: \.offset) { _, label in
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(TutorialStageColor.text)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .frame(minWidth: 24)
                    .background(TutorialStageColor.surface,
                                in: RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([bind.modifiers.contains(.hypr) ? hyprKey.displayName : nil].compactMap { $0 }
                             + otherLabels).joined(separator: " "))
    }
}

/// A rounded chip with a live state, e.g. "Capitals on".
struct StageStatusChip: View {
    let icon: String
    let label: String
    let lit: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(lit ? TutorialStageColor.cyan : TutorialStageColor.quiet)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(TutorialStageColor.surface, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - window

/// One borderless window over the whole screen under the pointer.
/// HyprMac never tiles its own windows.
final class TutorialWindowController {
    private(set) var window: NSWindow?

    private final class StageWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    /// Access sits at the normal level, so System Settings can come in
    /// front of it. Everything else sits above passive chrome, like the old tour.
    static func level(forAccess access: Bool) -> NSWindow.Level {
        access ? .normal : Constants.interfaceWindowLevel
    }

    func show<V: View>(_ view: V, level: NSWindow.Level) {
        dismiss()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        let win = StageWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentViewController = NSHostingController(rootView: view)
        win.setFrame(frame, display: true)
        win.level = level
        win.appearance = NSAppearance(named: .darkAqua)
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.fullScreenAuxiliary]
        win.title = "HyprMac Tutorial"
        window = win
        bringToFront()
        // hover focus must not reach through the stage
        OwnPanelTracker.shared.track(win)
    }

    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        hideBar()
        window?.close()
        window = nil
    }

    // MARK: practice lessons

    private var bar: NSPanel?

    /// just above the desktop icons: behind every app window
    static let backdropLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    /// The stage drops behind the practice windows and lets the mouse
    /// through, so they can be focused, hovered and dragged. It stops
    /// counting as an open HyprMac panel, which would turn hover focus off.
    func setPracticeMode(_ on: Bool, level: NSWindow.Level) {
        guard let window else { return }
        window.level = on ? Self.backdropLevel : level
        window.ignoresMouseEvents = on
        if on {
            OwnPanelTracker.shared.untrack(window)
            window.orderBack(nil)
        } else {
            OwnPanelTracker.shared.track(window)
            bringToFront()
        }
    }

    /// The lesson bar along the bottom edge, above the practice windows. A
    /// non-activating panel, so keys keep going to the focused window.
    func showBar<V: View>(_ view: V) {
        hideBar()
        guard let screen = window?.screen ?? NSScreen.main else { return }
        let hosting = NSHostingView(rootView: view)
        let width = screen.visibleFrame.width - 32
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        let height = hosting.fittingSize.height
        let panel = NSPanel(contentRect: NSRect(x: screen.visibleFrame.minX + 16, y: screen.visibleFrame.minY + 16,
                                                width: width, height: height),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = Constants.interfaceWindowLevel
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.orderFrontRegardless()
        bar = panel
    }

    func hideBar() {
        bar?.close()
        bar = nil
    }
}
