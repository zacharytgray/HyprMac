# Tiling algorithm

HyprMac uses a binary space partition (BSP) tree with dwindle layout.
This document is the algorithm walkthrough; for the orchestration
surface that drives it, see `docs/architecture.md`.

## Tree shape

One `BSPTree` per `(workspace, screen)` pair, owned by
`TilingEngine`. Each `BSPNode` is either a leaf carrying a
`HyprWindow` or an internal node with two children and a
`splitRatio` in `[0.15, 0.85]`. Leaves and internal nodes are
distinguished by:

- **leaf** = `window != nil` or both children are `nil`
- **internal** = both children are non-nil

Empty leaves are a transient state used during compact and prune;
outside those paths every populated tree has window-bearing leaves.

`splitRatio` is enforced at the property setter — direct writes
clamp to `[TilingConfig.minRatio, TilingConfig.maxRatio]`. Out-of-bounds
ratios would put the layout math into states it is not designed for.

## Dwindle layout

Each split picks the longer axis of the parent rect. By default the
new window goes on the right (horizontal split) or bottom (vertical
split). The pattern produces the characteristic dwindle spiral on
wide monitors:

```
   +---------+
   | A       |
   |         |
   +----+----+
   | B  | C  |
   |    +----+
   |    | D  |
   |    | etc|
   +----+----+
```

`togglesplit` (`Hypr+J`) overrides the dwindle direction on the
focused leaf's parent via `splitOverride`. The override survives
until the next sibling restructure (insert / remove on that node).

## Smart insert

Plain dwindle always splits the deepest-right leaf. On constrained
monitors — typically tall vertical displays — the deepest-right
slot can fall below `TilingConfig.minSlotDimension` (500 px),
producing unusable windows.

`BSPTree.smartInsert` walks every leaf right-to-left
(`allLeavesRightToLeft`) and skips any leaf where the resulting
children would fall below `minSlotDimension` on either axis. The
first leaf that fits accepts the insert. On a vertical 1440 px-wide
display, this typically backtracks past the deepest-right leaves and
produces a 2×2 grid layout instead of a degenerate dwindle spiral.

If no leaf fits — the tree is genuinely full given the monitor
dimensions — `TilingEngine.onAutoFloat` fires and the window is
auto-floated.

## Max depth

`TilingConfig.defaultMaxDepth` is 3. A depth-3 tree has 8 leaves;
the smallest slot is 1/8 of the screen. Beyond depth 3, smart insert
returns no fitting leaf and the window auto-floats.

Per-monitor overrides live in `TilingEngine.maxSplitsPerMonitor`,
keyed by `NSScreen.localizedName`. The settings UI exposes this so a
user can ratchet a wide monitor up to 4 splits (16 slots) or a
vertical monitor down to 2 (4 slots).

## Two-pass layout

macOS apps with hard min-size constraints (Spotify, Messages, Xcode)
refuse to shrink past their floor. The first pass writes target
frames and reads back what the OS actually accepted. When pass 1
reveals an oversize, pass 2 redistributes the parent's split ratio.

Pass 1:
1. `BSPTree.layout` produces `[(window, frame)]` pairs from the
   current ratios.
2. `HyprWindow.setFrameWithReadback` applies each frame and reads
   back the actual size.
3. `FrameReadbackPoller` polls the actual frames until they settle
   (consecutive matching reads within `readbackStableTolerancePx`)
   or `readbackMaxWait` (0.36 s) elapses.
4. Frames within `frameToleranceXPx` (20 px) of the target are
   "accepted"; oversize readings that survive
   `readbackMinConflictSettle` (0.24 s) become "conflicts".
5. Per-axis oversize observations feed `MinSizeMemory` so future
   layout decisions know about the constraint.

Pass 2 (only when pass 1 reported conflicts):
1. `BSPTree.adjustForMinSizes` walks each conflict and adjusts the
   parent's `splitRatio` to give the constrained window more room.
   Cascade is intentionally bounded to one parent — a multi-level
   cascade would destabilize the layout.
2. New ratios are clamped to `[minRatio, maxRatio]`.
3. The layout is recomputed and re-applied.
4. If pass 2 still overflows, the engine either auto-floats the
   inserted window (when there is a clear "newly inserted" target)
   or preserves recorded mins for the caller's post-retile fit
   check (the swap path) or discards the min-size adjustment and
   falls back to the pass-1 layout (the no-inserted-target path).

## Min-size memory

`MinSizeMemory` is the per-window record of the lowest accepted
size. macOS apps do not expose reliable `AXMinimumSize`; the engine
learns the floor from pass-1 readback.

Hysteresis on both ends:

- **Record (raise the floor):** when an oversize is observed, the
  recorded min is `max` of the existing value and the observed size
  on the affected axis. Sentinels above
  `usableMinSizeMaxPx` (10 000 px) are rejected — apps occasionally
  report `INT_MAX` when AX cannot resolve.
- **Lower (relax the floor):** an accepted size at least
  `lowerMinSizeAcceptedDeltaPx` (10 px) below the current bound
  becomes the new floor. Sub-pixel accepts cannot ratchet the floor
  down — without this, a one-time tight resize would over-eagerly
  relax our memory.

The memory mirrors back onto each `HyprWindow.observedMinSize` so
other subsystems (drag-swap fit check, floating toggle) read
consistent values.

## Swap

Direction swap (`Hypr+Shift+Arrow`) and drag swap go through
`canSwapWindows` first. The check:

1. Snapshot the tree.
2. Trial-swap the two windows with cleared `userSetRatio` flags.
3. Reset every internal node's `splitRatio` to the default so the
   trial layout matches what the actual swap will produce.
4. Ask `LayoutEngine.layoutCanAccommodateKnownMinimums` whether the
   resulting layout fits every recorded min size.
5. Restore the snapshot and return the answer.

When `canSwapWindows` accepts but the post-swap pass-1 readback
reveals an overflow (the seeded min was wrong), the swap reverts via
`pendingSwapRevert` (animated path) or the inline snapshot in
`swapWindows` (synchronous path). Rejection beeps and flashes a red
`focusBorder.flashError` around the source window.

## Cross-monitor swap

`crossSwapWindows` swaps two windows across `(workspace, screen)`
trees by exchanging their leaf references in place. Both screens
retile.

The two retile passes run synchronously back-to-back (~720 ms total
of `Thread.sleep` readback). `DragSwapHandler` registers
`SuppressionRegistry["cross-swap-in-flight"]` for ~800 ms and
`PollingScheduler` honors that key, so timer / notification polls do
not race the in-flight cross-swap and observe windows mid-mutation.

## Drag classification

`DragManager.detect` compares mouse-down frames against post-mouse-up
frames and produces one of:

- **resize** — width or height changed by more than 20 px. Sub-cases
  filter out app min-size-overflow false positives (the app refused
  to shrink) by checking `observedMinSize`.
- **swap** — same-monitor or cross-monitor; window dragged onto
  another tiled slot.
- **dragToEmpty** — cross-monitor drag onto an empty workspace.
- **snapBack** — small movement under thresholds, treat as user
  cancellation; just retile.
- **none** — nothing actionable.

`DragSwapHandler` applies the classified result. The 0.1 s settle
delay before classification gives macOS time to commit the final
dragged frame before AX queries it.

## `prepareTileLayout` / `prepareSwapLayout` / `prepareToggleSplitLayout`

These methods mutate the tree before returning the new layout rects.
Animation paths (`ActionDispatcher.swapInDirection`, `toggleSplit`,
`WindowManager.animatedRetile`) use them to compute the target rects
the animator interpolates toward; `applyComputedLayout` commits the
mutation by re-running the two-pass layout.

The contract: once `prepare*Layout` returns, the tree is committed
to the post-mutation state regardless of what the caller does with
the returned rects. `prepareSwapLayout` captures a pre-swap snapshot
on `pendingSwapRevert` so `applyComputedLayout` can restore on
post-readback overflow.

The synchronous paths (`tileWindows`, `swapWindows`, `toggleSplit`)
do not use `prepare*Layout` — they apply frames directly and own
their own snapshot/revert logic when needed.

## Known limitations

### Squishy-sibling swap rejection

When a swap squishes a "squishy" sibling — an app with no
AX-reported or readback-confirmed minimum size (Sidenote in the
canonical user setup) — the mathematical layout fits,
`overflowingWindows` reports no conflict, and the swap accepts. The
resulting compression may look visually wrong even though the
geometry is technically valid.

A "comfort band" rejection criterion was investigated and
deliberately deferred. Arbitrary thresholds risk false-rejecting
layouts that genuinely fit — Spotify needing 67 % of screen width
on a 1200 px monitor is a legitimate split, not a comfort
violation. The behavior is acceptable for now; future work would
either learn a per-app comfort minimum from accepted layouts or
expose a per-app override.

### Tiling tree keying

`TilingKey` keys on screen-origin coordinates
(`x * 10000 + y`). If two monitors swap physical positions during a
reconnect, trees follow the position rather than the physical
display. Migrating to `displayID` keying is tracked but not done —
the change is risky in isolation because it interacts with
`WorkspaceManager.screenID` (also coordinate-based) and the
home-screen migration path in `handleDisplayChange`.

### Engine line count

`TilingEngine` is over the 350-line target documented in the
refactor plan. The action-method cluster (`tileWindows`,
`prepareTileLayout`, `addWindow`, `removeWindow`, `applyResize`,
`swapWindows`, `crossSwapWindows`, `toggleSplit`,
`prepareSwapLayout`, `prepareToggleSplitLayout`,
`forceInsertWindow`, `canFitWindow`) plus `retile` and the
`autoFloatOverflow` fallback is the engine's external API;
extracting them would require splitting the engine into a thin
orchestrator over a sibling type, which produces ceremony without
removing duplication. The decomposition is left for a future cycle.
