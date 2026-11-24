// Lesson 2: move around. On the practice windows, the user moves focus to
// another window and back, then swaps two. A task counts when its action
// ran and the practice windows show it: focus landed elsewhere, or their
// order changed. Without the helper, the action alone counts.

import Combine
import SwiftUI

// MARK: - model

final class MoveAroundLessonModel: ObservableObject {
    @Published var focusedAway = false
    @Published var focusedBack = false
    @Published var swapped = false

    let practice: PracticeSession
    /// how long after a key a practice change still counts as its result
    private let window: TimeInterval
    private let now: () -> Date
    private var lastFocusKey: Date?
    private var lastSwapKey: Date?
    private var origin: Int?
    private var lastFocused: Int?
    private var lastOrder: [Int] = []
    private var cancellables: Set<AnyCancellable> = []
    private var observer: NSObjectProtocol?

    init(practice: PracticeSession, window: TimeInterval = 2.5, now: @escaping () -> Date = Date.init) {
        self.practice = practice
        self.window = window
        self.now = now
    }

    var tasksDone: Int { [focusedAway, focusedBack, swapped].filter { $0 }.count }
    var taskCount: Int { 3 }
    var isDone: Bool { tasksDone == taskCount }

    func start() {
        stop()
        lastFocused = practice.focused
        lastOrder = practice.order
        observer = NotificationCenter.default.addObserver(
            forName: .hyprMacActionDispatched, object: nil, queue: .main
        ) { [weak self] note in
            switch note.userInfo?["action"] as? String {
            case "focusDirection": self?.noteFocusKey()
            case "swapDirection": self?.noteSwapKey()
            default: break
            }
        }
        practice.$focused.dropFirst().sink { [weak self] in self?.noteFocused($0) }.store(in: &cancellables)
        practice.$order.dropFirst().sink { [weak self] in self?.noteOrder($0) }.store(in: &cancellables)
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        cancellables = []
    }

    func noteFocusKey() {
        lastFocusKey = now()
        // no helper: the key alone counts
        guard !practice.isRunning else { return }
        if !focusedAway { mark(\.focusedAway) } else if !focusedBack { mark(\.focusedBack) }
    }

    func noteSwapKey() {
        lastSwapKey = now()
        if !practice.isRunning, !swapped { mark(\.swapped) }
    }

    func noteFocused(_ focused: Int?) {
        defer { lastFocused = focused ?? lastFocused }
        guard let focused, let previous = lastFocused, focused != previous, recent(lastFocusKey) else { return }
        if !focusedAway {
            origin = previous
            mark(\.focusedAway)
        } else if !focusedBack, focused == origin {
            mark(\.focusedBack)
        }
    }

    func noteOrder(_ order: [Int]) {
        defer { lastOrder = order }
        guard !swapped, !lastOrder.isEmpty, order != lastOrder,
              Set(order) == Set(lastOrder), recent(lastSwapKey) else { return }
        mark(\.swapped)
    }

    private func recent(_ date: Date?) -> Bool {
        guard let date else { return false }
        return now().timeIntervalSince(date) <= window
    }

    private func mark(_ key: ReferenceWritableKeyPath<MoveAroundLessonModel, Bool>) {
        withAnimation(HyprMotion.snap) { self[keyPath: key] = true }
    }
}

// MARK: - lesson card

/// One task on a lesson card: what to do, the user's chord for it, done,
/// and one short line on why, shown while it's the step to do.
struct BarTask {
    let title: String
    let bind: Keybind?
    let done: Bool
    /// a button beside the task, e.g. Resume Tiling while paused
    var button: (title: String, action: () -> Void)? = nil
    var why: String? = nil
}

/// The lesson as a small glass card at the bottom center, about 380 pt
/// wide and under 100 tall. Row 1: the lesson, progress dots, Skip and
/// Next. Row 2: only the step to do now, with its keys. Row 3: one short
/// line on why. Done and later steps fold into the dots. The practice
/// workspace keeps room under its tiles for it, so it covers no window.
struct LessonBar: View {
    let lesson: TutorialLesson
    /// the line when no step has its own: a blocked lesson, all done
    var why: String = ""
    let tasks: [BarTask]
    let hyprKey: HyprKey
    /// why the lesson can't run; replaces the step, Skip still works
    var blocked: String? = nil
    /// a live state beside the dots, e.g. lesson 1's Capitals chip
    var accessory: AnyView? = nil
    /// Return presses Next: only where the card's window takes keys (lesson 1)
    var nextIsDefault = false
    let onExit: () -> Void
    let onNext: () -> Void

    /// at least this wide; wider, up to `maxWidth`, when row 1 needs it
    static let width: CGFloat = 380
    static let maxWidth: CGFloat = 460
    static let cornerRadius: CGFloat = 14
    @Environment(\.lessonCardActions) private var actions

    private var done: Int { tasks.filter(\.done).count }
    private var allDone: Bool { !tasks.isEmpty && done == tasks.count }
    private var current: BarTask? { tasks.first { !$0.done } }

    /// the line under the step: its own, else the lesson's
    var whyLine: String? {
        let line = blocked == nil ? (current?.why ?? why) : why
        return line.isEmpty ? nil : line
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let blocked {
                Text(blocked)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TutorialStageColor.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let current {
                step(current)
            } else if allDone {
                allDoneRow
            }
            if whyLine != nil || actions.startOver != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let whyLine {
                        Text(whyLine)
                            .font(.system(size: 11))
                            .foregroundStyle(TutorialStageColor.quiet)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    // after a resume: back to lesson 1
                    if let startOver = actions.startOver {
                        Button("Start over", action: startOver)
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TutorialStageColor.cyan)
                            .fixedSize()
                    }
                }
                // the line wraps in the card's width; it never widens it
                .frame(idealWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minWidth: Self.width, maxWidth: Self.maxWidth, alignment: .leading)
        .background(Self.glass)
        .environment(\.colorScheme, .dark)
    }

    // the lesson · dots · Skip Tutorial · Skip Lesson · Next. Past the
    // widest card, Skip Tutorial goes into a ⋯ menu so the row still fits
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(menu: false)
            headerRow(menu: true)
        }
    }

    /// Row 1 fits inside the widest card: as it is, or with Skip Tutorial
    /// in the ⋯ menu. Tests check it for every lesson.
    static func rowOneFits(lesson: TutorialLesson, taskCount: Int) -> Bool {
        let bar = LessonBar(lesson: lesson,
                            tasks: Array(repeating: BarTask(title: "", bind: nil, done: false), count: taskCount),
                            hyprKey: .capsLock, onExit: {}, onNext: {})
        let room = maxWidth - 28
        func width(_ menu: Bool) -> CGFloat {
            NSHostingView(rootView: bar.headerRow(menu: menu).fixedSize()).fittingSize.width
        }
        return width(false) <= room || width(true) <= room
    }

    func headerRow(menu: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text("\(lesson.rawValue + 1) · \(lesson.railLabel)")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(TutorialStageColor.text)
                .fixedSize()
            if blocked == nil, !tasks.isEmpty { dots }
            if let accessory { accessory }
            Spacer(minLength: 4)
            if menu {
                Menu {
                    Button("Skip Tutorial", action: onExit)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TutorialStageColor.quiet)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More: Skip Tutorial")
                .accessibilityLabel("More")
            } else {
                Button("Skip Tutorial", action: onExit)
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(TutorialStageColor.faint)
                    .fixedSize()
            }
            if blocked != nil || !allDone {
                StageQuietButton("Skip Lesson", action: onNext)
            }
            if blocked == nil {
                Self.nextButton(lesson.next == .finish ? "Finish" : "Next", enabled: allDone,
                                isDefault: nextIsDefault, action: onNext)
            }
        }
    }

    // done: cyan; to do now: the brand gradient ring; later: faint
    private var dots: some View {
        HStack(spacing: 4) {
            ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
                let isCurrent = index == tasks.firstIndex { !$0.done }
                Circle()
                    .fill(task.done ? TutorialStageColor.cyan
                          : isCurrent ? Color.clear : TutorialStageColor.faint.opacity(0.6))
                    .overlay { if isCurrent { Circle().strokeBorder(Self.accent, lineWidth: 1.5) } }
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(done) of \(tasks.count) done")
    }

    // the step to do now: an inset accent bar, heavier text, its keys
    private func step(_ task: BarTask) -> some View {
        HStack(alignment: .center, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Self.accent)
                .frame(width: 3, height: 16)
            Text(task.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(TutorialStageColor.text)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if let bind = task.bind {
                StageChord(bind: bind, hyprKey: hyprKey)
            }
            // outside the label, so VoiceOver and AX can press it
            if let button = task.button {
                StageSecondaryButton(button.title, action: button.action)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(task.title), to do next")
    }

    private var allDoneRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TutorialStageColor.cyan)
            Text("All done")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(TutorialStageColor.text)
        }
    }

    // a small Next: filled cyan once the steps are done, an outline before
    private static func nextButton(_ title: String, enabled: Bool, isDefault: Bool,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(enabled ? TutorialStageColor.navyTop : TutorialStageColor.faint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                .fill(enabled ? TutorialStageColor.cyan : .clear))
            .overlay(RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                .strokeBorder(enabled ? .clear : TutorialStageColor.faint, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(isDefault ? .defaultAction : nil)
        .fixedSize()
    }

    // see-through navy glass: the desktop blurred behind it, a light navy
    // tint, a hairline edge and a pink-to-blue line along the top
    static var glass: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
        return BehindWindowBlur(cornerRadius: cornerRadius)
            .overlay(shape.fill(LinearGradient(colors: [TutorialStageColor.glassTop.opacity(0.55),
                                                        TutorialStageColor.glassBottom.opacity(0.48)],
                                               startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.07)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .overlay(alignment: .top) {
                accent.frame(height: 1.5).padding(.horizontal, 16).opacity(0.85)
            }
            .background(OuterShadow(shape: shape, color: .black.opacity(0.35)))
    }

    static let accent = LinearGradient(colors: [TutorialStageColor.magenta, TutorialStageColor.cyan],
                                       startPoint: .leading, endPoint: .trailing)
}

struct MoveAroundLessonBar: View {
    @ObservedObject var model: MoveAroundLessonModel
    @ObservedObject var config: UserConfig = .shared
    let onExit: () -> Void
    let onNext: () -> Void

    var body: some View {
        LessonBar(
            lesson: .moveAround,
            tasks: [
                BarTask(title: "Focus the next window", bind: bind { $0 == .focusDirection(.right) },
                        done: model.focusedAway,
                        why: "The focused window is the one your keys go to."),
                BarTask(title: "Focus back", bind: bind { $0 == .focusDirection(.left) },
                        done: model.focusedBack,
                        why: "Your hands stay on the keyboard, no trip to the mouse."),
                // from window 1 on the left, the swap goes right
                BarTask(title: "Swap two windows", bind: bind { $0 == .swapDirection(.right) },
                        done: model.swapped,
                        why: "Swap moves the window itself, not just the focus."),
            ],
            hyprKey: config.hyprKey,
            onExit: onExit,
            onNext: onNext)
    }

    private func bind(_ match: (Action) -> Bool) -> Keybind? {
        config.keybinds.first { match($0.action) }
    }
}
