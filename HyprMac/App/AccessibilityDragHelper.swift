// Accessibility grant flow: Grant opens the Accessibility list in System
// Settings and floats a small panel under that window. The panel holds the
// HyprMac icon as a file drag; dropping it on the list adds HyprMac with its
// switch on, once macOS has asked for the user's password. There is no
// system Accessibility prompt: it opened on top of System Settings and asked
// for the same thing.

import AppKit
import QuartzCore
import SwiftUI

// MARK: - placement

/// Where the drag panel goes. Kept apart from AppKit so tests can pin it.
enum AccessibilityDragHelperPlacement {
    /// Space between System Settings, the panel and the screen edges.
    static let gap: CGFloat = 10
    /// The panel's width, side padding and icon size; the view uses them too.
    static let panelWidth: CGFloat = 340
    static let padding: CGFloat = 14
    static let iconSize: CGFloat = 44
    /// Center of the app icons in the Accessibility list, from the window's
    /// left edge, measured on macOS 27. System Settings gives no way
    /// to read it before HyprMac has Accessibility.
    static let listIconCenterX: CGFloat = 272

    /// Under the System Settings window, with the panel's icon in line with
    /// the icons in the list. Near the right edge of the screen the panel's
    /// text may run off it, so the icon keeps its place; the icon itself never
    /// leaves the visible frame. With no room below, the panel sits inside
    /// the window's bottom edge instead.
    static func panelOrigin(settings: CGRect, panel: CGSize, visible: CGRect) -> CGPoint {
        let aligned = settings.minX + listIconCenterX - padding - iconSize / 2
        let x = min(max(aligned, visible.minX + gap), visible.maxX - padding - iconSize - gap)
        var y = settings.minY - gap - panel.height
        if y < visible.minY + gap {
            y = max(settings.minY + gap, visible.minY + gap)
        }
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    /// Where the window that pressed Grant waits: beside the System Settings
    /// window with the top edges level, on its right when that fits on the
    /// screen, else on its left. nil when neither fits; the window stays put.
    static func besideOrigin(settings: CGRect, window: CGSize, visible: CGRect) -> CGPoint? {
        let y = max(min(settings.maxY, visible.maxY) - window.height, visible.minY)
        let right = settings.maxX + gap
        if right + window.width <= visible.maxX - gap { return CGPoint(x: right.rounded(), y: y.rounded()) }
        let left = settings.minX - gap - window.width
        if left >= visible.minX + gap { return CGPoint(x: left.rounded(), y: y.rounded()) }
        return nil
    }
}

// MARK: - panel controller

/// What every Grant button does. Opens the Accessibility list and, while
/// System Settings is in front, shows the drag panel under its window. The
/// flow ends on the grant, or gives up on the panel's ×, when System Settings
/// quits, or after `windowTimeout` with no System Settings window on screen.
final class AccessibilityDragHelper {
    static let shared = AccessibilityDragHelper()

    private static let settingsBundleID = "com.apple.systempreferences"
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    /// How often the panel checks the grant and follows the window.
    private static let pollInterval: TimeInterval = 0.2
    /// How long the flow waits for a System Settings window, at the start
    /// and after the last one closed.
    private static let windowTimeout: TimeInterval = 15
    /// How long System Settings stays as it is after the grant, so the new
    /// entry in the list can be seen.
    private static let resultBeat: TimeInterval = 1
    /// How long the panel takes to fly from the Grant click to its place.
    private static let launchDuration: TimeInterval = 0.35

    private var panel: NSPanel?
    private var timer: Timer?
    private var startedAt = Date()
    private var lastSettingsWindowAt: Date?
    /// Grant launched System Settings and its process hasn't shown up yet.
    private var launchingSettings = false
    /// The System Settings process Grant launched; it quits on the grant.
    /// Kept when the flow gives up, so a second Grant still quits it.
    private var settingsGrantLaunched: pid_t?
    private var onEnd: [(_ granted: Bool) -> Void] = []
    /// The window that pressed Grant. It stays on screen, moved beside System
    /// Settings when its window shows, so a user who looked away comes back
    /// to it.
    private weak var waitingWindow: NSWindow?
    /// Where Grant was clicked; the panel flies from here when it first shows.
    private var launchPoint: CGPoint?
    /// The panel's launch animation runs until then; nothing moves it meanwhile.
    private var launchEndsAt = Date.distantPast

    /// `onEnd` runs once, when the flow ends: true on the grant, false when it
    /// gives up. Every caller's `onEnd` runs, also on a second Grant.
    func start(beside window: NSWindow?, onEnd: @escaping (_ granted: Bool) -> Void) {
        if let window { waitingWindow = window }
        if panel?.isVisible != true { launchPoint = NSEvent.mouseLocation }
        if let running = Self.runningSettings() {
            if running.processIdentifier != settingsGrantLaunched { settingsGrantLaunched = nil }
        } else {
            launchingSettings = true
            settingsGrantLaunched = nil
        }
        openAccessibilityList()
        startedAt = Date()
        lastSettingsWindowAt = nil
        self.onEnd.append(onEnd)
        if panel == nil { panel = makePanel() }
        if timer == nil {
            let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.poll() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        poll()
    }

    private func openAccessibilityList() {
        if let url = Self.settingsURL { NSWorkspace.shared.open(url) }
    }

    private static func runningSettings() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).first
    }

    /// One tick: finish on the grant, give up when System Settings is gone,
    /// otherwise keep the panel under its window.
    private func poll() {
        guard !AccessibilityManager.isAccessibilityEnabled() else { finish(); return }
        guard let panel else { return }

        let settings = Self.runningSettings()
        if launchingSettings, let settings {
            settingsGrantLaunched = settings.processIdentifier
            launchingSettings = false
        }
        let frame = settingsWindowFrame(of: settings)
        if frame != nil {
            if lastSettingsWindowAt == nil {
                // a System Settings that is still launching can drop the link
                // and land on its first pane, so send it again to the window
                openAccessibilityList()
                if let frame { moveWaitingWindow(beside: frame) }
            }
            lastSettingsWindowAt = Date()
        }
        let settingsQuit = lastSettingsWindowAt != nil && settings == nil
        let noWindow = Date().timeIntervalSince(lastSettingsWindowAt ?? startedAt) > Self.windowTimeout
        if settingsQuit || noWindow { giveUp(); return }

        guard let frame, settings?.isActive == true else { panel.orderOut(nil); return }
        place(panel, under: frame)
    }

    /// Once per Grant, when the System Settings window first shows; after
    /// that the user may move it as they like.
    private func moveWaitingWindow(beside frame: CGRect) {
        guard let window = waitingWindow, window.isVisible,
              let visible = Self.visibleFrame(around: frame),
              let origin = AccessibilityDragHelperPlacement.besideOrigin(
                settings: frame, window: window.frame.size, visible: visible) else { return }
        window.setFrame(CGRect(origin: origin, size: window.frame.size), display: true, animate: true)
    }

    private static func visibleFrame(around frame: CGRect) -> CGRect? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        return screen?.visibleFrame
    }

    private func place(_ panel: NSPanel, under frame: CGRect) {
        guard let visible = Self.visibleFrame(around: frame) else { return }
        let origin = AccessibilityDragHelperPlacement.panelOrigin(
            settings: frame, panel: panel.frame.size, visible: visible)
        if !panel.isVisible, let from = launchPoint {
            launch(panel, from: from, to: origin)
            return
        }
        guard Date() >= launchEndsAt else { return }
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// The panel fades in at the Grant click and flies to its place under
    /// System Settings, so the eye follows it there.
    private func launch(_ panel: NSPanel, from point: CGPoint, to origin: CGPoint) {
        launchPoint = nil
        launchEndsAt = Date().addingTimeInterval(Self.launchDuration)
        panel.alphaValue = 0
        panel.setFrameOrigin(CGPoint(x: point.x - panel.frame.width / 2,
                                     y: point.y - panel.frame.height / 2))
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.launchDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(origin)
            panel.animator().alphaValue = 1
        }
    }

    /// Accessibility landed. The panel goes at once; everything else waits
    /// `resultBeat`, so the user sees HyprMac land in the list. Then the
    /// callers come back, and System Settings quits if Grant launched it, so
    /// a HyprMac window is in front when it goes.
    private func finish() {
        let launched = settingsGrantLaunched
        settingsGrantLaunched = nil
        launchingSettings = false
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resultBeat) { [weak self] in
            self?.end(granted: true)
            if let launched, let settings = Self.runningSettings(), settings.processIdentifier == launched {
                settings.terminate()
            }
        }
    }

    private func giveUp() {
        launchingSettings = false
        end(granted: false)
    }

    private func end(granted: Bool) {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        let callers = onEnd
        onEnd = []
        callers.forEach { $0(granted) }
    }

    /// The main System Settings window in NS coordinates, nil when it has
    /// none on screen. The largest one wins: the password dialog is a window
    /// of System Settings too, in front of the list while it asks. Window
    /// bounds need no Screen Recording access. No window manager runs yet,
    /// so the primary height comes from NSScreen.
    private func settingsWindowFrame(of settings: NSRunningApplication?) -> CGRect? {
        guard let settings,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return nil }
        let windows: [CGRect] = list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == settings.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: dict)
        }
        guard let main = windows.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        return CoordinateSpace.nsRect(fromCG: main, primaryHeight: primary.frame.height)
    }

    private func makePanel() -> NSPanel {
        let view = AccessibilityDragHelperView { [weak self] in self?.giveUp() }
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let panel = DragHelperPanel(contentRect: CGRect(origin: .zero, size: size),
                                    styleMask: [.nonactivatingPanel, .borderless],
                                    backing: .buffered, defer: true)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }
}

/// Borderless panels can't become key by default; this one must, so the
/// close button takes the first click. Non-activating, so System Settings
/// stays the front app.
private final class DragHelperPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - panel view

struct AccessibilityDragHelperView: View {
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AppIconDragSource()
                .frame(width: AccessibilityDragHelperPlacement.iconSize,
                       height: AccessibilityDragHelperPlacement.iconSize)
                .help("Drag to the Accessibility list")

            HStack(spacing: 4) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(TutorialStageColor.cyan)
                Text("Drag HyprMac to the list above")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(TutorialStageColor.text)
                    .fixedSize()
            }

            Spacer(minLength: 4)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(TutorialStageColor.quiet)
            .focusable(false)
            .help("Hide")
            .accessibilityLabel("Hide")
        }
        .padding(.horizontal, AccessibilityDragHelperPlacement.padding)
        .padding(.vertical, 10)
        .frame(width: AccessibilityDragHelperPlacement.panelWidth)
        // the onboarding stage's navy, opaque over System Settings, so the
        // panel reads as HyprMac's in light and dark
        .background(
            ZStack {
                LinearGradient(colors: [TutorialStageColor.glassTop, TutorialStageColor.navyBottom],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [TutorialStageColor.cyan.opacity(0.14), .clear],
                               center: .leading, startRadius: 0, endRadius: 160)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.18), Color.white.opacity(0.06)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }
}

/// The HyprMac icon as a drag source for the app bundle's file URL, the
/// same thing Finder hands System Settings.
private struct AppIconDragSource: NSViewRepresentable {
    func makeNSView(context: Context) -> AppIconDragView { AppIconDragView() }
    func updateNSView(_ nsView: AppIconDragView, context: Context) {}
}

private final class AppIconDragView: NSView, NSDraggingSource {
    private let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    // taken here so the drag isn't read as moving the window
    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        // System Settings takes the drop but doesn't report it as done, and
        // may be gone by then; the icon would fly back to the panel
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
