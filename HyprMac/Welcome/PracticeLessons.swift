// Lessons 3 to 7, on the practice windows. Each task ticks itself off when
// its key ran (hyprMacActionDispatched) and HyprMac's state shows the
// result: the workspace on screen, where a window went, what floats, a rule
// saved, tiling paused. Without the helper, the key alone counts where the
// result can't be seen.

import Combine
import SwiftUI

// MARK: - shared

/// When each action last ran.
final class ActionRecorder {
    private var last: [String: Date] = [:]
    private var observer: NSObjectProtocol?
    private let now: () -> Date
    var onAction: (String) -> Void = { _ in }

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func start() {
        stop()
        observer = NotificationCenter.default.addObserver(
            forName: .hyprMacActionDispatched, object: nil, queue: .main
        ) { [weak self] note in
            if let action = note.userInfo?["action"] as? String { self?.note(action) }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func note(_ action: String) {
        last[action] = now()
        onAction(action)
    }

    /// The action ran in the last 2.5 s: the live check saw results land
    /// about 1 s after the key.
    func recent(_ action: String, within window: TimeInterval = 2.5) -> Bool {
        guard let date = last[action] else { return false }
        return now().timeIntervalSince(date) <= window
    }
}

/// One practice lesson: watches the practice session and the actions, and
/// re-checks its tasks after every change.
class PracticeLessonModel: ObservableObject {
    let practice: PracticeSession
    let config: UserConfig
    let recorder: ActionRecorder
    private var cancellables: Set<AnyCancellable> = []

    init(practice: PracticeSession, config: UserConfig = .shared, now: @escaping () -> Date = Date.init) {
        self.practice = practice
        self.config = config
        recorder = ActionRecorder(now: now)
        recorder.onAction = { [weak self] action in
            self?.noteAction(action)
            self?.evaluate()
        }
    }

    func start() {
        stop()
        recorder.start()
        practice.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.evaluate() } }
            .store(in: &cancellables)
        config.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.evaluate() } }
            .store(in: &cancellables)
        didStart()
    }

    func stop() {
        recorder.stop()
        cancellables = []
    }

    /// hook: the lesson opened
    func didStart() {}
    /// hook: an action ran, before `evaluate`
    func noteAction(_ action: String) {}
    /// hook: re-check the tasks
    func evaluate() {}

    func mark<Model: PracticeLessonModel>(_ model: Model, _ key: ReferenceWritableKeyPath<Model, Bool>) {
        guard !model[keyPath: key] else { return }
        withAnimation(HyprMotion.snap) { model[keyPath: key] = true }
    }

    func bind(_ match: (Action) -> Bool) -> Keybind? {
        config.keybinds.first { match($0.action) }
    }

    /// "Caps Lock+Shift+T", for a quiet line: modifiers as words, since
    /// a lone ⌃ or ⇧ in a sentence reads as punctuation
    func chordText(_ match: (Action) -> Bool) -> String? {
        guard let bind = bind(match) else { return nil }
        let labels = bind.badgeLabels()
        let rest = bind.modifiers.contains(.hypr) ? Array(labels.dropFirst()) : labels
        let words = ["⌃": "Ctrl", "⌥": "Option", "⇧": "Shift", "⌘": "Cmd"]
        return ([bind.modifiers.contains(.hypr) ? config.hyprKey.displayName : nil].compactMap { $0 }
                + rest.map { words[$0] ?? $0 })
            .joined(separator: "+")
    }
}

// MARK: - 3 workspaces

final class WorkspacesLessonModel: PracticeLessonModel {
    @Published var wentAway = false
    @Published var cameBack = false
    @Published var sent = false

    var practiceWorkspace: Int { practice.practiceWorkspace ?? 1 }
    var otherWorkspace: Int { practice.otherWorkspace ?? (practiceWorkspace % 10) + 1 }

    override func noteAction(_ action: String) {
        // no helper: the send can't be seen
        if action == "moveToWorkspace", !practice.isRunning { mark(self, \.sent) }
    }

    override func evaluate() {
        let switched = recorder.recent("switchWorkspace")
        if !wentAway, switched, practice.workspace == otherWorkspace { mark(self, \.wentAway) }
        if wentAway, !cameBack, switched, practice.workspace == practiceWorkspace { mark(self, \.cameBack) }
        if !sent, recorder.recent("moveToWorkspace"),
           practice.windows.values.contains(where: { $0.workspace == otherWorkspace }) { mark(self, \.sent) }
    }
}

struct WorkspacesLessonBar: View {
    @ObservedObject var model: WorkspacesLessonModel
    @ObservedObject var config: UserConfig = .shared
    var displayCount = NSScreen.screens.count
    let onExit: () -> Void
    let onNext: () -> Void

    var body: some View {
        let other = model.otherWorkspace, home = model.practiceWorkspace
        LessonBar(
            lesson: .workspaces,
            why: "Ten workspaces, each its own screen. Windows stay where you leave them.",
            tasks: [
                BarTask(title: "Go to workspace \(other)", bind: model.bind { $0 == .switchWorkspace(other) },
                        done: model.wentAway),
                BarTask(title: "Come back to \(home)", bind: model.bind { $0 == .switchWorkspace(home) },
                        done: model.cameBack),
                BarTask(title: "Send a window to \(other)", bind: model.bind { $0 == .moveToWorkspace(other) },
                        done: model.sent),
            ],
            hyprKey: config.hyprKey,
            note: note,
            onExit: onExit,
            onNext: onNext)
    }

    private var note: String {
        var line = "The menu bar shows each workspace: \(HyprGlyph.workspaceShown) on screen, \(HyprGlyph.workspaceWaiting) windows waiting."
        if displayCount > 1, let chord = model.chordText({ $0 == .moveWindowToMonitor(.right) }) {
            line += " With two displays, \(chord) sends a window to the other one."
        }
        return line
    }
}

// MARK: - 4 floating

final class FloatingLessonModel: PracticeLessonModel {
    @Published var floatedTwo = false
    @Published var cycled = false
    @Published var tiledBack = false

    private var peak = 0
    private var lastFocused: Int?
    // without the helper, the keys count
    private var floatKeys = 0

    private var floating: [Int] {
        practice.windows.values
            .filter { $0.floating && $0.workspace == practice.practiceWorkspace }
            .map(\.number)
    }

    override func noteAction(_ action: String) {
        guard !practice.isRunning else { return }
        switch action {
        case "toggleFloating":
            floatKeys += 1
            if floatKeys >= 2 { mark(self, \.floatedTwo) }
            if floatKeys >= 3 { mark(self, \.tiledBack) }
        case "focusFloating" where floatedTwo:
            mark(self, \.cycled)
        default: break
        }
    }

    override func evaluate() {
        let count = floating.count
        if recorder.recent("toggleFloating") {
            if count >= 2 { mark(self, \.floatedTwo) }
            if floatedTwo, count < peak { mark(self, \.tiledBack) }
        }
        peak = max(peak, count)
        if floatedTwo, !cycled, recorder.recent("focusFloating"),
           let focused = practice.focused, focused != lastFocused, floating.contains(focused) {
            mark(self, \.cycled)
        }
        lastFocused = practice.focused ?? lastFocused
    }
}

struct FloatingLessonBar: View {
    @ObservedObject var model: FloatingLessonModel
    @ObservedObject var config: UserConfig = .shared
    let onExit: () -> Void
    let onNext: () -> Void

    var body: some View {
        LessonBar(
            lesson: .floating,
            why: "Dialogs, Picture in Picture and small tools work better above the tiles, so they float.",
            tasks: [
                BarTask(title: "Float two windows", bind: model.bind { $0 == .toggleFloating }, done: model.floatedTwo),
                BarTask(title: "Bring each one forward", bind: model.bind { $0 == .focusFloating }, done: model.cycled),
                BarTask(title: "Tile one back", bind: model.bind { $0 == .toggleFloating }, done: model.tiledBack),
            ],
            hyprKey: config.hyprKey,
            note: "Floating windows can end up behind the tiles or each other. "
                + "\(model.chordText { $0 == .focusFloating } ?? "Cycle Floating Windows") brings each one forward in turn, so none gets lost.",
            onExit: onExit,
            onNext: onNext)
    }
}

// MARK: - 5 fix a window

final class FixWindowLessonModel: PracticeLessonModel {
    @Published var openedRules = false
    @Published var fixed = false

    static let floatingWindow = 4

    override func didStart() {
        // a window that landed wrong, on purpose
        practice.openWindow(Self.floatingWindow, floating: true)
    }

    override func noteAction(_ action: String) {
        if action == "showWindowRules" { mark(self, \.openedRules) }
    }

    override func evaluate() {
        let ruled = config.floatingRules.contains {
            $0.bundleID == PracticeSession.helperBundleID && $0.match == nil && $0.action == .tile
        }
        let windowFloats = practice.windows[Self.floatingWindow]?.floating ?? false
        if ruled, !windowFloats { mark(self, \.fixed) }
    }
}

struct FixWindowLessonBar: View {
    @ObservedObject var model: FixWindowLessonModel
    @ObservedObject var config: UserConfig = .shared
    let onExit: () -> Void
    let onNext: () -> Void

    var body: some View {
        LessonBar(
            lesson: .fixWindow,
            why: "Window 4 floats when it should tile. When an app does that, "
                + "\(model.chordText { $0 == .showWindowRules } ?? "Show Window Rules") gives it a rule.",
            tasks: [
                BarTask(title: "Focus window 4, open its rules", bind: model.bind { $0 == .showWindowRules },
                        done: model.openedRules),
                BarTask(title: "Pick “Always tile HyprMac Practice”", bind: nil, done: model.fixed),
            ],
            hyprKey: config.hyprKey,
            note: model.chordText { $0 == .retileAll }.map { "If the whole layout looks off, \($0) retiles everything." },
            onExit: onExit,
            onNext: onNext)
    }
}

// MARK: - 6 menu bar and keys

final class MenuBarAndKeysLessonModel: PracticeLessonModel {
    @Published var jumped = false
    @Published var openedKeys = false
    @Published var searched = false

    override func noteAction(_ action: String) {
        if action == "showKeybinds" { mark(self, \.openedKeys) }
        if action == "focusMenuBar", !practice.isRunning { mark(self, \.jumped) }
    }

    override func evaluate() {
        if !jumped, recorder.recent("focusMenuBar"), practice.helperIsFront { mark(self, \.jumped) }
        if openedKeys, practice.keybindSearch.lowercased().contains("float") { mark(self, \.searched) }
    }
}

struct MenuBarAndKeysLessonBar: View {
    @ObservedObject var model: MenuBarAndKeysLessonModel
    @ObservedObject var config: UserConfig = .shared
    let onExit: () -> Void
    let onNext: () -> Void

    var body: some View {
        let jump = model.chordText { $0 == .focusMenuBar } ?? "Focus Menu Bar"
        LessonBar(
            lesson: .menuBarAndKeys,
            why: config.focusFollowsMouse
                ? "With focus following the mouse, the trip up to the menu bar crosses other windows and switches it to their app. \(jump) goes straight there."
                : "\(jump) puts the pointer on the menu bar of the app you're in, with no trip across the screen.",
            tasks: [
                BarTask(title: "Jump to the menu bar", bind: model.bind { $0 == .focusMenuBar }, done: model.jumped),
                BarTask(title: "Open the key list", bind: model.bind { $0 == .showKeybinds }, done: model.openedKeys),
                BarTask(title: "Search it for “float”", bind: nil, done: model.searched),
            ],
            hyprKey: config.hyprKey,
            note: "You don't need to remember every key: the list has them all, and Esc closes it.",
            onExit: onExit,
            onNext: onNext)
    }
}

// MARK: - 7 pause

final class PauseLessonModel: PracticeLessonModel {
    @Published var paused = false
    @Published var resumed = false
    /// the lesson saw tiling go off; the tutorial turns it back on if it ends paused
    private(set) var pausedHere = false

    override func evaluate() {
        if !config.enabled {
            pausedHere = true
            mark(self, \.paused)
        } else if paused {
            mark(self, \.resumed)
        }
    }

    func resume() {
        config.enabled = true
    }
}

struct PauseLessonBar: View {
    @ObservedObject var model: PauseLessonModel
    @ObservedObject var config: UserConfig = .shared
    @AppStorage(UserConfig.menuBarStyleKey) private var menuBarStyle: MenuBarStyle = .full
    let onExit: () -> Void
    let onNext: () -> Void

    var body: some View {
        let keyWorksPaused = config.hyprKey.keepsShortcutsWhilePaused
        LessonBar(
            lesson: .pause,
            why: "For a game, a screen share, or an app that fights tiling: pause, and every window stays put.",
            tasks: [
                BarTask(title: "Pause tiling", bind: model.bind { $0 == .toggleTiling }, done: model.paused),
                BarTask(title: "Resume it", bind: keyWorksPaused ? model.bind { $0 == .toggleTiling } : nil,
                        done: model.resumed,
                        button: !keyWorksPaused && model.paused && !model.resumed
                            ? ("Resume Tiling", { model.resume() }) : nil),
            ],
            hyprKey: config.hyprKey,
            note: keyWorksPaused ? nil : resumeNote,
            onExit: onExit,
            onNext: onNext)
    }

    private var resumeNote: String {
        let place = menuBarStyle == .hidden
            ? "the HyprMac switch in Settings → General"
            : "the Tiling switch in HyprMac's menu bar item"
        return "While paused, \(config.hyprKey.displayName) is a normal key again. Resume here, or later with \(place)."
    }
}

// MARK: - finish

struct FinishView: View {
    @ObservedObject var config: UserConfig = .shared
    var completed: Set<TutorialLesson> = []
    let onDone: () -> Void

    var body: some View {
        TutorialStage(
            step: TutorialLesson.finish,
            completed: completed,
            counter: TutorialLesson.finish.counterLabel,
            note: "The tutorial is in the menu bar, \(config.hyprKey.displayName)+K and Settings → General",
            canContinue: true,
            next: StageAction(title: "Done", action: onDone)
        ) {
            VStack(spacing: 0) {
                Text("You're set")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(TutorialStageColor.text)
                Text("That's the everyday keys. Three more worth trying next:")
                    .font(.system(size: 14))
                    .foregroundStyle(TutorialStageColor.quiet)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(next.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Rectangle().fill(TutorialStageColor.line).frame(height: 1) }
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.icon)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(TutorialStageColor.cyan)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(TutorialStageColor.text)
                                Text(item.detail)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(TutorialStageColor.quiet)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            if let bind = config.keybinds.first(where: { $0.action == item.action }) {
                                StageChord(bind: bind, hyprKey: config.hyprKey)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 16)
                .tutorialGlass(cornerRadius: 14)
                .padding(.top, 34)

                HStack(spacing: 8) {
                    Text("Every other key is in the list:")
                        .font(.system(size: 12.5))
                        .foregroundStyle(TutorialStageColor.quiet)
                    if let bind = config.keybinds.first(where: { $0.action == .showKeybinds }) {
                        StageChord(bind: bind, hyprKey: config.hyprKey)
                    }
                }
                .padding(.top, 18)
            }
            .frame(width: 560)
        }
    }

    private var next: [(icon: String, title: String, detail: String, action: Action)] {
        [
            ("arrow.up.left.and.arrow.down.right", "Maximize a window",
             "Fill the screen with the focused window. Press again to put it back.", .toggleMaximize),
            ("rectangle.grid.3x2", "See every workspace",
             "An overview of all ten. Click one to go there.", .showWorkspaceOverview),
            ("tray", "The scratchpad",
             "A layer of windows you call up over anything, and send away again.", .toggleScratchpad),
        ]
    }
}
