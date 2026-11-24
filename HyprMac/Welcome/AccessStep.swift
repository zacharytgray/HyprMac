// Step 0: Accessibility. Grant opens the list in System Settings and
// dex157's drag panel (AccessibilityDragHelper) under it; the user drags
// HyprMac in. The stage sits at the normal level for this step, so System
// Settings comes in front of it, and it comes back with the check.

import SwiftUI

// MARK: - model

final class AccessStepModel: ObservableObject {
    @Published var granted: Bool
    /// Grant pressed: System Settings and the drag panel are up
    @Published var waiting = false

    init(granted: Bool = AccessibilityManager.isAccessibilityEnabled()) {
        self.granted = granted
    }

    /// `bringBack` runs when the drag flow ends, granted or not, so the
    /// stage comes to the front again.
    func grant(beside window: NSWindow?, bringBack: @escaping () -> Void) {
        waiting = true
        AccessibilityDragHelper.shared.start(beside: window) { [weak self] granted in
            guard let self else { return }
            self.waiting = false
            if granted { withAnimation(HyprMotion.snap) { self.granted = true } }
            bringBack()
        }
    }

    func refresh() {
        let now = AccessibilityManager.isAccessibilityEnabled()
        // while the panel's flow runs, its end reports the grant, after the
        // user has seen HyprMac land in the list
        guard now != granted, !waiting else { return }
        withAnimation(HyprMotion.snap) { granted = now }
    }
}

// MARK: - view

struct AccessStepView: View {
    @ObservedObject var model: AccessStepModel
    let onGrant: () -> Void
    let onQuit: () -> Void
    let onNext: () -> Void

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        TutorialStage(
            lesson: .access,
            completed: model.granted ? [.access] : [],
            progress: model.granted ? "Access granted" : nil,
            canContinue: model.granted,
            exitTitle: "Quit HyprMac",
            canSkipLesson: false,
            onExit: onQuit,
            onSkipLesson: {},
            onNext: onNext
        ) {
            VStack(spacing: 0) {
                Text(model.granted ? "HyprMac can manage your windows" : "Let HyprMac move your windows")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(TutorialStageColor.text)
                Text("Tiling moves and resizes other apps’ windows. macOS allows that only for apps in its Accessibility list. HyprMac starts the moment it’s there, with no restart.")
                    .font(.system(size: 14))
                    .foregroundStyle(TutorialStageColor.quiet)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                DragToListPicture(waiting: model.waiting, granted: model.granted)
                    .padding(.top, 34)

                TutorialTaskCard(tasks: tasks)
                    .padding(.top, 34)

                if !model.granted {
                    staleEntryHelp
                        .padding(.top, 14)
                }
            }
            .frame(width: 560)
        }
        .onReceive(poll) { _ in model.refresh() }
    }

    private var tasks: [TutorialTask] {
        [
            TutorialTask(title: "Open Accessibility in System Settings",
                         detail: "It opens on the list, with a small HyprMac panel under its window.",
                         done: model.waiting || model.granted,
                         trailing: model.granted ? nil : AnyView(
                            model.waiting
                                ? AnyView(StageSecondaryButton("Open Again", action: onGrant))
                                : AnyView(StagePrimaryButton("Open Accessibility", showsArrow: false,
                                                             isDefault: false, action: onGrant)))),
            TutorialTask(title: "Drag the HyprMac icon into the list",
                         detail: "Drop it on the list and confirm with Touch ID or your password. Its switch turns on by itself.",
                         done: model.granted),
        ]
    }

    // an update can leave a stale entry that looks on but isn't
    private var staleEntryHelp: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(TutorialStageColor.faint)
                .accessibilityHidden(true)
            Text("HyprMac is in the list but this step doesn’t finish? Select it, remove it with −, then drag it in again.")
                .font(.system(size: 11.5))
                .foregroundStyle(TutorialStageColor.quiet)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - picture

/// What the drag does: the HyprMac icon going into a list of apps. The
/// empty slot lights up while System Settings is open and fills on the
/// grant.
private struct DragToListPicture: View {
    let waiting: Bool
    let granted: Bool

    var body: some View {
        HStack(spacing: 18) {
            VStack(spacing: 8) {
                HyprMark(size: 64)
                    .opacity(granted ? 0.35 : 1)
                Text("HyprMac")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TutorialStageColor.quiet)
            }
            .frame(width: 96)

            arrow

            list
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(granted ? "HyprMac is in the Accessibility list, switched on"
                            : "Drag the HyprMac icon into the Accessibility list")
    }

    private var arrow: some View {
        HStack(spacing: 0) {
            Line()
                .stroke(TutorialStageColor.cyan.opacity(granted ? 0.3 : 0.8),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(width: 96, height: 2)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(TutorialStageColor.cyan.opacity(granted ? 0.3 : 0.8))
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Accessibility")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TutorialStageColor.quiet)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            placeholderRow(width: 92, on: true)
            placeholderRow(width: 64, on: false)
            slot
        }
        .frame(width: 260)
        .tutorialGlass(cornerRadius: 12)
    }

    // someone else's app: an icon square and a name bar, no real names
    private func placeholderRow(width: CGFloat, on: Bool) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.12)).frame(width: 20, height: 20)
            RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.12)).frame(width: width, height: 7)
            Spacer()
            toggle(on: on, lit: false)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .overlay(alignment: .top) { Rectangle().fill(TutorialStageColor.line).frame(height: 1) }
    }

    @ViewBuilder
    private var slot: some View {
        if granted {
            HStack(spacing: 9) {
                HyprMark(size: 20)
                Text("HyprMac")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TutorialStageColor.text)
                Spacer()
                toggle(on: true, lit: true)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .overlay(alignment: .top) { Rectangle().fill(TutorialStageColor.line).frame(height: 1) }
        } else {
            Text("Drop HyprMac here")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(waiting ? TutorialStageColor.cyan : TutorialStageColor.faint)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(waiting ? TutorialStageColor.cyan.opacity(0.8) : TutorialStageColor.faint,
                                      style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .padding(8)
        }
    }

    private func toggle(on: Bool, lit: Bool) -> some View {
        Capsule()
            .fill(on ? (lit ? TutorialStageColor.cyan : Color.white.opacity(0.28)) : Color.white.opacity(0.10))
            .frame(width: 26, height: 15)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(Color.white.opacity(0.9)).frame(width: 11, height: 11).padding(2)
            }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}
