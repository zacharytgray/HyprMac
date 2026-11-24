// One run of the stage window: onboarding (required, once on a fresh
// install) and then, if the user takes it, the tutorial (optional,
// replayable). A Mac that ran HyprMac before but lost access gets the
// Access step alone.

import SwiftUI

enum StageScreen: Equatable {
    case onboarding(OnboardingStep)
    case tutorial(TutorialLesson)
}

final class StageSession: ObservableObject {
    @Published private(set) var screen: StageScreen
    @Published private(set) var onboardingDone: Set<OnboardingStep> = []
    @Published private(set) var lessonsDone: Set<TutorialLesson> = []
    let access = AccessStepModel()
    let hyprKeyLesson = HyprKeyLessonModel()
    let hyprKeyHold = HyprKeyHoldWatcher()
    let practice: PracticeSession
    let moveAround: MoveAroundLessonModel
    let workspaces: WorkspacesLessonModel
    let floating: FloatingLessonModel
    let fixWindow: FixWindowLessonModel
    let menuBarAndKeys: MenuBarAndKeysLessonModel
    let pause: PauseLessonModel
    /// access was lost on a Mac that's already set up: Access, then done
    let accessOnly: Bool
    private var escMonitor: Any?
    private var localEscMonitor: Any?
    /// Esc asked "Leave the tutorial?" in the card
    let leaveConfirmation = LeaveConfirmation()
    /// the lesson this run started at after a resume, for its Start over link
    private(set) var resumedAt: TutorialLesson?
    /// where the resume point lives: local defaults, never the synced config
    var resumeDefaults: UserDefaults = .standard

    static let builtOnboarding: [OnboardingStep] = [.access, .hyprKey, .makeItYours]
    static let builtLessons: [TutorialLesson] = TutorialLesson.allCases
    /// lessons done on the practice windows
    static let practiceLessons: Set<TutorialLesson> = [.moveAround, .workspaces, .floating, .fixWindow,
                                                       .menuBarAndKeys, .pause]

    private let controller = TutorialWindowController()
    var onClose: () -> Void = {}
    var onQuit: () -> Void = {}

    /// Onboarding starts at Access only while access is missing.
    static func onboarding(accessGranted: Bool, practiceHost: PracticeHost? = nil) -> StageSession {
        let first = accessGranted ? builtOnboarding.first { $0 != .access } ?? .makeItYours : .access
        let session = StageSession(screen: .onboarding(first), practiceHost: practiceHost)
        if accessGranted { session.onboardingDone.insert(.access) }
        return session
    }

    /// For a Mac that ran HyprMac before: just Access, never Hypr key or
    /// Make it yours, so nothing the user set changes.
    static func accessOnly() -> StageSession {
        StageSession(screen: .onboarding(.access), accessOnly: true)
    }

    /// From the first lesson, or from `resume`, the lesson a run left early
    /// was on. Each lesson starts on its own: practice opens its windows.
    static func tutorial(practiceHost: PracticeHost? = nil, resume: TutorialLesson? = nil) -> StageSession {
        let start = resume.flatMap { builtLessons.contains($0) && $0 != .finish ? $0 : nil } ?? builtLessons[0]
        let session = StageSession(screen: .tutorial(start), practiceHost: practiceHost)
        if start != builtLessons[0] { session.resumedAt = start }
        return session
    }

    init(screen: StageScreen, practiceHost: PracticeHost? = nil, accessOnly: Bool = false) {
        self.screen = screen
        self.accessOnly = accessOnly
        practice = PracticeSession(host: practiceHost)
        moveAround = MoveAroundLessonModel(practice: practice)
        workspaces = WorkspacesLessonModel(practice: practice)
        floating = FloatingLessonModel(practice: practice)
        fixWindow = FixWindowLessonModel(practice: practice)
        menuBarAndKeys = MenuBarAndKeysLessonModel(practice: practice)
        pause = PauseLessonModel(practice: practice)
    }

    private var lessonModels: [PracticeLessonModel] { [workspaces, floating, fixWindow, menuBarAndKeys, pause] }

    private var isPractice: Bool {
        if case let .tutorial(lesson) = screen { return Self.practiceLessons.contains(lesson) }
        return false
    }

    var isShowing: Bool { controller.window != nil }

    func show() {
        controller.show(StageFlowView(session: self), level: level)
        addEscMonitor()
        // a resumed run can start on a practice lesson
        enterScreen(wasPractice: false)
    }

    private var level: NSWindow.Level {
        TutorialWindowController.level(forAccess: screen == .onboarding(.access))
    }

    // MARK: onboarding

    func grantAccess() {
        access.grant(beside: controller.window) { [weak self] in self?.controller.bringToFront() }
    }

    /// The launch poll saw the grant.
    func noteAccessGranted() { access.refresh() }

    func nextOnboardingStep() {
        guard case let .onboarding(step) = screen else { return }
        onboardingDone.insert(step)
        if accessOnly { return close() }
        let built = Self.builtOnboarding
        if let index = built.firstIndex(of: step), index + 1 < built.count {
            go(to: .onboarding(built[index + 1]))
        }
    }

    var canGoBack: Bool {
        guard case let .onboarding(step) = screen,
              let index = Self.builtOnboarding.firstIndex(of: step), index > 0 else { return false }
        return Self.builtOnboarding[index - 1] != .access
    }

    func previousOnboardingStep() {
        guard case let .onboarding(step) = screen,
              let index = Self.builtOnboarding.firstIndex(of: step), index > 0 else { return }
        let previous = Self.builtOnboarding[index - 1]
        // access can't be undone, so Back stops at the step after it
        guard previous != .access else { return }
        go(to: .onboarding(previous))
    }

    /// Onboarding's last choice.
    func finishOnboarding(takeTutorial: Bool) {
        onboardingDone.insert(.makeItYours)
        if takeTutorial {
            go(to: .tutorial(Self.builtLessons[0]))
        } else {
            close()
        }
    }

    // MARK: tutorial

    func nextLesson() {
        guard case let .tutorial(lesson) = screen else { return }
        lessonsDone.insert(lesson)
        let built = Self.builtLessons
        if let index = built.firstIndex(of: lesson), index + 1 < built.count {
            go(to: .tutorial(built[index + 1]))
        } else {
            finishTutorial()
        }
    }

    // MARK: leaving

    /// Done on the finish: the whole tutorial, so no resume point.
    func finishTutorial() {
        TutorialResume.clear(resumeDefaults)
        close()
    }

    /// Skip Tutorial, or Leave in Esc's question: the lesson is kept, and
    /// the tutorial opens there next time.
    func leaveEarly() {
        noteLeaving()
        close()
    }

    /// Remembers the lesson this run is on, when it's one to come back to.
    /// HyprMac quitting mid-lesson calls this before the cleanup.
    func noteLeaving() {
        guard case let .tutorial(lesson) = screen, lesson != .finish else { return }
        TutorialResume.save(lesson, resumeDefaults)
    }

    /// Start over from lesson 1, forgetting the resume point.
    func startOver() {
        TutorialResume.clear(resumeDefaults)
        resumedAt = nil
        leaveConfirmation.isAsking = false
        go(to: .tutorial(Self.builtLessons[0]))
    }

    /// Esc on a lesson asks first; Esc again keeps going.
    func escPressed() {
        guard case let .tutorial(lesson) = screen, lesson != .finish else { return }
        leaveConfirmation.isAsking.toggle()
    }

    func keepGoing() { leaveConfirmation.isAsking = false }

    /// Every way out ends here: Done, Skip Tutorial, Leave, Quit HyprMac.
    /// The helper quits, its rules go, the workspace goes back, and tiling
    /// resumes if the pause lesson left it paused. Safe to call twice.
    func close() {
        leaveConfirmation.isAsking = false
        stopScreen()
        cleanUp()
        removeEscMonitor()
        controller.dismiss()
        onClose()
    }

    /// The part of `close` that must also run when HyprMac quits.
    func cleanUp() {
        // back on the user's own workspace first: resuming re-tiles the
        // windows on screen, and they should be the user's, not the practice
        practice.end()
        PauseLessonModel.resumeOwnedPause(config: .shared)
    }

    // MARK: switching

    private func go(to next: StageScreen) {
        let wasPractice = isPractice
        stopScreen()
        screen = next
        enterScreen(wasPractice: wasPractice)
    }

    private func enterScreen(wasPractice: Bool) {
        if isPractice, !practice.isActive {
            // each practice lesson tries again; without an empty workspace
            // the stage stays in front of the user's windows
            practice.begin()
            if practice.isActive { controller.setPracticeMode(true, level: level) }
        } else if !isPractice, wasPractice {
            cleanUp()
            controller.setPracticeMode(false, level: level)
        } else if !isPractice {
            controller.window?.level = level
        }
        startScreen()
    }

    /// Why a lesson that works on windows can't run, if it can't.
    func practiceBlocked(_ lesson: TutorialLesson) -> String? {
        guard Self.windowLessons.contains(lesson) else { return nil }
        if let reason = practice.unavailable { return reason }
        if lesson == .workspaces, practice.otherWorkspace == nil { return PracticeSession.needsSecondEmptyWorkspace }
        return nil
    }

    /// lessons that focus, move, float or give rules to windows
    static let windowLessons: Set<TutorialLesson> = [.moveAround, .workspaces, .floating, .fixWindow]

    private func startScreen() {
        if case .tutorial(.workspaces) = screen { practice.pickSendTarget() }
        if case let .tutorial(lesson) = screen, let reason = practiceBlocked(lesson) {
            controller.showBar(LessonBar(lesson: lesson,
                                         why: "This lesson runs on practice windows, never on yours.",
                                         tasks: [], hyprKey: UserConfig.shared.hyprKey, blocked: reason,
                                         onExit: exit, onNext: next), onHeight: cardHeight, confirmation: leaveConfirmation, actions: cardActions)
            return
        }
        switch screen {
        case .tutorial(.hyprKey): hyprKeyLesson.start()
        case .onboarding(.hyprKey): hyprKeyHold.start()
        case .tutorial(.moveAround):
            moveAround.start()
            controller.showBar(MoveAroundLessonBar(model: moveAround, onExit: exit, onNext: next), onHeight: cardHeight, confirmation: leaveConfirmation, actions: cardActions)
        case .tutorial(.workspaces):
            workspaces.start()
            controller.showBar(WorkspacesLessonBar(model: workspaces, onExit: exit, onNext: next), onHeight: cardHeight, confirmation: leaveConfirmation, actions: cardActions)
        case .tutorial(.floating):
            floating.start()
            controller.showBar(FloatingLessonBar(model: floating, onExit: exit, onNext: next), onHeight: cardHeight, confirmation: leaveConfirmation, actions: cardActions)
        case .tutorial(.fixWindow):
            fixWindow.start()
            controller.showBar(FixWindowLessonBar(model: fixWindow, onExit: exit, onNext: next), onHeight: cardHeight, confirmation: leaveConfirmation, actions: cardActions)
        case .tutorial(.menuBarAndKeys):
            menuBarAndKeys.start()
            controller.showBar(MenuBarAndKeysLessonBar(model: menuBarAndKeys, onExit: exit, onNext: next), onHeight: cardHeight, confirmation: leaveConfirmation, actions: cardActions)
        case .tutorial(.pause):
            pause.start()
            controller.showBar(PauseLessonBar(model: pause, onExit: exit, onNext: next), onHeight: cardHeight, confirmation: leaveConfirmation, actions: cardActions)
        default: break
        }
    }

    private var exit: () -> Void { { [weak self] in self?.leaveEarly() } }
    /// what the card offers besides its lesson: Keep Going and Leave for
    /// Esc's question, and Start over on the lesson a resume began at
    var cardActions: LessonCardActions {
        var actions = LessonCardActions(onKeepGoing: { [weak self] in self?.keepGoing() },
                                        onLeave: { [weak self] in self?.leaveEarly() })
        if case let .tutorial(lesson) = screen, lesson == resumedAt {
            actions.startOver = { [weak self] in self?.startOver() }
        }
        return actions
    }

    /// the card's height, so the practice tiles end above it
    private var cardHeight: (CGFloat) -> Void { { [weak self] in self?.practice.setCardHeight($0) } }
    private var next: () -> Void { { [weak self] in self?.nextLesson() } }

    private func stopScreen() {
        hyprKeyLesson.stop()
        hyprKeyHold.stop()
        moveAround.stop()
        lessonModels.forEach { $0.stop() }
        controller.hideBar()
    }

    /// Esc on a lesson asks "Leave the tutorial?" in the card while a
    /// practice window or the stage has the keys; Esc again keeps going.
    /// Onboarding and the finish have no Esc, and Esc in HyprMac's own
    /// panels (Hypr+K, Hypr+I) or another app stays theirs.
    static func escAsksToLeave(screen: StageScreen, keyCode: UInt16,
                               onStage: Bool, helperIsFront: Bool) -> Bool {
        guard keyCode == 53, case let .tutorial(lesson) = screen, lesson != .finish else { return false }
        return onStage || helperIsFront
    }

    /// Return answers Keep Going while the question shows, from the same places
    static func returnKeepsGoing(asking: Bool, keyCode: UInt16, onStage: Bool, helperIsFront: Bool) -> Bool {
        asking && (keyCode == 36 || keyCode == 76) && (onStage || helperIsFront)
    }

    // The card never takes keys. A practice window's keys go to the helper,
    // seen here as global events; the stage's, while it's in front
    // (practice blocked, lesson 1), are local ones. While the stage covers
    // the screen another app can still be active behind it, as after Hypr+K
    // closes; its Esc is the tutorial's too.
    private func addEscMonitor() {
        if escMonitor == nil {
            escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return }
                let helperFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    == PracticeSession.helperBundleID
                let onStage = self.controller.coversScreen
                if Self.escAsksToLeave(screen: self.screen, keyCode: event.keyCode,
                                       onStage: onStage, helperIsFront: helperFront) {
                    DispatchQueue.main.async { self.escPressed() }
                } else if Self.returnKeepsGoing(asking: self.leaveConfirmation.isAsking, keyCode: event.keyCode,
                                                onStage: onStage, helperIsFront: helperFront) {
                    DispatchQueue.main.async { self.keepGoing() }
                }
            }
        }
        if localEscMonitor == nil {
            localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let stage = self.controller.window else { return event }
                let onStage = event.window === stage
                if Self.escAsksToLeave(screen: self.screen, keyCode: event.keyCode,
                                       onStage: onStage, helperIsFront: false) {
                    DispatchQueue.main.async { self.escPressed() }
                    return nil
                }
                if Self.returnKeepsGoing(asking: self.leaveConfirmation.isAsking, keyCode: event.keyCode,
                                         onStage: onStage, helperIsFront: false) {
                    DispatchQueue.main.async { self.keepGoing() }
                    return nil
                }
                return event
            }
        }
    }

    private func removeEscMonitor() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        if let localEscMonitor { NSEvent.removeMonitor(localEscMonitor) }
        escMonitor = nil
        localEscMonitor = nil
    }
}

struct StageFlowView: View {
    @ObservedObject var session: StageSession

    var body: some View {
        switch session.screen {
        case .onboarding(.access):
            AccessStepView(model: session.access,
                           onGrant: { session.grantAccess() },
                           onQuit: { session.onQuit() },
                           onNext: { session.nextOnboardingStep() },
                           nextTitle: session.accessOnly ? "Done" : "Next: \(nextOnboardingLabel)",
                           standalone: session.accessOnly)
        case .onboarding(.hyprKey):
            HyprKeyPickerView(watcher: session.hyprKeyHold,
                              completed: session.onboardingDone,
                              onNext: { session.nextOnboardingStep() })
        case .onboarding:
            MakeItYoursView(completed: session.onboardingDone,
                            onBack: session.canGoBack ? { session.previousOnboardingStep() } : nil,
                            onSkipTutorial: { session.finishOnboarding(takeTutorial: false) },
                            onTakeTutorial: { session.finishOnboarding(takeTutorial: true) })
        case .tutorial(let lesson) where StageSession.practiceLessons.contains(lesson):
            // behind the practice windows; the lesson is on the bar
            StageBackdrop()
        case .tutorial(.finish):
            FinishView(completed: session.lessonsDone, onDone: { session.finishTutorial() })
        case .tutorial:
            HyprKeyLessonView(model: session.hyprKeyLesson,
                              completed: session.lessonsDone,
                              leave: session.leaveConfirmation,
                              actions: session.cardActions,
                              onExit: { session.leaveEarly() },
                              onNext: { session.nextLesson() })
        }
    }

    private var nextOnboardingLabel: String {
        StageSession.builtOnboarding.dropFirst().first?.railLabel ?? ""
    }
}

// MARK: - leaving and coming back

/// Esc's question in the card, shown in place of the lesson.
final class LeaveConfirmation: ObservableObject {
    @Published var isAsking = false
}

/// What the card does beyond its lesson; set by the stage.
struct LessonCardActions {
    var startOver: (() -> Void)? = nil
    var onKeepGoing: () -> Void = {}
    var onLeave: () -> Void = {}
}

private struct LessonCardActionsKey: EnvironmentKey {
    static let defaultValue = LessonCardActions()
}

extension EnvironmentValues {
    var lessonCardActions: LessonCardActions {
        get { self[LessonCardActionsKey.self] }
        set { self[LessonCardActionsKey.self] = newValue }
    }
}

/// The lesson a run was left on, in local defaults (never the synced
/// config): the tutorial opens there next time. Done clears it.
enum TutorialResume {
    static let key = "tutorialResumeLesson"

    static func load(_ defaults: UserDefaults = .standard) -> TutorialLesson? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return TutorialLesson(rawValue: defaults.integer(forKey: key))
    }

    static func save(_ lesson: TutorialLesson, _ defaults: UserDefaults = .standard) {
        defaults.set(lesson.rawValue, forKey: key)
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

/// The card, or Esc's question in its place: "Leave the tutorial?" with
/// Keep Going (Return) and Leave.
struct LeaveConfirmSwitch<Content: View>: View {
    @ObservedObject var confirmation: LeaveConfirmation
    let actions: LessonCardActions
    let content: Content

    var body: some View {
        Group {
            if confirmation.isAsking {
                LeaveConfirmCard(onKeepGoing: actions.onKeepGoing, onLeave: actions.onLeave)
            } else {
                content
            }
        }
        .environment(\.lessonCardActions, actions)
    }
}

struct LeaveConfirmCard: View {
    let onKeepGoing: () -> Void
    let onLeave: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Leave the tutorial?")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(TutorialStageColor.text)
                Text("You can pick up here later.")
                    .font(.system(size: 11))
                    .foregroundStyle(TutorialStageColor.quiet)
            }
            Spacer(minLength: 8)
            StageQuietButton("Leave", action: onLeave)
            Button(action: onKeepGoing) {
                Text("Keep Going")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(TutorialStageColor.navyTop)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                        .fill(TutorialStageColor.cyan))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: LessonBar.width, alignment: .leading)
        .background(LessonBar.glass)
        .environment(\.colorScheme, .dark)
    }
}
