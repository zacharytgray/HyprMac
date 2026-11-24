// Onboarding's last step: a few choices that shape how HyprMac feels, with
// a small drawn desktop that shows each one. Every choice writes the key
// Settings uses. It ends on taking the tutorial or skipping it for now.

import SwiftUI

// MARK: - focus indicator

/// The four looks Settings' focus indicator offers, over its two keys.
enum FocusIndicatorChoice: CaseIterable {
    case corners, border, cornersAndBorders, none

    var title: String {
        switch self {
        case .corners: return "Corners"
        case .border: return "Border"
        case .cornersAndBorders: return "Corners and borders"
        case .none: return "None"
        }
    }

    var hasCorners: Bool { self == .corners || self == .cornersAndBorders }
    var hasBorder: Bool { self == .border || self == .cornersAndBorders }

    init(bracketStyle: FocusBracketStyle, showBorder: Bool) {
        switch (bracketStyle, showBorder) {
        case (.rounded, false): self = .corners
        case (.off, true): self = .border
        case (.rounded, true): self = .cornersAndBorders
        case (.off, false): self = .none
        }
    }

    func apply(to config: UserConfig) {
        config.focusBracketStyle = hasCorners ? .rounded : .off
        config.showFocusBorder = hasBorder
    }
}

// MARK: - view

struct MakeItYoursView: View {
    @ObservedObject var config: UserConfig = .shared
    @AppStorage(UserConfig.menuBarStyleKey) private var menuBarStyle: MenuBarStyle = .full
    @StateObject private var loginItem = LoginItemController()
    var completed: Set<OnboardingStep> = [.access, .hyprKey]
    /// nil when there's no step to go back to
    var onBack: (() -> Void)? = nil
    let onSkipTutorial: () -> Void
    let onTakeTutorial: () -> Void

    var body: some View {
        TutorialStage(
            step: OnboardingStep.makeItYours,
            completed: completed,
            counter: OnboardingStep.makeItYours.counterLabel,
            note: "Later: menu bar → Tutorial, Hypr+K, or Settings → General",
            canContinue: true,
            exit: onBack.map { StageAction(title: "Back", action: $0) },
            secondary: StageAction(title: "Skip for Now", action: onSkipTutorial),
            next: StageAction(title: "Take the Tutorial (about 6 min)", action: onTakeTutorial)
        ) {
            VStack(spacing: 0) {
                Text("Make it yours")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(TutorialStageColor.text)
                Text("Pick how HyprMac looks and feels. The preview shows each choice, and Settings has them all later.")
                    .font(.system(size: 14))
                    .foregroundStyle(TutorialStageColor.quiet)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)

                HStack(alignment: .top, spacing: 24) {
                    choices
                        .frame(width: 470)
                    MiniDesktopPreview(focusFollowsMouse: config.focusFollowsMouse,
                                       indicator: indicator,
                                       dim: config.dimInactiveWindows,
                                       menuBar: menuBarStyle)
                }
                // the preview matches the choices' height
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 34)
            }
            .frame(width: 900)
        }
        .onAppear { loginItem.refresh() }
    }

    private var indicator: FocusIndicatorChoice {
        FocusIndicatorChoice(bracketStyle: config.focusBracketStyle, showBorder: config.showFocusBorder)
    }

    // MARK: choices

    private var choices: some View {
        VStack(alignment: .leading, spacing: 0) {
            choiceRow("Focus follows the mouse",
                      detail: "Pointing at a window focuses it. Off, you click to focus.") {
                segmented([("On", true), ("Off", false)], selection: config.focusFollowsMouse) {
                    config.focusFollowsMouse = $0
                }
            }
            divider
            choiceRow("Show the focused window with",
                      detail: "Marks on the window your keys go to.") {
                segmented(FocusIndicatorChoice.allCases.map { ($0.title, $0) }, selection: indicator) {
                    $0.apply(to: config)
                }
            }
            divider
            choiceRow("Dim other windows",
                      detail: "Windows you're not using fade a little.") {
                segmented([("On", true), ("Off", false)], selection: config.dimInactiveWindows) {
                    config.dimInactiveWindows = $0
                }
            }
            divider
            choiceRow("Menu bar",
                      detail: "Full shows every workspace in use. Compact shows only the current one.") {
                segmented([("Full", MenuBarStyle.full), ("Compact", MenuBarStyle.compact)],
                          selection: menuBarStyle) { menuBarStyle = $0 }
            }
            divider
            choiceRow("Launch at login",
                      detail: loginItem.instructionText ?? "HyprMac starts when you sign in, so your keys are ready.") {
                loginControl
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .tutorialGlass(cornerRadius: 14)
    }

    private var divider: some View {
        Rectangle().fill(TutorialStageColor.line).frame(height: 1)
    }

    private func choiceRow<Control: View>(_ title: String, detail: String,
                                          @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TutorialStageColor.text)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(TutorialStageColor.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            control()
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    /// Chips in a row; the picked one gets cyan text and a cyan outline,
    /// never a fill.
    private func segmented<Value: Equatable>(_ options: [(String, Value)], selection: Value,
                                             pick: @escaping (Value) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let picked = option.1 == selection
                Button { pick(option.1) } label: {
                    Text(option.0)
                        .font(.system(size: 11.5, weight: picked ? .semibold : .regular))
                        .foregroundStyle(picked ? TutorialStageColor.cyan : TutorialStageColor.quiet)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(TutorialStageColor.surface,
                                    in: RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                                .strokeBorder(picked ? TutorialStageColor.cyan.opacity(0.8) : .clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
    }

    // macOS has no off switch from an app, so this is On with Manage, the
    // same as Settings
    @ViewBuilder
    private var loginControl: some View {
        switch loginItem.state {
        case .enabled:
            HStack(spacing: 10) {
                Label("On", systemImage: "checkmark")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(TutorialStageColor.cyan)
                StageQuietButton("Manage in Login Items") { loginItem.openLoginItems() }
            }
        case .requiresApproval, .failed:
            StageSecondaryButton("Open Login Items") { loginItem.openLoginItems() }
        case .notEnabled:
            StageSecondaryButton("Turn On Launch at Login") { loginItem.enable() }
        }
    }
}

// MARK: - preview

/// A small drawn desktop: a menu bar and three tiles. The big tile is
/// focused, or, with focus following the mouse, the tile under the pointer.
struct MiniDesktopPreview: View {
    let focusFollowsMouse: Bool
    let indicator: FocusIndicatorChoice
    let dim: Bool
    let menuBar: MenuBarStyle

    private let gap: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TutorialStageColor.quiet)
            screen
            Text(focusFollowsMouse ? "The pointer is over window 2, so window 2 has focus."
                 : "The pointer is over window 2, but window 1 keeps focus until you click.")
                .font(.system(size: 11))
                .foregroundStyle(TutorialStageColor.quiet)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 406)
        .frame(maxHeight: .infinity, alignment: .top)
        .tutorialGlass(cornerRadius: 14)
        .accessibilityElement(children: .combine)
    }

    private var focused: Int { focusFollowsMouse ? 2 : 1 }

    private var screen: some View {
        VStack(spacing: 0) {
            menuBarStrip
            GeometryReader { geo in
                let w = geo.size.width - gap * 3
                let h = geo.size.height - gap * 2
                ZStack(alignment: .topLeading) {
                    tile(1, CGRect(x: gap, y: gap, width: w * 0.55, height: h))
                    tile(2, CGRect(x: gap * 2 + w * 0.55, y: gap, width: w * 0.45, height: (h - gap) / 2))
                    tile(3, CGRect(x: gap * 2 + w * 0.55, y: gap * 2 + (h - gap) / 2,
                                   width: w * 0.45, height: (h - gap) / 2))
                    pointer
                        .position(x: gap * 2 + w * 0.55 + w * 0.3, y: gap + (h - gap) * 0.32)
                }
            }
        }
        .frame(minHeight: 230, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Color(red: 0.10, green: 0.16, blue: 0.32), Color(red: 0.20, green: 0.12, blue: 0.30)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(TutorialStageColor.line))
    }

    // the HyprMac item on the right, Full or Compact
    private var menuBarStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "apple.logo").font(.system(size: 8))
            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.25)).frame(width: 34, height: 4)
            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.18)).frame(width: 22, height: 4)
            Spacer()
            Text(menuBar == .full
                 ? "\(HyprGlyph.workspaceShown) \(HyprGlyph.workspaceWaiting) \(HyprGlyph.workspaceWaiting)"
                 : "1")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(TutorialStageColor.text)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.white.opacity(menuBar == .full ? 0 : 0.18),
                            in: RoundedRectangle(cornerRadius: 3))
        }
        .foregroundStyle(Color.white.opacity(0.7))
        .padding(.horizontal, 8)
        .frame(height: 18)
        .background(Color.black.opacity(0.35))
    }

    private func tile(_ number: Int, _ frame: CGRect) -> some View {
        let isFocused = number == focused
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return ZStack {
            shape.fill(Color(red: 0.86, green: 0.88, blue: 0.93))
            VStack(spacing: 0) {
                HStack(spacing: 3) {
                    ForEach([Color.red, .yellow, .green], id: \.self) {
                        Circle().fill($0.opacity(0.8)).frame(width: 5, height: 5)
                    }
                    Spacer()
                }
                .padding(5)
                Spacer()
                Text("\(number)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.45))
                Spacer()
            }
            if dim && !isFocused {
                shape.fill(Color.black.opacity(0.32))
            }
            if isFocused && indicator.hasBorder {
                shape.strokeBorder(TutorialStageColor.cyan, lineWidth: 2)
            }
            if isFocused && indicator.hasCorners {
                CornerMarks().stroke(Color.black, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .overlay(CornerMarks().stroke(Color.white, style: StrokeStyle(lineWidth: 1, lineCap: .round)))
                    .padding(-3)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.minX, y: frame.minY)
        .animation(HyprMotion.snap, value: isFocused)
    }

    private var pointer: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(.black)
            .shadow(color: .white, radius: 0.5)
    }

    /// Four short L shapes at the corners, like HyprMac's focus brackets.
    private struct CornerMarks: Shape {
        func path(in rect: CGRect) -> Path {
            let l: CGFloat = 10
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.minY + l)); p.addLine(to: rect.origin)
            p.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
            p.move(to: CGPoint(x: rect.maxX - l, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
            p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
            p.move(to: CGPoint(x: rect.minX + l, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
            return p
        }
    }
}
