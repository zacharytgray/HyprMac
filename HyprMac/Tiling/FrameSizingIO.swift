// The AX calls a frame sizing attempt goes through, so tests can stand in for them.

import Cocoa

struct FrameSizingIO {
    let setMessagingTimeout: (CGWindowID, TimeInterval) -> AXError
    let writeSize: (CGWindowID, CGSize, TimeInterval) -> AXError
    let writePosition: (CGWindowID, CGPoint, TimeInterval) -> AXError
    let readPosition: (CGWindowID, TimeInterval) -> (AXError, CGPoint?)
    let readSize: (CGWindowID, TimeInterval) -> (AXError, CGSize?)
    let now: () -> TimeInterval
    let sleep: (TimeInterval) -> Void
    let currentGeneration: () -> UInt64
    var beginFrameWrite: (CGWindowID, TimeInterval, () -> FrameSizingFailure?) -> AXFrameWriteBatch.BeginResult = {
        windowID, _, _ in .ready(.noop(windowID: windowID))
    }
    var endFrameWrite: (AXFrameWriteBatch.Token, TimeInterval, () -> FrameSizingFailure?) -> AXFrameWriteBatch.EndResult = {
        _, _, _ in .restored
    }
    /// Diagnostic only: the window's frame before its writes and after each
    /// setter, for the `frame write trace:` notice on a refused attempt. nil
    /// skips those reads; production sets it only with
    /// `LogConfig.frameWriteTrace` on.
    var traceFrame: ((CGWindowID) -> CGRect?)?
    /// The window's frame as the window server has it: its whole bounds, in
    /// the global top-left coordinates AX uses, negative left of or above
    /// the primary display. No title bar or shadow is taken off. It judges
    /// a window whose setter answered -25205: that app's own answers are not
    /// evidence either way (see `FrameSizingAttempt.Progress.serverJudged`).
    /// The lookup is by window id, so a parked, off-screen or other-Space
    /// window still has bounds; it says where a window is, never whether it
    /// is visible or manageable. Discovery decides that. nil from the
    /// closure means no description right now: the window closed, or the
    /// lookup failed. A nil closure keeps such a setter a plain
    /// `writeFailed`.
    var serverFrame: ((CGWindowID) -> CGRect?)?
    /// The windows whose AX answers are not trusted, and how this IO names
    /// one of its windows in it. Every attempt built from one IO shares the
    /// store, so a candidate's marks reach its retry and its rollback.
    var suspects = FrameSuspects()
    var suspectKey: (CGWindowID) -> FrameSuspects.Key = { FrameSuspects.Key(pid: 0, windowID: $0) }
}

extension FrameSizingIO {
    static func accessibility(windows: [CGWindowID: HyprWindow],
                              currentGeneration: @escaping () -> UInt64) -> FrameSizingIO {
        var io = FrameSizingIO(
            setMessagingTimeout: { id, timeout in
                windows[id]?.setMessagingTimeout(timeout) ?? .invalidUIElement
            },
            writeSize: { id, size, _ in windows[id]?.writeSize(size) ?? .invalidUIElement },
            writePosition: { id, position, _ in windows[id]?.writePosition(position) ?? .invalidUIElement },
            readPosition: { id, _ in windows[id]?.readPosition() ?? (.invalidUIElement, nil) },
            readSize: { id, _ in windows[id]?.readSize() ?? (.invalidUIElement, nil) },
            now: { ProcessInfo.processInfo.systemUptime },
            sleep: { Thread.sleep(forTimeInterval: $0) },
            currentGeneration: currentGeneration,
            beginFrameWrite: { id, timeout, checkpoint in
                windows[id]?.beginFrameWrite(timeout: timeout, checkpoint: checkpoint)
                    ?? .failed(.invalidUIElement)
            },
            endFrameWrite: { token, timeout, checkpoint in
                AXFrameWriteBatch.accessibility.end(token, timeout: timeout,
                                                    checkpoint: checkpoint)
            }
        )
        io.serverFrame = { WindowStacking.bounds(of: $0) }
        io.suspects = .shared
        io.suspectKey = { FrameSuspects.Key(pid: windows[$0]?.ownerPID ?? 0, windowID: $0) }
        if LogConfig.frameWriteTrace {
            io.traceFrame = { id in
                guard let window = windows[id],
                      case let (.success, origin?) = window.readPosition(),
                      case let (.success, size?) = window.readSize() else { return nil }
                return CGRect(origin: origin, size: size)
            }
        }
        return io
    }
}

/// The windows whose AX answers are not trusted: one of their setters
/// answered -25205, which Dia does whether or not it carried the write out.
/// Such a window is read from the window server by every reader, for as
/// long as it lives. The cost is a 0.2 ms lookup in place of two AX calls.
///
/// Keyed by owner pid and window id, not by `HyprWindow`: a fresh window
/// walk builds new wrappers for the same window. Nothing expires and no
/// pass clears a mark. It is retired only when discovery forgets the window
/// or it comes back after a verified close, so a reused id starts clean.
/// Hiding, minimizing or leaving a tree keeps it.
///
/// Threading: main-thread only, like every frame pass.
final class FrameSuspects {
    struct Key: Hashable {
        let pid: pid_t
        let windowID: CGWindowID
    }

    /// The store production passes share.
    static let shared = FrameSuspects()

    private var marked: Set<Key> = []

    func mark(_ key: Key) { marked.insert(key) }
    func contains(_ key: Key) -> Bool { marked.contains(key) }
    /// The window closed or was replaced.
    func forget(windowID: CGWindowID) {
        marked = marked.filter { $0.windowID != windowID }
    }
}
