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

    static let builtOnboarding: [OnboardingStep] = [.access, .hyprKey, .makeItYours]
    static let builtLessons: [TutorialLesson] = [.hyprKey]

    private let controller = TutorialWindowController()
    var onClose: () -> Void = {}
    var onQuit: () -> Void = {}

    /// Onboarding starts at Access only while access is missing.
    static func onboarding(accessGranted: Bool) -> StageSession {
        let first = accessGranted ? builtOnboarding.first { $0 != .access } ?? .makeItYours : .access
        let session = StageSession(screen: .onboarding(first))
        if accessGranted { session.onboardingDone.insert(.access) }
        return session
    }

    static func tutorial() -> StageSession {
        StageSession(screen: .tutorial(builtLessons[0]))
    }

    init(screen: StageScreen) {
        self.screen = screen
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
        controller.dismiss()
        onClose()
    }

    // MARK: switching

    private func go(to next: StageScreen) {
        stopScreen()
        screen = next
        controller.window?.level = level
        startScreen()
    }

    private func startScreen() {
        if screen == .tutorial(.hyprKey) { hyprKeyLesson.start() }
        if screen == .onboarding(.hyprKey) { hyprKeyHold.start() }
    }

    private func stopScreen() {
        hyprKeyLesson.stop()
        hyprKeyHold.stop()
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
