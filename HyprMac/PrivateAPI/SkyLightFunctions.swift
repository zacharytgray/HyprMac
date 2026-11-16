// Private SkyLight APIs. `_SLPSSetFrontProcessWithOptions` activates a
// process without reordering its windows; `SLPSPostEventRecordTo`
// synthesizes keyboard focus events. Same approach yabai and
// AeroSpace use. `DeclaredSizeLimits.read` reads the size limits an app
// declared to WindowServer, for logs only.

import Cocoa

@_silgen_name("_SLPSSetFrontProcessWithOptions") @discardableResult
func _SLPSSetFrontProcessWithOptions(_ psn: inout ProcessSerialNumber, _ wid: UInt32, _ mode: UInt32) -> CGError

@_silgen_name("SLPSPostEventRecordTo") @discardableResult
func SLPSPostEventRecordTo(_ psn: inout ProcessSerialNumber, _ bytes: inout UInt8) -> CGError

@_silgen_name("GetProcessForPID") @discardableResult
func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

/// The min, max and preferred frame sizes an app declared to WindowServer
/// for one window. Title bar included. A hint for logs only: no fit check,
/// layout or min-size memory reads it.
///
/// No limit reads as 0x0 or 1x1 for min and 100000 or infinity for max. A
/// window that cannot resize reads all zeros.
struct DeclaredSizeLimits: Equatable {
    let min: CGSize
    let max: CGSize
    let preferred: CGSize

    var logText: String {
        "min=\(Self.text(min)) max=\(Self.text(max)) pref=\(Self.text(preferred))"
    }

    static func text(_ size: CGSize) -> String {
        String(format: "%gx%g", Double(size.width), Double(size.height))
    }

    /// How a declared minimum compares with the one the app enforced.
    enum Verdict: String {
        case match, declaredLow, declaredHigh, undeclared, unreadable
    }

    /// Compare on the refused axes only; both when neither is named.
    /// declaredHigh wins over declaredLow, which wins over undeclared: the
    /// high side is the one that would refuse a slot the app takes.
    static func verdict(declared: DeclaredSizeLimits?, enforced: CGSize,
                        widthRefused: Bool, heightRefused: Bool) -> Verdict {
        guard let declared else { return .unreadable }
        let both = !widthRefused && !heightRefused
        var axes: [(declared: CGFloat, enforced: CGFloat)] = []
        if widthRefused || both { axes.append((declared.min.width, enforced.width)) }
        if heightRefused || both { axes.append((declared.min.height, enforced.height)) }
        let verdicts: [Verdict] = axes.map { axis in
            if axis.declared <= 1 { return .undeclared }
            if axis.declared > axis.enforced + 1 { return .declaredHigh }
            if axis.declared < axis.enforced - 1 { return .declaredLow }
            return .match
        }
        for verdict in [Verdict.declaredHigh, .declaredLow, .undeclared] where verdicts.contains(verdict) {
            return verdict
        }
        return .match
    }

    /// One window's declared limits, or nil when SkyLight lacks a symbol or
    /// has no such window. Every symbol is looked up at first use, so a
    /// macOS without one logs nothing instead of failing to launch.
    static func read(_ windowID: CGWindowID) -> DeclaredSizeLimits? {
        guard let calls = SkyLightConstraintCalls.shared else { return nil }
        let ids = [NSNumber(value: windowID)] as CFArray
        guard let query = calls.queryWindows(calls.mainConnectionID(),
                                             Unmanaged.passUnretained(ids).toOpaque(), 1) else { return nil }
        defer { Unmanaged<CFTypeRef>.fromOpaque(query).release() }
        guard let iterator = calls.copyWindows(query) else { return nil }
        defer { Unmanaged<CFTypeRef>.fromOpaque(iterator).release() }
        guard calls.advance(iterator) else { return nil }
        var min = CGSize.zero, max = CGSize.zero, preferred = CGSize.zero
        // returns void. declaring a result reads garbage
        calls.getConstraints(iterator, &min, &max, &preferred)
        return DeclaredSizeLimits(min: min, max: max, preferred: preferred)
    }
}

/// SLSWindowQueryWindows -> SLSWindowQueryResultCopyWindows ->
/// SLSWindowIteratorAdvance -> SLSWindowIteratorGetConstraints. Do not use
/// SLSPackagesGetWindowConstraints: it reads zeros.
private struct SkyLightConstraintCalls {
    typealias MainConnectionID = @convention(c) () -> Int32
    // both return a +1 reference
    typealias QueryWindows = @convention(c) (Int32, UnsafeRawPointer, Int32) -> UnsafeRawPointer?
    typealias CopyWindows = @convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?
    typealias Advance = @convention(c) (UnsafeRawPointer) -> Bool
    typealias GetConstraints = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<CGSize>,
                                               UnsafeMutablePointer<CGSize>,
                                               UnsafeMutablePointer<CGSize>) -> Void

    let mainConnectionID: MainConnectionID
    let queryWindows: QueryWindows
    let copyWindows: CopyWindows
    let advance: Advance
    let getConstraints: GetConstraints

    static let shared: SkyLightConstraintCalls? = {
        // RTLD_DEFAULT: SkyLight is already linked
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        func symbol<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let main = symbol("SLSMainConnectionID", as: MainConnectionID.self),
              let query = symbol("SLSWindowQueryWindows", as: QueryWindows.self),
              let copy = symbol("SLSWindowQueryResultCopyWindows", as: CopyWindows.self),
              let advance = symbol("SLSWindowIteratorAdvance", as: Advance.self),
              let constraints = symbol("SLSWindowIteratorGetConstraints", as: GetConstraints.self) else {
            hyprLog(.notice, .tiling, "declared limits: SkyLight constraint calls unavailable")
            return nil
        }
        return SkyLightConstraintCalls(mainConnectionID: main, queryWindows: query, copyWindows: copy,
                                       advance: advance, getConstraints: constraints)
    }()
}
