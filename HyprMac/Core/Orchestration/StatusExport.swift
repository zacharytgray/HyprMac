// Status bar export (sketchybar and friends, upstream issue #44): a JSON
// state file written on every change a bar shows, an optional hook command
// run after each write. All of it is off unless
// `UserConfig.statusExportEnabled` is on. The hyprmac:// links a bar's click
// script calls are in ExternalCommand.swift.

import Cocoa

/// What `state.json` holds. No window titles: they are private and change
/// all the time, so a bar would redraw on every keystroke in a terminal.
struct StatusSnapshot: Codable, Equatable {
    struct Monitor: Codable, Equatable {
        let name: String
        let visibleWorkspace: Int
        let focused: Bool
    }

    struct Window: Codable, Equatable {
        let id: CGWindowID
        let app: String
        let bundleID: String?
        // absent on scratchpad entries
        var floating: Bool? = nil
        var focused: Bool? = nil
    }

    struct Workspace: Codable, Equatable {
        let id: Int
        let name: String?
        let monitor: String?
        let visible: Bool
        let windows: [Window]
    }

    var version = 1
    let focusedWorkspace: Int?
    let focusedMonitor: String?
    let monitors: [Monitor]
    let workspaces: [Workspace]
    let scratchpad: [Window]
    let scratchpadVisible: Bool

    /// The model a snapshot is built from, read off `WindowManager` on main.
    struct Input {
        struct Screen { let name: String; let visibleWorkspace: Int }
        struct App { let name: String; let bundleID: String? }

        /// enabled screens, left to right
        var screens: [Screen]
        /// home screen name of each workspace 1–10
        var homeScreens: [Int: String]
        /// workspace 1–10 → assigned window ids, hidden ones included
        var assigned: [Int: Set<CGWindowID>]
        var scratchpad: Set<CGWindowID>
        var scratchpadVisible: Bool
        /// closed-but-app-alive, minimized and hidden windows
        var hidden: Set<CGWindowID>
        var floating: Set<CGWindowID>
        var focusedWindowID: CGWindowID
        /// where focus is when no window holds it (an empty workspace)
        var cursorScreen: String?
        var apps: [CGWindowID: App]
        var names: [String: String]
    }

    /// Hidden windows are left out everywhere, as in the menu bar: a ghost
    /// (closed, app still running) keeps its assignment but is not on screen.
    static func build(_ input: Input) -> StatusSnapshot {
        let visible = Set(input.screens.map(\.visibleWorkspace))
        func live(_ ids: Set<CGWindowID>) -> [CGWindowID] { ids.subtracting(input.hidden).sorted() }

        let focusID = input.focusedWindowID
        let focusWorkspace = input.assigned.first {
            visible.contains($0.key) && live($0.value).contains(focusID)
        }?.key
        let focusInScratchpad = input.scratchpadVisible && live(input.scratchpad).contains(focusID)
        let focusedWindow: CGWindowID? = focusWorkspace != nil || focusInScratchpad ? focusID : nil
        let focusScreen = focusWorkspace.flatMap { ws in input.screens.first { $0.visibleWorkspace == ws } }
            ?? input.screens.first { $0.name == input.cursorScreen }
            ?? input.screens.first

        func window(_ id: CGWindowID, detailed: Bool) -> Window {
            let app = input.apps[id]
            var w = Window(id: id, app: app?.name ?? "Unknown app", bundleID: app?.bundleID)
            if detailed {
                w.floating = input.floating.contains(id)
                w.focused = id == focusedWindow
            }
            return w
        }

        let workspaces = Constants.workspaceRange.compactMap { ws -> Workspace? in
            guard let monitor = input.homeScreens[ws] else { return nil }
            let name = input.names[String(ws)]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Workspace(id: ws, name: name?.isEmpty == false ? name : nil, monitor: monitor,
                             visible: visible.contains(ws),
                             windows: live(input.assigned[ws] ?? []).map { window($0, detailed: true) })
        }
        return StatusSnapshot(
            focusedWorkspace: focusScreen?.visibleWorkspace,
            focusedMonitor: focusScreen?.name,
            monitors: input.screens.map {
                // each screen shows its own workspace; names can repeat
                Monitor(name: $0.name, visibleWorkspace: $0.visibleWorkspace,
                        focused: $0.visibleWorkspace == focusScreen?.visibleWorkspace)
            },
            workspaces: workspaces,
            scratchpad: live(input.scratchpad).map { window($0, detailed: false) },
            scratchpadVisible: input.scratchpadVisible)
    }

    /// The hook's environment.
    func hookEnvironment(stateFile: URL) -> [String: String] {
        Self.hookEnvironment(self, stateFile: stateFile)
    }

    /// nil is the run after the file was removed: everything but the path is empty.
    static func hookEnvironment(_ snapshot: StatusSnapshot?, stateFile: URL) -> [String: String] {
        let focused = snapshot?.focusedWorkspace
        return [
            "HYPRMAC_STATE_FILE": stateFile.path,
            "HYPRMAC_FOCUSED_WORKSPACE": focused.map(String.init) ?? "",
            "HYPRMAC_FOCUSED_WORKSPACE_NAME": snapshot?.workspaces.first { $0.id == focused }?.name ?? "",
            "HYPRMAC_FOCUSED_MONITOR": snapshot?.focusedMonitor ?? "",
        ]
    }
}

/// Coalesces change notes into one snapshot per burst and drops snapshots
/// equal to the last one published. Main thread only; `publish` must not
/// block (production hands it to a background queue), and `clear` blocks
/// only for the file removal at quit.
final class StatusExporter {
    static let coalesceDelay: TimeInterval = 0.05

    var isEnabled: () -> Bool = { false }
    var hookCommand: () -> String? = { nil }
    var snapshot: () -> StatusSnapshot? = { nil }

    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let publish: (StatusSnapshot, String?) -> Void
    private let clearFile: (String?, Bool) -> Void
    private var flushPending = false
    // bumped by clear, so a flush scheduled before it does nothing
    private var generation: UInt64 = 0
    private var lastPublished: StatusSnapshot?

    init(schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
         publish: @escaping (StatusSnapshot, String?) -> Void,
         clear: @escaping (String?, Bool) -> Void) {
        self.schedule = schedule
        self.publish = publish
        self.clearFile = clear
    }

    /// Something a bar shows may have changed.
    func noteChange() {
        guard isEnabled() else {
            // turning export back on writes the file again
            lastPublished = nil
            return
        }
        guard !flushPending else { return }
        flushPending = true
        let current = generation
        schedule(Self.coalesceDelay) { [weak self] in
            guard let self, self.generation == current else { return }
            self.flush()
        }
    }

    /// Tiling is stopping or the app is quitting: remove the file and run
    /// the hook once, so a bar shows nothing. Call it while `isEnabled`
    /// still holds; once stopped it does nothing, so pause then quit
    /// clears once.
    func clear(quitting: Bool) {
        guard isEnabled() else { return }
        generation &+= 1
        flushPending = false
        // the next start writes even an unchanged state
        lastPublished = nil
        clearFile(hookCommand(), quitting)
    }

    private func flush() {
        flushPending = false
        guard isEnabled() else {
            lastPublished = nil
            return
        }
        guard let next = snapshot(), next != lastPublished else { return }
        lastPublished = next
        publish(next, hookCommand())
    }
}

/// Runs the hook with at most one child in flight. A request while one
/// runs is kept (the latest wins) and runs once the child ends. A child
/// past `timeout` is killed, so a hung bar can't stall later updates.
/// Every call, `onExit` included, must come on one serial queue.
final class StatusHookRunner {
    /// Starts the hook and returns a closure that kills it, or nil when it
    /// never started. `onExit` fires once the child ends.
    typealias Launch = (_ command: String, _ environment: [String: String],
                        _ onExit: @escaping () -> Void) -> (() -> Void)?

    static let timeout: TimeInterval = 2

    private let launch: Launch
    private let after: (TimeInterval, @escaping () -> Void) -> Void
    private var generation: UInt64 = 0
    private var inFlight = false
    private var killInFlight: (() -> Void)?
    private var queued: (command: String, environment: [String: String])?
    private var loggedTimeout = false
    private var loggedLaunchFailure = false

    init(launch: @escaping Launch, after: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        self.launch = launch
        self.after = after
    }

    func request(command: String, environment: [String: String]) {
        guard !inFlight else {
            queued = (command, environment)
            return
        }
        start(command, environment)
    }

    /// For quit, where nothing would start a queued run later: kills the
    /// child in flight and starts this one at once.
    func runNow(command: String, environment: [String: String]) {
        if inFlight { killInFlight?() }
        inFlight = false
        queued = nil
        start(command, environment)
    }

    private func start(_ command: String, _ environment: [String: String]) {
        generation &+= 1
        let current = generation
        inFlight = true
        guard let kill = launch(command, environment, { [weak self] in self?.finished(current) }) else {
            inFlight = false
            // the command text stays out of the log, as with runCommand
            hyprLog(loggedLaunchFailure ? .debug : .notice, .lifecycle, "status hook did not start")
            loggedLaunchFailure = true
            return
        }
        killInFlight = kill
        after(Self.timeout) { [weak self] in
            guard let self, self.inFlight, self.generation == current else { return }
            kill()
            hyprLog(self.loggedTimeout ? .debug : .notice, .lifecycle,
                    "status hook ran past \(Int(Self.timeout)) s, killed")
            self.loggedTimeout = true
            // don't wait for the exit: a child that never reports one must
            // not block every later update
            self.finished(current)
        }
    }

    private func finished(_ run: UInt64) {
        guard inFlight, run == generation else { return }
        inFlight = false
        killInFlight = nil
        if let next = queued {
            queued = nil
            start(next.command, next.environment)
        }
    }
}

/// The background half: writes `state.json` atomically and runs the hook.
final class StatusFilePublisher {
    static let stateFileURL = ConfigStore.configDir.appendingPathComponent("state.json")

    private let stateFile: URL

    private let queue = DispatchQueue(label: "HyprMac.StatusExport", qos: .utility)
    private let runner = CommandRunner()
    private lazy var hook = StatusHookRunner(
        launch: { [queue, runner] command, environment, onExit in
            let launched = runner.launch(command: command, environment: environment,
                                         logName: "status hook") { _ in queue.async(execute: onExit) }
            guard case .success(let process) = launched else { return nil }
            return { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        },
        after: { [queue] delay, work in queue.asyncAfter(deadline: .now() + delay, execute: work) })

    init(stateFile: URL = StatusFilePublisher.stateFileURL) {
        self.stateFile = stateFile
    }

    /// Removes the file and runs the hook once. Behind any write already
    /// queued, so none can land after it. At quit it runs before
    /// returning; the hook is only launched, never waited on, and the
    /// child outlives HyprMac.
    func clear(hookCommand: String?, quitting: Bool) {
        let work = { [self] in
            do {
                try FileManager.default.removeItem(at: stateFile)
            } catch CocoaError.fileNoSuchFile {
            } catch {
                hyprLog(.warning, .persistence, "state.json remove failed (code \((error as NSError).code))")
            }
            guard let command = trimmed(hookCommand) else { return }
            let environment = StatusSnapshot.hookEnvironment(nil, stateFile: stateFile)
            if quitting {
                hook.runNow(command: command, environment: environment)
            } else {
                hook.request(command: command, environment: environment)
            }
        }
        if quitting { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    func publish(_ snapshot: StatusSnapshot, hookCommand: String?) {
        queue.async { [self] in
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            do {
                // .atomic writes a temp file and renames it over the old one
                try encoder.encode(snapshot).write(to: stateFile, options: .atomic)
            } catch {
                hyprLog(.warning, .persistence, "state.json write failed (code \((error as NSError).code))")
                return
            }
            guard let command = trimmed(hookCommand) else { return }
            hook.request(command: command, environment: snapshot.hookEnvironment(stateFile: stateFile))
        }
    }

    private func trimmed(_ command: String?) -> String? {
        guard let command = command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else { return nil }
        return command
    }
}
