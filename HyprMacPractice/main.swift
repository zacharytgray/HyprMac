// HyprMac Practice: the tutorial's own windows. HyprMac opens it from
// Contents/Helpers on an empty workspace so lessons never touch the user's
// windows. It is a regular app, so HyprMac tiles it like any other. It
// reports which of its windows has focus and their order on screen, and
// quits when HyprMac does.
//
// Arguments: --windows N (default 3), --parent PID.

import AppKit
import SwiftUI

enum Practice {
    /// DistributedNotificationCenter name. userInfo: "focused" (Int, 0 for
    /// none), "order" ([Int], left to right, then top to bottom).
    static let stateNotification = Notification.Name("com.zachgray.HyprMac.practice.state")
    /// From HyprMac. userInfo: "open" (Int), a window number to open.
    static let commandNotification = Notification.Name("com.zachgray.HyprMac.practice.command")

    static func argument(_ name: String) -> Int? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }
}

private let palette: [Color] = [
    Color(red: 0x56/255, green: 0xD8/255, blue: 0xF0/255),
    Color(red: 0xE8/255, green: 0x4B/255, blue: 0xCB/255),
    Color(red: 0x8B/255, green: 0x9C/255, blue: 0xFF/255),
    Color(red: 0xF5/255, green: 0xB9/255, blue: 0x4A/255),
]

private struct PracticeWindowView: View {
    let number: Int

    var body: some View {
        let tint = palette[(number - 1) % palette.count]
        ZStack {
            LinearGradient(colors: [Color(red: 0x0A/255, green: 0x10/255, blue: 0x24/255),
                                    Color(red: 0x13/255, green: 0x1B/255, blue: 0x3A/255)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [tint.opacity(0.28), .clear], center: .center, startRadius: 0, endRadius: 320)
            VStack(spacing: 6) {
                Text("\(number)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                Text("Practice window \(number)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(minWidth: 220, minHeight: 160)
    }
}

final class PracticeAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var windows: [NSWindow] = []
    private var parentWatch: Timer?
    private var pendingReport = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let count = max(1, min(4, Practice.argument("--windows") ?? 3))
        for number in 1...count { open(number) }
        DistributedNotificationCenter.default().addObserver(
            forName: Practice.commandNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let number = note.userInfo?["open"] as? Int, (1...4).contains(number) else { return }
            self?.open(number)
            NSApp.activate(ignoringOtherApps: true)
        }
        // lessons start on window 1, the left tile, so "the next window" is
        // to its right
        windows.first?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // quit with HyprMac, even if it crashed
        if let parent = Practice.argument("--parent") {
            let timer = Timer(timeInterval: 1, repeats: true) { _ in
                if kill(pid_t(parent), 0) != 0 { NSApp.terminate(nil) }
            }
            RunLoop.main.add(timer, forMode: .common)
            parentWatch = timer
        }
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.report() }
        }
        report()
    }

    private func open(_ number: Int) {
        guard !windows.contains(where: { $0.title == "Practice \(number)" }) else { return }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(
            contentRect: NSRect(x: visible.minX + CGFloat(number) * 40, y: visible.maxY - 460 - CGFloat(number) * 30,
                                width: 520, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Practice \(number)"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PracticeWindowView(number: number))
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        report()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func windowDidBecomeKey(_ notification: Notification) { report() }
    func windowDidResignKey(_ notification: Notification) { report() }
    func windowDidMove(_ notification: Notification) { report() }
    func windowDidResize(_ notification: Notification) { report() }

    /// Coalesced: a tile pass moves every window at once.
    private func report() {
        guard !pendingReport else { return }
        pendingReport = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.pendingReport = false
            let focused = NSApp.isActive ? (self.windows.firstIndex { $0.isKeyWindow }.map { $0 + 1 } ?? 0) : 0
            let order = self.windows.enumerated()
                .filter { $0.element.isVisible }
                .sorted { a, b in
                    let fa = a.element.frame, fb = b.element.frame
                    return abs(fa.minX - fb.minX) > 20 ? fa.minX < fb.minX : fa.maxY > fb.maxY
                }
                .map { $0.offset + 1 }
            DistributedNotificationCenter.default().postNotificationName(
                Practice.stateNotification, object: nil,
                userInfo: ["focused": focused, "order": order], deliverImmediately: true)
        }
    }
}

let app = NSApplication.shared
let delegate = PracticeAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
