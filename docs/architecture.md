# HyprMac Architecture

HyprMac is a keyboard-driven tiling window manager for macOS. One
physical key acts as the "Hypr" modifier. It defaults to Caps Lock,
which HyprMac remaps to F18 at the IOKit driver level through
`hidutil`; every other choice is a key the event tap already sees.
Hotkeys feed into a thin orchestration layer that delegates to focused
subsystems for tiling, focus, workspaces, floating, drag, and
discovery.

This document is the long-form companion to `CLAUDE.md`. CLAUDE.md is
the build / run / style guide; this is the structural narrative.

## Module layout

```
HyprMac/
├── App/                      lifecycle, settings shell, menu bar
├── Core/
│   ├── Discovery/            window discovery service
│   ├── Input/                verified tiled-drag sessions
│   ├── Orchestration/        action dispatch, polling
│   ├── State/                window state cache, focus, suppressions
│   ├── Workspace/            workspace orchestration, layout restore
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
| `HotkeyManager` | Session-level CGEventTap on a dedicated thread. Translates Hypr-key chords into `Action` values, dispatched to main. |
| `KeyRemapper` | hidutil-driven Caps Lock → F18 remap so the Hypr key produces clean keyDown/keyUp events. |
| `AccessibilityManager` | AX bridge. Enumerates windows, resolves the focused window, picks directional neighbors. |
| `DisplayManager` | NSScreen tracking and CG ↔ NS coordinate conversion. |
| `SpaceManager` | macOS native Spaces enumeration via private CGS APIs (read-only). |
| `WorkspaceManager` | HyprMac's ten virtual workspaces, screen↔workspace mapping, home-screen affinity. |
| `TilingEngine` | One BSP tree per `(workspace, screen)`, verified sizing, smart insert, keyboard swap, and candidate drag commit. |
| `FloatingWindowController` | Float / tile toggle, cycle, raise-behind (with `RaiseBehindThrottle`), auto-float predicate. |
| `MouseTrackingManager` | Focus-follows-mouse, refocus-under-cursor, menu and popup suppression. |
| `TiledFocusRouter` | Focus for hover, Hypr+Arrow, Hypr keydown, the focus invariant and the raise restore. A tile a floater covers is focused through SkyLight alone, checked, and falls back to the usual path. |
| `WindowStacking` | Pure rules over the CG window list: the frontmost app's open popup, pointer hit-test, floater/tile overlap. |
| `TiledDragHandler` | Owns captured press/release state, cancellation, and verified cache updates. |
| `TiledDragTransaction` | Builds isolated insertion, swap, or resize candidates and verifies frames before commit. |
| `FrameSizingAttempt` | Bounded AX writes and complete frame readback through an injected clock and IO surface. |
| `FocusBorder` | Visual focus indicator. Persistent panels at `.floating` level with occlusion masking. |
| `FocusBrackets` | Corner brackets shown around the focus target while the Hypr key is held. |
| `DimmingOverlay` | Dim mask over non-focused tiled windows; one panel per display at `.floating - 1`. |
| `CursorManager` | Cursor warp via `CGWarpMouseCursorPosition` + reassociate dance. |
| `AppLauncherManager` | Launch-or-focus path for the `launchApp` action. |
| `CommandRunner` | Runs the `runCommand` action's command line directly through `Process` — tokenize, resolve the program, launch. Never a shell. |
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
  (`activation-switch`, `mouse-focus`, `workspace-transition`).
- **`PollingScheduler`** owns a slow (10s) reconcile timer plus a
  coalescing token that funnels event-driven `schedule(after:)` requests
  down to a single in-flight call. The timer is a safety net — it catches
  apps that refuse AX observers, notifications the observer layer missed,
  and external moves nothing else reports; `AXNotificationService` events
  are the primary trigger. WindowManager suppresses polling while the mouse
  is down, a tiled release is finishing, or a workspace transition is active.
  The drag finishing flag lasts through the deferred settle and verified
  transaction rather than expiring after a fixed timeout.
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
    └ AppLauncherManager         (launch / focus)
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
- **`LayoutSnapshotStore`** owns `layout-snapshots.json`. It never
  sees a tree — `LayoutRestorer.capture` asks `TilingEngine.layoutTree`
  to serialise one and `WindowManager` hands the result across.

## Layout persistence

A snapshot covers every regular workspace on every monitor, keyed by
a fingerprint of the connected displays. Each workspace saves its BSP
shape — a `LayoutNode` (leaf, or split with override / ratio /
user-set flag) — plus `unplaced`: windows assigned to it that have not
joined its tree yet, such as one sent to a hidden workspace that has
not been shown since. Frames are not stored. Floaters, scratchpad
members and closed-but-alive windows are never saved. Titles are
stored with Terminal's trailing ` — 120×30` size dropped, since it
changes on every resize. Restore rearranges open windows only; it
never launches an app.

`Hypr+Ctrl+S` saves manually. The first `didChangeScreenParameters`
notification of a transition auto-saves under the departing key —
before macOS shuffles windows onto surviving screens and before the
trees migrate; later fires in the same debounce do not save again. An
automatic save never replaces a manual snapshot, and pruning evicts
automatic snapshots first.

`Hypr+Ctrl+R`, a settled reconcile whose display key differs from the
one it replaced, and the first start of the process (opt-in via
`restoreLayoutOnLaunch`; resuming from pause is not a launch) restore.
A settle under the same key (Dock resize, arrangement drag, primary
change) does not restore. Display keys are sorted `name:WxH` pairs, so
identical monitor models at the same size alias regardless of
arrangement. Both actions are dropped
while a display transition is settling. `LayoutRestorer`
(`Core/Workspace/LayoutRestorer.swift`) runs the restore and returns a
`LayoutRestoreOutcome`; `WindowManager` only looks up the snapshot,
refreshes the position cache, logs, and shows the HUD.

1. `LayoutMatcher` pairs saved leaves with live windows. Bundle ID is
   required. Exact non-empty title matches are reserved first across
   the whole snapshot, so a missing earlier leaf can't take a window a
   later leaf names exactly. Remaining leaves then take any unclaimed
   window of the same app, the one already on the leaf's workspace
   first. Every window is claimed once. Floaters and scratchpad
   members are never candidates.
2. `WorkspaceOrchestrator.moveWindows` applies the workspace moves.
   It uses the same suppressions and park/place steps as
   `Hypr+Shift+N`, but lays out and verifies each visible destination
   before any assignment changes, and drops windows from their source
   trees by membership only, with one retile at the end. A destination
   that refuses is laid out again with its old members, so its windows
   return to their tiles even when the arrival was parked. Each destination is judged on its projected
   membership once the whole batch lands, so two full workspaces can
   trade windows. A destination takes all of its arrivals or none;
   refusals (`full`, `wontFit`, `sizingRefused`, disabled monitors,
   scratchpad) come back per window.
3. `TilingEngine.rebuildTree` replaces each saved workspace's tree with
   the saved shape. Workspaces whose home monitor is disabled are
   skipped. A leaf whose window is gone collapses its split as a close
   would. Windows the snapshot never named smart-insert around the
   restored shape, incumbents first. A saved tree deeper than the
   screen's max depth is left alone. An already-admitted window that
   would find no slot rejects the rebuild and the live tree stays. A
   newcomer that finds none is left out; the restorer hands it to
   `AdmissionRecovery` the way a tile pass hands over its refused
   newcomers, so it floats in place instead of sitting untracked.
   Publishing removes the restored windows from any other screen's
   tree for the same workspace, so no window ends up in two trees.
   Visible workspaces go through the same verified sizing as any tile
   and publish only on acceptance. A hidden workspace's windows are
   parked, so its shape is published with the key marked unverified,
   and the accepted tile on its next show clears the mark.

The outcome is one of: no snapshot for this display setup, already in
place, complete, partial, or failed. Complete means every matched
window reached its saved workspace and every shape was rebuilt.
Partial means some of it applied and some was refused (a refused move,
a shape kept live, or a refused newcomer). Failed means something was
asked and none of it applied. Saved windows that are not open do not
make a restore partial; the log counts them, and the manual HUD
mentions them. A manual save or restore shows the workspace-switch
HUD (`WorkspaceOverviewController.showStatusHUD`) on the screen under
the cursor, with a title for each case and a short detail line.
Automatic restores are silent and
log the outcome at `.notice`. The Settings monitor toggle reuses the
reconcile under an unchanged key and does not restore.

The snapshot file keeps each tiled window's raw title, on this Mac
only. Deleting `layout-snapshots.json` (and any `.unreadable` copy)
while HyprMac is quit clears every snapshot.

## Threading

Every public method runs on the main thread, with one exception: the
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

HyprMac maintains ten virtual workspaces in userspace. macOS native
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

`WorkspaceOrchestrator.moveToNextEmptyWorkspace` implements Hypr+F. It resolves
the actual AX-focused standard window and its physical display, then asks
`WorkspaceManager.nextEmptyWorkspace` for the next empty anchored workspace,
wrapping numerically. Any assigned window reserves a workspace, including
hidden and floating windows. The source workspace is never a candidate.
A sole assigned window is already dedicated, so the action returns without moving it.
Workspace 10 belongs to the same anchoring formula; keyboard 0 selects it,
while internal workspace 0 remains the scratchpad.

The transfer captures source frames, verifies a private one-window candidate,
then verifies position-only source-window parking before publishing destination membership.
Parking accepts the macOS titlebar clamp only when every physical display sees
at most the normal one-pixel right-edge sliver and the window size is preserved.
Generation, display, and membership checks guard the commit. Ordinary failures
restore captured geometry through verified AX writes. Superseded or changed
display state must not receive stale-coordinate restoration. The mover is
never parked, and unrelated monitors are not retiled. Floating movers become
tiled and retain their captured floating frame for a later Toggle Float.
This fills the padded usable area without entering native macOS fullscreen.

The overview presents ten workspaces in two rows of five. Its window list
intersects assignment with fresh discovery, deliberate hidden reservations,
and unhidden known/cached windows. Verified-closed hidden entries are omitted
without deleting workspace reservations as a presentation side effect.

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

Max BSP depth is 3 (smallest slot = 1/8 of screen). Beyond that, smart
insert finds no fitting leaf. The pass reports the window as refused on its
`AdmissionResult`; nothing routes it elsewhere, and `AdmissionRecovery`
gives it one bounded retry and then floats it where it stands.

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

`ConfigUpdateCoordinator` observes one post-mutation signal from `UserConfig`
and compares complete snapshots against the initial configuration. Disk reloads
emit after all properties have been stored. Geometry and monitor changes route
to layout callbacks; appearance changes route only to chrome updates. This
avoids first-reload retiles, stale `@Published` reads, and duplicate listeners
after restart. Hover response and focus-follows-mouse are read on each mouse
event and need no update callback. See [settings polish](settings-polish.md).

The on-disk JSON wire format for keybinds is frozen — see
`docs/keybinds-and-actions.md` for the contract.

## Permissions

- **Accessibility** (System Settings → Privacy → Accessibility) —
  required for AX queries and CGEventTap. AX permission gate runs
  in `AppDelegate.applicationDidFinishLaunching`; the user is
  prompted on first launch.
- **Caps Lock set to "⇪ Caps Lock"** in System Settings → Keyboard →
  Keyboard Shortcuts… → Modifier Keys — that pane applies in the HID
  event system, before the `hidutil` user mapping and before any
  CGEvent exists, so "No Action" (or any other choice) swallows the key
  before `KeyRemapper` or the event tap sees it. It is per keyboard.
  The same holds for Control, Option, and Command when one of them is
  the Hypr key. macOS exposes no supported way to read or change this,
  so HyprMac never claims it is verified: `HyprKeySystemGuidance`
  supplies the copy and the deep link shown in the permissions gate,
  the tour, and Settings → Keys.

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
  level. `Hypr+Shift+T` cycles and raises floaters; `raiseBehind` runs
  automatically on app activation and discovery reconciliation. It leaves
  floating siblings of the focused tiled app alone, because restoring focus
  within that app can put the tile back above its sibling and cause a loop.
  It raises only floaters a tile overlaps, stands down while the frontmost
  app has a menu open, and cools a pair down when the raise does nothing
  (Tahoe often refuses a cross-app AXRaise) or loops. Hover and Hypr+Arrow
  focus avoid burying floaters in the first place through
  `TiledFocusRouter`; workspace switches, window moves and the scratchpad
  do not yet. See `docs/debugging.md` "Floaters, open menus and no-raise
  focus".
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
