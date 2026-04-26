# HyprMac Architecture

> **Status:** skeleton — Phase 0 placeholder. Expanded fully in Phase 8.
> See `REFACTOR_PLAN.md` §3 for the authoritative target architecture.

HyprMac is a macOS tiling window manager. Caps Lock is remapped to F18 at the
HID level and used as the "Hypr" modifier. Keybinds drive a thin orchestration
layer that delegates to focused subsystems.

## Layers

- **App** — lifecycle, settings shell, menu bar.
- **Core** — orchestration and the long-lived services it depends on.
- **Tiling** — BSP dwindle trees, layout computation, frame readback.
- **Models** — windows, keybinds, actions, persisted config.
- **Settings** — SwiftUI editors that bind to `UserConfig`.
- **Welcome** — onboarding + what's new.
- **Shared** — logging, constants, coordinate conversion, thread assertions.
- **PrivateAPI** — bridging header + CGS/SkyLight private declarations.

## Hot path (today)

```
HotkeyManager (CGEventTap)
    └→ WindowManager.dispatch(Action)
        ├→ WorkspaceManager       (virtual workspaces)
        ├→ AccessibilityManager   (AX queries, focus)
        ├→ TilingEngine           (BSP layout)
        ├→ FloatingWindowController
        ├→ MouseTrackingManager   (focus-follows-mouse)
        └→ DragManager            (drag-swap)
```

`WindowManager` is currently a 2k-line orchestrator. The refactor decomposes it
into `ActionDispatcher`, `PollingScheduler`, `WindowStateCache`,
`FocusStateController`, `SuppressionRegistry`, and friends. See the target
architecture in `REFACTOR_PLAN.md` §3.

## Threading

- All UI / AX / CGEvent code runs on the main thread.
- The CGEventTap callback is installed on the main run loop in `HotkeyManager`.
- Phase 5 introduces `mainThreadOnly()` assertions on UI-touching classes.
- No `async/await` migration is in scope for the current refactor.

## Logging

Two-tier `os.Logger`-backed logging in `Shared/Log.swift`:

- **Trace** (`.debug`/`.info`) — developer-only, gated by build configuration.
  Emits in DEBUG; in RELEASE only when `HyprMacVerboseLogging` UserDefault is
  set (for support sessions).
- **Diagnostic** (`.notice`/`.warning`/`.error`/`.fault`) — always emits via
  `os.Logger`. Visible in `Console.app` filtered by subsystem
  `com.zachgray.HyprMac` so users can grab logs for bug reports.

See `REFACTOR_PLAN.md` §7 for the full strategy and Console.app filter recipes.

## Workspaces

HyprMac maintains nine virtual workspaces in userspace; macOS native Spaces are
bypassed (use one Space per monitor). Hidden workspaces park their windows in
the bottom corner of their home screen — see `WorkspaceManager` and
`docs/desktop-switching-notes.md` for the implementation details.

## Tiling

BSP dwindle with smart insertion (`BSPTree.smartInsert`) that backtracks to
shallower leaves on constrained monitors. Two-pass layout via
`HyprWindow.setFrameWithReadback` handles apps that refuse to shrink below
their minimum size — `BSPTree.adjustForMinSizes` redistributes split ratios on
the second pass. Max BSP depth is 3; deeper insertions auto-float.

## Where to look next

- `REFACTOR_PLAN.md` — full architectural plan, per-file refactor map,
  migration phases, acceptance criteria.
- `CLAUDE.md` — build/run instructions, code style, key technical decisions.
- `docs/desktop-switching-notes.md` — virtual workspace implementation notes.
