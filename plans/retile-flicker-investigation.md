# Retile flicker investigation (2026-07-07)

## Symptom (user report)

Samsung monitor, Claude Code left half / Zed right half. Claude Code
kept snapping to full screen while Zed stayed at its original spot,
visually on top of the expanded Claude Code. Flickered repeatedly,
dimming redrew each time, settled back to halves after a couple of
seconds. User suspected an app-initiated resize fighting HyprMac.

## Finding: not a resize fight — an AX snapshot flap

HyprMac does not enforce tile frames in steady state. An app resizing
itself does not trigger any retile (nothing watches frames between
discovery deltas), so a self-resize inside Claude Code cannot produce
this loop. The only paths that re-lay a visible workspace at 1 Hz
cadence are the discovery deltas: new / gone / returned / drift
(`WindowChanges.needsRetile` → `ActionDispatcher.applyChanges` →
`animatedRetile`).

The mechanism that exactly reproduces the report:

1. `AccessibilityManager.getAllWindows()` walks every app and reads
   `kAXWindowsAttribute` **synchronously with no messaging timeout
   configured**. A busy app (stalled main thread — common for
   Electron apps under load, and plausible for Zed during heavy GPU /
   indexing work) fails or times out that read, and *every window of
   that app silently drops from the snapshot for the cycle*
   (`guard result == .success else { continue }`). Per-window
   position/size read failures drop windows the same way.
2. Discovery diffs the snapshot: the missing window lands in
   `goneIDs`. Its pid is alive, so it moves to `hiddenWindowIDs` —
   indistinguishable from a real minimize. The mass-gone guard does
   not trip (it needs ≥3 windows missing *and* more than half of all
   known windows).
3. `applyChanges` removes the id from its BSP tree
   (`removeWindowID`, sibling promotion) and retiles: the surviving
   sibling's node is promoted and gets the **full screen rect**. The
   vanished window is never moved (HyprMac believes it hidden), so it
   visually stays where it was, now overlapping the expanded sibling.
   That is Zed "sitting on top of" a full-screen Claude Code — i.e.
   **Zed is the window whose AX reads failed**, Claude Code just
   inherited the freed space.
4. Next healthy poll: the window is back → `returned` →
   `needsRetile` → re-inserted, both windows retile to halves.
5. While the app stays busy, 2–4 repeat at poll cadence — the
   flicker. Each retile runs `updatePositionCache` →
   `refreshDimming`, which is the dim churn. When the app recovers,
   the layout settles — "after a couple of seconds it went back."

## Status: hypothesis, not yet log-confirmed

Per the repo discipline (no guess-fixes without a confirmed repro),
v-next ships diagnostics only. Notice-tier logs now cover the whole
chain (see `docs/debugging.md` § "Retile churn / full-screen
flicker"):

- `AccessibilityManager`: edge-logged per-app AX window-list read
  failures and per-window frame read failures (outage start / end,
  not per cycle).
- `WindowDiscoveryService`: `window hidden` / `window returned`
  bumped to notice with bundle id; `FLAP:` line when a window
  returns within 5 s of vanishing.
- `ActionDispatcher.applyChanges`: `discovery retile:` cause line
  (new/gone/returned/drift ids) for every discovery-driven re-layout.

When it recurs, pull:

```bash
/usr/bin/log show --predicate 'subsystem == "com.zachgray.HyprMac" AND category == "discovery"' --last 10m --info
```

Expected confirmation: `AX window-list read FAILED for dev.zed.Zed`
(or the Claude Code bundle) immediately before `window hidden`, then
`FLAP:` + `discovery retile: returned=[...]` pairs at ~1 s intervals.

## Proposed fix once confirmed (do not land before)

Debounce the gone→hidden transition for pid-alive windows: require
the id to be missing from **two consecutive** snapshots before
hiding + retiling (one extra second of latency on real minimizes is
invisible — macOS's own minimize animation is longer). Optionally
also `AXUIElementSetMessagingTimeout(appRef, ~0.25s)` so a stalled
app fails fast instead of blocking the main-thread poll. The
readback-tolerant precedent is `autoFloatOverflow`, which already
treats single-cycle AX readings as untrustworthy on Tahoe.

Alternative considered and rejected: skipping the retile when goneIDs
are pid-alive-hidden — that would break real minimizes (tiles must
expand when a window minimizes).
