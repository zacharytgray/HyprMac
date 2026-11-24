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

    /// practice windows last seen on the practice workspace. A window parked
    /// on another workspace drops out of what HyprMac reports, so a send
    /// shows as one of these going missing.
    private var lastHome: Set<Int> = []

    var practiceWorkspace: Int { practice.practiceWorkspace ?? 1 }
    /// nil without a second empty workspace; the lesson then says so
    var otherWorkspace: Int? { practice.otherWorkspace }

    override func noteAction(_ action: String) {
        // no helper: the send can't be seen
        if action == "moveToWorkspace", !practice.isRunning { mark(self, \.sent) }
    }

    override func evaluate() {
        guard let otherWorkspace else { return }
        let switched = recorder.recent("switchWorkspace")
        if !wentAway, switched, practice.workspace == otherWorkspace { mark(self, \.wentAway) }
        if wentAway, !cameBack, switched, practice.workspace == practiceWorkspace { mark(self, \.cameBack) }
        let home = Set(practice.windows.values.filter { $0.workspace == practiceWorkspace }.map(\.number))
        if !sent, recorder.recent("moveToWorkspace") {
            let arrived = practice.windows.values.contains { $0.workspace == otherWorkspace }
            let left = practice.workspace == practiceWorkspace && !lastHome.isEmpty && home.count < lastHome.count
            if arrived || left { mark(self, \.sent) }
        }
        // only while on the practice workspace: away, nothing is listed
        if practice.workspace == practiceWorkspace { lastHome = home }
    }
}

struct WorkspacesLessonBar: View {
    @ObservedObject var model: WorkspacesLessonModel
    @ObservedObject var config: UserConfig = .shared
    var displayCount = NSScreen.screens.count
    let onExit: () -> Void
    let onNext: () -> Void

    var body: some View {
        let other = model.otherWorkspace ?? 0, home = model.practiceWorkspace
        LessonBar(
            lesson: .workspaces,
            tasks: [
                BarTask(title: "Go to workspace \(other)", bind: model.bind { $0 == .switchWorkspace(other) },
                        done: model.wentAway,
                        why: "Ten workspaces, each its own screen."),
                BarTask(title: "Come back to \(home)", bind: model.bind { $0 == .switchWorkspace(home) },
                        done: model.cameBack,
                        why: "Windows stay where you leave them."),
                BarTask(title: "Send a window to \(other)", bind: model.bind { $0 == .moveToWorkspace(other) },
                        done: model.sent,
                        why: sendWhy),
            ],
            hyprKey: config.hyprKey,
            onExit: onExit,
            onNext: onNext)
    }

    private var sendWhy: String {
        if displayCount > 1, let chord = model.chordText({ $0 == .moveWindowToMonitor(.right) }) {
            return "\(chord) sends one to your other display."
        }
        return "The menu bar shows each: \(HyprGlyph.workspaceShown) on screen, \(HyprGlyph.workspaceWaiting) windows waiting."
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
            tasks: [
                BarTask(title: "Float two windows", bind: model.bind { $0 == .toggleFloating }, done: model.floatedTwo,
                        why: "Dialogs and small tools work better above the tiles."),
                BarTask(title: "Bring each one forward", bind: model.bind { $0 == .focusFloating }, done: model.cycled,
                        why: "Floaters can hide behind each other. This brings each one up."),
                BarTask(title: "Tile one back", bind: model.bind { $0 == .toggleFloating }, done: model.tiledBack,
                        why: "The same key puts a floating window back in the tiles."),
            ],
            hyprKey: config.hyprKey,
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
            tasks: [
                BarTask(title: "Focus window 4, open its rules", bind: model.bind { $0 == .showWindowRules },
                        done: model.openedRules,
                        why: "Window 4 floats when it should tile. A rule fixes the whole app."),
                BarTask(title: "Pick “Always tile HyprMac Practice”", bind: nil, done: model.fixed,
                        why: "It's already selected in the rules: press ↩."),
            ],
            hyprKey: config.hyprKey,
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
            tasks: [
                BarTask(title: "Jump to the menu bar", bind: model.bind { $0 == .focusMenuBar }, done: model.jumped,
                        why: config.focusFollowsMouse
                            ? "Moving the mouse up there changes the menu bar on the way. This doesn't."
                            : "It puts the pointer on your app's menu bar, no trip across the screen."),
                BarTask(title: "Open the key list", bind: model.bind { $0 == .showKeybinds }, done: model.openedKeys,
                        why: "You don't need to remember every key. They're all in the list."),
                BarTask(title: "Search it for “float”", bind: nil, done: model.searched,
                        why: "Type to search. Esc closes the list."),
            ],
            hyprKey: config.hyprKey,
            onExit: onExit,
            onNext: onNext)
    }
}

// MARK: - 7 pause

final class PauseLessonModel: PracticeLessonModel {
    @Published var paused = false
    @Published var resumed = false

    /// Set while tiling is off because this lesson turned it off. Local
    /// defaults, not the synced config, so a crash mid-lesson can't leave
    /// another Mac paused; the next launch resumes and clears it.
    static let ownedPauseKey = "tutorialPausedTiling"

    private let defaults: UserDefaults
    /// tiling was on when the lesson opened; started paused, it's never ours
    private var startedOn = true
    private var lastEnabled = true

    init(practice: PracticeSession, config: UserConfig = .shared, defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        super.init(practice: practice, config: config, now: now)
    }

    override func didStart() {
        startedOn = config.enabled
        lastEnabled = config.enabled
        // opened paused: Pause is done and Resume Tiling shows at once
        evaluate()
    }

    override func evaluate() {
        let on = config.enabled
        // only an on → off during the lesson is ours, and off → on settles it
        if startedOn, lastEnabled, !on { defaults.set(true, forKey: Self.ownedPauseKey) }
        if !lastEnabled, on { defaults.removeObject(forKey: Self.ownedPauseKey) }
        lastEnabled = on
        if !on {
            mark(self, \.paused)
        } else if paused {
            mark(self, \.resumed)
        }
    }

    /// Tiling back on if this lesson paused it, then forget. Run when the
    /// tutorial ends and at launch, for a tutorial a crash cut short.
    static func resumeOwnedPause(config: UserConfig, defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: ownedPauseKey) else { return }
        defaults.removeObject(forKey: ownedPauseKey)
        hyprLog(.notice, .lifecycle, "tutorial: resuming the pause lesson 7 left on")
        if !config.enabled { config.enabled = true }
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
            tasks: [
                BarTask(title: "Pause tiling", bind: model.bind { $0 == .toggleTiling }, done: model.paused,
                        why: "For a game, a screen share, or an app that fights tiling."),
                BarTask(title: "Resume it", bind: keyWorksPaused ? model.bind { $0 == .toggleTiling } : nil,
                        done: model.resumed,
                        button: !keyWorksPaused && model.paused && !model.resumed
                            ? ("Resume Tiling", { model.resume() }) : nil,
                        why: keyWorksPaused ? "Every window stays where it was." : resumeWhy),
            ],
            hyprKey: config.hyprKey,
            onExit: onExit,
            onNext: onNext)
    }

    private var resumeWhy: String {
        let place = menuBarStyle == .hidden ? "Settings → General" : "the menu bar"
        return "Paused, \(config.hyprKey.displayName) types normally. Resume here or from \(place)."
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
