// Onboarding's last step: a few choices that shape how HyprMac feels, with
// a small drawn desktop that shows each one. Every choice writes the key
// Settings uses, at once, except Keep floating windows in front, which
// writes when the step ends so macOS asks for Screen Recording only then.
// It ends on taking the tutorial or skipping it for now.

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
    /// the session's pick, written to the config when the step ends
    var keepFloatersInFront: Binding<Bool> = .constant(true)
    /// nil when there's no step to go back to
    var onBack: (() -> Void)? = nil
    let onSkipTutorial: () -> Void
    let onTakeTutorial: () -> Void

    var body: some View {
        TutorialStage(
            step: OnboardingStep.makeItYours,
            completed: completed,
            counter: OnboardingStep.makeItYours.counterLabel,
            note: "Later: menu bar → Tutorial, \(config.hyprKey.displayName)+K, or Settings → General",
            canContinue: true,
            exit: onBack.map { StageAction(title: "Back", action: $0) },
            secondary: StageAction(title: "Skip for Now", action: onSkipTutorial),
            next: StageAction(title: "Take the Tutorial (about 5 min)", action: onTakeTutorial)
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
                                       menuBar: menuBarStyle,
                                       floaterInFront: keepFloatersInFront.wrappedValue)
                }
                // the preview matches the choices' height
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 26)
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
            choiceRow("Keep floating windows in front", tag: "Recommended",
                      detail: "Floating windows stay in front of your tiles. Off, they can slip behind the window you're working in.") {
                VStack(alignment: .leading, spacing: 7) {
                    segmented([("On", true), ("Off", false)], selection: keepFloatersInFront.wrappedValue) {
                        keepFloatersInFront.wrappedValue = $0
                    }
                    if keepFloatersInFront.wrappedValue {
                        Label("Needs Screen Recording, because macOS has no other way to do this. HyprMac shows a live picture of a covered floating window and never saves it. macOS asks when you continue.",
                              systemImage: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(TutorialStageColor.cyan)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            divider
            choiceRow("Menu bar",
                      detail: "Full shows every workspace in use. Compact shows only the current one.") {
                VStack(alignment: .leading, spacing: 7) {
                    segmented([("Full", MenuBarStyle.full), ("Compact", MenuBarStyle.compact),
                               ("Hidden", MenuBarStyle.hidden)],
                              selection: menuBarStyle) { menuBarStyle = $0 }
                    if menuBarStyle == .hidden {
                        // what the app really offers with no menu bar item
                        Label("Without it, open HyprMac again from Spotlight or Applications to get Settings. \(config.hyprKey.displayName)+K has the tutorial.",
                              systemImage: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(TutorialStageColor.cyan)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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

    private func choiceRow<Control: View>(_ title: String, tag: String? = nil, detail: String,
                                          @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TutorialStageColor.text)
                    if let tag {
                        Text(tag)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(TutorialStageColor.cyan)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .overlay(Capsule().strokeBorder(TutorialStageColor.cyan.opacity(0.6)))
                    }
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(TutorialStageColor.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            control()
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tag.map { "\(title), \($0)" } ?? title)
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

// MARK: - screen recording

/// Make it yours ended with Keep floating windows in front on and Screen
/// Recording not usable yet. macOS asked as the step ended; this shows the
/// grant, then a reopen when the running copy can't see it. Going on
/// without it keeps the switch on, with the icon-and-title card.
struct ScreenRecordingStepView: View {
    @ObservedObject var access: ScreenRecordingAccess
    var completed: Set<OnboardingStep> = [.access, .hyprKey]
    let takeTutorial: Bool
    let onBack: () -> Void
    let onContinue: () -> Void

    private var state: ScreenRecordingAccess.State { access.state ?? .notGranted }

    var body: some View {
        TutorialStage(
            step: OnboardingStep.makeItYours,
            completed: completed,
            counter: OnboardingStep.makeItYours.counterLabel,
            note: state == .granted ? nil : "Settings → Tiling has this later",
            canContinue: state != .notGranted,
            exit: StageAction(title: "Back", action: onBack),
            secondary: state == .granted ? nil : StageAction(title: "Continue Without It", action: onContinue),
            next: next
        ) {
            VStack(spacing: 0) {
                Text("One more step: Screen Recording")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(TutorialStageColor.text)
                Text("Keeping floating windows in front needs Screen Recording, because macOS has no other way to do this. HyprMac shows a live picture of a covered floating window. It never saves that picture or sends it anywhere.")
                    .font(.system(size: 14))
                    .foregroundStyle(TutorialStageColor.quiet)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                TutorialTaskCard(tasks: tasks)
                    .padding(.top, 34)

                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(TutorialStageColor.faint)
                        .accessibilityHidden(true)
                    Text("Without it, a covered floating window shows its app icon and title instead. Turn the switch off in Settings → Tiling to keep the old behavior.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(TutorialStageColor.quiet)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
                .padding(.top, 14)
            }
            .frame(width: 560)
        }
        .onAppear { access.startWatching() }
        .onDisappear { access.stopWatching() }
    }

    private var finishTitle: String { takeTutorial ? "Take the Tutorial (about 5 min)" : "Done" }

    private var next: StageAction {
        switch state {
        case .granted: return StageAction(title: finishTitle, action: onContinue)
        case .needsReopen: return StageAction(title: "Reopen HyprMac", action: { access.reopen() })
        case .notGranted: return StageAction(title: "Reopen HyprMac", action: {})
        }
    }

    private var tasks: [TutorialTask] {
        [
            TutorialTask(title: "Turn on HyprMac in Screen Recording",
                         detail: "macOS asked just now. Choose Open System Settings and turn on HyprMac. Missed it? Open the list here.",
                         done: state != .notGranted,
                         trailing: state == .notGranted
                            ? AnyView(StageSecondaryButton("Open Screen Recording") { access.openSettings() })
                            : nil),
            TutorialTask(title: "Reopen HyprMac",
                         detail: takeTutorial
                            ? "HyprMac can use it after a reopen. Your windows stay put, and the tutorial opens again."
                            : "HyprMac can use it after a reopen. Your windows stay put.",
                         done: state == .granted),
        ]
    }
}

// MARK: - preview

/// A small drawn desktop: a menu bar, three tiles and a floating window,
/// at half size. The marks, border, window corners, dim, gaps and floating
/// outline come from the same code and config values HyprMac draws the
/// real ones with, scaled. The big tile is focused, or, with focus
/// following the mouse, the tile under the pointer. The floating window
/// sits in front of the tiles, or behind the focused one without the switch.
struct MiniDesktopPreview: View {
    @ObservedObject var config: UserConfig = .shared
    let focusFollowsMouse: Bool
    let indicator: FocusIndicatorChoice
    let dim: Bool
    let menuBar: MenuBarStyle
    let floaterInFront: Bool

    /// the preview is a half-size screen
    private let scale: CGFloat = 0.5

    init(config: UserConfig = .shared, focusFollowsMouse: Bool, indicator: FocusIndicatorChoice,
         dim: Bool, menuBar: MenuBarStyle, floaterInFront: Bool = true) {
        self.config = config
        self.focusFollowsMouse = focusFollowsMouse
        self.indicator = indicator
        self.dim = dim
        self.menuBar = menuBar
        self.floaterInFront = floaterInFront
    }

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
            Text(floaterInFront ? "The floating window stays in front of the tiles."
                 : "The floating window slipped behind window \(focused), the one with focus.")
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
    private var gap: CGFloat { config.gapSize * scale }
    private var padding: CGFloat { config.outerPadding * scale }
    private var windowRadius: CGFloat { config.windowCornerRadius * scale }

    private var screen: some View {
        VStack(spacing: 0) {
            menuBarStrip
            GeometryReader { geo in
                let w = geo.size.width - padding * 2 - gap
                let h = geo.size.height - padding * 2
                let rightX = padding + w * 0.55 + gap
                let halfH = (h - gap) / 2
                ZStack(alignment: .topLeading) {
                    tile(1, CGRect(x: padding, y: padding, width: w * 0.55, height: h))
                        .zIndex(focused == 1 ? 2 : 0)
                    tile(2, CGRect(x: rightX, y: padding, width: w * 0.45, height: halfH))
                        .zIndex(focused == 2 ? 2 : 0)
                    tile(3, CGRect(x: rightX, y: padding + halfH + gap, width: w * 0.45, height: halfH))
                    // across the line between windows 1 and 2, clear of the pointer
                    floater(CGRect(x: rightX - 78, y: padding + halfH * 0.1, width: 128, height: halfH * 0.5))
                        .zIndex(floaterInFront ? 3 : 1)
                    pointer
                        .zIndex(4)
                        .position(x: rightX + w * 0.3, y: padding + halfH * 0.62)
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

    // HyprMac's item as the real menu bar draws it: the workspace glyphs,
    // or the compact numbered square
    private var menuBarStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "apple.logo").font(.system(size: 8))
            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.25)).frame(width: 34, height: 4)
            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.18)).frame(width: 22, height: 4)
            Spacer()
            Group {
                if menuBar == .hidden {
                    EmptyView()
                } else if menuBar == .compact {
                    Image(systemName: "1.square").font(.system(size: 10, weight: .medium))
                } else {
                    Text(MenuBarPresentation.workspaceGlyphs(active: [1], occupied: [1, 2], floating: []))
                        .font(.system(size: 9, weight: .medium))
                }
            }
            .foregroundStyle(TutorialStageColor.text)
        }
        .foregroundStyle(Color.white.opacity(0.7))
        .padding(.horizontal, 8)
        .frame(height: 18)
        .background(Color.black.opacity(0.35))
    }

    private func tile(_ number: Int, _ frame: CGRect) -> some View {
        let isFocused = number == focused
        let shape = RoundedRectangle(cornerRadius: windowRadius, style: .continuous)
        let markColor = config.resolvedFocusBracketColor
        return ZStack {
            shape.fill(Color(red: 0.86, green: 0.88, blue: 0.93))
            VStack(spacing: 0) {
                HStack(spacing: 3) {
                    ForEach([Color.red, .yellow, .green], id: \.self) {
                        Circle().fill($0.opacity(0.8)).frame(width: 5, height: 5)
                    }
                    Spacer()
                }
                .padding(.leading, max(5, windowRadius * 0.7))
                .padding(.top, 5)
                Spacer()
                Text("\(number)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.45))
                Spacer()
            }
            if dim && !isFocused {
                shape.fill(Color.black.opacity(config.dimIntensity))
            }
            if isFocused && indicator.hasBorder {
                shape.strokeBorder(Color(nsColor: config.resolvedFocusBorderColor),
                                   lineWidth: max(1, FocusBorder.settledBorderWidth * scale))
            }
            if isFocused && indicator.hasCorners {
                let marks = FocusMarksShape(inset: CornerMarkGeometry.focusMarkInset * scale,
                                            radius: config.resolvedFocusBracketRadius * scale,
                                            length: config.resolvedFocusBracketLength * scale)
                let thickness = config.resolvedFocusBracketThickness * scale
                marks
                    .stroke(Color(cgColor: FocusBrackets.contrastOutlineColor(for: markColor.cgColor)),
                            style: StrokeStyle(lineWidth: thickness + 1, lineCap: .round, lineJoin: .round))
                    .overlay(marks.stroke(Color(nsColor: markColor),
                                          style: StrokeStyle(lineWidth: thickness, lineCap: .round, lineJoin: .round)))
            }
        }
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.minX, y: frame.minY)
        .animation(HyprMotion.snap, value: isFocused)
    }

    // a small window with the floating outline
    private func floater(_ frame: CGRect) -> some View {
        let shape = RoundedRectangle(cornerRadius: windowRadius, style: .continuous)
        return ZStack {
            shape.fill(Color(red: 0.95, green: 0.95, blue: 0.97))
            VStack(spacing: 0) {
                HStack(spacing: 3) {
                    ForEach([Color.red, .yellow, .green], id: \.self) {
                        Circle().fill($0.opacity(0.8)).frame(width: 5, height: 5)
                    }
                    Spacer()
                }
                .padding(.leading, max(5, windowRadius * 0.7))
                .padding(.top, 5)
                Spacer()
                Text("Floating")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.5))
                Spacer()
            }
            shape.strokeBorder(Color(nsColor: config.resolvedFloatingBorderColor), lineWidth: 1)
        }
        .frame(width: frame.width, height: frame.height)
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        .offset(x: frame.minX, y: frame.minY)
        .animation(HyprMotion.snap, value: floaterInFront)
    }

    private var pointer: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(.black)
            .shadow(color: .white, radius: 0.5)
    }
}

/// The Hypr-key focus marks, built by the same `CornerMarkGeometry` the
/// real marks use. Its corners are symmetric, so the y flip between AppKit
/// and SwiftUI only swaps which path is which.
struct FocusMarksShape: Shape {
    let inset: CGFloat
    let radius: CGFloat
    let length: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for corner in CornerMarkGeometry.paths(in: rect, inset: inset, radius: radius, legLength: length) {
            path.addPath(Path(corner))
        }
        return path
    }
}
