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
