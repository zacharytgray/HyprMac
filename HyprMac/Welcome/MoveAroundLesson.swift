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

/// One task on a lesson card: what to do, the user's chord for it, done.
struct BarTask {
    let title: String
    let bind: Keybind?
    let done: Bool
    /// a button beside the task, e.g. Resume Tiling while paused
    var button: (title: String, action: () -> Void)? = nil
    /// a short line under the task, e.g. lesson 1's "Press it and keep it down"
    var detail: String? = nil
}

/// The lesson as a small glass card at the bottom center, about 380 pt
/// wide: the lesson, only the step to do now with its keys, the reason in
/// a line or two, progress dots, and Skip / Next. Done and later steps fold
/// into the dots. The practice workspace keeps room under its tiles for it,
/// so it covers no window; it grows a little rather than cut the reason off.
struct LessonBar: View {
    let lesson: TutorialLesson
    let why: String
    let tasks: [BarTask]
    let hyprKey: HyprKey
    /// a quieter line under the reason, e.g. the two-display key
    var note: String? = nil
    /// why the lesson can't run; replaces the step, Skip still works
    var blocked: String? = nil
    /// a live state beside the lesson name, e.g. lesson 1's Capitals chip
    var accessory: AnyView? = nil
    /// Return presses Next: only where the card's window takes keys (lesson 1)
    var nextIsDefault = false
    let onExit: () -> Void
    let onNext: () -> Void

    static let width: CGFloat = 380

    private var done: Int { tasks.filter(\.done).count }
    private var allDone: Bool { !tasks.isEmpty && done == tasks.count }
    private var current: BarTask? { tasks.first { !$0.done } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let blocked {
                Text(blocked)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(TutorialStageColor.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let current {
                step(current)
            } else if allDone {
                allDoneRow
            }
            if !why.isEmpty {
                Text(why)
                    .font(.system(size: 11.5))
                    .foregroundStyle(TutorialStageColor.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(TutorialStageColor.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: Self.width, alignment: .leading)
        .background(cardBackground)
        .environment(\.colorScheme, .dark)
    }

    // lesson · name · dots
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(lesson.counterLabel)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(TutorialStageColor.faint)
                .fixedSize()
            Text(lesson.railLabel)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TutorialStageColor.text)
                .fixedSize()
            Spacer(minLength: 6)
            if let accessory { accessory }
            if blocked == nil, !tasks.isEmpty { dots }
        }
    }

    // done: cyan; to do now: the brand gradient ring; later: faint
    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
                let isCurrent = index == tasks.firstIndex { !$0.done }
                Circle()
                    .fill(task.done ? TutorialStageColor.cyan
                          : isCurrent ? Color.clear : TutorialStageColor.faint.opacity(0.6))
                    .overlay { if isCurrent { Circle().strokeBorder(Self.accent, lineWidth: 1.5) } }
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(done) of \(tasks.count) done")
    }

    // the step to do now: an inset accent bar, heavier text, its keys
    private func step(_ task: BarTask) -> some View {
        HStack(alignment: .center, spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Self.accent)
                .frame(width: 3)
                .frame(minHeight: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TutorialStageColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = task.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(TutorialStageColor.quiet)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(task.title), to do next")
    }

    private var allDoneRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TutorialStageColor.cyan)
            Text("All done")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TutorialStageColor.text)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            StageQuietButton("Skip Tutorial", action: onExit)
            Spacer(minLength: 8)
            if blocked != nil || !allDone {
                StageQuietButton("Skip Lesson", action: onNext)
            }
            if blocked == nil {
                // the dots say where you are; a short title keeps one line
                StagePrimaryButton(lesson.next == .finish ? "Finish" : "Next", enabled: allDone,
                                   isDefault: nextIsDefault, action: onNext)
                    .fixedSize()
            }
        }
        .padding(.top, 2)
    }

    // translucent navy glass with a pink-to-blue hairline along the top
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return shape
            .fill(LinearGradient(colors: [TutorialStageColor.glassTop.opacity(0.78),
                                          TutorialStageColor.glassBottom.opacity(0.74)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.20), Color.white.opacity(0.06)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .overlay(alignment: .top) {
                Self.accent
                    .frame(height: 1.5)
                    .padding(.horizontal, 18)
                    .opacity(0.8)
            }
            .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
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
            why: "Your hands stay on the keyboard. The focused window is the one your keys go to.",
            tasks: [
                BarTask(title: "Focus the next window", bind: bind { $0 == .focusDirection(.right) },
                        done: model.focusedAway),
                BarTask(title: "Focus back", bind: bind { $0 == .focusDirection(.left) },
                        done: model.focusedBack),
                // from window 1 on the left, the swap goes right
                BarTask(title: "Swap two windows", bind: bind { $0 == .swapDirection(.right) },
                        done: model.swapped),
            ],
            hyprKey: config.hyprKey,
            onExit: onExit,
            onNext: onNext)
    }

    private func bind(_ match: (Action) -> Bool) -> Keybind? {
        config.keybinds.first { match($0.action) }
    }
}
