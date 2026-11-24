// One run of the stage window: onboarding (required, once) and then, if
// the user takes it, the tutorial (optional, replayable). Steps not built
// yet are passed over.

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
    private var escMonitor: Any?

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

    static func tutorial(practiceHost: PracticeHost? = nil) -> StageSession {
        StageSession(screen: .tutorial(builtLessons[0]), practiceHost: practiceHost)
    }

    init(screen: StageScreen, practiceHost: PracticeHost? = nil) {
        self.screen = screen
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
        startScreen()
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
            close()
        }
    }

    /// Every way out ends here: Done, Skip Tutorial, Esc, Quit HyprMac.
    /// The helper quits, its rules go, the workspace goes back, and tiling
    /// resumes if the pause lesson left it paused. Safe to call twice.
    func close() {
        stopScreen()
        cleanUp()
        controller.dismiss()
        onClose()
    }

    /// The part of `close` that must also run when HyprMac quits.
    func cleanUp() {
        if pause.pausedHere, !UserConfig.shared.enabled { UserConfig.shared.enabled = true }
        practice.end()
        removeEscMonitor()
    }

    // MARK: switching

    private func go(to next: StageScreen) {
        let wasPractice = isPractice
        stopScreen()
        screen = next
        if isPractice, !wasPractice {
            controller.setPracticeMode(true, level: level)
            practice.begin()
            addEscMonitor()
        } else if !isPractice, wasPractice {
            cleanUp()
            controller.setPracticeMode(false, level: level)
        } else if !isPractice {
            controller.window?.level = level
        }
        startScreen()
    }

    private func startScreen() {
        switch screen {
        case .tutorial(.hyprKey): hyprKeyLesson.start()
        case .onboarding(.hyprKey): hyprKeyHold.start()
        case .tutorial(.moveAround):
            moveAround.start()
            controller.showBar(MoveAroundLessonBar(model: moveAround, onExit: exit, onNext: next))
        case .tutorial(.workspaces):
            workspaces.start()
            controller.showBar(WorkspacesLessonBar(model: workspaces, onExit: exit, onNext: next))
        case .tutorial(.floating):
            floating.start()
            controller.showBar(FloatingLessonBar(model: floating, onExit: exit, onNext: next))
        case .tutorial(.fixWindow):
            fixWindow.start()
            controller.showBar(FixWindowLessonBar(model: fixWindow, onExit: exit, onNext: next))
        case .tutorial(.menuBarAndKeys):
            menuBarAndKeys.start()
            controller.showBar(MenuBarAndKeysLessonBar(model: menuBarAndKeys, onExit: exit, onNext: next))
        case .tutorial(.pause):
            pause.start()
            controller.showBar(PauseLessonBar(model: pause, onExit: exit, onNext: next))
        default: break
        }
    }

    private var exit: () -> Void { { [weak self] in self?.close() } }
    private var next: () -> Void { { [weak self] in self?.nextLesson() } }

    private func stopScreen() {
        hyprKeyLesson.stop()
        hyprKeyHold.stop()
        moveAround.stop()
        lessonModels.forEach { $0.stop() }
        controller.hideBar()
    }

    // Esc ends the tutorial. The lesson bar never takes keys, so watch for it
    // while a practice window is in front. HyprMac's own panels (Hypr+K,
    // Hypr+I) get their Esc as local events, which this never sees.
    private func addEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == PracticeSession.helperBundleID
            else { return }
            DispatchQueue.main.async { self?.close() }
        }
    }

    private func removeEscMonitor() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
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
                           nextTitle: "Next: \(nextOnboardingLabel)")
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
            FinishView(completed: session.lessonsDone, onDone: { session.close() })
        case .tutorial:
            HyprKeyLessonView(model: session.hyprKeyLesson,
                              completed: session.lessonsDone,
                              onExit: { session.close() },
                              onNext: { session.nextLesson() })
        }
    }

    private var nextOnboardingLabel: String {
        StageSession.builtOnboarding.dropFirst().first?.railLabel ?? ""
    }
}
