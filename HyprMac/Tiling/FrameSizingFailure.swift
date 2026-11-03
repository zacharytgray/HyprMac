// Why a frame sizing attempt failed.

import Cocoa

enum FrameSizingFailure: Equatable {
    indirect case cleanupFailed(CGWindowID, primary: FrameSizingFailure?, error: AXError)
    case writeFailed(CGWindowID, AXError)
    case readFailed(CGWindowID, AXError)
    case deadlineExceeded
    case attemptsExhausted
    case noFittingSlot(CGWindowID)
    case geometryMismatch(CGWindowID)
    case outsideUsableFrame(CGWindowID)
    case overlap(CGWindowID, CGWindowID)
    case gapViolation(CGWindowID, CGWindowID)
    case windowUnavailable(CGWindowID)
    case duplicateWindowID(CGWindowID)
    case invalidFrame(CGWindowID)
    case superseded
}

extension FrameSizingFailure {
    /// The windows answered and the frames did not work together. Another
    /// arrangement may still fit, unlike an AX failure or a superseded pass.
    var isGeometricRefusal: Bool {
        switch self {
        case .geometryMismatch, .outsideUsableFrame, .overlap, .gapViolation: return true
        default: return false
        }
    }

    /// The app did not answer in time: the attempt ran out of budget, the
    /// readback never settled, or AX gave up waiting (`cannotComplete` is
    /// what a messaging timeout returns). None of these says the app refused
    /// the frames. Admission recovery retries them instead of floating.
    var isTimeout: Bool {
        switch self {
        case .deadlineExceeded, .attemptsExhausted:
            return true
        case let .writeFailed(_, error), let .readFailed(_, error):
            return error == .cannotComplete
        case let .cleanupFailed(_, primary, error):
            return primary?.isTimeout ?? (error == .cannotComplete)
        default:
            return false
        }
    }

    /// AX did not carry out or did not answer a call: a setter, a read, or
    /// the cleanup after them came back with an error, or the attempt ran
    /// out of time. It says nothing about whether the frames fit, so the
    /// same layout may land on a later pass. Seen live: a browser window
    /// refused its grow into a closed neighbour's slot and took it 250 ms
    /// later.
    var isAXFailure: Bool {
        switch self {
        case .writeFailed, .readFailed, .cleanupFailed: return true
        default: return isTimeout
        }
    }

    /// A setter or read that AX gave up on itself, not wrapped in a cleanup
    /// failure. What an AX timeout recovery may try again.
    var isDirectCannotComplete: Bool {
        switch self {
        case .writeFailed(_, .cannotComplete), .readFailed(_, .cannotComplete): true
        default: false
        }
    }

    /// The windows the failure names: the one that refused or lost its
    /// frame, both of an overlapping or gapless pair, the primary failure's
    /// windows behind a cleanup failure. Empty for the failures nobody
    /// caused — a deadline, an exhausted attempt budget, a superseded pass.
    /// The admission recovery reads it as the newcomers to give up on while
    /// the rest of a refused arrangement gets its pass again.
    var namedWindowIDs: Set<CGWindowID> {
        switch self {
        case let .cleanupFailed(id, primary, _):
            return primary?.namedWindowIDs ?? [id]
        case let .writeFailed(id, _), let .readFailed(id, _),
             let .noFittingSlot(id), let .geometryMismatch(id), let .outsideUsableFrame(id),
             let .windowUnavailable(id), let .duplicateWindowID(id), let .invalidFrame(id):
            return [id]
        case let .overlap(first, second), let .gapViolation(first, second):
            return [first, second]
        case .deadlineExceeded, .attemptsExhausted, .superseded:
            return []
        }
    }

    /// The failure with raw AX codes. The synthesized description prints
    /// `__C.AXError`, which does not say which error it was.
    var trace: String {
        switch self {
        case let .writeFailed(id, error): return "writeFailed(\(id), \(error.rawValue))"
        case let .readFailed(id, error): return "readFailed(\(id), \(error.rawValue))"
        case let .cleanupFailed(id, primary, error):
            return "cleanupFailed(\(id), primary: \(primary?.trace ?? "nil"), \(error.rawValue))"
        default: return "\(self)"
        }
    }
}
