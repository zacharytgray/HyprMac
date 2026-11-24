// The tutorial's practice windows. Lessons 2 to 6 run on HyprMac Practice
// (Contents/Helpers), on an empty workspace, so the user's own windows are
// never focused, moved, floated or given rules. With no empty workspace on
// the screen, practice doesn't start and those lessons say why. The helper reports which of
// its windows has focus and their order on screen; the window manager says
// where each one is and whether it floats.

import AppKit

/// One practice window as the window manager sees it.
struct PracticeWindowState: Equatable {
    let number: Int
    let workspace: Int?
    let floating: Bool
}

/// What the practice session needs from the window manager.
protocol PracticeHost: AnyObject {
    /// the workspace showing on the pointer's screen
    func currentWorkspace() -> Int?
    /// the empty workspaces on the pointer's screen, in order after the
    /// current one; the one on screen never counts
    func emptyWorkspaces() -> [Int]
    func switchToWorkspace(_ number: Int)
    /// how many windows `workspace` tiles before the next one spills to
    /// another workspace: Max splits on its display, 0 when the display
    /// doesn't tile
    func tileCapacity(of workspace: Int) -> Int
    /// the helper's windows HyprMac knows, by the number in their title
    func practiceWindows(pid: pid_t) -> [PracticeWindowState]
    /// float one practice window, as Hypr+T would
    func floatPracticeWindow(pid: pid_t, number: Int) -> Bool
    /// Hypr+K's search text, "" when the list is closed
    func keybindSearchText() -> String
    /// every rule that names `bundleID`, from Hypr+I or Settings
    func removeRules(bundleID: String)
    /// room under `workspace`'s tiles for the lesson card; nil removes it
    func setBottomInset(_ inset: CGFloat?, workspace: Int)
}

extension PracticeHost {
    func practiceWindows(pid: pid_t) -> [PracticeWindowState] { [] }
    func floatPracticeWindow(pid: pid_t, number: Int) -> Bool { false }
    func keybindSearchText() -> String { "" }
    func removeRules(bundleID: String) {}
    func setBottomInset(_ inset: CGFloat?, workspace: Int) {}
}

final class WindowManagerPracticeHost: PracticeHost {
    private weak var windowManager: WindowManager?

    init(_ windowManager: WindowManager?) {
        self.windowManager = windowManager
    }

    func currentWorkspace() -> Int? {
        guard let wm = windowManager, let workspaces = wm.workspaceManager else { return nil }
        return workspaces.workspaceForScreen(wm.displayManager.screenUnderCursor())
    }

    func emptyWorkspaces() -> [Int] {
        guard let wm = windowManager, let workspaces = wm.workspaceManager, let current = currentWorkspace() else { return [] }
        return workspaces.emptyWorkspaces(after: current, on: wm.displayManager.screenUnderCursor())
    }

    func switchToWorkspace(_ number: Int) {
        windowManager?.handleAction(.switchWorkspace(number))
    }

    func tileCapacity(of workspace: Int) -> Int {
        guard let wm = windowManager, let workspaces = wm.workspaceManager,
              let screen = workspaces.homeScreenForWorkspace(workspace),
              !workspaces.isMonitorDisabled(screen) else { return 0 }
        return RetileAllPlanner.workspaceCapacity(maxDepth: wm.tilingEngine.maxDepth(for: screen))
    }

    func practiceWindows(pid: pid_t) -> [PracticeWindowState] {
        guard let wm = windowManager, let workspaces = wm.workspaceManager else { return [] }
        let found = wm.stateCache.cachedWindows.values.filter { $0.ownerPID == pid }
        if found.isEmpty { hyprLog(.debug, .lifecycle, "tutorial practice: no cached windows for pid \(pid)") }
        return found.compactMap { window in
            guard window.ownerPID == pid, let number = Self.number(of: window) else { return nil }
            return PracticeWindowState(number: number,
                                       workspace: workspaces.workspaceFor(window.windowID),
                                       floating: wm.stateCache.floatingWindowIDs.contains(window.windowID))
        }
    }

    func floatPracticeWindow(pid: pid_t, number: Int) -> Bool {
        guard let wm = windowManager, let workspaces = wm.workspaceManager,
              let window = wm.stateCache.cachedWindows.values.first(where: {
                  $0.ownerPID == pid && Self.number(of: $0) == number }),
              !wm.stateCache.floatingWindowIDs.contains(window.windowID),
              let workspace = workspaces.workspaceFor(window.windowID),
              let screen = workspaces.homeScreenForWorkspace(workspace) else { return false }
        wm.floatingController.toggle(window, on: screen, in: workspace)
        return true
    }

    func keybindSearchText() -> String {
        windowManager?.keybindOverlay.isShowing == true ? windowManager?.keybindOverlay.searchText ?? "" : ""
    }

    func removeRules(bundleID: String) {
        PracticeSession.removeRules(bundleID: bundleID, from: UserConfig.shared)
    }

    func setBottomInset(_ inset: CGFloat?, workspace: Int) {
        windowManager?.setTutorialBottomInset(inset, workspace: workspace)
    }

    /// "Practice 3" → 3
    private static func number(of window: HyprWindow) -> Int? {
        guard let title = window.title, title.hasPrefix("Practice ") else { return nil }
        return Int(title.dropFirst("Practice ".count))
    }
}

/// A host that finds the window manager when it's needed: onboarding opens
/// before access, and the window manager only starts after it.
final class LatePracticeHost: PracticeHost {
    private let windowManager: () -> WindowManager?

    init(_ windowManager: @escaping () -> WindowManager?) {
        self.windowManager = windowManager
    }

    private var host: WindowManagerPracticeHost { WindowManagerPracticeHost(windowManager()) }
    func currentWorkspace() -> Int? { host.currentWorkspace() }
    func emptyWorkspaces() -> [Int] { host.emptyWorkspaces() }
    func switchToWorkspace(_ number: Int) { host.switchToWorkspace(number) }
    func tileCapacity(of workspace: Int) -> Int { host.tileCapacity(of: workspace) }
    func practiceWindows(pid: pid_t) -> [PracticeWindowState] { host.practiceWindows(pid: pid) }
    func floatPracticeWindow(pid: pid_t, number: Int) -> Bool { host.floatPracticeWindow(pid: pid, number: number) }
    func keybindSearchText() -> String { host.keybindSearchText() }
    func removeRules(bundleID: String) { host.removeRules(bundleID: bundleID) }
    func setBottomInset(_ inset: CGFloat?, workspace: Int) { host.setBottomInset(inset, workspace: workspace) }
}

/// The helper's process: NSRunningApplication in the app, a fake in tests.
protocol PracticeHelperProcess: AnyObject {
    var processIdentifier: pid_t { get }
    func terminate() -> Bool
}

extension NSRunningApplication: PracticeHelperProcess {}

final class PracticeSession: ObservableObject {
    /// the helper's focused window number, nil when none of its windows is
    @Published private(set) var focused: Int?
    /// window numbers left to right, then top to bottom
    @Published private(set) var order: [Int] = []
    /// the helper launched and reported in
    @Published private(set) var isRunning = false
    /// where each practice window is and whether it floats, by number
    @Published private(set) var windows: [Int: PracticeWindowState] = [:]
    /// the workspace showing on the pointer's screen
    @Published private(set) var workspace: Int?
    /// the front app is the helper
    @Published private(set) var helperIsFront = false
    /// Hypr+K's search text while the list is open
    @Published private(set) var keybindSearch = ""

    /// where the practice windows live, and a second empty one for lesson 3;
    /// nil when the screen has no such workspace
    private(set) var practiceWorkspace: Int?
    private(set) var otherWorkspace: Int?
    /// the room kept under the practice tiles for the lesson card
    private(set) var cardInset: CGFloat?
    /// why practice didn't start, for the lesson bar
    @Published private(set) var unavailable: String?

    static let needsEmptyWorkspace = "Practice needs one empty workspace. Move the windows off one, then try again."
    /// lesson 5 can have four practice windows tiled at once
    static let tilesNeeded = 4
    static let needsRoomForTiles = "Practice needs this display to tile 4 windows. Check Tile windows on this display and Max splits in Settings → Monitors, then try again."
    static let switchRefused = "Practice couldn't move to an empty workspace just now. Wait a moment, then try again."
    static let needsSecondEmptyWorkspace = "This lesson needs a second empty workspace. Move the windows off one, then try again."

    static let stateNotification = Notification.Name("com.zachgray.HyprMac.practice.state")
    static let commandNotification = Notification.Name("com.zachgray.HyprMac.practice.command")
    static let helperBundleID = "com.zachgray.HyprMac.practice"

    private let host: PracticeHost?
    private var startWorkspace: Int?
    private var observer: NSObjectProtocol?
    private var helper: PracticeHelperProcess?
    /// counts begin() calls, so a late open from an earlier one is told apart
    private(set) var launch = 0
    private var poll: Timer?
    /// a window to float as soon as HyprMac has it
    private var pendingFloat: (number: Int, deadline: Date)?

    init(host: PracticeHost?) {
        self.host = host
    }

    static var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/HyprMac Practice.app")
    }

    var isActive: Bool { observer != nil }

    /// the helper this session opened, or any running copy of it
    private var helperPID: pid_t? {
        helper?.processIdentifier
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: Self.helperBundleID).first?.processIdentifier
    }

    /// Move to an empty workspace and open the practice windows there. With
    /// none, nothing starts: the user's own windows are never practice.
    func begin(windows count: Int = 3) {
        guard !isActive else { return }
        let empty = host?.emptyWorkspaces() ?? []
        guard let home = empty.first else {
            unavailable = Self.needsEmptyWorkspace
            hyprLog(.notice, .lifecycle, "tutorial practice: no empty workspace on this screen, not starting")
            return
        }
        // a window past Max splits spills to another workspace, maybe one in use
        guard (host?.tileCapacity(of: home) ?? 0) >= Self.tilesNeeded else {
            unavailable = Self.needsRoomForTiles
            hyprLog(.notice, .lifecycle, "tutorial practice: ws\(home) tiles fewer than \(Self.tilesNeeded) windows, not starting")
            return
        }
        let start = host?.currentWorkspace()
        host?.switchToWorkspace(home)
        // a switch can be refused, as mid display change; the windows
        // would then open on the user's own workspace
        guard host?.currentWorkspace() == home else {
            unavailable = Self.switchRefused
            hyprLog(.notice, .lifecycle, "tutorial practice: the switch to ws\(home) didn't happen, not starting")
            return
        }
        unavailable = nil
        launch += 1
        startWorkspace = start
        practiceWorkspace = home
        otherWorkspace = nil
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.stateNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.apply(note.userInfo)
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
        guard FileManager.default.fileExists(atPath: Self.helperURL.path) else {
            hyprLog(.notice, .lifecycle, "tutorial practice: helper missing at \(Self.helperURL.path)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--windows", "\(count)", "--parent", "\(getpid())"]
        let launch = launch
        NSWorkspace.shared.openApplication(at: Self.helperURL, configuration: configuration) { [weak self] app, error in
            DispatchQueue.main.async {
                if let error { hyprLog(.notice, .lifecycle, "tutorial practice: helper did not open (\(error.localizedDescription))") }
                guard let self else { _ = app?.terminate(); return }
                self.adoptHelper(app, launch: launch)
            }
        }
    }

    /// The open call hands the helper back late. A session that ended
    /// meanwhile, or began again, quits it instead of keeping it.
    func adoptHelper(_ app: PracticeHelperProcess?, launch: Int) {
        guard let app else { return }
        guard isActive, launch == self.launch else {
            hyprLog(.notice, .lifecycle, "tutorial practice: helper opened after the session ended, quitting it")
            _ = app.terminate()
            return
        }
        helper = app
    }

    /// The lesson card is `height` tall, 8 pt above the visible bottom, and
    /// the tiles keep their outer padding: room of the card plus 12 pt puts
    /// a 12 pt gap between the tiles and the card. In 4 pt steps, so a
    /// wrapped line doesn't retile for nothing.
    func setCardHeight(_ height: CGFloat) {
        guard isActive, let workspace = practiceWorkspace else { return }
        let inset = Self.cardInset(forCardHeight: height)
        guard inset != cardInset else { return }
        cardInset = inset
        host?.setBottomInset(inset, workspace: workspace)
    }

    static func cardInset(forCardHeight height: CGFloat) -> CGFloat {
        ((height + 12) / 4).rounded(.up) * 4
    }

    /// Lesson 3's send target: an empty workspace other than practice's,
    /// checked when the lesson opens, since windows may have moved since
    /// begin(). nil without one, and the lesson says so.
    func pickSendTarget() {
        otherWorkspace = isActive
            ? host?.emptyWorkspaces().first { $0 != practiceWorkspace }
            : nil
    }

    /// Open one more practice window; with `floating`, HyprMac floats it as
    /// soon as it has it, as if the window had landed wrong.
    func openWindow(_ number: Int, floating: Bool) {
        DistributedNotificationCenter.default().postNotificationName(
            Self.commandNotification, object: nil, userInfo: ["open": number], deliverImmediately: true)
        if floating { pendingFloat = (number, Date().addingTimeInterval(5)) }
    }

    /// Quit the helper, drop any rule made for it, and go back to where the
    /// tutorial started. Safe to call more than once.
    func end() {
        unavailable = nil
        guard isActive || helper != nil else { return }
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        poll?.invalidate()
        poll = nil
        pendingFloat = nil
        _ = helper?.terminate()
        helper = nil
        // a copy the open call didn't hand back goes too
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.helperBundleID).forEach { $0.terminate() }
        host?.removeRules(bundleID: Self.helperBundleID)
        if cardInset != nil, let workspace = practiceWorkspace { host?.setBottomInset(nil, workspace: workspace) }
        cardInset = nil
        isRunning = false
        focused = nil
        order = []
        windows = [:]
        if let start = startWorkspace, start != host?.currentWorkspace() {
            host?.switchToWorkspace(start)
        }
        startWorkspace = nil
        practiceWorkspace = nil
        otherWorkspace = nil
    }

    /// The helper's report; also called directly by tests.
    func apply(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        isRunning = true
        let number = info["focused"] as? Int ?? 0
        focused = number > 0 ? number : nil
        order = info["order"] as? [Int] ?? order
    }

    /// The window manager's side, four times a second; also called by tests.
    func refresh() {
        guard let host else { return }
        let current = host.currentWorkspace()
        if current != workspace { workspace = current }
        let search = host.keybindSearchText()
        if search != keybindSearch { keybindSearch = search }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.helperBundleID
        if front != helperIsFront { helperIsFront = front }
        guard let pid = helperPID else { return }
        let states = Dictionary(host.practiceWindows(pid: pid).map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        if states != windows {
            windows = states
            let line = states.values.sorted { $0.number < $1.number }
                .map { "\($0.number):ws\($0.workspace.map(String.init) ?? "-")\($0.floating ? " floating" : "")" }
            hyprLog(.notice, .lifecycle, "tutorial practice windows: \(line.joined(separator: ", "))")
        }
        if let pending = pendingFloat {
            if host.floatPracticeWindow(pid: pid, number: pending.number) || Date() > pending.deadline {
                pendingFloat = nil
            }
        }
    }

    /// For tests: stand in for the window manager's view.
    func setWindowsForTesting(_ states: [PracticeWindowState], workspace: Int?) {
        windows = Dictionary(states.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        self.workspace = workspace
    }

    func setWorkspacesForTesting(practice: Int?, other: Int?) {
        practiceWorkspace = practice
        otherWorkspace = other
    }

    func setFrontForTesting(_ front: Bool, search: String = "") {
        helperIsFront = front
        keybindSearch = search
    }

    // MARK: rules

    /// Drop every rule that names `bundleID`: the floating rules from
    /// Hypr+I and the Never tile list. Also run at launch, so a tutorial
    /// cut short by a crash leaves nothing behind.
    static func removeRules(bundleID: String, from config: UserConfig) {
        if config.floatingRules.contains(where: { $0.bundleID == bundleID }) {
            config.floatingRules.removeAll { $0.bundleID == bundleID }
        }
        if config.excludedBundleIDs.contains(bundleID) {
            config.excludedBundleIDs.remove(bundleID)
        }
    }
}
