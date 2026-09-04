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
├── AppIntents/               Spotlight/Shortcuts entry point, app catalog
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
live for the app lifetime. `UserConfig.shared`, `MenuBarState.shared`,
and the installed-app catalog are shared entry points. The App Intent
bridge holds only a weak reference to the activation service owned by
`WindowManager`.

| Service | Responsibility |
|---|---|
| `WindowManager` | Orchestrator. Wires services, drives lifecycle, owns mouse monitors and observers. |
| `HotkeyManager` | Session-level CGEventTap on a dedicated thread. Translates Hypr-key chords into `Action` values, dispatched to main. |
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
| `FocusBrackets` | Corner brackets shown around the focus target while the Hypr key is held. |
| `DimmingOverlay` | Dim mask over non-focused tiled windows; one panel per display at `.floating - 1`. |
| `CursorManager` | Cursor warp via `CGWarpMouseCursorPosition` + reassociate dance. |
| `ApplicationActivationCoordinator` | Shared open-or-reveal workflow for app hotkeys and Spotlight/Shortcuts; implemented in `AppLauncherManager.swift`. |
| `ApplicationLaunchVisibilityGuard` | Bounded fail-open cleanup for an app HyprMac requested to launch hidden. |
| `InstalledApplicationCatalog` | Actor-isolated, cached public-API app discovery for the App Intent parameter. |
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
- **`PollingScheduler`** owns a slow (10s) reconcile timer plus a
  coalescing token that funnels event-driven `schedule(after:)` requests
  down to a single in-flight call. The timer is a safety net — it catches
  apps that refuse AX observers, notifications the observer layer missed,
  and external moves nothing else reports; `AXNotificationService` events
  are the primary trigger. Honors
  `SuppressionRegistry["cross-swap-in-flight"]` so cross-monitor
  drag-swap can hold polling off for the duration of its two
  back-to-back retiles.
- **`AXNotificationService`** owns one `AXObserver` per regular app and
  translates their AX notifications (window created / destroyed /
  miniaturized / deminiaturized, focused-window changed) into
  `schedule(after:)` calls on `PollingScheduler`. This is the
  event-driven front end that replaced the 1 Hz full-desktop AX walk:
  apps report changes instead of being polled, so the discovery diff runs
  only when something changed. App-level subscriptions attach on
  `attachToRunningApps` / `attach(pid:)`; window-level ones attach lazily
  via `ensureWindowSubscriptions(for:)` after each discovery pass. Same
  architecture as yabai / AeroSpace.
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
HotkeyManager.eventTap (CGEventTap, dedicated thread → dispatched to main)
  → WindowManager.handleAction
  → ActionDispatcher.dispatch
    ├ FocusStateController       (focus id + visual border)
    ├ WorkspaceOrchestrator      (workspace switch / move)
    ├ FloatingWindowController   (toggle / cycle / raise)
    ├ TilingEngine               (swap / split toggle / retile)
    └ ApplicationActivationCoordinator (open / reveal)
        ↓
WindowStateCache mutations
        ↓
TilingEngine.applyLayout (two-pass via FrameReadbackPoller)
        ↓
FocusBorder, FocusBrackets, DimmingOverlay (visual layer)
```

Polling / discovery (parallel):

```
AXNotificationService (per-app AXObserver)     ┐
NSWorkspace notifications (launch/hide/…)       ├→ PollingScheduler.schedule(after:)
PollingScheduler.timer (10s reconcile net)     ┘        (coalesced)
  → WindowManager.pollWindowChanges
    → AccessibilityManager.getAllWindows
    → AXNotificationService.ensureWindowSubscriptions   (window-level subs)
    → WindowDiscoveryService.computeChanges
    → ActionDispatcher.applyChanges
```

Per-app AXObserver notifications are the primary discovery trigger; the
10s timer only backstops missed events and observer-refusing apps.

## Application activation and Spotlight

The `launchApp(bundleID:)` hotkey and the **Open App with HyprMac** App
Intent call the same `ApplicationActivating` service. The intent never
launches a second, independent `NSWorkspace` workflow:

```
Hotkey → ActionDispatcher ──────────────────────────────┐
Spotlight / Shortcuts → App Intent → main-actor bridge ─┤
                                                      ↓
                         ApplicationActivationCoordinator
                           → cold launch: reserve / reflow → launch
                           → AX inventory / preparation / restoration
                           → exact-window workspace or scratchpad routing
                           → focus
```

The coordinator pins a request to one process and one selected window.
It prefers a non-minimized window, then the last-focused, AX-focused,
or main window, using the window ID as a stable tie-breaker. Existing
windows are restored and routed through the normal workspace or
scratchpad path. A running app receives a reopen request only when AX
successfully reports no windows; an unavailable AX inventory is not
treated as an empty one.

For a cold launch, the coordinator first asks the tiling layer for a
**geometric slot plan** on the target workspace. This plan is transient:
it creates neither a fake window nor a placeholder in the live BSP
tree, and nothing is persisted. Existing tiled siblings are reflowed
before Launch Services is called; only siblings whose target frame
changes receive AX writes. Frame readback is checked asynchronously
at 40 ms intervals with a 350 ms verification budget. A sibling that
does not accept its frame causes the speculative gap to be released
and the launch to continue through the safe fallback. These are
readback scheduling bounds, not guarantees about AX call latency.

Normal discovery polling is held off for a bounded reservation period
so it does not immediately fill the deliberately empty gap. AX events
still reach the coordinator. After verification, Launch Services
receives `NSWorkspace.OpenConfiguration` with `activates = false` and
`hides = true`. If the app cooperates, the coordinator waits for a
bounded window-creation burst and prepares its addressable windows
before reveal. Actual windows enter ordinary discovery and BSP
insertion; they do not replace fake nodes. The initial slot is only a
prediction: restored window count and real minimum sizes can require
another layout before reveal. Scratchpad windows use their existing
reveal and stacking sequence rather than a second speculative layout.

This is best-effort preparation, **not a pre-map interception
guarantee**: public macOS APIs do not let HyprMac suspend another app
before its first window appears. Apps can ignore the hidden launch
request or reject geometry changes; already-visible apps are never
hidden to compensate.

Requests have a deadline, cancellation, and stale-callback checks.
Repeated requests for the same app share the pending operation; a new
app request or an explicit user override cancels it. The visibility
guard outlives request cancellation when necessary and provides bounded
fail-open cleanup, including late launch completion. The safety rule
is to undo HyprMac's hidden-launch request without stealing focus back
after the user moves on, even if layout preparation fails.
The guard has a separate serial queue and only uses the documented
thread-safe `NSRunningApplication` unhide API there; AX work and view
mutation stay on the main thread. This gives cleanup an independent
chance to run while main-thread AX calls are busy, not a no-jank or
visibility guarantee. Once a reveal has been observed, the guard is
irreversibly disarmed so a later intentional Cmd-H is not undone.
On failure, timeout, or user override, the speculative reservation is
discarded and current live geometry is retiled. Rollback never restores
an old tree or saved frames over a newer user action or display change.

The App Intent and App Shortcut provider live in the main app target;
there is no extension or private launch interception API. They are
availability-gated to macOS 15, while direct Spotlight actions require
macOS Tahoe 26. The rest of HyprMac still targets macOS 13. The intent
keeps HyprMac itself in the background and awaits the shared service;
only activation or the explicit no-manageable-window fallback counts
as success. If Spotlight starts HyprMac, the bridge waits asynchronously
for service installation and the initial window snapshot, up to two
seconds. It never activates an app through a partially initialized
manager. Cancellation and errors propagate to the caller.

`InstalledApplicationEntity` uses bundle IDs as stable identifiers.
Its query scans standard application folders, skips background-only and
agent apps, deduplicates IDs deterministically, and caches the results
for five minutes. Suggestions are alphabetic rather than dependent on
which apps happen to be running. Saved IDs outside those folders can
also resolve through public `NSWorkspace` lookup. This is not an
exhaustive index of every app in arbitrary filesystem locations.

Spotlight owns ranking and Quick Keys; HyprMac does not overwrite its
preferences or promise first-place results. The existing `launchApp`
JSON format is unchanged, and this integration needs no config
migration. See [keybinds and actions](keybinds-and-actions.md#opening-apps-with-hotkeys-spotlight-and-shortcuts)
for setup and platform limits.

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

Window management and UI mutation run on the main thread. The
CGEventTap lives on its own dedicated thread (`HyprMac.EventTap`). It
is an *active* tap — macOS holds all system keyboard input until the
hosting run loop services the callback — so it must never share a run
loop with the synchronous AX work on main. The callback is O(1) chord
matching (mutable state guarded by a lock) and dispatches every action
to the main queue. Mouse monitors and `NSWorkspace` notifications
still fire on the main run loop. UI-touching classes (`FocusBorder`,
`DimmingOverlay`, `KeybindOverlayController`, `CursorManager`,
`MouseTrackingManager`) call `mainThreadOnly()` on entry so an
off-main caller crashes loudly in DEBUG.

App Intent queries use `async/await` and an actor-isolated installed-app
catalog, so filesystem scans do not run on the main actor. The
`@MainActor` activation bridge adapts the intent's async completion and
cancellation to the main-thread coordinator's callback interface.
The visibility guard's separate serial queue performs bounded public
unhide requests only; it does not move AX calls off the main thread.

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
workspaces park their windows at a single global hide position: 1 px
inside the bottom-right corner of the **rightmost** monitor (a 1 px
sliver remains visible; macOS limitation). The rightmost edge has no
neighbor, so the parked window's off-screen extension never overlaps
another monitor and macOS's rescale-to-neighbor bug cannot fire.

Every workspace is **statically anchored** to a home screen:
`enabledScreens[(N - 1) % enabledScreens.count]`, left to right.
Switching to workspace N always lands on its home; workspaces cannot
move between monitors, so workspace identity never drifts. The
`moveWindowToMonitor` action (`Hypr+Ctrl+←/→`) moves the focused
*window* to the adjacent monitor's visible workspace instead.

Monitor connect/disconnect runs `WindowManager.reconcileAfterDisplayChange`:
visible-workspace mapping refreshes (`initializeMonitors`), BSP trees
migrate to each workspace's current home
(`TilingEngine.handleDisplayChange`), hidden-workspace windows
re-park at the (possibly moved) global corner, and visible workspaces
retile. Workspace assignments and the floating set are preserved —
full redistribution (`distributeWindowsAcrossWorkspaces`) runs only at
first launch and on explicit "Retile All". Discovery polling is
suppressed through the settle window so drift detection cannot
reassign windows from their OS-shuffled mid-transition positions.

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
