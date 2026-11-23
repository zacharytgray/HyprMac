// Full-screen tutorial shell: a navy stage with the lesson rail on top and
// skip / next at the bottom. One lesson at a time sits in the middle.

import SwiftUI

// MARK: - lessons

/// The tutorial's steps in order. Access is the permission gate; the rest
/// are lessons the user does on real keys.
enum TutorialLesson: Int, CaseIterable {
    case access, hyprKey, focus, move, workspaces, floatOrTile, cycleFloaters, fixWindow, allKeys, pause

    var railLabel: String {
        switch self {
        case .access: return "Access"
        case .hyprKey: return "Hypr key"
        case .focus: return "Focus"
        case .move: return "Move windows"
        case .workspaces: return "Workspaces"
        case .floatOrTile: return "Float or tile"
        case .cycleFloaters: return "Cycle floaters"
        case .fixWindow: return "Fix a window"
        case .allKeys: return "All keys"
        case .pause: return "Pause"
        }
    }

    var next: TutorialLesson? { TutorialLesson(rawValue: rawValue + 1) }
}

// MARK: - stage colors

/// The stage is navy in both appearances, like the showreel's desktop. Its
/// own text and accents are fixed to the dark-mode brand values; cards on it
/// follow the system appearance.
enum TutorialStageColor {
    static let navyTop = Color(red: 0x0A/255, green: 0x10/255, blue: 0x24/255)
    static let navyBottom = Color(red: 0x13/255, green: 0x1B/255, blue: 0x3A/255)
    static let cyan = Color(red: 0x56/255, green: 0xD8/255, blue: 0xF0/255)
    static let magenta = Color(red: 0xE8/255, green: 0x4B/255, blue: 0xCB/255)
    static let text = Color.white
    static let quiet = Color.white.opacity(0.62)
    static let faint = Color.white.opacity(0.38)
    static let line = Color.white.opacity(0.10)
}

// MARK: - shell

struct TutorialStage<Content: View>: View {
    let lesson: TutorialLesson
    let completed: Set<TutorialLesson>
    /// e.g. "1 of 3 done"; nil hides it
    let progress: String?
    let canContinue: Bool
    let onSkipTutorial: () -> Void
    let onSkipLesson: () -> Void
    let onNext: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottomBar
        }
        .background(backdrop)
    }

    // navy with a faint cyan and magenta glow in opposite corners
    private var backdrop: some View {
        ZStack {
            LinearGradient(colors: [TutorialStageColor.navyTop, TutorialStageColor.navyBottom],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [TutorialStageColor.cyan.opacity(0.16), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 700)
            RadialGradient(colors: [TutorialStageColor.magenta.opacity(0.14), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 760)
        }
        .ignoresSafeArea()
    }

    // MARK: top: lockup · lesson rail · lesson count

    private var topBar: some View {
        HStack(spacing: 24) {
            HyprLockup(markSize: 20)
                .environment(\.colorScheme, .dark)
                .foregroundStyle(TutorialStageColor.text)
            Spacer(minLength: 0)
            rail
            Spacer(minLength: 0)
            Text("Lesson \(lesson.rawValue) of \(TutorialLesson.allCases.count - 1)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(TutorialStageColor.faint)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(TutorialStageColor.line).frame(height: 1)
        }
    }

    // the current lesson gets an inset accent bar, a colored icon and
    // heavier text, never a filled chip
    private var rail: some View {
        HStack(spacing: 18) {
            ForEach(TutorialLesson.allCases, id: \.self) { step in
                let current = step == lesson
                let done = completed.contains(step)
                VStack(spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: done ? "checkmark.circle.fill"
                              : current ? "circle.inset.filled" : "circle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(done || current ? TutorialStageColor.cyan : TutorialStageColor.faint)
                        Text(step.railLabel)
                            .font(.system(size: 11.5, weight: current ? .semibold : .regular))
                            .foregroundStyle(current ? TutorialStageColor.text
                                             : done ? TutorialStageColor.quiet : TutorialStageColor.faint)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(current ? TutorialStageColor.cyan : .clear)
                        .frame(height: 3)
                }
                // the bar matches the label; without this each step stretches
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(step.railLabel), \(done ? "done" : current ? "current lesson" : "not started")")
            }
        }
    }

    // MARK: bottom: skip tutorial · progress · skip lesson · next

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Button(action: onSkipTutorial) {
                HStack(spacing: 6) {
                    Text("Skip Tutorial")
                    StageKeyHint("esc")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(TutorialStageColor.quiet)
            .keyboardShortcut(.cancelAction)

            Spacer()

            if let progress {
                Text(progress)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(canContinue ? TutorialStageColor.cyan : TutorialStageColor.faint)
            }
            if !canContinue {
                Button("Skip Lesson", action: onSkipLesson)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(TutorialStageColor.quiet)
            }
            StagePrimaryButton(nextTitle, enabled: canContinue, action: onNext)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .overlay(alignment: .top) {
            Rectangle().fill(TutorialStageColor.line).frame(height: 1)
        }
    }

    private var nextTitle: String {
        guard let next = lesson.next else { return "Finish Tutorial" }
        return "Next: \(next.railLabel)"
    }
}

// MARK: - stage controls

/// Cyan filled button with dark text, dimmed while the lesson isn't done.
struct StagePrimaryButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .font(.system(size: 12.5, weight: .semibold))
            // not done yet: an outline with quiet text, so it can't read as pressable
            .foregroundStyle(enabled ? TutorialStageColor.navyTop : TutorialStageColor.faint)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.md + 1, style: .continuous)
                    .fill(enabled ? TutorialStageColor.cyan : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HyprRadius.md + 1, style: .continuous)
                    .strokeBorder(enabled ? .clear : TutorialStageColor.faint, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(.defaultAction)
    }
}

/// A small key label on the stage, like the overlay footers' hints.
struct StageKeyHint: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(TutorialStageColor.quiet)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                    .strokeBorder(TutorialStageColor.faint, lineWidth: 1)
            )
    }
}

// MARK: - window

/// One borderless window over the whole screen under the pointer, above
/// passive chrome like the old tour. HyprMac never tiles its own windows.
final class TutorialWindowController {
    private var window: NSWindow?

    private final class StageWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    func show<V: View>(_ view: V) {
        dismiss()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        let win = StageWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentViewController = NSHostingController(rootView: view)
        win.setFrame(frame, display: true)
        win.level = Constants.interfaceWindowLevel
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.fullScreenAuxiliary]
        win.title = "HyprMac Tutorial"
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // hover focus must not reach through the stage
        OwnPanelTracker.shared.track(win)
        window = win
    }

    func dismiss() {
        window?.close()
        window = nil
    }
}
