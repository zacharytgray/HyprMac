// Standalone CLI for iterating on Space-move private API approaches
// without launching HyprMac. Build:
//   swiftc -F/System/Library/PrivateFrameworks -framework SkyLight \
//     tools/space-test.swift -o tools/space-test
//
// Use:
//   ./tools/space-test list          — print every window + every space
//   ./tools/space-test where <wid>   — show which spaces a window is on
//   ./tools/space-test move <wid> <sid> <method>
//
//   methods:
//     cgs-move    CGSMoveWindowsToManagedSpace
//     sls-move    SLSMoveWindowsToManagedSpace
//     cgs-addrm   CGSAddWindowsToSpaces + CGSRemoveWindowsFromSpaces
//     compat      yabai SLSSpaceSetCompatID + SLSSetWindowListWorkspace
//     compat-flip cookie-on-old-space then -on-new (alternate ordering)
//     all         try every method with read-back between each

import Foundation
import CoreGraphics
import AppKit

@_silgen_name("_CGSDefaultConnection") func _CGSDefaultConnection() -> Int32
@_silgen_name("SLSMainConnectionID")   func SLSMainConnectionID()   -> Int32

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray?

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: Int32, _ type: Int32, _ wids: CFArray) -> CFArray?

@_silgen_name("CGSMoveWindowsToManagedSpace")
func CGSMoveWindowsToManagedSpace(_ cid: Int32, _ wids: CFArray, _ sid: UInt64)

@_silgen_name("SLSMoveWindowsToManagedSpace")
func SLSMoveWindowsToManagedSpace(_ cid: Int32, _ wids: CFArray, _ sid: UInt64)

@_silgen_name("CGSAddWindowsToSpaces")
func CGSAddWindowsToSpaces(_ cid: Int32, _ wids: CFArray, _ sids: CFArray)

@_silgen_name("CGSRemoveWindowsFromSpaces")
func CGSRemoveWindowsFromSpaces(_ cid: Int32, _ wids: CFArray, _ sids: CFArray)

@_silgen_name("SLSSpaceSetCompatID")
func SLSSpaceSetCompatID(_ cid: Int32, _ sid: UInt64, _ workspace: Int32) -> Int32

@_silgen_name("SLSSetWindowListWorkspace")
func SLSSetWindowListWorkspace(_ cid: Int32, _ wids: UnsafePointer<UInt32>, _ count: Int32, _ workspace: Int32) -> Int32

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

let kCGSAllSpacesMask: Int32 = 7

// MARK: - helpers

func widArray(_ wid: UInt32) -> CFArray {
    var w = Int32(bitPattern: wid)
    let cf = CFNumberCreate(nil, .sInt32Type, &w)!
    return [cf] as CFArray
}

func sidArray(_ sid: UInt64) -> CFArray {
    var s = sid
    let cf = CFNumberCreate(nil, .sInt64Type, &s)!
    return [cf] as CFArray
}

func spacesForWindow(_ wid: UInt32) -> [UInt64] {
    let conn = _CGSDefaultConnection()
    guard let cf = CGSCopySpacesForWindows(conn, kCGSAllSpacesMask, widArray(wid)),
          let nums = cf as? [NSNumber] else { return [] }
    return nums.map { $0.uint64Value }
}

func listSpaces() -> [(displayUUID: String, spaces: [UInt64], current: UInt64?)] {
    let conn = _CGSDefaultConnection()
    guard let cf = CGSCopyManagedDisplaySpaces(conn),
          let arr = cf as? [[String: Any]] else { return [] }
    var out: [(String, [UInt64], UInt64?)] = []
    for d in arr {
        let uuid = d["Display Identifier"] as? String ?? "?"
        var ids: [UInt64] = []
        if let spaces = d["Spaces"] as? [[String: Any]] {
            for s in spaces {
                if let t = s["type"] as? Int, t != 0 { continue }
                if let id = s["ManagedSpaceID"] as? UInt64 { ids.append(id) }
                else if let id = s["id64"] as? UInt64 { ids.append(id) }
            }
        }
        var current: UInt64?
        if let cur = d["Current Space"] as? [String: Any] {
            current = (cur["ManagedSpaceID"] as? UInt64) ?? (cur["id64"] as? UInt64)
        }
        out.append((uuid, ids, current))
    }
    return out
}

func listWindows() -> [(wid: UInt32, owner: String, name: String)] {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let arr = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return arr.compactMap { d in
        guard let wid = d[kCGWindowNumber as String] as? UInt32 else { return nil }
        let owner = d[kCGWindowOwnerName as String] as? String ?? "?"
        let name = d[kCGWindowName as String] as? String ?? ""
        return (wid, owner, name)
    }
}

// MARK: - move methods

enum Method: String { case cgsMove = "cgs-move", slsMove = "sls-move",
    cgsAddRm = "cgs-addrm", compat = "compat", compatFlip = "compat-flip", all = "all" }

func tryMove(_ wid: UInt32, to sid: UInt64, method: Method) {
    let conn = _CGSDefaultConnection()
    let slsConn = SLSMainConnectionID()
    print("conn=\(conn) sls-conn=\(slsConn)")
    let before = spacesForWindow(wid)
    print("[\(method.rawValue)] before=\(before) target=\(sid)")

    switch method {
    case .cgsMove:
        CGSMoveWindowsToManagedSpace(conn, widArray(wid), sid)
    case .slsMove:
        SLSMoveWindowsToManagedSpace(slsConn, widArray(wid), sid)
    case .cgsAddRm:
        CGSAddWindowsToSpaces(conn, widArray(wid), sidArray(sid))
        let toRemove = before.filter { $0 != sid }
        if !toRemove.isEmpty {
            let nums = toRemove.map { NSNumber(value: $0) } as CFArray
            CGSRemoveWindowsFromSpaces(conn, widArray(wid), nums)
        }
    case .compat:
        let cookie: Int32 = 0x68797072  // "hypr"
        let wids: [UInt32] = [wid]
        wids.withUnsafeBufferPointer { buf in
            let r1 = SLSSpaceSetCompatID(slsConn, sid, cookie)
            let r2 = SLSSetWindowListWorkspace(slsConn, buf.baseAddress!, Int32(buf.count), cookie)
            let r3 = SLSSpaceSetCompatID(slsConn, sid, 0)
            print("[compat] SLSSpaceSetCompatID=\(r1) SLSSetWindowListWorkspace=\(r2) clear=\(r3)")
        }
    case .compatFlip:
        // tag the OLD space first so windows lose it, then tag the new one
        let cookie: Int32 = 0x68797072
        var wids: [UInt32] = [wid]
        wids.withUnsafeBufferPointer { buf in
            for old in before where old != sid {
                _ = SLSSpaceSetCompatID(slsConn, old, cookie)
                _ = SLSSetWindowListWorkspace(slsConn, buf.baseAddress!, Int32(buf.count), 0)
                _ = SLSSpaceSetCompatID(slsConn, old, 0)
            }
            _ = SLSSpaceSetCompatID(slsConn, sid, cookie)
            _ = SLSSetWindowListWorkspace(slsConn, buf.baseAddress!, Int32(buf.count), cookie)
            _ = SLSSpaceSetCompatID(slsConn, sid, 0)
        }
    case .all:
        for m in [Method.cgsMove, .slsMove, .cgsAddRm, .compat, .compatFlip] {
            tryMove(wid, to: sid, method: m)
            usleep(100_000)
        }
        return
    }

    // give SkyLight a moment to settle
    usleep(50_000)
    let after = spacesForWindow(wid)
    let success = after.contains(sid) && !after.contains(where: { before.contains($0) && $0 != sid })
    let partial = after.contains(sid)
    print("[\(method.rawValue)] after=\(after)  \(success ? "✅ MOVED" : (partial ? "🟡 ASSOCIATED-BUT-NOT-REMOVED" : "❌ NO CHANGE"))")
}

// MARK: - main

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: space-test list | where <wid> | move <wid> <sid> <method>")
    exit(1)
}

switch args[1] {
case "list":
    print("=== SPACES ===")
    for (i, d) in listSpaces().enumerated() {
        print("display \(i): uuid=\(d.displayUUID)")
        for s in d.spaces {
            let mark = s == d.current ? " [active]" : ""
            print("  space \(s)\(mark)")
        }
    }
    print("\n=== WINDOWS (on-screen) ===")
    let filterOwner = args.count >= 3 ? args[2].lowercased() : nil
    for w in listWindows() where w.owner != "Window Server" && w.owner != "Dock" {
        if let f = filterOwner, !w.owner.lowercased().contains(f) { continue }
        let n = w.name.isEmpty ? "(no title)" : String(w.name.prefix(60))
        print("  wid=\(w.wid)  owner=\(w.owner)  name=\(n)")
    }
case "where":
    guard args.count >= 3, let wid = UInt32(args[2]) else { print("usage: where <wid>"); exit(1) }
    print("window \(wid) → spaces=\(spacesForWindow(wid))")
case "move":
    guard args.count >= 5,
          let wid = UInt32(args[2]),
          let sid = UInt64(args[3]),
          let method = Method(rawValue: args[4]) else {
        print("usage: move <wid> <sid> <method>")
        print("methods: cgs-move sls-move cgs-addrm compat compat-flip all")
        exit(1)
    }
    tryMove(wid, to: sid, method: method)
case "park":
    // Park a cross-process window via AX at extreme coordinates and
    // read back the actual position macOS accepted. Tests whether
    // far-off-screen positions are clamped back into a monitor's
    // bounding rect (which is what causes the middle-monitor leak).
    //
    // Usage: park <wid> <x> <y>
    guard args.count >= 5,
          let wid = UInt32(args[2]),
          let x = Double(args[3]),
          let y = Double(args[4]) else {
        print("usage: park <wid> <x> <y>"); exit(1)
    }
    // Look up AX element from CGWindowID
    let opts: CGWindowListOption = [.optionIncludingWindow]
    guard let arr = CGWindowListCopyWindowInfo(opts, wid) as? [[String: Any]],
          let info = arr.first,
          let pid = info[kCGWindowOwnerPID as String] as? pid_t else {
        print("can't find pid for wid \(wid)"); exit(1)
    }
    let app = AXUIElementCreateApplication(pid)
    var windowsRef: AnyObject?
    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
    guard let axWindows = windowsRef as? [AXUIElement] else {
        print("no AX windows for pid \(pid)"); exit(1)
    }
    // Find the AXUIElement whose CGWindowID matches `wid`.
    var matched: AXUIElement?
    for el in axWindows {
        var w: CGWindowID = 0
        if _AXUIElementGetWindow(el, &w) == .success, w == wid { matched = el; break }
    }
    guard let target = matched else { print("no AXUIElement matched wid \(wid)"); exit(1) }

    // Read pre-position
    var posRef: AnyObject?
    AXUIElementCopyAttributeValue(target, kAXPositionAttribute as CFString, &posRef)
    var prePos = CGPoint.zero
    if let posVal = posRef {
        AXValueGetValue(posVal as! AXValue, .cgPoint, &prePos)
    }
    print("before pos=\(prePos)")

    // Write target position
    var newPos = CGPoint(x: x, y: y)
    if let val = AXValueCreate(.cgPoint, &newPos) {
        AXUIElementSetAttributeValue(target, kAXPositionAttribute as CFString, val)
    }
    Thread.sleep(forTimeInterval: 0.2)

    // Read back actual position
    var afterRef: AnyObject?
    AXUIElementCopyAttributeValue(target, kAXPositionAttribute as CFString, &afterRef)
    var afterPos = CGPoint.zero
    if let v = afterRef { AXValueGetValue(v as! AXValue, .cgPoint, &afterPos) }
    print("after  pos=\(afterPos) (requested \(newPos))")
    print(prePos == afterPos ? "❌ position write rejected (no change)"
          : (afterPos == newPos ? "✅ position write accepted exactly"
             : "🟡 position clamped — macOS moved it to \(afterPos)"))

case "self":
    // Self-owned NSWindow. Wait long enough for it to actually land
    // on a Space, then attempt a real cross-Space move (not just an
    // add to an empty space-list).
    guard args.count >= 3, let sid = UInt64(args[2]) else {
        print("usage: self <target-sid>"); exit(1)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let win = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                       styleMask: [.titled, .closable, .resizable],
                       backing: .buffered, defer: false)
    win.title = "space-test target"
    win.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    // wait long enough for the window to actually attach to a Space
    Thread.sleep(forTimeInterval: 1.5)

    let wid = UInt32(win.windowNumber)
    let initial = spacesForWindow(wid)
    print("self-owned window wid=\(wid)  initial-space=\(initial)")
    if initial.contains(sid) {
        print("WARN: target sid \(sid) is already in initial — pick a different one for a real move test")
    }

    for m in [Method.cgsMove, .slsMove, .cgsAddRm, .compat, .compatFlip] {
        Thread.sleep(forTimeInterval: 0.3)
        tryMove(wid, to: sid, method: m)
    }
    print("\nKeeping window open for 5s so you can verify in Mission Control...")
    Thread.sleep(forTimeInterval: 5)
default:
    print("unknown command \(args[1])")
    exit(1)
}
