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

// MARK: - bar

/// One task on a lesson bar: what to do, the user's chord for it, done.
struct BarTask {
    let title: String
    let bind: Keybind?
    let done: Bool
    /// a button beside the task, e.g. Resume Tiling while paused
    var button: (title: String, action: () -> Void)? = nil
}

/// The lesson as a slim bar along the bottom edge, above the practice
/// windows, so the windows themselves get the screen.
struct LessonBar: View {
    let lesson: TutorialLesson
    let why: String
    let tasks: [BarTask]
    let hyprKey: HyprKey
    /// a quiet line under the tasks, e.g. the two-display key
    var note: String? = nil
    let onExit: () -> Void
    let onNext: () -> Void

    private var done: Int { tasks.filter(\.done).count }
    private var currentIndex: Int? { tasks.firstIndex { !$0.done } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(lesson.counterLabel)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(TutorialStageColor.faint)
                Text(lesson.railLabel)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TutorialStageColor.text)
                Text(why)
                    .font(.system(size: 12.5))
                    .foregroundStyle(TutorialStageColor.quiet)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Text("\(done) of \(tasks.count) done")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(done == tasks.count ? TutorialStageColor.cyan : TutorialStageColor.faint)
                if done < tasks.count {
                    StageQuietButton("Skip Lesson", action: onNext)
                }
                StagePrimaryButton(lesson.nextTitle, enabled: done == tasks.count, isDefault: false, action: onNext)
            }

            HStack(spacing: 10) {
                ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
                    taskView(task, current: index == currentIndex)
                }
                Spacer(minLength: 12)
                StageQuietButton("Skip Tutorial", action: onExit)
            }

            if let note {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(TutorialStageColor.quiet)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .tutorialGlass(cornerRadius: 16, opaque: true)
        .environment(\.colorScheme, .dark)
    }

    // the next task: an inset accent bar, a colored icon and heavier text
    private func taskView(_ task: BarTask, current: Bool) -> some View {
        HStack(spacing: 8) {
            taskLabel(task, current: current)
            // outside the combined label, so VoiceOver and AX can press it
            if let button = task.button {
                StageSecondaryButton(button.title, action: button.action)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
        .background(TutorialStageColor.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func taskLabel(_ task: BarTask, current: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(current ? TutorialStageColor.cyan : .clear)
                .frame(width: 3, height: 16)
            Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(task.done || current ? TutorialStageColor.cyan : TutorialStageColor.faint)
            Text(task.title)
                .font(.system(size: 12.5, weight: current ? .semibold : .regular))
                .foregroundStyle(task.done ? TutorialStageColor.quiet : TutorialStageColor.text)
                .fixedSize()
            if let bind = task.bind {
                StageChord(bind: bind, hyprKey: hyprKey)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(task.done ? "done" : current ? "to do next" : "to do")
    }
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
