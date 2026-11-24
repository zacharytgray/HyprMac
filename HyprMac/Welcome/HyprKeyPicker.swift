// Onboarding's second step: pick the Hypr key. Caps Lock is preselected and
// recommended; the rest are Settings → Keys' fixed list. A pick writes
// hyprKey at once, the same key Settings writes, so the try-it keycap and
// every later lesson use it.

import SwiftUI

// MARK: - notes

extension HyprKey {
    /// One line under each choice: what the user gives up, where it matters.
    var onboardingNote: String {
        switch self {
        case .capsLock:
            return "Few people use it, it sits under your little finger, and two quick taps still turn Caps Lock on."
        case .backslash:
            return "\\ won’t type while HyprMac runs. Pause tiling to type it."
        case .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20:
            return "Only on full-size keyboards, or sent by a remapping tool. Nothing else uses them."
        case .leftOption:
            return "Left ⌥ with a key HyprMac uses, like ⌥←, goes to HyprMac. Right ⌥ keeps them."
        case .rightOption:
            return "Right ⌥ loses the special characters on keys HyprMac uses, like ß (⌥S) and π (⌥P). Left ⌥ still types them."
        case .leftCommand:
            return "Left ⌘ with a key HyprMac uses, like ⌘S or ⌘W, goes to HyprMac. Right ⌘ keeps them."
        case .rightCommand:
            return "Right ⌘ with a key HyprMac uses, like ⌘S or ⌘W, goes to HyprMac. Left ⌘ keeps them."
        case .tab, .grave, .leftShift, .rightShift, .leftControl, .rightControl:
            return notRecommendedNote ?? ""
        }
    }

    static let functionKeys: [HyprKey] = [.f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20]
    var isFunctionKey: Bool { Self.functionKeys.contains(self) }
}

// MARK: - hold watcher

/// Whether the Hypr key is down right now, for the try-it keycap.
final class HyprKeyHoldWatcher: ObservableObject {
    @Published var held = false
    @Published var heldOnce = false
    private var observer: NSObjectProtocol?

    func start() {
        stop()
        observer = NotificationCenter.default.addObserver(
            forName: .hyprMacHyprKeyChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let down = note.userInfo?["down"] as? Bool else { return }
            self.held = down
            if down { self.heldOnce = true }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        held = false
    }
}

// MARK: - view

struct HyprKeyPickerView: View {
    @ObservedObject var config: UserConfig = .shared
    @ObservedObject var watcher: HyprKeyHoldWatcher
    var completed: Set<OnboardingStep> = [.access]
    let onNext: () -> Void

    var body: some View {
        TutorialStage(
            step: OnboardingStep.hyprKey,
            completed: completed,
            counter: OnboardingStep.hyprKey.counterLabel,
            note: "Change it any time in Settings → Keys",
            canContinue: true,
            next: StageAction(title: "Next: \(OnboardingStep.makeItYours.railLabel)", action: onNext)
        ) {
            VStack(spacing: 0) {
                Text("Pick your Hypr key")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(TutorialStageColor.text)
                Text("Every HyprMac shortcut is this key held down plus one more, like Shift.")
                    .font(.system(size: 14))
                    .foregroundStyle(TutorialStageColor.quiet)
                    .padding(.top, 8)

                HStack(alignment: .top, spacing: 24) {
                    keyList
                        .frame(width: 520)
                    tryIt
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 34)
            }
            .frame(width: 900)
        }
    }

    // MARK: list

    private var keyList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Rectangle().fill(TutorialStageColor.line).frame(height: 1) }
                keyRow(row)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .tutorialGlass(cornerRadius: 14)
    }

    /// The function keys share a row, picked by chip.
    private enum Row: Hashable {
        case key(HyprKey)
        case functionKeys
    }

    private var rows: [Row] {
        var list: [Row] = []
        for key in HyprKey.pickerChoices {
            if key.isFunctionKey {
                if !list.contains(.functionKeys) { list.append(.functionKeys) }
            } else {
                list.append(.key(key))
            }
        }
        return list
    }

    private func isPicked(_ row: Row) -> Bool {
        switch row {
        case .key(let key): return config.hyprKey == key
        case .functionKeys: return config.hyprKey.isFunctionKey
        }
    }

    private func title(_ row: Row) -> String {
        switch row {
        case .key(.backslash): return "Backslash  \\"
        case .key(let key): return key.displayName
        case .functionKeys: return "A function key, F13–F20"
        }
    }

    // the pick: an inset accent bar, a colored icon and heavier text
    private func keyRow(_ row: Row) -> some View {
        let picked = isPicked(row)
        let note = row == .functionKeys ? HyprKey.f13.onboardingNote
            : { if case .key(let key) = row { return key.onboardingNote }; return "" }()
        return Button {
            switch row {
            case .key(let key): config.hyprKey = key
            case .functionKeys: if !config.hyprKey.isFunctionKey { config.hyprKey = .f18 }
            }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(picked ? TutorialStageColor.cyan : .clear)
                    .frame(width: 3, height: 16)
                    .padding(.top, 2)
                Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(picked ? TutorialStageColor.cyan : TutorialStageColor.faint)
                    .frame(width: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(title(row))
                            .font(.system(size: 13, weight: picked ? .semibold : .regular))
                            .foregroundStyle(TutorialStageColor.text)
                        if row == .key(.capsLock) {
                            Text("Recommended")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(TutorialStageColor.cyan)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .overlay(Capsule().strokeBorder(TutorialStageColor.cyan.opacity(0.6)))
                        }
                    }
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(TutorialStageColor.quiet)
                        .fixedSize(horizontal: false, vertical: true)
                    if row == .functionKeys, picked {
                        functionKeyChips.padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private var functionKeyChips: some View {
        HStack(spacing: 5) {
            ForEach(HyprKey.functionKeys) { key in
                let picked = config.hyprKey == key
                Button { config.hyprKey = key } label: {
                    Text(key.displayName)
                        .font(.system(size: 10.5, weight: picked ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(picked ? TutorialStageColor.cyan : TutorialStageColor.quiet)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(TutorialStageColor.surface,
                                    in: RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                            .strokeBorder(picked ? TutorialStageColor.cyan.opacity(0.8) : .clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
    }

    // MARK: try it

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Try it")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TutorialStageColor.quiet)

            VStack(spacing: 10) {
                LessonKeycap.cap(label: config.hyprKey.displayName.uppercased(),
                                 glyph: glyph, held: watcher.held,
                                 size: CGSize(width: 240, height: 84))
                Text(watcher.held ? "Held" : watcher.heldOnce ? "Works. Let go." : "Hold \(config.hyprKey.displayName) to test it")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(watcher.held || watcher.heldOnce ? TutorialStageColor.cyan : TutorialStageColor.faint)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 18)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(config.hyprKey.displayName), \(watcher.held ? "held" : "not held")")

            if config.hyprKey == .capsLock {
                Rectangle().fill(TutorialStageColor.line).frame(height: 1).padding(.vertical, 16)
                doubleTapRow
            }

            Rectangle().fill(TutorialStageColor.line).frame(height: 1).padding(.vertical, 16)
            examples

            Spacer(minLength: 0)

            if let guidance = HyprKeySystemGuidance.forKey(config.hyprKey) {
                modifierKeysHelp(guidance).padding(.top, 16)
            }
        }
        .padding(16)
        .frame(width: 356)
        .frame(maxHeight: .infinity, alignment: .top)
        .tutorialGlass(cornerRadius: 14)
    }

    // three real binds, drawn with the picked key
    private var examples: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Your shortcuts will look like")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TutorialStageColor.text)
            ForEach(Array(exampleBinds.enumerated()), id: \.offset) { _, example in
                HStack {
                    Text(example.0)
                        .font(.system(size: 11.5))
                        .foregroundStyle(TutorialStageColor.quiet)
                    Spacer(minLength: 8)
                    StageChord(bind: example.1, hyprKey: config.hyprKey)
                }
            }
        }
    }

    private var exampleBinds: [(String, Keybind)] {
        let wanted: [(String, (Action) -> Bool)] = [
            ("Focus the window to the left", { if case .focusDirection(.left) = $0 { return true }; return false }),
            ("Float or tile a window", { $0 == .toggleFloating }),
            ("List every key", { $0 == .showKeybinds }),
        ]
        return wanted.compactMap { label, match in
            config.keybinds.first { match($0.action) }.map { (label, $0) }
        }
    }

    private var glyph: String? {
        let badge = config.hyprKey.badgeLabel
        return badge.lowercased() == config.hyprKey.displayName.lowercased() ? nil : badge
    }

    private var doubleTapRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Double-tap Caps Lock for capitals")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TutorialStageColor.text)
                Text("Two quick taps turn Caps Lock on or off. Not in password fields, where macOS hides keys.")
                    .font(.system(size: 11))
                    .foregroundStyle(TutorialStageColor.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                ForEach([("On", true), ("Off", false)], id: \.0) { option in
                    let picked = config.doubleTapHyprTogglesCapsLock == option.1
                    Button { config.doubleTapHyprTogglesCapsLock = option.1 } label: {
                        Text(option.0)
                            .font(.system(size: 11.5, weight: picked ? .semibold : .regular))
                            .foregroundStyle(picked ? TutorialStageColor.cyan : TutorialStageColor.quiet)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(TutorialStageColor.surface,
                                        in: RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                                .strokeBorder(picked ? TutorialStageColor.cyan.opacity(0.8) : .clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }
        }
    }

    private func modifierKeysHelp(_ guidance: HyprKeySystemGuidance) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Holding it does nothing? \(guidance.title)")
                .font(.system(size: 11))
                .foregroundStyle(TutorialStageColor.quiet)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Modifier Keys") { HyprKeySystemGuidance.openKeyboardSettings() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(TutorialStageColor.cyan)
                .help(guidance.detail)
        }
    }
}
