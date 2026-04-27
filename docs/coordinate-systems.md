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
| `HyprWindow.frame` (CG, from AX) | `NSPanel.setFrame` (NS) | `ns_y = primaryScreenHeight - cg_y - height` |
| `screen.frame` (NS) | `DisplayManager.cgRect(for:)` (CG) | as above, applied to `visibleFrame` |
| `CGWindowListCopyWindowInfo` bounds (CG) | overlap math against `screen.frame` (NS) | as above |

`DisplayManager` owns the canonical `cgRect(for screen: NSScreen)`
helper. New code that needs a CG-space rect for a screen should call
it rather than re-deriving the math inline.

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
  `config.disabledMonitors`, `config.maxSplitsPerMonitor`, and
  every per-monitor row in the settings UI. Config files written
  before a monitor unplug must continue to apply when that monitor
  reappears, so the key has to be stable across power events. The
  localized name is the closest stable identifier macOS exposes
  through `NSScreen`.
- **Internal-only state** — keyed by `CGDirectDisplayID`. This
  includes `DimmingOverlay`'s panel cache. The display ID is
  guaranteed unique across plug events for the same physical
  display, even when two monitors share a localized name.

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

The CG↔NS conversion currently appears inline in:

- `MouseTrackingManager.handleMouseMove` and `refocusUnderCursor`
- `FocusBorder.panelRect(for:)`
- `DimmingOverlay.localRect(cgRect:screenNS:)` (and the inverse for
  the dim path computation)
- `WindowManager.screenUnderCursor`,
  `WindowManager.captureMouseDownFrames`,
  `WindowManager.syncFocusTrackerToCursor`,
  `WindowManager.refreshDimming`

`Shared/CoordinateSpace.swift` is the agreed home for a shared
helper. The extraction is deferred until a third caller appears or
until the conversion grows beyond `primaryScreenHeight - y` — two
inline copies of a one-liner do not yet justify the indirection.

## `subtract()` rect-strip helper

Both `DimmingOverlay` and `FocusBorder` use a `subtract(hole, from
rect)` helper that returns up to four strips representing
`rect - hole`. The implementations are identical. Same rationale as
above: two callers do not yet justify a `Shared/Geometry.swift`
extraction. The third caller (or any meaningful expansion of
`Shared/CoordinateSpace.swift` into a geometry section) is the right
moment to fold both.

## Edge cases

### Cross-monitor window moves

When `HyprWindow.setFrame` moves a window across screens, macOS
clamps the resize against the *current* screen's bounds. The
resize-move-resize pattern handles this:

1. Resize to target dimensions (may be clamped by the source screen).
2. Move to target position (now on the destination screen).
3. Resize again (now unclamped by the destination's bounds).

Same-screen tile updates pass `crossMonitor: false` and skip step 3
to save one AX call per window per retile.

### Hide-corner sliver

Hidden workspace windows park at
`screen.frame.maxX - 1, primaryScreenHeight - screen.frame.minY - 1`
(in CG). macOS leaves a 1 px sliver visible regardless — fully
off-screen windows trigger window-recovery alerts in some apps. The
sliver is the lesser evil.

### Display change ordering

On `NSApplication.didChangeScreenParameters`,
`DisplayManager.refresh` runs automatically. The downstream sequence
must then be:

1. `WorkspaceManager.initializeMonitors()` — reassigns workspaces
   to the new screen set.
2. `TilingEngine.handleDisplayChange(currentScreens:
   homeScreenForWorkspace:)` — migrates trees from vanished screens
   to their workspaces' new home screens; prunes orphans.
3. `WindowManager.snapshotAndTile()` — re-snapshot windows and
   tile.

Reversing 1 and 2 prunes the home-screen mapping before the engine
queries it and orphans the migration. `WindowManager.screenParametersChanged`
runs them in this order with a 0.5 s delay so AX has time to settle.
