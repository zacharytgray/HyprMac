// Screen Recording, for "Keep floating windows in front": whether HyprMac
// has it, and whether this running copy can use it yet. macOS can show a
// grant to a fresh process while the running one still reads the old
// answer, so a fresh copy of the binary answers that (`freshCheckArgument`).
// Onboarding, Settings and What's New show the same three states.

import AppKit
import CoreGraphics

/// The Screen Recording state the UI shows.
final class ScreenRecordingAccess: ObservableObject {
    enum State: Equatable {
        /// this copy can use it: covered floaters show a live picture
        case granted
        /// not granted: covered floaters show the app icon and title
        case notGranted
        /// granted in System Settings, but this copy still reads no. a
        /// reopen picks it up
        case needsReopen
    }

    static let shared = ScreenRecordingAccess()

    /// The binary run with this answers with its exit code and quits at once.
    static let freshCheckArgument = "--check-screen-recording"
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    /// how often a shown status asks again
    static let pollInterval: TimeInterval = 2

    /// nil until the first check comes back
    @Published private(set) var state: State?

    var inProcess: () -> Bool = { CGPreflightScreenCaptureAccess() }
    /// a fresh process's answer, delivered on the main queue
    var freshCheck: (@escaping (Bool) -> Void) -> Void = ScreenRecordingAccess.runFreshCheck
    var openSettingsPane: () -> Void = { NSWorkspace.shared.open(ScreenRecordingAccess.settingsURL) }
    /// set by the app delegate: quit and open again, desk kept
    var reopenApp: () -> Void = {}

    private var watchers = 0
    private var timer: Timer?
    private var checking = false

    init(state: State? = nil) {
        self.state = state
    }

    /// The in-process answer alone, for a quick yes.
    var isGrantedHere: Bool { Self.pretended().map { $0 == .granted } ?? inProcess() }

    /// Debug app only, to see each state on a Mac that granted it (the
    /// stand-in itself still reads the real answer):
    /// `defaults write com.zachgray.HyprMac.debug screenRecordingPretend notGranted|needsReopen|granted`
    static func pretended(_ defaults: UserDefaults = .standard) -> State? {
        #if HYPRMAC_DEBUG_VARIANT
        switch defaults.string(forKey: "screenRecordingPretend") {
        case "granted": return .granted
        case "notGranted": return .notGranted
        case "needsReopen": return .needsReopen
        default: return nil
        }
        #else
        return nil
        #endif
    }

    /// Ask again. A no here waits on a fresh process before it shows, so the
    /// state never flips from not granted to reopen.
    func refresh() {
        if let pretend = Self.pretended() {
            set(pretend)
            return
        }
        if inProcess() {
            set(.granted)
            return
        }
        guard !checking else { return }
        checking = true
        freshCheck { [weak self] granted in
            guard let self else { return }
            self.checking = false
            // the running copy may have caught up meanwhile
            self.set(self.inProcess() ? .granted : granted ? .needsReopen : .notGranted)
        }
    }

    /// A view showing the state is up: check now and every `pollInterval`,
    /// and when HyprMac comes back to the front, until the last one goes.
    func startWatching() {
        watchers += 1
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            guard let self, self.state != .granted else { return }
            self.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    func stopWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func appBecameActive() { refresh() }

    func openSettings() { openSettingsPane() }

    func reopen() {
        hyprLog(.notice, .floating, "screen recording: reopening HyprMac to pick up the grant")
        reopenApp()
    }

    private func set(_ new: State) {
        guard new != state else { return }
        hyprLog(.notice, .floating, "screen recording state \(new)")
        state = new
    }

    // MARK: fresh check

    /// Run first thing at launch: a copy started with `freshCheckArgument`
    /// exits 0 when granted and 1 when not, before anything else starts.
    static func answerFreshCheckIfAsked(arguments: [String] = CommandLine.arguments) {
        guard arguments.contains(freshCheckArgument) else { return }
        exit(CGPreflightScreenCaptureAccess() ? 0 : 1)
    }

    /// This binary, started again with `freshCheckArgument`. Its parent is
    /// HyprMac, so macOS answers for HyprMac, as of now.
    private static func runFreshCheck(_ done: @escaping (Bool) -> Void) {
        guard let path = Bundle.main.executablePath else { return done(false) }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = [freshCheckArgument]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var granted = false
            do {
                try process.run()
                process.waitUntilExit()
                granted = process.terminationReason == .exit && process.terminationStatus == 0
            } catch {
                hyprLog(.notice, .floating, "screen recording fresh check failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { done(granted) }
        }
    }
}

extension ScreenRecordingAccess.State {
    /// One line for the switch's status, the same in every place.
    var message: String {
        switch self {
        case .granted: return "Screen Recording is on, so a covered floating window shows a live picture."
        case .notGranted: return "Screen Recording is off, so a covered floating window shows its app icon and title instead."
        case .needsReopen: return "Screen Recording is on. Reopen HyprMac to start using it."
        }
    }
}
