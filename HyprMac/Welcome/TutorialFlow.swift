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

    static let builtOnboarding: [OnboardingStep] = [.access, .hyprKey, .makeItYours]
    static let builtLessons: [TutorialLesson] = [.hyprKey, .moveAround]
    /// lessons done on the practice windows
    static let practiceLessons: Set<TutorialLesson> = [.moveAround, .workspaces, .floating, .fixWindow, .menuBarAndKeys]

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
    }

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

    func close() {
        stopScreen()
        practice.end()
        controller.dismiss()
        onClose()
    }

    // MARK: switching

    private func go(to next: StageScreen) {
        let wasPractice = isPractice
        stopScreen()
        screen = next
        if isPractice, !wasPractice {
            controller.setPracticeMode(true, level: level)
            practice.begin()
        } else if !isPractice, wasPractice {
            practice.end()
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
            controller.showBar(MoveAroundLessonBar(model: moveAround,
                                                   onExit: { [weak self] in self?.close() },
                                                   onNext: { [weak self] in self?.nextLesson() }))
        default: break
        }
    }

    private func stopScreen() {
        hyprKeyLesson.stop()
        hyprKeyHold.stop()
        moveAround.stop()
        controller.hideBar()
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
