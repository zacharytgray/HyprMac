import XCTest
import SwiftUI
@testable import HyprMac

// lesson 2 on the practice windows: a task counts when its key ran and the
// windows show it; the practice session moves to an empty workspace and back
final class MoveAroundLessonTests: XCTestCase {
    private final class FakeHost: PracticeHost {
        var current = 1
        var empty: [Int] = [3, 4]
        var switches: [Int] = []
        /// a refused switch, as mid display change
        var refuses = false
        var capacity = 8
        var insets: [Int: CGFloat] = [:]
        func tileCapacity(of workspace: Int) -> Int { capacity }
        func setBottomInset(_ inset: CGFloat?, workspace: Int) { insets[workspace] = inset }
        var preselected: String?
        func preselectTileRule(for bundleID: String?) { preselected = bundleID }
        var panelsClosed = 0
        func closeHyprMacPanels() { panelsClosed += 1 }
        func currentWorkspace() -> Int? { current }
        func emptyWorkspaces() -> [Int] { empty }
        func switchToWorkspace(_ number: Int) {
            switches.append(number)
            if !refuses { current = number }
        }
    }

    private var clock = Date(timeIntervalSince1970: 1000)
    private var practice: PracticeSession!
    private var model: MoveAroundLessonModel!

    override func setUp() {
        practice = PracticeSession(host: nil)
        model = MoveAroundLessonModel(practice: practice, window: 1.5) { [unowned self] in self.clock }
        practice.apply(["focused": 1, "order": [1, 2, 3]])
        model.start()
    }

    override func tearDown() {
        model.stop()
    }

    private func report(focused: Int, order: [Int] = [1, 2, 3]) {
        practice.apply(["focused": focused, "order": order])
    }

    func testFocusAwayBackAndSwap() {
        model.noteFocusKey()
        report(focused: 2)
        XCTAssertTrue(model.focusedAway)
        XCTAssertFalse(model.focusedBack)

        model.noteFocusKey()
        report(focused: 1)
        XCTAssertTrue(model.focusedBack)

        model.noteSwapKey()
        report(focused: 1, order: [2, 1, 3])
        XCTAssertTrue(model.swapped)
        XCTAssertTrue(model.isDone)
    }

    func testFocusFromTheMouseAloneDoesNotCount() {
        report(focused: 2)
        XCTAssertFalse(model.focusedAway)
    }

    func testAStaleKeyDoesNotCount() {
        model.noteFocusKey()
        clock.addTimeInterval(2)
        report(focused: 2)
        XCTAssertFalse(model.focusedAway)
    }

    func testFocusBackMeansTheFirstWindowAgain() {
        model.noteFocusKey()
        report(focused: 2)
        model.noteFocusKey()
        report(focused: 3)
        XCTAssertFalse(model.focusedBack)
        model.noteFocusKey()
        report(focused: 1)
        XCTAssertTrue(model.focusedBack)
    }

    func testWithoutTheHelperTheKeysAloneCount() {
        let alone = MoveAroundLessonModel(practice: PracticeSession(host: nil))
        alone.noteFocusKey()
        alone.noteFocusKey()
        alone.noteSwapKey()
        XCTAssertTrue(alone.isDone)
    }

    func testPracticeMovesToAnEmptyWorkspaceAndBack() {
        let host = FakeHost()
        let session = PracticeSession(host: host)
        session.begin()
        XCTAssertEqual(host.switches, [3])
        session.end()
        XCTAssertEqual(host.switches, [3, 1])
    }

    private final class FakeHelper: PracticeHelperProcess {
        var processIdentifier: pid_t { 4242 }
        var terminated = 0
        func terminate() -> Bool { terminated += 1; return true }
    }

    // the open call can hand the helper back after the tutorial ended
    func testAHelperThatOpensAfterTheEndIsQuit() {
        let session = PracticeSession(host: FakeHost())
        session.begin()
        let launch = session.launch
        session.end()
        let late = FakeHelper()
        session.adoptHelper(late, launch: launch)
        XCTAssertEqual(late.terminated, 1)
    }

    // or after the session ended and began again: that one isn't ours either
    func testAHelperFromAnEarlierBeginIsQuit() {
        let session = PracticeSession(host: FakeHost())
        session.begin()
        let first = session.launch
        session.end()
        session.begin()
        let stale = FakeHelper()
        session.adoptHelper(stale, launch: first)
        XCTAssertEqual(stale.terminated, 1)
        let current = FakeHelper()
        session.adoptHelper(current, launch: session.launch)
        XCTAssertEqual(current.terminated, 0)
        session.end()
        XCTAssertEqual(current.terminated, 1, "end quits the helper it kept")
    }

    // the user's own workspace is never practice: with no empty one,
    // nothing starts and the lessons that move windows say why
    func testPracticeNeverStartsOnAnOccupiedWorkspace() {
        let host = FakeHost()
        host.empty = []
        let stage = StageSession.tutorial(practiceHost: host)
        stage.practice.begin()
        XCTAssertEqual(host.switches, [])
        XCTAssertFalse(stage.practice.isActive)
        XCTAssertNil(stage.practice.practiceWorkspace)
        XCTAssertEqual(stage.practiceBlocked(.moveAround), PracticeSession.needsEmptyWorkspace)
        XCTAssertEqual(stage.practiceBlocked(.fixWindow), PracticeSession.needsEmptyWorkspace)
        XCTAssertNil(stage.practiceBlocked(.pause), "pause and the key list touch no windows")
        stage.practice.end()
        XCTAssertEqual(host.switches, [])
    }

    // a low Max splits would spill the third practice window onto another,
    // maybe occupied, workspace: practice doesn't start and names the setting
    func testTooFewTilesStartsNoPractice() {
        let host = FakeHost()
        host.capacity = 2
        let stage = StageSession.tutorial(practiceHost: host)
        stage.practice.begin()
        XCTAssertFalse(stage.practice.isActive)
        XCTAssertEqual(host.switches, [])
        XCTAssertEqual(stage.practiceBlocked(.floating), PracticeSession.needsRoomForTiles)
        XCTAssertTrue(PracticeSession.needsRoomForTiles.contains("Settings → Monitors"))
        host.capacity = 4
        stage.practice.begin()
        XCTAssertTrue(stage.practice.isActive)
        stage.practice.end()
    }

    // Esc asks to leave from the stage or a practice window, practice
    // running or not; never in onboarding, on the finish, another key, or
    // someone else's Esc
    func testEscAsksToLeaveFromTheStageOrAPracticeWindow() {
        let lesson = StageScreen.tutorial(.moveAround)
        XCTAssertTrue(StageSession.escAsksToLeave(screen: lesson, keyCode: 53, onStage: true, helperIsFront: false),
                      "practice blocked: the stage has the keys")
        XCTAssertTrue(StageSession.escAsksToLeave(screen: lesson, keyCode: 53, onStage: false, helperIsFront: true))
        XCTAssertFalse(StageSession.escAsksToLeave(screen: lesson, keyCode: 53, onStage: false, helperIsFront: false),
                       "Hypr+K, Hypr+I or another app keep their Esc")
        XCTAssertFalse(StageSession.escAsksToLeave(screen: lesson, keyCode: 36, onStage: true, helperIsFront: false))
        XCTAssertFalse(StageSession.escAsksToLeave(screen: .onboarding(.hyprKey), keyCode: 53,
                                                    onStage: true, helperIsFront: false))
        XCTAssertFalse(StageSession.escAsksToLeave(screen: .tutorial(.finish), keyCode: 53,
                                                    onStage: true, helperIsFront: false))
        XCTAssertFalse(TutorialWindowController().coversScreen, "no stage, nothing to cover")
        XCTAssertTrue(StageSession.returnKeepsGoing(asking: true, keyCode: 36, onStage: false, helperIsFront: true))
        XCTAssertFalse(StageSession.returnKeepsGoing(asking: false, keyCode: 36, onStage: true, helperIsFront: false))
    }

    private func resumeDefaults() throws -> UserDefaults {
        let suite = "MoveAroundLessonTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    // Esc shows the question; Keep Going and a second Esc both keep the lesson
    func testEscAsksAndKeepGoingOrASecondEscCarriesOn() throws {
        let stage = StageSession.tutorial(practiceHost: FakeHost())
        stage.resumeDefaults = try resumeDefaults()
        stage.escPressed()
        XCTAssertTrue(stage.leaveConfirmation.isAsking)
        stage.keepGoing()
        XCTAssertFalse(stage.leaveConfirmation.isAsking)
        XCTAssertEqual(stage.screen, .tutorial(.hyprKey))
        stage.escPressed()
        stage.escPressed()
        XCTAssertFalse(stage.leaveConfirmation.isAsking, "Esc again keeps going")
        XCTAssertEqual(stage.screen, .tutorial(.hyprKey))
        XCTAssertNil(TutorialResume.load(stage.resumeDefaults))
    }

    // Leave runs the normal exit: practice ends, the user's workspace comes
    // back, and the lesson is kept for next time
    func testLeaveCleansUpAndSavesTheResumePoint() throws {
        let host = FakeHost()
        let stage = StageSession.tutorial(practiceHost: host, resume: .floating)
        let defaults = try resumeDefaults()
        stage.resumeDefaults = defaults
        stage.practice.begin()
        XCTAssertTrue(stage.practice.isActive)
        stage.escPressed()
        stage.leaveEarly()
        XCTAssertFalse(stage.practice.isActive)
        XCTAssertEqual(host.current, 1, "back on the user's own workspace")
        XCTAssertFalse(stage.leaveConfirmation.isAsking)
        XCTAssertEqual(TutorialResume.load(defaults), .floating)
    }

    // the next run opens at the kept lesson with Start over; Done clears it
    func testATutorialLeftEarlyResumesAndDoneClearsIt() throws {
        let defaults = try resumeDefaults()
        TutorialResume.save(.fixWindow, defaults)
        let resumed = StageSession.tutorial(practiceHost: FakeHost(), resume: TutorialResume.load(defaults))
        resumed.resumeDefaults = defaults
        XCTAssertEqual(resumed.screen, .tutorial(.fixWindow))
        XCTAssertNotNil(resumed.cardActions.startOver, "Start over on the lesson it resumed at")
        resumed.finishTutorial()
        XCTAssertNil(TutorialResume.load(defaults))

        XCTAssertEqual(StageSession.tutorial(resume: nil).screen, .tutorial(.hyprKey))
        XCTAssertEqual(StageSession.tutorial(resume: .finish).screen, .tutorial(.hyprKey), "never at the finish")
        XCTAssertNil(StageSession.tutorial(resume: nil).cardActions.startOver)
    }

    // every lesson's card fits its row 1 inside the card: the plain row
    // within the widest card, or the ⋯ row within it, also when asking to
    // leave and with Start over
    func testRowOneFitsTheCardForEveryLesson() {
        let bind = Keybind(keyCode: 34, modifiers: .hypr, action: .showWindowRules)
        for lesson in TutorialLesson.allCases where lesson != .finish {
            let tasks = [BarTask(title: "A step", bind: bind, done: false, why: "Why it matters, in a short line."),
                         BarTask(title: "Another", bind: nil, done: false)]
            for startOver in [false, true] {
                var actions = LessonCardActions()
                if startOver { actions.startOver = {} }
                let card = LessonBar(lesson: lesson, tasks: tasks, hyprKey: .capsLock, onExit: {}, onNext: {})
                    .environment(\.lessonCardActions, actions)
                let size = NSHostingView(rootView: card.fixedSize()).fittingSize
                XCTAssertLessThanOrEqual(size.width, LessonBar.maxWidth + 0.5, "\(lesson) startOver=\(startOver)")
                XCTAssertGreaterThanOrEqual(size.width, LessonBar.width - 0.5)
                XCTAssertTrue(LessonBar.rowOneFits(lesson: lesson, taskCount: tasks.count), "\(lesson)")
            }
        }
        let asking = NSHostingView(rootView: LeaveConfirmCard(onKeepGoing: {}, onLeave: {}).fixedSize()).fittingSize
        XCTAssertLessThanOrEqual(asking.width, LessonBar.maxWidth + 0.5)
    }

    // the lesson card keeps room under the practice tiles, on the practice
    // workspace only, and every way out of practice takes it away
    func testTheCardsRoomIsOnThePracticeWorkspaceUntilPracticeEnds() {
        let host = FakeHost()
        let session = PracticeSession(host: host)
        session.setCardHeight(150)
        XCTAssertEqual(host.insets, [:], "no practice, no room")
        session.begin()
        session.setCardHeight(150)
        XCTAssertEqual(host.insets[3], PracticeSession.cardInset(forCardHeight: 150))
        XCTAssertEqual(host.insets[1], nil, "the user's own workspace keeps its tiles")
        XCTAssertGreaterThanOrEqual(PracticeSession.cardInset(forCardHeight: 150), 150 + 12)
        XCTAssertLessThan(PracticeSession.cardInset(forCardHeight: 150), 150 + 16, "the card and a gap, nothing more")
        session.setCardHeight(190)
        XCTAssertEqual(host.insets[3], PracticeSession.cardInset(forCardHeight: 190))
        session.end()
        XCTAssertNil(host.insets[3])
        XCTAssertNil(session.cardInset)
    }

    // a practice window the user closes opens again, floating if the lesson
    // needs it floating, and only while practice runs
    func testAClosedPracticeWindowOpensAgain() {
        let session = PracticeSession(host: FakeHost())
        var opened: [Int] = []
        session.sendOpen = { opened.append($0) }
        session.begin()
        session.apply(["focused": 1, "order": [1, 2, 3], "open": [1, 2, 3, 4]])
        session.apply(["focused": 1, "order": [1, 2, 3], "open": [1, 2, 3]])
        XCTAssertEqual(opened, [4])
        session.apply(["focused": 1, "order": [1, 2, 3], "open": [1, 2, 3]])
        XCTAssertEqual(opened, [4], "asked once, not every report")
        session.apply(["focused": 1, "order": [1, 2, 3], "open": [1, 2, 3, 4]])
        session.end()
        session.apply(["focused": 0, "order": [], "open": []])
        XCTAssertEqual(opened, [4], "practice over, nothing reopens")
    }

    // lesson 5: window 4 reopens floating, and Hypr+I starts on the tile row,
    // only while the lesson runs
    func testLessonFiveReopensWindowFourFloatingAndPreselectsTile() {
        let host = FakeHost()
        let session = PracticeSession(host: host)
        session.sendOpen = { _ in }
        session.begin()
        let lesson = FixWindowLessonModel(practice: session)
        lesson.start()
        XCTAssertTrue(session.floatsOnReopen.contains(FixWindowLessonModel.floatingWindow))
        XCTAssertEqual(host.preselected, PracticeSession.helperBundleID)
        lesson.stop()
        XCTAssertNil(host.preselected, "other lessons and the rest of HyprMac keep the normal first row")
        session.end()
    }

    // lesson 4 starts from three tiles: window 3 left on lesson 3's other
    // workspace, or a floater, comes back tiled; a fresh run is left alone
    func testLessonFourBringsWindowThreeBackAndKeepsThreeTiles() {
        let session = PracticeSession(host: FakeHost())
        var closed: [Int] = [], opened: [Int] = []
        session.sendClose = { closed.append($0) }
        session.sendOpen = { opened.append($0) }
        session.begin()
        session.apply(["focused": 1, "order": [1, 2], "open": [1, 2, 3]])
        // window 3 is on workspace 4, away from practice's 3; window 2 floats
        session.setWindowsForTesting([PracticeWindowState(number: 1, workspace: 3, floating: false),
                                      PracticeWindowState(number: 2, workspace: 3, floating: true)],
                                     workspace: 3)
        let lesson = FloatingLessonModel(practice: session)
        lesson.setUpWindows()
        XCTAssertEqual(closed, [], "once could be windows still showing up")
        lesson.setUpWindows()
        XCTAssertEqual(closed, [2, 3], "the floater and the one away close, to open here")
        // the helper reports them closed: they open again, tiled
        session.apply(["focused": 1, "order": [1], "open": [1]])
        XCTAssertEqual(opened.sorted(), [2, 3])
        XCTAssertFalse(session.floatsOnReopen.contains(3))

        // a resumed lesson 4: three tiles already, nothing to do
        closed = []
        session.setWindowsForTesting((1...3).map { PracticeWindowState(number: $0, workspace: 3, floating: false) },
                                     workspace: 3)
        lesson.setUpWindows()
        lesson.setUpWindows()
        XCTAssertEqual(closed, [])

        // a fresh practice HyprMac hasn't listed yet: nothing closes
        session.setWindowsForTesting([], workspace: 3)
        lesson.setUpWindows()
        lesson.setUpWindows()
        XCTAssertEqual(closed, [])
        session.end()
    }

    // the desk is written once when the tutorial starts, before practice
    // (also for a run resumed at a practice lesson), and only tutorials do it
    func testTheDeskIsSavedOnceWhenTheTutorialStarts() {
        let host = FakeHost()
        let stage = StageSession.tutorial(practiceHost: host, resume: .floating)
        var saves: [Bool] = []
        stage.onTutorialStart = { saves.append(stage.practice.isActive) }
        stage.show()
        XCTAssertEqual(saves, [false], "written before practice moved anything")
        XCTAssertTrue(stage.tutorialStarted)
        stage.close()

        let onboarding = StageSession.onboarding(accessGranted: true)
        var onboardingSaves = 0
        onboarding.onTutorialStart = { onboardingSaves += 1 }
        onboarding.finishOnboarding(takeTutorial: false)
        XCTAssertEqual(onboardingSaves, 0, "setup alone never touches the desk")
        let leading = StageSession.onboarding(accessGranted: true)
        leading.onTutorialStart = { onboardingSaves += 1 }
        leading.finishOnboarding(takeTutorial: true)
        XCTAssertEqual(onboardingSaves, 1)
        leading.close()
    }

    // every way out ends in onClose after the practice cleanup, where the
    // app puts the desk back: Done, Skip Tutorial, Leave
    func testEveryExitClosesAfterThePracticeCleanup() throws {
        for exit in ["done", "skip", "leave"] {
            let host = FakeHost()
            let stage = StageSession.tutorial(practiceHost: host, resume: .workspaces)
            stage.resumeDefaults = try resumeDefaults()
            stage.practice.begin()
            var practiceOverAtClose: Bool?
            var panelsClosedAtClose = 0
            stage.onClose = {
                practiceOverAtClose = !stage.practice.isActive && host.current == 1
                panelsClosedAtClose = host.panelsClosed
            }
            switch exit {
            case "done": stage.finishTutorial()
            case "skip": stage.leaveEarly()
            default: stage.escPressed(); stage.leaveEarly()
            }
            XCTAssertEqual(practiceOverAtClose, true, exit)
            XCTAssertGreaterThan(panelsClosedAtClose, 0, "Hypr+K or Hypr+I left open closes before the desk restore: \(exit)")
        }
        // HyprMac quitting mid-lesson runs the same cleanup
        let host = FakeHost()
        let stage = StageSession.tutorial(practiceHost: host, resume: .menuBarAndKeys)
        stage.resumeDefaults = try resumeDefaults()
        stage.noteLeaving()
        stage.cleanUp()
        XCTAssertGreaterThan(host.panelsClosed, 0)
    }

    // the line under the step is that step's own, not the lesson's first
    func testTheWhyLineFollowsTheCurrentStep() {
        func card(_ done: [Bool]) -> LessonBar {
            LessonBar(lesson: .menuBarAndKeys, why: "lesson line",
                      tasks: [BarTask(title: "Jump", bind: nil, done: done[0], why: "jump why"),
                              BarTask(title: "Open the key list", bind: nil, done: done[1], why: "list why"),
                              BarTask(title: "Search", bind: nil, done: done[2])],
                      hyprKey: .capsLock, onExit: {}, onNext: {})
        }
        XCTAssertEqual(card([false, false, false]).whyLine, "jump why")
        XCTAssertEqual(card([true, false, false]).whyLine, "list why")
        XCTAssertEqual(card([true, true, false]).whyLine, "lesson line", "a step without its own falls back")
        let blocked = LessonBar(lesson: .moveAround, why: "lesson line", tasks: [BarTask(title: "x", bind: nil, done: false, why: "step")],
                                hyprKey: .capsLock, blocked: "no room", onExit: {}, onNext: {})
        XCTAssertEqual(blocked.whyLine, "lesson line")
    }

    // compact: under 100 pt tall with a step, its keys and a two-line why
    func testTheCardStaysCompact() {
        let bind = Keybind(keyCode: 34, modifiers: .hypr, action: .showWindowRules)
        let card = LessonBar(lesson: .fixWindow,
                             tasks: [BarTask(title: "Focus window 4, open its rules", bind: bind, done: false,
                                             why: "Window 4 floats when it should tile. A rule fixes the whole app.")],
                             hyprKey: .capsLock, onExit: {}, onNext: {})
        let size = NSHostingView(rootView: card).fittingSize
        XCTAssertEqual(size.width, LessonBar.width, accuracy: 1)
        XCTAssertLessThanOrEqual(size.height, 100)
    }

    // a refused switch leaves the user on their own workspace: no practice there
    func testARefusedSwitchStartsNoPractice() {
        let host = FakeHost()
        host.refuses = true
        let stage = StageSession.tutorial(practiceHost: host)
        stage.practice.begin()
        XCTAssertFalse(stage.practice.isActive)
        XCTAssertNil(stage.practice.practiceWorkspace)
        XCTAssertEqual(stage.practiceBlocked(.moveAround), PracticeSession.switchRefused)
        stage.practice.end()
        XCTAssertEqual(host.switches, [3], "nothing to switch back from")

        host.refuses = false
        stage.practice.begin()
        XCTAssertTrue(stage.practice.isActive, "the next lesson tries again")
        stage.practice.end()
    }

    // lesson 3's send target is a second empty workspace, never an occupied one
    func testTheSendTargetIsASecondEmptyWorkspace() {
        let host = FakeHost()
        let stage = StageSession.tutorial(practiceHost: host)
        stage.practice.begin()
        XCTAssertEqual(stage.practice.practiceWorkspace, 3)
        stage.practice.pickSendTarget()
        XCTAssertEqual(stage.practice.otherWorkspace, 4)
        XCTAssertNil(stage.practiceBlocked(.workspaces))
        // picked again when lesson 3 opens: 4 filled up since
        host.empty = [3]
        stage.practice.pickSendTarget()
        XCTAssertNil(stage.practice.otherWorkspace)
        stage.practice.end()

        host.current = 1
        host.empty = [3]
        stage.practice.begin()
        stage.practice.pickSendTarget()
        XCTAssertEqual(stage.practice.practiceWorkspace, 3)
        XCTAssertNil(stage.practice.otherWorkspace)
        XCTAssertEqual(stage.practiceBlocked(.workspaces), PracticeSession.needsSecondEmptyWorkspace)
        XCTAssertNil(stage.practiceBlocked(.moveAround))
        stage.practice.end()
    }
}
