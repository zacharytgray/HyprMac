import XCTest
import SwiftUI
import Carbon
@testable import HyprMac

// renders the settings, tour, gate, menu and keybind overlay views offscreen
// into 2x pngs. opt-in: set HYPRMAC_RENDER_UI to an output directory. needs
// the isolated home from scripts/test-isolated.sh because it flips the saved
// hypr key.
@MainActor
final class InterfaceSnapshotTests: XCTestCase {
    private var outputDir: URL!
    private var savedHyprKey: HyprKey!
    private var savedKeybinds: [Keybind] = []

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["HYPRMAC_RENDER_UI"], !dir.isEmpty else {
            throw XCTSkip("set HYPRMAC_RENDER_UI to an output directory to render ui snapshots")
        }
        guard env["HYPRMAC_HEADLESS_TESTS"] == "1" else {
            throw XCTSkip("requires isolated config")
        }
        outputDir = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        savedHyprKey = UserConfig.shared.hyprKey
        savedKeybinds = UserConfig.shared.keybinds
        UserConfig.shared.keybinds = Keybind.defaults
    }

    override func tearDown() async throws {
        guard outputDir != nil else { return }
        UserConfig.shared.hyprKey = savedHyprKey
        UserConfig.shared.keybinds = savedKeybinds
    }

    // the Keys card for each kind of saved Hypr key: notes and guidance
    func testRenderHyprKeyVariants() throws {
        UserConfig.shared.hyprKey = .tab
        try render("keys-tab-dark", tab(KeybindsSettingsView()))

        // tab above and these two are no longer offered: the note shows, plus
        // Modifier Keys guidance where the pane can remap the key
        UserConfig.shared.hyprKey = .rightShift
        try render("keys-rightshift-dark", tab(KeybindsSettingsView()))
        UserConfig.shared.hyprKey = .leftControl
        try render("keys-leftcontrol-dark", tab(KeybindsSettingsView()))

        // left-hand modifier: the use-the-right-key note plus guidance
        UserConfig.shared.hyprKey = .leftCommand
        try render("keys-leftcommand-dark", tab(KeybindsSettingsView()))
    }

    // every section in the window and full height, dark and light
    func testRenderSettingsRedesign() throws {
        UserConfig.shared.hyprKey = .capsLock
        for section in SettingsSection.allCases {
            for dark in [true, false] {
                let mode = dark ? "dark" : "light"
                try render("redesign-window-\(section.rawValue)-\(mode)",
                           SettingsView(showTutorial: {}, initialSection: section),
                           size: CGSize(width: 780, height: 760), dark: dark)
                try render("redesign-\(section.rawValue)-\(mode)",
                           tab(SettingsSectionContent(section: section, showTutorial: {})), dark: dark)
            }
        }
        for dark in [true, false] {
            let mode = dark ? "dark" : "light"
            try render("redesign-search-\(mode)", SettingsView(showTutorial: {}, initialSearch: "dock"),
                       size: CGSize(width: 780, height: 600), dark: dark)
            try render("redesign-managed-updates-\(mode)", tab(ManagedUpdatesPanel(nixInstall: true)), dark: dark)
        }
        // names and a pin, so the filled rows show too
        let namesWere = UserConfig.shared.workspaceNames
        let pinsWere = UserConfig.shared.windowRules
        UserConfig.shared.workspaceNames = ["1": "web", "2": "code", "9": "music"]
        UserConfig.shared.windowRules = [WindowRule(bundleID: "com.apple.Safari", workspace: 1),
                                         WindowRule(bundleID: "com.apple.Music", workspace: WindowRule.scratchpad)]
        for dark in [true, false] {
            try render("redesign-workspaces-filled-\(dark ? "dark" : "light")",
                       tab(WorkspacesSettingsView()), dark: dark)
        }
        UserConfig.shared.workspaceNames = namesWere
        UserConfig.shared.windowRules = pinsWere

        // corners and borders together show every appearance row
        let cornersWere = UserConfig.shared.focusBracketStyle != .off
        let bordersWere = UserConfig.shared.showFocusBorder
        UserConfig.shared.setFocusIndicators(showCorners: true, showBorders: true)
        for dark in [true, false] {
            try render("redesign-appearance-both-\(dark ? "dark" : "light")",
                       tab(AppearanceSettingsView()), dark: dark)
        }
        UserConfig.shared.setFocusIndicators(showCorners: cornersWere, showBorders: bordersWere)

        // the export's command field shows only while the export is on
        let exportWas = UserConfig.shared.statusExportEnabled
        let hookWas = UserConfig.shared.statusHookCommand
        UserConfig.shared.statusExportEnabled = true
        UserConfig.shared.statusHookCommand = "sketchybar --trigger hyprmac_change"
        defer {
            UserConfig.shared.statusExportEnabled = exportWas
            UserConfig.shared.statusHookCommand = hookWas
        }
        for dark in [true, false] {
            try render("redesign-advanced-export-on-\(dark ? "dark" : "light")",
                       tab(AdvancedSettingsView()), dark: dark)
        }
    }

    func testRenderManagedUpdatesPanel() throws {
        try render("updates-managed-package-manager-dark", tab(ManagedUpdatesPanel(nixInstall: false)))
        try render("updates-managed-nix-dark", tab(ManagedUpdatesPanel(nixInstall: true)))
    }

    func testRenderWhatsNewAndMenu() throws {
        try render("whats-new-dark", WhatsNewView(onDismiss: {}),
                   size: CGSize(width: 520, height: 440))
        try render("whats-new-light", WhatsNewView(onDismiss: {}),
                   size: CGSize(width: 520, height: 440), dark: false)
        try render("accessibility-drag-helper-dark", AccessibilityDragHelperView(onClose: {}),
                   width: AccessibilityDragHelperPlacement.panelWidth)
        try render("accessibility-drag-helper-light", AccessibilityDragHelperView(onClose: {}),
                   width: AccessibilityDragHelperPlacement.panelWidth, dark: false)
        // the release variant builds the menu with a sparkle updater; the
        // debug variant has none, so only render it there
        #if HYPRMAC_DEBUG_VARIANT
        try render("menu-bar-dark", MenuBarView(appDelegate: AppDelegate()), width: 320)
        #endif
    }

    // the full-screen hypr key lesson at its three points, plus double-tap off
    func testRenderHyprKeyLesson() throws {
        UserConfig.shared.hyprKey = .capsLock
        let savedDoubleTap = UserConfig.shared.doubleTapHyprTogglesCapsLock
        defer { UserConfig.shared.doubleTapHyprTogglesCapsLock = savedDoubleTap }
        let size = CGSize(width: 1440, height: 900)
        func lesson(_ setup: (HyprKeyLessonModel) -> Void) -> some View {
            let model = HyprKeyLessonModel()
            setup(model)
            return HyprKeyLessonView(model: model, onExit: {}, onNext: {})
        }
        for dark in [true, false] {
            let mode = dark ? "dark" : "light"
            UserConfig.shared.doubleTapHyprTogglesCapsLock = true
            try render("tutorial-1-hypr-key-1-start-\(mode)", lesson { _ in }, size: size, dark: dark)
            try render("tutorial-1-hypr-key-2-held-\(mode)", lesson {
                $0.hyprHeld = true
                $0.heldOnce = true
            }, size: size, dark: dark)
            try render("tutorial-1-hypr-key-3-capitals-on-\(mode)", lesson {
                $0.heldOnce = true
                $0.capsLockOn = true
                $0.capsTurnedOn = true
            }, size: size, dark: dark)
            try render("tutorial-1-hypr-key-4-done-\(mode)", lesson {
                $0.heldOnce = true
                $0.capsTurnedOn = true
                $0.capsTurnedOff = true
            }, size: size, dark: dark)
            UserConfig.shared.doubleTapHyprTogglesCapsLock = false
            try render("tutorial-1-hypr-key-5-double-tap-off-\(mode)", lesson { $0.heldOnce = true },
                       size: size, dark: dark)
        }
    }

    // the full-screen access step: before Grant, waiting on the drag, granted
    func testRenderAccessStep() throws {
        let size = CGSize(width: 1440, height: 900)
        func step(granted: Bool, waiting: Bool) -> some View {
            let model = AccessStepModel(granted: granted)
            model.waiting = waiting
            return AccessStepView(model: model, onGrant: {}, onQuit: {}, onNext: {})
        }
        for dark in [true, false] {
            let mode = dark ? "dark" : "light"
            try render("onboarding-1-access-start-\(mode)", step(granted: false, waiting: false), size: size, dark: dark)
            try render("onboarding-1-access-waiting-\(mode)", step(granted: false, waiting: true), size: size, dark: dark)
            try render("onboarding-1-access-granted-\(mode)", step(granted: true, waiting: false), size: size, dark: dark)
            // a Mac that's set up but lost access: the step alone
            try render("access-only-start-\(mode)",
                       AccessStepView(model: AccessStepModel(granted: false), onGrant: {}, onQuit: {}, onNext: {},
                                      nextTitle: "Done", standalone: true),
                       size: size, dark: dark)
        }
        // dex157's drag panel, which shows under System Settings meanwhile
        try render("onboarding-1-access-drag-panel-dark", AccessibilityDragHelperView(onClose: {}),
                   width: AccessibilityDragHelperPlacement.panelWidth)
        try render("onboarding-1-access-drag-panel-light", AccessibilityDragHelperView(onClose: {}),
                   width: AccessibilityDragHelperPlacement.panelWidth, dark: false)
    }

    // lesson 2 as it looks on screen: the backdrop, three practice windows
    // tiled with the real gaps, marks and dim, and the lesson bar
    func testRenderMoveAroundLesson() throws {
        let savedKey = UserConfig.shared.hyprKey
        defer { UserConfig.shared.hyprKey = savedKey }
        let size = CGSize(width: 1440, height: 900)
        func scene(focused: Int, setup: (MoveAroundLessonModel) -> Void) -> some View {
            let model = MoveAroundLessonModel(practice: PracticeSession(host: nil))
            setup(model)
            return PracticeSceneMock(focused: focused) {
                MoveAroundLessonBar(model: model, onExit: {}, onNext: {})
            }
        }
        for dark in [true, false] {
            let mode = dark ? "dark" : "light"
            UserConfig.shared.hyprKey = .capsLock
            try render("tutorial-2-move-around-1-start-\(mode)", scene(focused: 1) { _ in }, size: size, dark: dark)
            try render("tutorial-2-move-around-2-focused-\(mode)", scene(focused: 2) {
                $0.focusedAway = true
            }, size: size, dark: dark)
            try render("tutorial-2-move-around-3-done-\(mode)", scene(focused: 1) {
                $0.focusedAway = true
                $0.focusedBack = true
                $0.swapped = true
            }, size: size, dark: dark)
            // the chips follow the picked key
            UserConfig.shared.hyprKey = .rightOption
            try render("tutorial-2-move-around-4-right-option-\(mode)", scene(focused: 1) { _ in },
                       size: size, dark: dark)
        }
    }

    // lessons 3 to 7 and the finish, at the start and done, on the mock
    // practice desktop
    func testRenderPracticeLessons() throws {
        let config = UserConfig.shared
        let saved = (config.hyprKey, config.enabled, config.focusFollowsMouse)
        defer { (config.hyprKey, config.enabled, config.focusFollowsMouse) = saved }
        config.hyprKey = .capsLock
        let size = CGSize(width: 1440, height: 900)
        let practice = PracticeSession(host: nil)
        practice.setWorkspacesForTesting(practice: 4, other: 5)
        for dark in [true, false] {
            let mode = dark ? "dark" : "light"
            func shot<Bar: View>(_ name: String, focused: Int = 1, tiled: [Int] = [1, 2, 3],
                                 floaters: [Int] = [], _ bar: Bar) throws {
                try render("tutorial-\(name)-\(mode)",
                           PracticeSceneMock(focused: focused, tiled: tiled, floaters: floaters) { bar },
                           size: size, dark: dark)
            }
            let workspaces = WorkspacesLessonModel(practice: practice)
            try shot("3-workspaces-1-start", WorkspacesLessonBar(model: workspaces, displayCount: 2, onExit: {}, onNext: {}))
            workspaces.wentAway = true; workspaces.cameBack = true; workspaces.sent = true
            try shot("3-workspaces-2-done", tiled: [1, 2],
                     WorkspacesLessonBar(model: workspaces, displayCount: 1, onExit: {}, onNext: {}))

            // no empty workspace: the line says why, Skip still works
            try render("tutorial-2-move-around-no-empty-workspace-\(mode)",
                       StageBackdrop().overlay(alignment: .bottom) {
                           LessonBar(lesson: .moveAround, why: "This lesson runs on practice windows, never on yours.",
                                     tasks: [], hyprKey: .capsLock, blocked: PracticeSession.needsEmptyWorkspace,
                                     onExit: {}, onNext: {})
                               .padding(16)
                       }, size: size, dark: dark)

            let floating = FloatingLessonModel(practice: practice)
            try shot("4-floating-1-start", tiled: [1, 2],
                     FloatingLessonBar(model: floating, onExit: {}, onNext: {}))
            floating.floatedTwo = true
            try shot("4-floating-2-floated", focused: 2, tiled: [], floaters: [1, 2],
                     FloatingLessonBar(model: floating, onExit: {}, onNext: {}))

            let fix = FixWindowLessonModel(practice: practice)
            try shot("5-fix-a-window-1-start", focused: 4, tiled: [1, 2], floaters: [4],
                     FixWindowLessonBar(model: fix, onExit: {}, onNext: {}))
            fix.openedRules = true; fix.fixed = true
            try shot("5-fix-a-window-2-done", focused: 4, tiled: [1, 2, 4],
                     FixWindowLessonBar(model: fix, onExit: {}, onNext: {}))

            config.focusFollowsMouse = true
            let keys = MenuBarAndKeysLessonModel(practice: practice)
            try shot("6-menu-bar-and-keys-1-start", tiled: [1, 2, 4],
                     MenuBarAndKeysLessonBar(model: keys, onExit: {}, onNext: {}))
            keys.jumped = true; keys.openedKeys = true
            try shot("6-menu-bar-and-keys-2-searching", tiled: [1, 2, 4],
                     MenuBarAndKeysLessonBar(model: keys, onExit: {}, onNext: {}))

            let pause = PauseLessonModel(practice: practice)
            try shot("7-pause-1-start", tiled: [1, 2, 4], PauseLessonBar(model: pause, onExit: {}, onNext: {}))
            pause.paused = true
            try shot("7-pause-2-paused-caps-lock", tiled: [1, 2, 4],
                     PauseLessonBar(model: pause, onExit: {}, onNext: {}))

            try render("tutorial-8-finish-\(mode)",
                       FinishView(completed: Set(TutorialLesson.allCases.filter { $0 != .finish }), onDone: {}),
                       size: size, dark: dark)
        }
    }

    // onboarding's hypr key step: caps lock (recommended), a function key,
    // right option, and caps lock held
    func testRenderHyprKeyPicker() throws {
        let saved = (UserConfig.shared.hyprKey, UserConfig.shared.doubleTapHyprTogglesCapsLock)
        defer { (UserConfig.shared.hyprKey, UserConfig.shared.doubleTapHyprTogglesCapsLock) = saved }
        UserConfig.shared.doubleTapHyprTogglesCapsLock = true
        let size = CGSize(width: 1440, height: 900)
        func picker(held: Bool = false) -> some View {
            let watcher = HyprKeyHoldWatcher()
            watcher.held = held
            watcher.heldOnce = held
            return HyprKeyPickerView(watcher: watcher, onNext: {})
        }
        for dark in [true, false] {
            let mode = dark ? "dark" : "light"
            UserConfig.shared.hyprKey = .capsLock
            try render("onboarding-2-hypr-key-caps-lock-\(mode)", picker(), size: size, dark: dark)
            try render("onboarding-2-hypr-key-caps-lock-held-\(mode)", picker(held: true), size: size, dark: dark)
            UserConfig.shared.hyprKey = .f18
            try render("onboarding-2-hypr-key-f18-\(mode)", picker(), size: size, dark: dark)
            UserConfig.shared.hyprKey = .rightOption
            try render("onboarding-2-hypr-key-right-option-\(mode)", picker(), size: size, dark: dark)
        }
    }

    // onboarding's last step, at the defaults and at the other picks
    func testRenderMakeItYours() throws {
        let config = UserConfig.shared
        let saved = (config.focusFollowsMouse, config.focusBracketStyle, config.showFocusBorder,
                     config.dimInactiveWindows)
        let savedStyle = UserDefaults.standard.string(forKey: UserConfig.menuBarStyleKey)
        defer {
            (config.focusFollowsMouse, config.focusBracketStyle, config.showFocusBorder,
             config.dimInactiveWindows) = saved
            UserDefaults.standard.set(savedStyle, forKey: UserConfig.menuBarStyleKey)
        }
        let size = CGSize(width: 1440, height: 900)
        for dark in [true, false] {
            let mode = dark ? "dark" : "light"
            config.focusFollowsMouse = true
            FocusIndicatorChoice.corners.apply(to: config)
            config.dimInactiveWindows = true
            UserDefaults.standard.set(MenuBarStyle.full.rawValue, forKey: UserConfig.menuBarStyleKey)
            try render("onboarding-3-make-it-yours-defaults-\(mode)",
                       MakeItYoursView(onSkipTutorial: {}, onTakeTutorial: {}), size: size, dark: dark)
            config.focusFollowsMouse = false
            FocusIndicatorChoice.cornersAndBorders.apply(to: config)
            config.dimInactiveWindows = false
            UserDefaults.standard.set(MenuBarStyle.compact.rawValue, forKey: UserConfig.menuBarStyleKey)
            try render("onboarding-3-make-it-yours-changed-\(mode)",
                       MakeItYoursView(onBack: {}, onSkipTutorial: {}, onTakeTutorial: {}), size: size, dark: dark)
            FocusIndicatorChoice.border.apply(to: config)
            config.dimInactiveWindows = true
            UserDefaults.standard.set(MenuBarStyle.hidden.rawValue, forKey: UserConfig.menuBarStyleKey)
            try render("onboarding-3-make-it-yours-menu-bar-hidden-\(mode)",
                       MakeItYoursView(onBack: {}, onSkipTutorial: {}, onTakeTutorial: {}), size: size, dark: dark)
        }
    }

    // the stage with the Dock on the bottom (the hub's 1920×1080 insets) and
    // on the left: the bars and the step stay clear of it. a gray block
    // stands in for the Dock
    func testRenderStageClearOfTheDock() throws {
        UserConfig.shared.hyprKey = .capsLock
        let size = CGSize(width: 1920, height: 1080)
        func withDock<V: View>(_ view: V, _ insets: EdgeInsets) -> some View {
            ZStack {
                view.environment(\.stageInsets, insets)
                Color.clear
                    .overlay(alignment: insets.bottom > 30 ? .bottom : .leading) {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.white.opacity(0.3))
                            .frame(width: insets.bottom > 30 ? 820 : insets.leading - 8,
                                   height: insets.bottom > 30 ? insets.bottom - 8 : 640)
                            .padding(insets.bottom > 30 ? .bottom : .leading, 4)
                    }
            }
        }
        let bottom = EdgeInsets(top: 25, leading: 0, bottom: 85, trailing: 0)
        let left = EdgeInsets(top: 25, leading: 80, bottom: 4, trailing: 0)
        try render("stage-dock-bottom-make-it-yours", withDock(
            MakeItYoursView(onBack: {}, onSkipTutorial: {}, onTakeTutorial: {}), bottom), size: size)
        try render("stage-dock-bottom-lesson-1", withDock(
            HyprKeyLessonView(model: HyprKeyLessonModel(), onExit: {}, onNext: {}), bottom), size: size)
        try render("stage-dock-left-make-it-yours", withDock(
            MakeItYoursView(onBack: {}, onSkipTutorial: {}, onTakeTutorial: {}), left), size: size)
    }

    // the compact lesson card on every lesson, dark, with the Dock at the
    // bottom; lesson 5 again with the Dock on the left. the practice tiles
    // end above the card
    func testRenderLessonCards() throws {
        let config = UserConfig.shared
        let saved = (config.hyprKey, config.enabled, config.focusFollowsMouse, config.doubleTapHyprTogglesCapsLock)
        defer { (config.hyprKey, config.enabled, config.focusFollowsMouse, config.doubleTapHyprTogglesCapsLock) = saved }
        config.hyprKey = .capsLock
        config.doubleTapHyprTogglesCapsLock = true
        config.focusFollowsMouse = true
        let size = CGSize(width: 1512, height: 982)
        let practice = PracticeSession(host: nil)
        practice.setWorkspacesForTesting(practice: 2, other: 3)

        func room<Bar: View>(_ bar: Bar) -> CGFloat {
            PracticeSession.cardInset(forCardHeight: NSHostingView(rootView: bar).fittingSize.height)
        }
        func shot<Bar: View>(_ name: String, focused: Int = 1, tiled: [Int] = [1, 2, 3], floaters: [Int] = [],
                             dock: PracticeSceneMock<Bar>.Dock = .bottom, _ bar: Bar) throws {
            try render(name, PracticeSceneMock(focused: focused, tiled: tiled, floaters: floaters,
                                               cardRoom: room(bar), dock: dock) { bar }, size: size)
        }

        let one = HyprKeyLessonModel()
        one.heldOnce = true
        try render("card-lesson-1",
                   HyprKeyLessonView(model: one, onExit: {}, onNext: {})
                       .environment(\.stageInsets, EdgeInsets(top: 25, leading: 0,
                                                              bottom: PracticeSceneMock<EmptyView>.dockSize, trailing: 0))
                       .overlay(alignment: .bottom) {
                           RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.22))
                               .frame(width: 760, height: PracticeSceneMock<EmptyView>.dockSize - 10).padding(.bottom, 5)
                       },
                   size: size)

        let move = MoveAroundLessonModel(practice: practice)
        move.focusedAway = true
        try shot("card-lesson-2", focused: 2, MoveAroundLessonBar(model: move, onExit: {}, onNext: {}))

        let workspaces = WorkspacesLessonModel(practice: practice)
        try shot("card-lesson-3", WorkspacesLessonBar(model: workspaces, displayCount: 1, onExit: {}, onNext: {}))

        let floating = FloatingLessonModel(practice: practice)
        floating.floatedTwo = true
        try shot("card-lesson-4", focused: 2, tiled: [3], floaters: [1, 2],
                 FloatingLessonBar(model: floating, onExit: {}, onNext: {}))

        let fix = FixWindowLessonModel(practice: practice)
        try shot("card-lesson-5", focused: 4, tiled: [1, 2, 3], floaters: [4],
                 FixWindowLessonBar(model: fix, onExit: {}, onNext: {}))
        try shot("card-lesson-5-dock-left", focused: 4, tiled: [1, 2, 3], floaters: [4], dock: .left,
                 FixWindowLessonBar(model: fix, onExit: {}, onNext: {}))

        let keys = MenuBarAndKeysLessonModel(practice: practice)
        keys.jumped = true
        try shot("card-lesson-6", MenuBarAndKeysLessonBar(model: keys, onExit: {}, onNext: {}))

        let pause = PauseLessonModel(practice: practice)
        pause.paused = true
        try shot("card-lesson-7", PauseLessonBar(model: pause, onExit: {}, onNext: {}))
    }

    func testRenderKeybindChips() throws {
        UserConfig.shared.hyprKey = .capsLock
        let binds = [
            Keybind(keyCode: UInt16(kVK_ANSI_K), modifiers: .hypr, action: .showKeybinds),
            Keybind(keyCode: UInt16(kVK_LeftArrow), modifiers: [.hypr, .shift], action: .swapDirection(.left)),
            Keybind(keyCode: UInt16(kVK_ANSI_T), modifiers: [.hypr, .control, .option, .shift, .command],
                    action: .toggleFloating),
            Keybind(keyCode: UInt16(kVK_ANSI_Q), modifiers: [.command, .shift], action: .closeWindow),
        ]
        let rows = VStack(alignment: .trailing, spacing: 8) {
            ForEach(Array(binds.enumerated()), id: \.offset) { _, bind in
                HStack {
                    Text(bind.actionDescription).font(.hyprBody)
                    Spacer()
                    KeybadgeView(bind: bind)
                }
            }
        }
        .padding(16)
        .background(Color.hyprBackground)
        try render("keybind-chips-dark", rows, width: 420)

        let editor = KeybindEditorSheet(existingBind: binds[1]) { _ in }
            .background(Color.hyprBackground)
        try render("keybind-editor-dark", editor, width: 480)
    }

    func testRenderKeybindOverlay() throws {
        UserConfig.shared.hyprKey = .capsLock
        let width = KeybindOverlayView.preferredWidth
        // glass over a stand-in wallpaper. an offscreen render can't show the
        // blur itself, only the content: labels, chips and the header fade
        func overlay(_ text: String) -> some View {
            let input = OverlayInput()
            input.text = text
            return KeybindOverlayView(keybinds: Keybind.defaults, cardWidth: width,
                                      listHeight: OverlayListLayout.preferredHeight) {}
                .environmentObject(input)
                .background(wallpaper)
        }
        try render("keybind-overlay-dark", overlay(""), width: width + 128)
        try render("keybind-overlay-light", overlay(""), width: width + 128, dark: false)
        try render("keybind-overlay-filter-dark", overlay("work"), width: width + 128)
        try render("keybind-overlay-nomatch-dark", overlay("zzz"), width: width + 128)

        // the longest section's third row plus half a row, so a row sits half
        // under its pinned header
        let sections = KeybindOverlayContent.sections(
            for: Keybind.defaults, filter: "",
            scratchpadTilesSentWindows: UserConfig.shared.scratchpadTileByDefault)
        let longest = try XCTUnwrap(sections.indices.max { sections[$0].rows.count < sections[$1].rows.count })
        let firstRow = sections[..<longest].reduce(0) { $0 + $1.rows.count }
        let midRow = OverlayListLayout.scrollStops(for: sections)[firstRow + 2] + 17
        for dark in [true, false] {
            try render("keybind-overlay-scrolled-\(dark ? "dark" : "light")", overlay(""),
                       size: CGSize(width: width + 128, height: 0), dark: dark, scrollTo: midRow)
        }
    }

    func testRenderWindowRulesOverlay() throws {
        let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/FaceTime.app")
        func card(_ info: FocusedWindowRuleInfo, _ select: WindowRulesOverlayModel.Row? = nil,
                  click: WindowRulesOverlayModel.Row? = nil,
                  text: String? = nil, contains: Bool = false) -> some View {
            let model = WindowRulesOverlayModel(target: info)
            if let select { model.selection = select }
            if let click { _ = model.click(click) }
            if let text { model.text = text }
            model.contains = contains
            return WindowRulesOverlayView(model: model, icon: icon) { _ in }
                .padding(48)
                .background(wallpaper)
        }
        let teams = FocusedWindowRuleInfo(
            windowID: 1, appName: "Microsoft Teams", bundleID: "com.microsoft.teams2",
            title: "Chat | Weekly sync with design", currentRule: nil,
            appFloats: false, appTiles: false, isFloating: false)
        let faceTime = FocusedWindowRuleInfo(
            windowID: 2, appName: "FaceTime", bundleID: "com.apple.FaceTime", title: "FaceTime",
            currentRule: "Never tile: all windows", appFloats: true, appTiles: false, isFloating: true)
        let width = WindowRulesOverlayView.width + 96
        for dark in [true, false] {
            let mode = dark ? "dark" : "light"
            try render("rules-overlay-\(mode)", card(teams), width: width, dark: dark)
            try render("rules-overlay-title-\(mode)", card(teams, .floatTitle, text: "Chat |", contains: true),
                       width: width, dark: dark)
            try render("rules-overlay-rule-\(mode)", card(faceTime), width: width, dark: dark)
            // a mouse click on a title row opens the editor with the full title
            try render("rules-overlay-title-click-\(mode)", card(teams, click: .floatTitle),
                       width: width, dark: dark)
        }
    }

    func testRenderWorkspaceOverview() throws {
        func window(_ id: Int, _ name: String, _ frame: CGRect, floating: Bool) -> WorkspaceWindowSnapshot {
            WorkspaceWindowSnapshot(id: CGWindowID(id), title: name, bundleID: nil, appName: name,
                                    normalizedFrame: frame, isFloating: floating)
        }
        let snapshots: [WorkspaceSnapshot] = (1...10).map { id in
            let windows: [WorkspaceWindowSnapshot] = id > 3 ? [] : [
                window(id * 10, "Notes", CGRect(x: 0, y: 0, width: 0.5, height: 1), floating: false),
                window(id * 10 + 1, "Terminal", CGRect(x: 0.5, y: 0.2, width: 0.4, height: 0.6), floating: id == 2),
            ]
            return WorkspaceSnapshot(id: id, monitorID: 1, monitorName: "Built-in", isActive: id == 2,
                                     windows: windows)
        }
        let view = WorkspaceOverviewView(model: WorkspaceOverviewModel(snapshots: snapshots),
                                         selectWorkspace: { _ in }, selectWindow: { _, _ in })
            .background(wallpaper)
        try render("overview-dark", view, size: CGSize(width: 1100, height: 620))
    }

    // something busy behind the glass renders, in place of a desktop
    private var wallpaper: some View {
        LinearGradient(colors: [.orange, .pink, .teal, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: helpers

    // mimics the settings detail pane: 568pt wide with 24pt side padding
    private func tab<V: View>(_ content: V) -> some View {
        VStack(spacing: HyprSpacing.lg) { content }
            .padding(.horizontal, HyprSpacing.xl)
            .padding(.vertical, HyprSpacing.lg)
            .frame(width: 568)
            .background(Color.settingsBackground)
    }


    private func render<V: View>(_ name: String, _ view: V, width: CGFloat = 568, dark: Bool = true) throws {
        try render(name, view, size: CGSize(width: width, height: 0), dark: dark)
    }

    private func render<V: View>(_ name: String, _ view: V, size: CGSize, dark: Bool = true,
                                 scrollTo: CGFloat? = nil) throws {
        let fixedHeight = size.height > 0
        let root = AnyView(fixedHeight
            ? AnyView(view.frame(width: size.width, height: size.height))
            : AnyView(view.frame(width: size.width).fixedSize(horizontal: false, vertical: true)))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: max(size.height, 100)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }

        host.frame = NSRect(x: 0, y: 0, width: size.width, height: max(size.height, 100))
        host.layoutSubtreeIfNeeded()
        // let onAppear, state and short animations settle
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        if !fixedHeight {
            let height = ceil(host.fittingSize.height)
            window.setContentSize(NSSize(width: size.width, height: height))
            host.frame = NSRect(x: 0, y: 0, width: size.width, height: height)
        }
        host.layoutSubtreeIfNeeded()
        if let scrollTo, let scrollView = firstScrollView(in: host) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollTo))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.display()

        let bounds = host.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: outputDir.appendingPathComponent("\(name).png"))
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}

// stand-in for the practice helper's windows, tiled as HyprMac would: the
// same look as HyprMacPractice, the config's gaps, corner radius, marks and dim
private struct PracticeSceneMock<Bar: View>: View {
    enum Dock { case bottom, left }
    let focused: Int
    var tiled: [Int] = [1, 2, 3]
    var floaters: [Int] = []
    /// the room the practice workspace keeps under its tiles for the card
    var cardRoom: CGFloat = 0
    var dock: Dock? = nil
    @ViewBuilder let bar: Bar

    static var dockSize: CGFloat { 72 }
    private let config = UserConfig.shared

    private let tints: [Color] = [
        Color(red: 0x56/255, green: 0xD8/255, blue: 0xF0/255),
        Color(red: 0xE8/255, green: 0x4B/255, blue: 0xCB/255),
        Color(red: 0x8B/255, green: 0x9C/255, blue: 0xFF/255),
    ]

    var body: some View {
        GeometryReader { geo in
            let pad = config.outerPadding, gap = config.gapSize
            let top: CGFloat = 25 + pad
            let dockBottom: CGFloat = dock == .bottom ? Self.dockSize : 0
            let dockLeft: CGFloat = dock == .left ? Self.dockSize : 0
            let w = geo.size.width - dockLeft - pad * 2 - gap
            let h = geo.size.height - top - pad - dockBottom - cardRoom
            let rightX = pad + w * 0.5 + gap
            let halfH = (h - gap) / 2
            let frames: [CGRect] = {
                switch tiled.count {
                case 0: return []
                case 1: return [CGRect(x: dockLeft + pad, y: top, width: w + gap, height: h)]
                case 2: return [CGRect(x: dockLeft + pad, y: top, width: w * 0.5, height: h),
                                CGRect(x: dockLeft + rightX, y: top, width: w * 0.5, height: h)]
                default: return [CGRect(x: dockLeft + pad, y: top, width: w * 0.5, height: h),
                                 CGRect(x: dockLeft + rightX, y: top, width: w * 0.5, height: halfH),
                                 CGRect(x: dockLeft + rightX, y: top + halfH + gap, width: w * 0.5, height: halfH)]
                }
            }()
            ZStack(alignment: .topLeading) {
                StageBackdrop()
                ForEach(Array(zip(tiled, frames)), id: \.0) { number, frame in
                    window(number, frame)
                }
                // floating windows sit above the tiles with their outline
                ForEach(Array(floaters.enumerated()), id: \.offset) { index, number in
                    floater(number, index: index, in: geo.size)
                }
                // the card at the bottom center of the visible frame
                VStack { Spacer(); HStack { Spacer(); bar; Spacer() } }
                    .padding(.bottom, 16 + dockBottom)
                    .padding(.leading, dockLeft)
                if let dock { dockMock(dock, in: geo.size) }
            }
        }
    }

    // a stand-in Dock: a glass strip where the real one sits
    private func dockMock(_ dock: Dock, in screen: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let long: CGFloat = 760, short = Self.dockSize - 10
        return shape.fill(Color.white.opacity(0.22))
            .overlay(shape.strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
            .frame(width: dock == .bottom ? long : short, height: dock == .bottom ? short : long * 0.7)
            .offset(x: dock == .bottom ? (screen.width - long) / 2 : 5,
                    y: dock == .bottom ? screen.height - short - 5 : (screen.height - long * 0.7) / 2)
    }

    private func floater(_ number: Int, index: Int, in screen: CGSize) -> some View {
        let size = CGSize(width: 460, height: 330)
        let x: CGFloat = screen.width / 2 - size.width / 2 + CGFloat(index) * 70 - 35
        let y: CGFloat = screen.height / 2 - size.height / 2 - 90 + CGFloat(index) * 60
        let outline = RoundedRectangle(cornerRadius: config.windowCornerRadius, style: .continuous)
            .strokeBorder(Color(nsColor: config.resolvedFloatingBorderColor), lineWidth: 1.5)
            .frame(width: size.width, height: size.height)
            .offset(x: x, y: y)
        return window(number, CGRect(x: x, y: y, width: size.width, height: size.height))
            .overlay(outline, alignment: .topLeading)
            .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
    }

    private func window(_ number: Int, _ frame: CGRect) -> some View {
        let shape = RoundedRectangle(cornerRadius: config.windowCornerRadius, style: .continuous)
        let tint = tints[(number - 1) % tints.count]
        return ZStack {
            LinearGradient(colors: [TutorialStageColor.navyTop, TutorialStageColor.navyBottom],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [tint.opacity(0.28), .clear], center: .center, startRadius: 0, endRadius: 320)
            VStack(spacing: 6) {
                Text("\(number)").font(.system(size: 96, weight: .bold, design: .rounded)).foregroundStyle(tint)
                Text("Practice window \(number)").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            VStack {
                HStack(spacing: 8) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
                    Spacer()
                    Text("Practice \(number)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                }
                .padding(.horizontal, 14).frame(height: 30)
                Spacer()
            }
            if config.dimInactiveWindows, number != focused {
                Color.black.opacity(config.dimIntensity)
            }
            if number == focused, config.focusBracketStyle != .off {
                let marks = FocusMarksShape(inset: CornerMarkGeometry.focusMarkInset,
                                            radius: config.resolvedFocusBracketRadius,
                                            length: config.resolvedFocusBracketLength)
                let color = config.resolvedFocusBracketColor
                marks.stroke(Color(cgColor: FocusBrackets.contrastOutlineColor(for: color.cgColor)),
                             style: StrokeStyle(lineWidth: config.resolvedFocusBracketThickness + 2,
                                                lineCap: .round, lineJoin: .round))
                    .overlay(marks.stroke(Color(nsColor: color),
                                          style: StrokeStyle(lineWidth: config.resolvedFocusBracketThickness,
                                                             lineCap: .round, lineJoin: .round)))
            }
        }
        .clipShape(shape)
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.minX, y: frame.minY)
    }
}
