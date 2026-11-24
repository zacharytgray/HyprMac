// The tutorial's practice windows. Lessons 2 to 6 run on HyprMac Practice
// (Contents/Helpers), on an empty workspace, so the user's own windows are
// never focused, moved, floated or given rules. The helper reports which of
// its windows has focus and their order on screen.

import AppKit

/// What the practice session needs from the window manager.
protocol PracticeHost: AnyObject {
    /// the workspace showing on the pointer's screen
    func currentWorkspace() -> Int?
    /// an empty workspace on the pointer's screen
    func emptyWorkspace() -> Int?
    func switchToWorkspace(_ number: Int)
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

    func emptyWorkspace() -> Int? {
        guard let wm = windowManager, let workspaces = wm.workspaceManager, let current = currentWorkspace() else { return nil }
        return workspaces.nextEmptyWorkspace(after: current, on: wm.displayManager.screenUnderCursor())
    }

    func switchToWorkspace(_ number: Int) {
        windowManager?.handleAction(.switchWorkspace(number))
    }
}

final class PracticeSession: ObservableObject {
    /// the helper's focused window number, nil when none of its windows is
    @Published private(set) var focused: Int?
    /// window numbers left to right, then top to bottom
    @Published private(set) var order: [Int] = []
    /// the helper launched and reported in
    @Published private(set) var isRunning = false

    static let stateNotification = Notification.Name("com.zachgray.HyprMac.practice.state")
    static let helperBundleID = "com.zachgray.HyprMac.practice"

    private let host: PracticeHost?
    private var startWorkspace: Int?
    private var observer: NSObjectProtocol?
    private var helper: NSRunningApplication?

    init(host: PracticeHost?) {
        self.host = host
    }

    static var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/HyprMac Practice.app")
    }

    /// Move to an empty workspace and open the practice windows there.
    func begin(windows: Int = 3) {
        guard helper == nil else { return }
        startWorkspace = host?.currentWorkspace()
        if let empty = host?.emptyWorkspace() {
            host?.switchToWorkspace(empty)
        } else {
            hyprLog(.notice, .lifecycle, "tutorial practice: no empty workspace on this screen, using the current one")
        }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.stateNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.apply(note.userInfo)
        }
        guard FileManager.default.fileExists(atPath: Self.helperURL.path) else {
            hyprLog(.notice, .lifecycle, "tutorial practice: helper missing at \(Self.helperURL.path)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--windows", "\(windows)", "--parent", "\(getpid())"]
        NSWorkspace.shared.openApplication(at: Self.helperURL, configuration: configuration) { [weak self] app, error in
            DispatchQueue.main.async {
                if let error { hyprLog(.notice, .lifecycle, "tutorial practice: helper did not open (\(error.localizedDescription))") }
                self?.helper = app
            }
        }
    }

    /// Quit the helper and go back to where the tutorial started.
    func end() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        helper?.terminate()
        helper = nil
        isRunning = false
        focused = nil
        order = []
        if let start = startWorkspace, start != host?.currentWorkspace() {
            host?.switchToWorkspace(start)
        }
        startWorkspace = nil
    }

    /// The helper's report; also called directly by tests.
    func apply(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        isRunning = true
        let number = info["focused"] as? Int ?? 0
        focused = number > 0 ? number : nil
        order = info["order"] as? [Int] ?? order
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
    func emptyWorkspace() -> Int? { host.emptyWorkspace() }
    func switchToWorkspace(_ number: Int) { host.switchToWorkspace(number) }
}
