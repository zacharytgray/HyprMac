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

    /// Nothing declared yet: a failed read, or no minimum on either axis.
    /// A brand-new window often reads this way for a while.
    static func isEmpty(_ limits: DeclaredSizeLimits?) -> Bool {
        guard let limits else { return true }
        return limits.min.width <= 1 && limits.min.height <= 1
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

/// Where a window that left the screen is, by the window server's Spaces.
/// An app's AX window list holds only the windows on the current Space, so a
/// window on a Space its display does not show reads as closed to AX.
enum OffSpaceStanding: Equatable {
    /// its display shows a native full-screen Space (or Split View)
    case behindFullScreen
    /// its display shows another desktop Space
    case onOtherDesktop
}

/// The window server's answer for some missing windows.
struct SpaceAnswers: Equatable {
    /// the ones on a Space their display does not show
    var offSpace: [CGWindowID: OffSpaceStanding] = [:]
    /// every id the window server answered for, wherever it is. One it did
    /// not answer for is left to AX alone, as before Spaces were asked
    var answered: Set<CGWindowID> = []
}

enum WindowSpaces {
    /// One display's Spaces: the current one, its type, and every Space it has.
    struct Display: Equatable {
        let current: UInt64
        let currentIsFullScreen: Bool
        let spaces: Set<UInt64>
    }

    /// SkyLight's type for a native full-screen Space.
    static let fullScreenSpaceType = 4

    /// Where a window on `windowSpaces` stands. nil when it is on a current
    /// Space, on none (ordered out, closed) or on one no display has.
    static func standing(windowSpaces: [UInt64], displays: [Display]) -> OffSpaceStanding? {
        guard !windowSpaces.isEmpty else { return nil }
        let current = Set(displays.map(\.current))
        guard current.isDisjoint(with: windowSpaces) else { return nil }
        guard let display = displays.first(where: { !$0.spaces.isDisjoint(with: windowSpaces) }) else { return nil }
        return display.currentIsFullScreen ? .behindFullScreen : .onOtherDesktop
    }

    /// Where each of `ids` is: off-Space, or answered and not. One
    /// window-server question per id, plus one for the displays. A failed
    /// question answers nothing.
    static func answers(_ ids: Set<CGWindowID>) -> SpaceAnswers {
        guard !ids.isEmpty, let calls = SkyLightSpaceCalls.shared else { return SpaceAnswers() }
        let cid = calls.mainConnectionID()
        guard let raw = calls.copyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]]
        else { return SpaceAnswers() }
        let displays = raw.compactMap(display(from:))
        // every display must read, or a current Space could be missed
        guard !displays.isEmpty, displays.count == raw.count else { return SpaceAnswers() }
        var result = SpaceAnswers()
        for id in ids {
            let list = [NSNumber(value: id)] as CFArray
            // 0x7: every Space the window is on, current or not
            guard let spaces = calls.copySpacesForWindows(cid, 0x7, list)?.takeRetainedValue() as? [NSNumber]
            else { continue }
            result.answered.insert(id)
            if let standing = standing(windowSpaces: spaces.map(\.uint64Value), displays: displays) {
                result.offSpace[id] = standing
            }
        }
        return result
    }

    /// Which of `ids` are on a native full-screen Space a display shows now.
    /// One window-server question for the displays, and one per id only
    /// while such a Space is shown. A failed question answers none.
    static func onShownFullScreenSpace(_ ids: Set<CGWindowID>) -> Set<CGWindowID> {
        guard !ids.isEmpty, let calls = SkyLightSpaceCalls.shared else { return [] }
        let cid = calls.mainConnectionID()
        guard let raw = calls.copyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        let shown = Set(raw.compactMap(display(from:)).filter(\.currentIsFullScreen).map(\.current))
        guard !shown.isEmpty else { return [] }
        return ids.filter { id in
            let list = [NSNumber(value: id)] as CFArray
            guard let spaces = calls.copySpacesForWindows(cid, 0x7, list)?.takeRetainedValue() as? [NSNumber]
            else { return false }
            return !shown.isDisjoint(with: spaces.map(\.uint64Value))
        }
    }

    private static func display(from entry: [String: Any]) -> Display? {
        guard let current = entry["Current Space"] as? [String: Any],
              let currentID = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value else { return nil }
        let spaces = (entry["Spaces"] as? [[String: Any]] ?? [])
            .compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
        let type = (current["type"] as? NSNumber)?.intValue
        return Display(current: currentID, currentIsFullScreen: type == fullScreenSpaceType,
                       spaces: Set(spaces).union([currentID]))
    }
}

private struct SkyLightSpaceCalls {
    typealias MainConnectionID = @convention(c) () -> Int32
    // both return a +1 reference
    typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    let mainConnectionID: MainConnectionID
    let copyManagedDisplaySpaces: CopyManagedDisplaySpaces
    let copySpacesForWindows: CopySpacesForWindows

    static let shared: SkyLightSpaceCalls? = {
        // RTLD_DEFAULT: SkyLight is already linked
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        func symbol<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let main = symbol("SLSMainConnectionID", as: MainConnectionID.self),
              let displays = symbol("SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self),
              let spaces = symbol("SLSCopySpacesForWindows", as: CopySpacesForWindows.self) else {
            hyprLog(.notice, .discovery, "window spaces: SkyLight Space calls unavailable")
            return nil
        }
        return SkyLightSpaceCalls(mainConnectionID: main, copyManagedDisplaySpaces: displays,
                                  copySpacesForWindows: spaces)
    }()
}
