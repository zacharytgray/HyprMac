# HyprMac Architecture

HyprMac is a keyboard-driven tiling window manager for macOS. The Caps
Lock key is remapped at the IOKit driver level to F18 and used as the
"Hypr" modifier. Hotkeys feed into a thin orchestration layer that
delegates to focused subsystems for tiling, focus, workspaces,
floating, drag, and discovery.

This document is the long-form companion to `CLAUDE.md`. CLAUDE.md is
the build / run / style guide; this is the structural narrative.

## Module layout

```
HyprMac/
├── App/                      lifecycle, settings shell, menu bar
├── Core/
│   ├── Discovery/            window discovery service
│   ├── Input/                drag-swap result application
│   ├── Orchestration/        action dispatch, polling
│   ├── State/                window state cache, focus, suppressions
│   ├── Workspace/            workspace orchestration
│   └── *.swift               long-lived per-subsystem managers
├── Tiling/                   BSP trees, layout, frame readback
├── Models/                   windows, keybinds, actions, persisted config
├── Persistence/              config I/O + schema migration
├── Settings/                 SwiftUI settings panes
├── Welcome/                  onboarding + what's new
├── Shared/                   logging, constants, coordinate space, asserts
└── PrivateAPI/               bridging header + CGS/SkyLight declarations
```

## Long-lived services

`WindowManager` constructs the dependency graph at app launch and
holds the only strong reference to most subsystems. The graph stays
live for the entire app lifetime; nothing in HyprMac is process-wide
singleton except `UserConfig.shared` and `MenuBarState.shared`.

| Service | Responsibility |
|---|---|
| `WindowManager` | Orchestrator. Wires services, drives lifecycle, owns mouse monitors and observers. |
| `HotkeyManager` | Session-level CGEventTap. Translates Hypr-key chords into `Action` values. |
| `KeyRemapper` | hidutil-driven Caps Lock → F18 remap so the Hypr key produces clean keyDown/keyUp events. |
| `AccessibilityManager` | AX bridge. Enumerates windows, resolves the focused window, picks directional neighbors. |
| `DisplayManager` | NSScreen tracking and CG ↔ NS coordinate conversion. |
| `SpaceManager` | macOS native Spaces enumeration via private CGS APIs (read-only). |
| `WorkspaceManager` | HyprMac's nine virtual workspaces, screen↔workspace mapping, home-screen affinity. |
| `TilingEngine` | One BSP tree per `(workspace, screen)` plus smart insert, swap, two-pass min-size resolution. |
| `FloatingWindowController` | Float / tile toggle, cycle, raise-behind, auto-float predicate. |
| `MouseTrackingManager` | Focus-follows-mouse, refocus-under-cursor, menu-tracking suppression. |
| `DragManager` | Classifies drag gestures into resize / swap / cross-monitor / snap-back. |
| `DragSwapHandler` | Applies the classified drag (tree mutation, workspace reassignment, animation). |
| `FocusBorder` | Visual focus indicator. Persistent panels at `.floating` level with occlusion masking. |
| `DimmingOverlay` | Dim mask over non-focused tiled windows; one panel per display at `.floating - 1`. |
| `WindowAnimator` | Screenshot-proxy frame tweens for tile transitions. |
| `CursorManager` | Cursor warp via `CGWarpMouseCursorPosition` + reassociate dance. |
| `AppLauncherManager` | Launch-or-focus path for the `launchApp` action. |
| `KeybindOverlayController` | HUD panel listing every active keybind (`Hypr+K`). |

## Orchestration layer (Core/Orchestration + Core/State + Core/Discovery)

These types decompose what would otherwise be a monolithic
`WindowManager`. Each owns one concern and exposes a small surface:

- **`WindowStateCache`** holds the seven window-keyed dicts that
  classify a window's lifecycle: `knownWindowIDs`,
  `floatingWindowIDs`, `originalFrames`, `windowOwners`,
  `hiddenWindowIDs`, `tiledPositions`, `cachedWindows`.
- **`FocusStateController`** owns the canonical "last focused" id and
  passes through the focus-border tracked id.
- **`SuppressionRegistry`** is a tiny date-gated key-value store for
  short-lived "don't react to X for Y seconds" flags
  (`activation-switch`, `mouse-focus`, `cross-swap-in-flight`).
- **`PollingScheduler`** owns the 1 Hz periodic discovery timer plus a
  coalescing token that funnels notification-driven `schedule(after:)`
  requests down to a single in-flight call. Honors
  `SuppressionRegistry["cross-swap-in-flight"]` so cross-monitor
  drag-swap can hold polling off for the duration of its two
  back-to-back retiles.
- **`WindowDiscoveryService`** runs the diff between the previous and
  current AX snapshot. Owns the lifecycle/classification cache
  mutations on the discovery path; surfaces the rest in a
  `WindowChanges` value the dispatcher applies.
- **`WorkspaceOrchestrator`** sequences the switch / move-window /
  move-workspace flows on top of `WorkspaceManager` and
  `TilingEngine`. No new policy lives here — each workflow is the
  right sequence of calls plus the focus/cursor/border glue.
- **`ActionDispatcher`** routes `Action` values to the services that
  handle them and runs the post-discovery apply-loop
  (`applyChanges`).

## Hot path

Hotkey trigger:

```
HotkeyManager.eventTap (CGEventTap, main run loop)
  → WindowManager.handleAction
  → ActionDispatcher.dispatch
    ├ FocusStateController       (focus id + visual border)
    ├ WorkspaceOrchestrator      (workspace switch / move)
    ├ FloatingWindowController   (toggle / cycle / raise)
    ├ TilingEngine               (swap / split toggle / retile)
    └ AppLauncherManager         (launch / focus)
        ↓
WindowStateCache mutations
        ↓
TilingEngine.applyLayout (two-pass via FrameReadbackPoller)
        ↓
FocusBorder, DimmingOverlay, WindowAnimator (visual layer)
```

Polling / discovery (parallel):

```
PollingScheduler.timer or NSWorkspace notifications
  → WindowManager.pollWindowChanges
  → WindowDiscoveryService.computeChanges
  → ActionDispatcher.applyChanges
```

## Ownership rules

- **`WindowStateCache`** is the only owner of window-keyed
  classification / lifecycle dicts. Other services read it directly
  and mutate it through the cache.
- **`FocusStateController`** is the only place "last focus intent"
  lives. Every focus action records its result here.
- **`SuppressionRegistry`** owns date-gated time suppressions only.
  Same-stack reentrancy guards (e.g.
  `FloatingWindowController.isRaising`) and in-flight coalescing
  tokens (e.g. `PollingScheduler.pendingPoll`) deliberately do not
  live here.
- **`TilingEngine`** owns the BSP trees. Nothing else mutates
  `tree.root`.
- **`WorkspaceManager`** owns the workspace↔screen mapping. Nothing
  else writes `monitorWorkspace` or `workspaceHomeScreen`.

## Threading

Every public method runs on the main thread. The CGEventTap callback,
mouse monitors, and `NSWorkspace` notifications all fire on the main
run loop. UI-touching classes (`FocusBorder`, `DimmingOverlay`,
`KeybindOverlayController`, `CursorManager`, `WindowAnimator`,
`MouseTrackingManager`) call `mainThreadOnly()` on entry so an
off-main caller crashes loudly in DEBUG.

There is no `async/await` in HyprMac today.

## Logging

Two-tier `os.Logger`-backed logging in `Shared/Log.swift`:

- **Trace** (`.debug` / `.info`) — developer-only, gated by build
  configuration. Emits in DEBUG by default; in Release only when the
  `HyprMacVerboseLogging` `UserDefault` is set, for support sessions.
- **Diagnostic** (`.notice` / `.warning` / `.error` / `.fault`) —
  always emits via `os.Logger`. Visible in Console.app filtered by
  subsystem `com.zachgray.HyprMac` and any of the categories in
  `LogCategory`.

See `docs/debugging.md` for filter recipes and the verbose-logging
toggle.

## Workspaces

HyprMac maintains nine virtual workspaces in userspace. macOS native
Spaces are bypassed — use one native Space per monitor. Inactive
workspaces park their windows at the bottom-right corner of their home
screen (a 1 px sliver remains visible; macOS limitation).

Each workspace remembers a home screen — the monitor it was last
shown on. Switching to a hidden workspace returns it to its home
screen, not the cursor's screen, so workspace identity does not
drift across monitors over time.

See `docs/desktop-switching-notes.md` for the deeper implementation
notes on workspace switching.

## Tiling

BSP dwindle layout. Each split picks the longer axis of the parent
rect by default; `togglesplit` overrides per-node. Smart insert
(`BSPTree.smartInsert`) backtracks to shallower leaves when the
default deepest-right split would create slots below
`TilingConfig.minSlotDimension` (500 px), producing 2×2 grids on
constrained vertical monitors.

Max BSP depth is 3 (smallest slot = 1/8 of screen). Beyond that,
windows auto-float via `TilingEngine.onAutoFloat`.

Two-pass layout via `HyprWindow.setFrameWithReadback`:
1. Pass 1 applies target frames and reads back actual sizes.
2. When pass 1 reveals a min-size conflict (Spotify, Messages, etc.),
   `BSPTree.adjustForMinSizes` redistributes the parent's split ratio
   to give the constrained app more room (clamped to
   `[TilingConfig.minRatio, TilingConfig.maxRatio]`), and pass 2
   re-applies.

`MinSizeMemory` records observed minimums so subsequent layout
decisions know which apps cannot shrink. Min sizes lower only when
the app accepts a tighter resize by at least
`lowerMinSizeAcceptedDeltaPx` (10 px) — sub-pixel accepts cannot
ratchet the floor down.

See `docs/tiling-algorithm.md` for the full algorithm walkthrough.

## Coordinate systems

CG (CoreGraphics) uses a top-left origin; NS (AppKit) uses
bottom-left. Conversion anchors on the primary screen height:

```
ns_y = primaryScreenHeight - cg_y - height
cg_y = primaryScreenHeight - ns_y - height
```

`DisplayManager.primaryScreenHeight` is cached and refreshed on
`didChangeScreenParameters`. Every visible-tile / mouse-coordinate
calculation routes through it.

See `docs/coordinate-systems.md` for the multi-monitor edge cases
and the monitor identity contract (user-facing config keys by
`localizedName`; internal state keys by `displayID`).

## Persistence

`UserConfig` (the `@Published` SwiftUI-observable surface) →
`ConfigStore` (raw I/O + iCloud sync) → JSON on disk at
`~/Library/Application Support/HyprMac/config.json`.

`ConfigMigration` handles one-time data migrations and schema
versioning. Today: the monitor-config split (per-machine
`maxSplitsPerMonitor` and `disabledMonitors` extracted from the
synced config). Future schema bumps land here too.

The on-disk JSON wire format for keybinds is frozen — see
`docs/keybinds-and-actions.md` for the contract.

## Permissions

- **Accessibility** (System Settings → Privacy → Accessibility) —
  required for AX queries and CGEventTap. AX permission gate runs
  in `AppDelegate.applicationDidFinishLaunching`; the user is
  prompted on first launch.
- **Caps Lock set to "Caps Lock"** in System Settings → Keyboard →
  Modifier Keys — `hidutil` needs the OS to pass the keypress through
  before the IOKit remap fires. `KeyRemapper.clearSystemModifierOverrides`
  clears competing OS-level remaps.

HyprMac runs without disabling SIP, but is not App Store compatible —
it uses private SkyLight APIs (`_SLPSSetFrontProcessWithOptions`,
`SLPSPostEventRecordTo`), private CGS APIs
(`CGSCopyManagedDisplaySpaces`), and `hidutil` shell execution. The
public API replacements do not exist.

## Known limitations

These are documented in detail in their respective `docs/` files;
this list is the index.

- **1 px hide-corner sliver** — hidden workspace windows leave a
  one-pixel visible corner. macOS limitation.
- **Floating windows can sit behind tiled windows** — without SIP
  disabled, HyprMac cannot reliably set another process's window
  level. `Hypr+F` cycles and raises floaters; `raiseBehind` runs
  automatically on app activation.
- **Squishy-sibling swap rejection** — when a swap squishes a
  sibling app that has no AX-reported or readback-confirmed minimum
  size (the canonical case in the user's setup is Sidenote), the
  mathematical layout fits and the swap accepts even though the
  resulting compression may look wrong. See
  `docs/tiling-algorithm.md` "Known limitations".
- **Two physical monitors with identical localized names cannot be
  configured separately** — user-facing per-monitor config keys by
  `localizedName`. See `docs/coordinate-systems.md` for the contract.

## Carried-forward cleanup

These are not bugs — they are extractions deferred until a third
caller appears or until someone is in the area for a different
reason:

- **`screenUnderCursor()`** is a 5-line helper on `WindowManager`
  used by both `ActionDispatcher` and `WorkspaceOrchestrator`
  through closures. Belongs on `DisplayManager`; the move would let
  both services drop one closure handle each.
- **`subtract()` rect-strip helper** is duplicated between
  `DimmingOverlay` and `FocusBorder`. Two callers do not yet
  justify a shared helper; the third caller (or a geometry section
  on `Shared/CoordinateSpace.swift`) is the right moment to fold
  both.
- **`forgetWindow` is split in two** —
  `WindowStateCache.forget(_:)` clears cache state and
  `applyForgottenIDExternalCleanup(_:)` runs the engine / workspace
  / focus side. Intentional: the discovery apply-loop calls them
  separately so it can clear cache state for a batch in one pass
  and run external cleanup per id.

## Where to look next

- `CLAUDE.md` — build, run, code style, technical decisions.
- `docs/tiling-algorithm.md` — BSP algorithm, smart insert, two-pass
  layout, min-size memory.
- `docs/coordinate-systems.md` — CG ↔ NS, multi-monitor edge cases,
  monitor identity contract.
- `docs/keybinds-and-actions.md` — `Action` enum, Codable contract,
  frozen JSON case keys.
- `docs/debugging.md` — Console.app filters, verbose-logging toggle.
- `docs/desktop-switching-notes.md` — virtual workspace
  implementation notes.
