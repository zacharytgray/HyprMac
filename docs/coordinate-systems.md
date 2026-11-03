# Coordinate systems

macOS uses two coordinate systems with different origins. HyprMac
crosses the boundary constantly — every visible-tile rect, every
mouse-position read, every NSPanel placement involves at least one
conversion. This document is the reference for getting it right.

## CG vs NS

| | Origin | Y axis grows |
|---|---|---|
| **CG** (CoreGraphics) | Top-left of the primary screen | Downward |
| **NS** (AppKit / NSScreen) | Bottom-left of the primary screen | Upward |

Conversion anchors on `primaryScreenHeight`:

```swift
ns_y = primaryScreenHeight - cg_y - height
cg_y = primaryScreenHeight - ns_y - height
```

For a point (height = 0):

```swift
ns_y = primaryScreenHeight - cg_y
cg_y = primaryScreenHeight - ns_y
```

`DisplayManager.primaryScreenHeight` is the cached source of truth.
It refreshes automatically on `didChangeScreenParameters`. Reading
`NSScreen.screens.first?.frame.height` directly works but bypasses
the cache and adds an unnecessary syscall on every conversion.

## Where conversions happen

| Source | Sink | Conversion |
|---|---|---|
| `NSEvent.mouseLocation` (NS) | hit-test against tile rects (CG) | `cg = primaryScreenHeight - ns_y` |
| Drag event `cgEvent.location` (CG) | press and release target hit-test | use the event point directly; AppKit fallback converts once |
| `HyprWindow.frame` (CG, from AX) | `NSPanel.setFrame` (NS) | `ns_y = primaryScreenHeight - cg_y - height` |
| `screen.frame` (NS) | `DisplayManager.cgRect(for:)` (CG) | as above, applied to `visibleFrame` |
| `CGWindowListCopyWindowInfo` bounds (CG) | overlap math against `screen.frame` (NS) | as above |

`DisplayManager` owns the canonical `cgRect(for screen: NSScreen)`
helper. New code that needs a CG-space rect for a screen should call
it rather than re-deriving the math inline.

Tiled insertion captures mouse-down and mouse-up event points before AX
work or deferred scheduling. It does not sample the live cursor to choose
the release target. Source matching requires exact screen containment and
physical display identity; it does not use the nearest-screen fallback. A
release on another monitor matches that screen the same way, by exact
containment in its full display frame.

## Multi-monitor

Each `NSScreen` has its own `frame.origin`, expressed in NS
coordinates relative to the primary screen's bottom-left corner.
`primaryScreenHeight` is the height of `NSScreen.screens.first`.

A point on a non-primary screen still uses the same conversion — the
primary screen's height is the global reference for the entire
display arrangement, not a per-screen height.

`DisplayManager.screen(at:)` resolves a CG point to its containing
screen. When the point is outside every screen (cursor on a
disconnected display, off-screen window), it falls back to the
nearest screen by Manhattan distance to its edge — an "out of
bounds" call always returns *some* screen rather than `nil`.

`DisplayManager.screen(for: HyprWindow)` resolves a window to its
screen via the window's center point, falling back to its top-left
position when size is unknown.

## Monitor identity

This is the source of bugs that look like "settings disappeared
after I unplugged the monitor". HyprMac uses two different identity
schemes intentionally:

- **User-facing per-monitor config** — keyed by
  `NSScreen.localizedName`. This includes
  `config.disabledMonitors`, `config.maxSplitsPerMonitor`,
  `config.outerPaddingPerMonitor`, `config.workspaceMonitors`, and
  every per-monitor row in the settings UI. Config files written
  before a monitor unplug must continue to apply when that monitor
  reappears, so the key has to be stable across power events. The
  localized name is the closest stable identifier macOS exposes
  through `NSScreen`.
- **Internal-only state** — keyed by `CGDirectDisplayID`. This
  includes `DimmingOverlay`'s panel cache. The display ID tells two
  monitors with one localized name apart, but it can change across a wake,
  so nothing that must outlive a wake is keyed by it. The display fingerprint
  and the last-shown workspace use name and frame instead.

The `WorkspaceManager.screenID(for:)` integer is its own thing —
derived from `screen.frame.origin` so two screens at the same
position would collide. macOS prevents that in practice. The
`TilingEngine.TilingKey` derives the same way so trees follow the
position when two monitors swap places. This is documented as
fragile in `docs/tiling-algorithm.md` "Known limitations".

### The localized-name limitation

Two physical monitors with identical model and connection type can
share a localized name. The user cannot configure them separately
through the per-monitor settings UI — both rows would map to the
same key. Tracked as a known limitation; not in scope to fix without
introducing an unfamiliar identifier into the settings UI.

## Coordinate-conversion duplication

`DisplayManager.flippedY` converts a point in either direction.
`CoordinateSpace.nsRect(fromCG:primaryHeight:)` converts a rect, for the
overlays that keep their own copy of the primary height. `MouseTrackingManager`,
`FocusBorder` and `FocusBrackets` still write the conversion inline.
`Shared/CoordinateSpace.swift` also holds the shared `CGRect` helpers
(`isSubstantiallyVisible`, `clamped(into:)`).

## `subtract()` rect-strip helper

`WindowStacking.subtract` returns up to four strips representing `rect - hole`.
`FocusBorder` shares it. `DimmingOverlay` uses `CGPath.subtracting` instead.

## Edge cases

### Cross-monitor window moves

When `FrameSizingAttempt` moves a window across screens, macOS
clamps the resize against the *current* screen's bounds. The
resize-move-resize order is used for that reason:

1. Resize to target dimensions (may be clamped by the source screen).
2. Move to target position (now on the destination screen).
3. Resize again, this time with the window standing on the destination
   screen.

Step 3 is an attempt, not a guarantee. It removes the *source* screen's
clamp; it does not make the app answer. An app with its own idea of a legal
size answers with that size however many times it is asked. Treat the third
write as the best available request and read the frame back to find out what
happened — `FrameSizingAttempt` does exactly that.

Step 1 assumes the source screen can hold the target size. A verified layout
moves a window first instead when it is parked or when its target is bigger
than the screen it stands on, since step 1 would be clamped there. See the
write order paragraph under "Two-pass layout" in
[tiling-algorithm.md](tiling-algorithm.md).

### Hide-corner sliver

Hidden workspace windows all park at one global point
(`WorkspaceManager.hidePosition`): 1 pt inside the bottom-right of the
rightmost monitor's visible frame, in CG. Monitors that share the rightmost
edge resolve to the lowest. macOS leaves a 1 px sliver visible. See
"Workspaces" in `docs/architecture.md`.

### Display change ordering

On `NSApplication.didChangeScreenParameters`, `DisplayManager.refresh` runs
automatically. `WindowManager.screenParametersChanged` ignores a fire whose
fingerprint is unchanged. Otherwise it saves the departing layout, hides the
scratchpad, suppresses polling, and waits for the topology to hold still for
2 s, or 5 s within 20 s of a sleep, wake or lock. Then
`reconcileAfterDisplayChange` runs:

1. `WorkspaceManager.initializeMonitors()` — refreshes each monitor's
   visible workspace for the new screen set.
2. `TilingEngine.handleDisplayChange(currentScreens:
   homeScreenForWorkspace:)` — migrates trees to each workspace's current
   home; prunes orphans.
3. `classifyAndAssign`, then `reparkHiddenWorkspaceWindows` — re-parks hidden
   workspaces at the possibly moved corner.
4. `tileAllVisibleSpaces` — retiles visible workspaces.

Reversing 1 and 2 feeds the engine a stale home-screen mapping.
A display change does not call `snapshotAndTile`: that redistributes every
window, and assignments must survive.
