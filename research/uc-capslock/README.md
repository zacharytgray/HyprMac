# Caps Lock over Universal Control: research notes

Preliminary research for https://github.com/zacharytgray/HyprMac/issues/115. None of this has been tested with two Macs yet.

## The problem

HyprMac remaps Caps Lock to F18 with `UserKeyMapping` and treats F18 as the Hypr key. Over Universal Control, Caps Lock pressed on the other Mac arrives as a plain Caps Lock, so Hypr chords do nothing.

## What we found

**Universal Control types through its own virtual keyboard on the receiving Mac.**
- `UniversalControl.app` imports `HIDVirtualEventService`, `IOHIDEventCreateKeyboardEvent` and `IOHIDEventSetSenderID`. It imports no `CGEventPost`.
- So its keys go through the HID event system as a virtual service, the same path as a real keyboard. They are not posted CGEvents.
- On an idle Mac, `hidutil list` shows a `V-UC Automouse` service with Transport `UniversalControl` and VendorID/ProductID 0xff00. It appears under Services only, not Devices. We expect a matching keyboard service once the other Mac starts typing, but haven't seen one yet.
- Universal Control also syncs Caps Lock state between the Macs. Its binary contains `Caps Lock resync` and `HIDCapsLockState` strings.

**Probable cause.** `UserKeyMapping` is kept per keyboard service by the keyboard filter in IOHIDFamily: `setPropertyForClient` in [IOHIDKeyboardFilter.mm](https://github.com/apple-oss-distributions/IOHIDFamily/blob/IOHIDFamily-2238.120.5/IOHIDEventSystemPlugIns/IOHIDKeyboardFilter.mm). The virtual keyboard appears after HyprMac has set the mapping, so it most likely has none. That's the same situation as a keyboard plugged in late.

**Why HyprMac doesn't repair it.** HyprMac already copies the mapping onto keyboards that lack one. It just never notices this keyboard arrive:
- `KeyRemapper.readKeyboardMappings` (`HyprMac/Core/Input/KeyRemapper.swift:289`) lists services from the event system, which includes virtual ones.
- `copyListToKeyboardsWithoutOne` (`KeyRemapper.swift:148`) writes the mapping to each keyboard that has none, through `writeKeyboardMapping` (`KeyRemapper.swift:303`).
- That runs from `reassertHyprKey` (`KeyRemapper.swift:117`), on wake and unlock (`HyprMac/Core/WindowManager.swift:3987`) and when a keyboard arrives (`WindowManager.swift:226`).
- The arrival watcher matches `IOServiceMatching("IOHIDEventService")` (`KeyRemapper.swift:446`). A virtual service is not in the IORegistry, so it never fires for Universal Control.
- `PhysicalKeyMonitor` uses `IOHIDManager`, which also only sees IORegistry devices. So it won't see Universal Control presses either.

## Possible fixes, most reliable first

1. **Give the Universal Control keyboard the mapping when it appears.** This needs no event-level detection and only touches that one service, so other virtual keyboards are unaffected. It needs a trigger that sees virtual services. Two options:
   - the private `IOHIDEventSystemClientRegisterDeviceMatchingCallback`;
   - or calling `reassertHyprKey` when the event tap sees a plain Caps Lock (keycode 57) while the remap is on. That loses the first press.
2. **Match the sender of the IOHIDEvent behind each CGEvent** (`CGEventCopyIOHIDEvent` and `IOHIDEventGetSenderID`) against services whose Transport is `UniversalControl`. This is private API. Caps Lock also gives no release event this way, and the lock would still toggle.
3. **CGEvent source fields** (PID, source state, keyboard type). These probably look the same for local and Universal Control keys, so this is not reliable.

Open questions only a two-Mac test can answer:
- Does the virtual keyboard accept a `UserKeyMapping`?
- Does the mapping take effect there?
- Does Universal Control's Caps Lock sync fight it?

## The probe

`main.swift` is a small command-line tool that logs every layer a key passes through.

```sh
swiftc -O main.swift -o uc-capslock-probe -framework IOKit -framework CoreGraphics
```

- `list` prints every keyboard and Universal Control service with its properties and current `UserKeyMapping`. It changes nothing.
- `watch [--all-fields]` prints a live log. It changes nothing.
  - `[SVC+]` and `[SVC-]`: services appearing and going away.
  - `[HIDSYS]`: key events with the service that sent them.
  - `[HIDDEV]`: what `IOHIDManager` sees.
  - `[CG]`: CGEvents with their source fields.
  - `[CAPS]`: Caps Lock state changes.
  - **Note:** this logs every key you press, so don't type passwords while it runs.
- `map-uc` sets Caps Lock → F18 on Universal Control keyboard services only, then reads it back. `unmap-uc` clears it. The service also goes away when Universal Control disconnects.

Run it in Terminal.app on the Mac that receives Universal Control, not over ssh. Terminal needs Input Monitoring.

## Test script

Mac A runs HyprMac with Caps Lock as the Hypr key and receives Universal Control. Mac B is the other Mac.

1. On A, with Universal Control connected: `./uc-capslock-probe list > before.txt`.
2. On A: `./uc-capslock-probe watch --all-fields | tee watch.log`.
3. On A's own keyboard: tap Caps Lock, hold Caps Lock and press H, tap Shift, type `a`.
4. Move B's pointer onto A. On B's keyboard: type `a`, tap Shift, tap Caps Lock, wait 2 s, tap Caps Lock again, then hold Caps Lock and press H.
5. In a second Terminal tab on A: `./uc-capslock-probe list > during.txt`.
6. Still on A: `./uc-capslock-probe map-uc`. Repeat B's Caps Lock tap and Caps Lock+H. Then run `./uc-capslock-probe unmap-uc` and stop `watch` with Ctrl-C.

## What answers the question

**Does Universal Control add a keyboard service without the mapping?** Look for an `[SVC+] ... transport=UniversalControl keyboard=true ... userKeyMapping=none` line when B first types.

**Does fix 1 work?**
- Yes if `map-uc` reads the entry back, B's Caps Lock then logs `[HIDSYS] usage=0x6d (F18)` and `[CG] keyDown keycode=79 (F18)`, and Caps Lock+H does the Hypr action.
- No if B's Caps Lock still logs `usage=0x39` and `keycode=57`.
- A `[CAPS] off -> on` line after `map-uc` means Universal Control's sync is fighting the mapping.

**Is fix 2 possible?** Compare the `[CG]` lines for A's and B's Caps Lock. It is possible if they show `hidEvent{... uc=true}` against `uc=false`. It is ruled out if they show `hidEvent=none`.
