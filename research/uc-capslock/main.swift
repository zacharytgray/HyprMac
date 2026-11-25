// uc-capslock-probe: tells a Universal Control key press apart from a local
// one by logging every layer a key passes through on this Mac.
//
//   list      every HID event system service (virtual ones included) and
//             every IORegistry HID device, with the properties that matter
//   watch     live log, default. four sources, each line tagged:
//               [SVC=]         keyboard and UC services present at start
//               [SVC+]/[SVC-]  event system services appearing / going away
//               [HIDSYS]       keyboard IOHIDEvents from the event system
//                              monitor, with the service that sent them
//               [HIDDEV]       key values from IORegistry devices (IOHIDManager,
//                              the path HyprMac's PhysicalKeyMonitor uses)
//               [CAPS]         this Mac's caps lock state changed (checked
//                              every 100 ms; Universal Control syncs it)
//               [CG]           CGEvents from a listen-only tap, with the
//                              source fields and the IOHIDEvent behind them
//             --all-fields  also dump every nonzero CGEvent integer field
//             --session     tap at session level instead of HID level
//   map-uc    WRITES: puts Caps Lock -> F18 on Universal Control keyboard
//             services only, then reads it back
//   unmap-uc  WRITES: clears UserKeyMapping on those services again
//
// watch and list change nothing. run watch from Terminal.app on the Mac that
// receives Universal Control; Terminal needs Input Monitoring.
//
// build: swiftc -O -target arm64-apple-macos13 main.swift -o uc-capslock-probe \
//          -framework IOKit -framework CoreGraphics

import Foundation
import CoreGraphics
import IOKit
import IOKit.hid
import IOKit.hidsystem

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - private symbols, looked up at run time

private let selfHandle = dlopen(nil, RTLD_NOW)

private func sym<T>(_ name: String, _ type: T.Type) -> T? {
    guard let p = dlsym(selfHandle, name) else { return nil }
    return unsafeBitCast(p, to: type)
}

typealias RawRef = UnsafeMutableRawPointer
typealias CopyHIDEventFn = @convention(c) (CGEvent) -> RawRef?
typealias SenderIDFn = @convention(c) (RawRef) -> UInt64
typealias EventTypeFn = @convention(c) (RawRef) -> UInt32
typealias EventIntFn = @convention(c) (RawRef, UInt32) -> Int
typealias CreateWithTypeFn = @convention(c) (CFAllocator?, Int32, CFDictionary?) -> RawRef?
typealias HIDEventCallback = @convention(c) (RawRef?, RawRef?, RawRef?, RawRef?) -> Void
typealias RegisterEventCallbackFn = @convention(c) (RawRef, HIDEventCallback, RawRef?, RawRef?) -> Void
typealias ScheduleFn = @convention(c) (RawRef, CFRunLoop, CFString) -> Void
typealias ServiceCallback = @convention(c) (RawRef?, RawRef?, RawRef?) -> Void
typealias RegisterServiceCallbackFn = @convention(c) (RawRef, ServiceCallback, RawRef?, RawRef?) -> Void

private let cgEventCopyIOHIDEvent = sym("CGEventCopyIOHIDEvent", CopyHIDEventFn.self)
private let hidEventGetSenderID = sym("IOHIDEventGetSenderID", SenderIDFn.self)
private let hidEventGetType = sym("IOHIDEventGetType", EventTypeFn.self)
private let hidEventGetInt = sym("IOHIDEventGetIntegerValue", EventIntFn.self)
private let clientCreateWithType = sym("IOHIDEventSystemClientCreateWithType", CreateWithTypeFn.self)
private let clientRegisterEvent = sym("IOHIDEventSystemClientRegisterEventCallback", RegisterEventCallbackFn.self)
private let clientSchedule = sym("IOHIDEventSystemClientScheduleWithRunLoop", ScheduleFn.self)
private let clientRegisterMatching = sym("IOHIDEventSystemClientRegisterDeviceMatchingCallback", RegisterServiceCallbackFn.self)
private let serviceRegisterRemoval = sym("IOHIDServiceClientRegisterRemovalCallback", RegisterServiceCallbackFn.self)
typealias SetMatchingMultipleFn = @convention(c) (RawRef, CFArray?) -> Void
private let clientSetMatchingMultiple = sym("IOHIDEventSystemClientSetMatchingMultiple", SetMatchingMultipleFn.self)

// IOHIDEvent keyboard type and fields: type 3, field = type << 16 | index
private let kHIDEventTypeKeyboard: UInt32 = 3
private let kFieldUsagePage: UInt32 = 3 << 16 | 0
private let kFieldUsage: UInt32 = 3 << 16 | 1
private let kFieldDown: UInt32 = 3 << 16 | 2
private let kClientTypeMonitor: Int32 = 1

// MARK: - log

private let start = Date()

func log(_ tag: String, _ text: String) {
    let t = Date().timeIntervalSince(start)
    print(String(format: "t=%8.3f ", t) + "[\(tag)] " + text)
}

func hex(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }

func procName(_ pid: Int64) -> String {
    guard pid > 0 else { return "-" }
    var buf = [CChar](repeating: 0, count: 256)
    let n = proc_name(Int32(pid), &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : "?"
}

// MARK: - event system services

struct ServiceInfo {
    let id: UInt64
    let props: [String: Any]
    let isKeyboard: Bool

    var product: String { props["Product"].map { "\($0)" } ?? "(null)" }
    var transport: String { props["Transport"].map { "\($0)" } ?? "(null)" }
    var isUniversalControl: Bool {
        transport == "UniversalControl" || props["UniversalControlVirtualService"] != nil
            || props["UniversalControlMatchedService"] != nil
    }

    var summary: String {
        func p(_ k: String) -> String {
            guard let v = props[k] else { return "-" }
            if let n = v as? NSNumber, k.hasSuffix("ID") { return hex(n.uint64Value) }
            return "\(v)".replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: "")
        }
        return "id=\(hex(id)) product=\"\(product)\" transport=\(transport) "
            + "vendor=\(p("VendorID")) productID=\(p("ProductID")) location=\(p("LocationID")) "
            + "primary=\(p("PrimaryUsagePage"))/\(p("PrimaryUsage")) keyboard=\(isKeyboard) "
            + "builtIn=\(p("Built-In")) uc=\(isUniversalControl)"
    }
}

// property keys worth reading on every service. a virtual service only
// answers keys it is asked for, so they are named here.
let serviceKeys = [
    "Product", "Manufacturer", "Transport", "VendorID", "ProductID", "LocationID",
    "PrimaryUsagePage", "PrimaryUsage", "DeviceUsagePairs", "Built-In", "CountryCode",
    "HIDVirtualDevice", "UniversalControlVirtualService", "UniversalControlMatchedService",
    "UniversalControlBuiltIn", "HIDUniversalSenderID", "KeyboardLanguage",
    "UserKeyMapping", "HIDCapsLockState", "HIDKeyboardModifierMappingPairs", "IOClass",
]

// a simple client, kept alive for the whole run: a service client used
// after its event system client is gone aborts the process
let simpleClient = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)

func readService(_ s: IOHIDServiceClient) -> ServiceInfo? {
    guard let idNum = IOHIDServiceClientGetRegistryID(s) as? NSNumber else { return nil }
    var props: [String: Any] = [:]
    for k in serviceKeys {
        if let v = IOHIDServiceClientCopyProperty(s, k as CFString) { props[k] = v }
    }
    let kb = IOHIDServiceClientConformsTo(s, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0
    return ServiceInfo(id: idNum.uint64Value, props: props, isKeyboard: kb)
}

func allServices() -> [(IOHIDServiceClient, ServiceInfo)] {
    let services = IOHIDEventSystemClientCopyServices(simpleClient) as? [IOHIDServiceClient] ?? []
    return services.compactMap { s in readService(s).map { (s, $0) } }
}

var serviceCache: [UInt64: ServiceInfo] = [:]

func refreshServiceCache() {
    for (_, info) in allServices() { serviceCache[info.id] = info }
}

func describeSender(_ id: UInt64) -> String {
    if serviceCache[id] == nil { refreshServiceCache() }
    guard let info = serviceCache[id] else { return "sender=\(hex(id)) (no such service)" }
    return "sender=\(hex(id)) \"\(info.product)\" transport=\(info.transport) uc=\(info.isUniversalControl)"
}

// MARK: - caps lock state

func capsLockState() -> String {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
    guard service != 0 else { return "?" }
    defer { IOObjectRelease(service) }
    var connect: io_connect_t = 0
    guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return "?" }
    defer { IOServiceClose(connect) }
    var on = false
    guard IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &on) == KERN_SUCCESS else { return "?" }
    return on ? "on" : "off"
}

// MARK: - list

func listAll() {
    let mapping = IOHIDEventSystemClientCopyProperty(simpleClient, kIOHIDUserKeyUsageMapKey as CFString)
    print("system-wide UserKeyMapping: \(mapping.map { "\($0)" } ?? "(not set)")")
    print("caps lock state: \(capsLockState())")
    print("\n== event system services (what hidd routes events through; virtual ones included)")
    for (_, info) in allServices().sorted(by: { $0.1.id < $1.1.id }) {
        guard info.isKeyboard || info.isUniversalControl else { continue }
        print(info.summary)
        for k in ["DeviceUsagePairs", "UserKeyMapping", "HIDCapsLockState", "HIDVirtualDevice",
                  "UniversalControlVirtualService", "UniversalControlMatchedService",
                  "UniversalControlBuiltIn", "HIDUniversalSenderID", "KeyboardLanguage", "Manufacturer"] {
            if let v = info.props[k] {
                print("    \(k) = " + "\(v)".replacingOccurrences(of: "\n", with: " "))
            }
        }
    }
    print("\n== IORegistry HID devices that are keyboards (what IOHIDManager and PhysicalKeyMonitor see)")
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                                        kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard] as CFDictionary)
    let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> ?? []
    for d in devices { print(deviceSummary(d)) }
    print("\n(the hidutil list output, for comparison)")
    let task = Process()
    task.launchPath = "/usr/bin/hidutil"
    task.arguments = ["list"]
    try? task.run()
    task.waitUntilExit()
}

func deviceSummary(_ d: IOHIDDevice) -> String {
    func p(_ k: String) -> String {
        guard let v = IOHIDDeviceGetProperty(d, k as CFString) else { return "-" }
        if let n = v as? NSNumber, k != "Product" { return hex(n.uint64Value) }
        return "\(v)"
    }
    return "device product=\"\(p(kIOHIDProductKey))\" transport=\(p(kIOHIDTransportKey)) "
        + "vendor=\(p(kIOHIDVendorIDKey)) productID=\(p(kIOHIDProductIDKey)) location=\(p(kIOHIDLocationIDKey))"
}

// MARK: - map-uc / unmap-uc

func setUCMapping(_ entries: [[String: UInt64]]) {
    let ucKeyboards = allServices().filter { $0.1.isUniversalControl && $0.1.isKeyboard }
    if ucKeyboards.isEmpty {
        print("no Universal Control keyboard service right now. start Universal Control, press a key on the other Mac, and run this again.")
        let ucAny = allServices().filter { $0.1.isUniversalControl }
        for (_, info) in ucAny { print("  (UC service that is not a keyboard: \(info.summary))") }
        return
    }
    for (s, info) in ucKeyboards {
        let ok = IOHIDServiceClientSetProperty(s, kIOHIDUserKeyUsageMapKey as CFString, entries as CFArray)
        let back = IOHIDServiceClientCopyProperty(s, kIOHIDUserKeyUsageMapKey as CFString)
        print("\(info.summary)\n    set returned \(ok); reads back: " + "\(back.map { "\($0)" } ?? "nil")".replacingOccurrences(of: "\n", with: " "))
    }
}

// MARK: - watch: event system monitor

private let hidEventCallback: HIDEventCallback = { _, _, _, event in
    guard let event, let getType = hidEventGetType, let getInt = hidEventGetInt else { return }
    guard getType(event) == kHIDEventTypeKeyboard else { return }
    let page = getInt(event, kFieldUsagePage)
    let usage = getInt(event, kFieldUsage)
    let down = getInt(event, kFieldDown)
    let sender = hidEventGetSenderID?(event) ?? 0
    let name = usage == 0x39 ? " (Caps Lock)" : usage == 0x6D ? " (F18)" : ""
    log("HIDSYS", "page=\(hex(UInt64(page))) usage=\(hex(UInt64(usage)))\(name) down=\(down) \(describeSender(sender))")
}

private let serviceAdded: ServiceCallback = { _, _, service in
    guard let service else { return }
    let s = Unmanaged<IOHIDServiceClient>.fromOpaque(service).takeUnretainedValue()
    guard let info = readService(s) else { return }
    serviceCache[info.id] = info
    log("SVC+", info.summary + " userKeyMapping=" + "\(info.props["UserKeyMapping"].map { "\($0)" } ?? "none")".replacingOccurrences(of: "\n", with: " "))
    serviceRegisterRemoval?(service, serviceRemoved, nil, nil)
}

private let serviceRemoved: ServiceCallback = { _, _, service in
    guard let service else { return }
    let s = Unmanaged<IOHIDServiceClient>.fromOpaque(service).takeUnretainedValue()
    let id = (IOHIDServiceClientGetRegistryID(s) as? NSNumber)?.uint64Value ?? 0
    let name = serviceCache[id]?.product ?? "?"
    log("SVC-", "id=\(hex(id)) \"\(name)\"")
}

var monitorClient: RawRef?

func startEventSystemMonitor() {
    guard let create = clientCreateWithType, let register = clientRegisterEvent, let schedule = clientSchedule else {
        log("INFO", "event system monitor: private symbols missing, skipped")
        return
    }
    guard let client = create(kCFAllocatorDefault, kClientTypeMonitor, nil) else {
        log("INFO", "event system monitor: could not create a monitor client (Input Monitoring?), skipped")
        return
    }
    monitorClient = client
    // same order as Apple's IOHIDEventSystemMonitor tool: schedule, event
    // callback, matching (nil = every service), then the service callback
    schedule(client, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    register(client, hidEventCallback, nil, nil)
    clientSetMatchingMultiple?(client, nil)
    clientRegisterMatching?(client, serviceAdded, nil, nil)
    log("INFO", "event system monitor started")
    // the services already here, keyboards and UC ones only
    for (s, info) in allServices() where info.isKeyboard || info.isUniversalControl {
        log("SVC=", info.summary + " userKeyMapping=" + "\(info.props["UserKeyMapping"].map { "\($0)" } ?? "none")".replacingOccurrences(of: "\n", with: " "))
        serviceRegisterRemoval?(Unmanaged.passUnretained(s).toOpaque(), serviceRemoved, nil, nil)
    }
}

// MARK: - watch: IORegistry devices

private let deviceValueCallback: IOHIDValueCallback = { _, _, _, value in
    let element = IOHIDValueGetElement(value)
    let usage = IOHIDElementGetUsage(element)
    guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad),
          (4...0xE7).contains(usage) else { return }
    let device = IOHIDElementGetDevice(element)
    let name = usage == 0x39 ? " (Caps Lock)" : usage == 0x6D ? " (F18)" : ""
    log("HIDDEV", "usage=\(hex(UInt64(usage)))\(name) down=\(IOHIDValueGetIntegerValue(value)) \(deviceSummary(device))")
}

func startDeviceMonitor() {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                                        kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard] as CFDictionary)
    IOHIDManagerSetInputValueMatching(mgr, [kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad] as CFDictionary)
    IOHIDManagerRegisterInputValueCallback(mgr, deviceValueCallback, nil)
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    log("INFO", r == kIOReturnSuccess ? "IOHIDManager device monitor started"
        : "IOHIDManager open failed (\(hex(UInt64(UInt32(bitPattern: r))))), device lines will be missing")
    deviceManager = mgr
}

var deviceManager: IOHIDManager?

// MARK: - watch: CGEvent tap

var allFields = false

func typeName(_ t: CGEventType) -> String {
    switch t {
    case .keyDown: return "keyDown"
    case .keyUp: return "keyUp"
    case .flagsChanged: return "flagsChanged"
    default: return "type\(t.rawValue)"
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        log("INFO", "tap disabled (\(type.rawValue)), re-enabling")
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags.rawValue
    let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
    let state = event.getIntegerValueField(.eventSourceStateID)
    let kbType = event.getIntegerValueField(.keyboardEventKeyboardType)
    let userData = event.getIntegerValueField(.eventSourceUserData)
    let repeatFlag = event.getIntegerValueField(.keyboardEventAutorepeat)
    let alpha = event.flags.contains(.maskAlphaShift) ? " alphaShift" : ""
    let name = code == 57 ? " (Caps Lock)" : code == 79 ? " (F18)" : ""
    var hid = "hidEvent=none"
    if let copy = cgEventCopyIOHIDEvent, let h = copy(event) {
        let sender = hidEventGetSenderID?(h) ?? 0
        var usageText = ""
        if hidEventGetType?(h) == kHIDEventTypeKeyboard, let getInt = hidEventGetInt {
            usageText = " usage=\(hex(UInt64(getInt(h, kFieldUsage)))) down=\(getInt(h, kFieldDown))"
        } else if let t = hidEventGetType?(h) {
            usageText = " hidType=\(t)"
        }
        hid = "hidEvent{\(describeSender(sender))\(usageText)}"
        Unmanaged<AnyObject>.fromOpaque(h).release()
    }
    var line = "\(typeName(type)) keycode=\(code)\(name) flags=\(hex(flags))\(alpha) repeat=\(repeatFlag) "
        + "srcPID=\(pid) (\(procName(pid))) srcState=\(state) kbType=\(kbType) userData=\(userData) \(hid)"
    if code == 57 || code == 79 { line += " capsState=\(capsLockState())" }
    log("CG", line)
    if allFields {
        var parts: [String] = []
        for raw in 0...255 {
            guard let f = CGEventField(rawValue: UInt32(raw)) else { continue }
            let v = event.getIntegerValueField(f)
            if v != 0 { parts.append("\(raw)=\(v)") }
        }
        log("CGF", parts.joined(separator: " "))
    }
    return Unmanaged.passUnretained(event)
}

var eventTap: CFMachPort?

func startTap(session: Bool) {
    let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        | (1 << CGEventType.flagsChanged.rawValue)
    guard let tap = CGEvent.tapCreate(tap: session ? .cgSessionEventTap : .cghidEventTap,
                                      place: .headInsertEventTap, options: .listenOnly,
                                      eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else {
        log("INFO", "CGEvent tap failed: give Terminal Input Monitoring in System Settings > Privacy & Security, then rerun")
        return
    }
    eventTap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log("INFO", "listen-only CGEvent tap started at \(session ? "session" : "HID") level")
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
let mode = args.first(where: { !$0.hasPrefix("--") }) ?? "watch"
allFields = args.contains("--all-fields")

switch mode {
case "list":
    listAll()
case "map-uc":
    setUCMapping([[kIOHIDKeyboardModifierMappingSrcKey: 0x700000039, kIOHIDKeyboardModifierMappingDstKey: 0x70000006D]])
case "unmap-uc":
    setUCMapping([])
case "watch":
    log("INFO", "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), caps lock \(capsLockState())")
    let mapping = IOHIDEventSystemClientCopyProperty(simpleClient, kIOHIDUserKeyUsageMapKey as CFString)
    log("INFO", "system-wide UserKeyMapping: " + "\(mapping.map { "\($0)" } ?? "(not set)")".replacingOccurrences(of: "\n", with: " "))
    log("INFO", "private symbols: CGEventCopyIOHIDEvent=\(cgEventCopyIOHIDEvent != nil) monitor=\(clientCreateWithType != nil)")
    refreshServiceCache()
    startEventSystemMonitor()
    startDeviceMonitor()
    startTap(session: args.contains("--session"))
    var lastCaps = capsLockState()
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
        let now = capsLockState()
        if now != lastCaps { log("CAPS", "caps lock \(lastCaps) -> \(now)"); lastCaps = now }
    }
    log("INFO", "watching. ctrl-c to stop")
    CFRunLoopRun()
default:
    print("usage: uc-capslock-probe [watch [--all-fields] [--session] | list | map-uc | unmap-uc]")
    exit(2)
}
