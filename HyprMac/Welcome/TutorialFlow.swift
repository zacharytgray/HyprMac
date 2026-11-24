// One tutorial run: which step is up, what's done, and the window it lives
// in. Built so far: Access and the Hypr key lesson; Next past the last
// built step ends the run.

import SwiftUI

final class TutorialSession: ObservableObject {
    @Published private(set) var step: TutorialLesson
    @Published private(set) var completed: Set<TutorialLesson> = []
    let access = AccessStepModel()
    let hyprKey = HyprKeyLessonModel()

    private static let built: Set<TutorialLesson> = [.access, .hyprKey]

    private let controller = TutorialWindowController()
    var onClose: () -> Void = {}
    var onQuit: () -> Void = {}

    init(startAt step: TutorialLesson) {
        self.step = step
        if step != .access { completed.insert(.access) }
    }

    var isShowing: Bool { controller.window != nil }

    func show() {
        controller.show(TutorialFlowView(session: self), level: TutorialWindowController.level(for: step))
        startStep()
    }

    func grantAccess() {
        access.grant(beside: controller.window) { [weak self] in self?.controller.bringToFront() }
    }

    /// The launch poll saw the grant.
    func noteAccessGranted() { access.refresh() }

    func advance() {
        stopStep()
        completed.insert(step)
        guard let next = step.next, Self.built.contains(next) else {
            close()
            return
        }
        step = next
        controller.window?.level = TutorialWindowController.level(for: next)
        startStep()
    }

    func close() {
        stopStep()
        controller.dismiss()
        onClose()
    }

    private func startStep() {
        if step == .hyprKey { hyprKey.start() }
    }

    private func stopStep() {
        hyprKey.stop()
    }
}

struct TutorialFlowView: View {
    @ObservedObject var session: TutorialSession

    var body: some View {
        switch session.step {
        case .access:
            AccessStepView(model: session.access,
                           onGrant: { session.grantAccess() },
                           onQuit: { session.onQuit() },
                           onNext: { session.advance() })
        default:
            HyprKeyLessonView(model: session.hyprKey,
                              completed: session.completed,
                              onExit: { session.close() },
                              onNext: { session.advance() })
        }
    }
}
