// Lesson 1: the Hypr key. The user holds it, then (with Caps Lock as the
// Hypr key) taps it twice to turn capitals on and twice to turn them off.
// Each task ticks itself off from the real key; nothing is clicked through.

import SwiftUI
import CoreGraphics

// MARK: - model

final class HyprKeyLessonModel: ObservableObject {
    @Published var hyprHeld = false
    @Published var heldOnce = false
    @Published var capsLockOn = false
    @Published var capsTurnedOn = false
    @Published var capsTurnedOff = false
    /// the user passed on the double-tap part
    @Published var skippedDoubleTap = false

    private let config: UserConfig
    private var observers: [NSObjectProtocol] = []
    private var capsPoll: Timer?

    init(config: UserConfig = .shared) {
        self.config = config
    }

    /// The taps are practiced only with Caps Lock as the Hypr key and the
    /// double tap on; onboarding is where the user chose that.
    var teachesDoubleTap: Bool {
        config.hyprKey == .capsLock && config.doubleTapHyprTogglesCapsLock && !skippedDoubleTap
    }

    /// what the card lists: the hold, then the two taps
    private var tasks: [Bool] {
        teachesDoubleTap ? [heldOnce, capsTurnedOn, capsTurnedOff] : [heldOnce]
    }
    var tasksDone: Int { tasks.filter { $0 }.count }
    var taskCount: Int { tasks.count }
    var isDone: Bool { tasksDone == taskCount }

    func skipDoubleTap() { skippedDoubleTap = true }

    /// Live input: the Hypr key from the hotkey manager, Caps Lock from the
    /// session's modifier flags. The window controller calls this; previews
    /// and snapshot tests set the published state by hand instead.
    func start() {
        stop()
        capsLockOn = Self.readCapsLock()
        observers.append(NotificationCenter.default.addObserver(
            forName: .hyprMacHyprKeyChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let down = note.userInfo?["down"] as? Bool else { return }
            self.hyprHeld = down
            if down, !self.heldOnce { withAnimation(HyprMotion.snap) { self.heldOnce = true } }
        })
        // the double tap flips the lock state through IOHID, with no event
        // the app sees, so poll it
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.noteCapsLock(Self.readCapsLock()) }
        RunLoop.main.add(timer, forMode: .common)
        capsPoll = timer
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        capsPoll?.invalidate()
        capsPoll = nil
    }

    func noteCapsLock(_ on: Bool) {
        guard on != capsLockOn else { return }
        capsLockOn = on
        withAnimation(HyprMotion.snap) {
            if on { capsTurnedOn = true } else if capsTurnedOn { capsTurnedOff = true }
        }
    }

    private static func readCapsLock() -> Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
    }
}

// MARK: - view

struct HyprKeyLessonView: View {
    @ObservedObject var model: HyprKeyLessonModel
    @ObservedObject var config: UserConfig = .shared
    var completed: Set<TutorialLesson> = []
    let onExit: () -> Void
    let onNext: () -> Void

    var body: some View {
        TutorialStage(
            step: TutorialLesson.hyprKey,
            completed: completed,
            counter: TutorialLesson.hyprKey.counterLabel,
            progress: "\(model.tasksDone) of \(model.taskCount) done",
            canContinue: model.isDone,
            exit: StageAction(title: "Skip Tutorial", shortcut: .cancelAction, action: onExit),
            skip: StageAction(title: "Skip Lesson", action: onNext),
            next: StageAction(title: TutorialLesson.hyprKey.nextTitle, action: onNext)
        ) {
            VStack(spacing: 0) {
                Text("\(keyName) is your Hypr key")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(TutorialStageColor.text)
                Text("Every HyprMac shortcut starts with it held down, like Shift. On its own it does nothing.")
                    .font(.system(size: 14))
                    .foregroundStyle(TutorialStageColor.quiet)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)

                Group {
                    if config.hyprKey == .capsLock {
                        CapsLockCorner(held: model.hyprHeld)
                    } else {
                        LessonKeycap(label: keyName.uppercased(), glyph: glyph, held: model.hyprHeld)
                    }
                }
                .padding(.top, 34)

                LessonTaskCard(model: model, keyName: keyName)
                    .padding(.top, 34)

                if let guidance = HyprKeySystemGuidance.forKey(config.hyprKey) {
                    modifierKeysHelp(guidance)
                        .padding(.top, 14)
                }
            }
            .frame(width: 560)
        }
    }

    private var keyName: String { config.hyprKey.displayName }

    private var glyph: String? {
        let badge = config.hyprKey.badgeLabel
        return badge.lowercased() == keyName.lowercased() ? nil : badge
    }

    // the one thing that stops the key from working, said once, quietly
    private func modifierKeysHelp(_ guidance: HyprKeySystemGuidance) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(TutorialStageColor.faint)
                .accessibilityHidden(true)
            Text("Nothing happens when you hold it? \(guidance.title)")
                .font(.system(size: 11.5))
                .foregroundStyle(TutorialStageColor.quiet)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button("Open Modifier Keys") { HyprKeySystemGuidance.openKeyboardSettings() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(TutorialStageColor.cyan)
                .fixedSize()
                .help(guidance.detail)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - keycap

/// A large key that presses in and lights up while the Hypr key is down.
struct LessonKeycap: View {
    let label: String
    let glyph: String?
    let held: Bool

    var body: some View {
        VStack(spacing: 10) {
            Self.cap(label: label, glyph: glyph, held: held, size: CGSize(width: 260, height: 92))

            Text(held ? "Held" : "Not held")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(held ? TutorialStageColor.cyan : TutorialStageColor.faint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) key, \(held ? "held" : "not held")")
    }

    static func cap(label: String, glyph: String?, held: Bool, size: CGSize) -> some View {
        chrome(HStack(spacing: 8) {
            if let glyph {
                Text(glyph)
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .foregroundStyle(TutorialStageColor.cyan)
            }
            Text(label)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(TutorialStageColor.text.opacity(held ? 1 : 0.85))
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: size.width, height: size.height), held: held)
    }

    /// the lit key's border, bottom edge and glow, around any face
    static func chrome<Face: View>(_ face: Face, held: Bool) -> some View {
        face
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(held ? TutorialStageColor.cyan.opacity(0.16) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(TutorialStageColor.cyan.opacity(held ? 0.95 : 0.45), lineWidth: held ? 1.5 : 1)
            )
            .overlay(alignment: .bottom) {
                // a bright bottom edge that flattens when pressed
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(TutorialStageColor.cyan.opacity(0.7))
                    .frame(height: held ? 1.5 : 4)
                    .mask(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .shadow(color: TutorialStageColor.cyan.opacity(held ? 0.45 : 0.18), radius: held ? 28 : 16)
            .offset(y: held ? 2 : 0)
            .animation(HyprMotion.snap, value: held)
    }
}

// MARK: - keyboard corner

/// The left edge of a keyboard with Caps Lock lit, so a new user sees where
/// the key is. The neighbors are faded and the letters fade out to the right.
private struct CapsLockCorner: View {
    let held: Bool
    private let unit: CGFloat = 66
    private let gap: CGFloat = 8

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: gap) {
                row(edge: "tab", width: 1.5, letters: ["Q", "W", "E", "R"])
                HStack(spacing: gap) {
                    // labeled like a Mac key: the glyph top left, the name bottom left
                    LessonKeycap.chrome(
                        VStack(alignment: .leading, spacing: 0) {
                            Text("⇪")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(TutorialStageColor.cyan)
                            Spacer(minLength: 0)
                            Text("caps lock")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(TutorialStageColor.text.opacity(held ? 1 : 0.9))
                        }
                        .padding(10)
                        .frame(width: unit * 1.8, height: unit, alignment: .leading),
                        held: held)
                    letters(["A", "S", "D", "F"])
                }
                row(edge: "shift", width: 2.3, letters: ["Z", "X", "C"])
            }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))

            Text(held ? "Held" : "Not held")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(held ? TutorialStageColor.cyan : TutorialStageColor.faint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Caps Lock key, \(held ? "held" : "not held")")
    }

    private func row(edge: String, width: CGFloat, letters names: [String]) -> some View {
        HStack(spacing: gap) {
            quietKey(edge, width: unit * width, alignment: .bottomLeading)
            letters(names)
        }
    }

    private func letters(_ names: [String]) -> some View {
        HStack(spacing: gap) {
            ForEach(names, id: \.self) { quietKey($0, width: unit, alignment: .center) }
        }
    }

    private func quietKey(_ label: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(label)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(TutorialStageColor.faint)
            .padding(10)
            .frame(width: width, height: unit, alignment: alignment)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }
}

// MARK: - task card

/// The lesson's checklist. With double-tap off, the taps wait behind one
/// row that turns it on.
private struct LessonTaskCard: View {
    @ObservedObject var model: HyprKeyLessonModel
    let keyName: String

    var body: some View {
        TutorialTaskCard(tasks: tasks) {
            if model.teachesDoubleTap {
                // live Caps Lock state, so the taps show at once
                StageStatusChip(icon: model.capsLockOn ? "capslock.fill" : "capslock",
                                label: model.capsLockOn ? "Capitals on" : "Capitals off",
                                lit: model.capsLockOn)
            }
        }
    }

    private var tasks: [TutorialTask] {
        var list = [TutorialTask(title: "Hold \(keyName)",
                                 detail: "Press it and keep it down for a moment.",
                                 done: model.heldOnce)]
        guard model.teachesDoubleTap else { return list }
        list.append(TutorialTask(title: "Tap \(keyName) twice to type in capitals",
                                 detail: "Two quick taps, with no other key, turn Caps Lock on.",
                                 done: model.capsTurnedOn))
        list.append(TutorialTask(title: "Tap it twice again to turn capitals off",
                                 detail: "The same two taps turn Caps Lock back off.",
                                 done: model.capsTurnedOff))
        return list
    }
}
