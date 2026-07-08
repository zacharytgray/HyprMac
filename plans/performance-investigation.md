# Performance investigation — system-wide sluggishness

2026-07-08. Five-agent audit (input path, polling/discovery, layout/overlays,
runtime logs, external research on yabai/AeroSpace/JankyBorders). Root cause
is **confirmed by logs**, not hypothesized.

## Symptom

Whole machine feels sluggish while HyprMac runs; Activity Monitor shows low
CPU for HyprMac. The settings "Refresh rate" slider has no effect.

## Confirmed root cause

HyprMac owns an **active** (`.defaultTap`) session keyboard tap scheduled on
the **main run loop** (`HotkeyManager.swift:77-92`). An active tap means macOS
holds *every keystroke system-wide* until HyprMac's run loop services the
callback. The callback itself is fast (defers all work via
`DispatchQueue.main.async`) — but everything else in the app also runs on that
same main thread, so any main-thread stall freezes all keyboard input on the
machine.

The stalls are real and frequent:

1. **`Thread.sleep` readback loop on the main thread** —
   `FrameReadbackPoller.swift:108,124`. Up to 360 ms per retile
   (`readbackPollInterval` 0.03 × `readbackMaxWait` 0.36, `TilingConfig.swift:69-73`),
   ~720 ms for a cross-monitor swap (two back-to-back passes). Worst single
   offender.
2. **Unbounded synchronous AX calls** — `AXUIElementSetMessagingTimeout` is
   never called anywhere in the codebase, so every AX round-trip runs with the
   macOS default (~6 s) timeout. One busy app (compiling IDE, hung Electron,
   Spotify quitting) can park the main thread — and the keyboard — for seconds.
   Log evidence: `AX window-list read FAILED (err -25204)` ×6 against Safari,
   Messages, Disk Utility, System Settings, Setapp.
3. **Full-desktop AX enumeration, constantly** —
   `AccessibilityManager.getAllWindows()` (:141-276) walks every regular app
   and reads ~8–9 attributes per window, one synchronous cross-process
   round-trip each (~100–250 round-trips/sec at a typical desktop):
   - every 1 s from the hardcoded discovery poll (`PollingScheduler.swift:25,48`)
   - on every app activate/launch/terminate/hide notification (coalesced extra polls)
   - on **every physical left-click** (`WindowManager.swift:685` → `captureMouseDownFrames:1667` → `:1675`)
   - from `getFocusedWindow()` which re-enumerates the whole desktop (`AccessibilityManager.swift:299`), called from 6 per-action sites
   - ~20 more per-action call sites (workspace switch, drag apply, scratchpad, retile)

   This also works in reverse: each AX request is serviced by the *target*
   app's main thread, so the 1 Hz walk injects micro-stalls into every app on
   the system — sluggishness with no CPU signature anywhere.
4. **WindowServer load** — one persistent full-screen transparent dim panel
   per display (`DimmingOverlay.swift:476-512`) plus frame churn from retiles.

## Log evidence (unified log, last 3 days)

- **15× `event tap disabled (timeout) — re-enabling…`** from HyprMac's own
  hotkey category, in tight clusters (e.g. 23:30:31–23:32:21, 23:45:24–23:46:02
  on 2026-07-07). macOS force-disabled the tap because the run loop starved it.
  Each occurrence = a multi-hundred-ms system-wide keyboard freeze. Plus 2×
  "resetting stuck hyprKeyDown after tap interruption" (the stuck-Caps-Lock bug
  is the same failure).
- **WindowServer CPU-limit diagnostic** (56% avg over 159 s,
  `WindowServer_2026-07-07-233503_….cpu_resource.diag`) during the *exact*
  window of one tap-timeout cluster; heaviest stacks are compositing.
- 535× `focusWithoutRaise(N) activate dropped — app still inactive 10ms after
  activate()` — focus churn dominating the log.
- No hang/spin reports blame HyprMac; memory ~45 MB. This is all runtime
  behavior, all fixable.

## Why the slider does nothing

`mouseHoverPollHz` (GeneralSettingsView.swift:63-77 → MouseTrackingManager.swift:103)
only throttles the focus-follows-mouse hit-test — which is event-driven and
uses a single cheap in-process `CGWindowListCopyWindowInfo`, **zero AX**. It
controls none of: the 1 Hz discovery poll, the readback sleep loop, the
notification extra-polls, or any AX enumeration. All of those are hardcoded.
The slider structurally cannot touch the problem.

## What yabai/AeroSpace do (all SIP-on compatible)

- AeroSpace v0.18 fixed this exact symptom ("single-threaded + blocking AX API
  → one unresponsive app blocks the entire system", nikitabobko/AeroSpace#131)
  with **one dedicated thread per app** for all AX work, cancellable/coalesced
  jobs.
- Both set `AXUIElementSetMessagingTimeout(systemWideElement, 1.0)`
  (yabai `window_manager.c:2712`).
- yabai's tap callback does zero work: `CFRetain(event)` → queue → return
  (koekeishiya/yabai#1061). Its FFM latches per window-entry and hit-tests via
  SkyLight (`SLSFindWindowAndOwner`), never AX.
- Neither polls: per-app `AXObserver` (windowCreated/moved/resized/destroyed/
  miniaturized, focusedWindowChanged) + SkyLight connection notifications.
- yabai removed borders from core after overlay compositing caused stutter
  (#478); JankyBorders draws shaped SLS windows (region-shaped, not
  full-screen), redrawn only on geometry notifications, updates batched in
  `SLSDisableUpdate`/`SLSReenableUpdate`.
- Explicitly unavailable with SIP on: moving *other apps'* windows via SLS
  transactions/proxy windows (yabai's `--load-sa` path). Per-window AX sets
  remain the only SIP-on move mechanism — so per-window cost stays; the win is
  keeping it off the input-critical thread.

## Remediation plan (ranked)

### Phase 0 — quick wins, low risk, big felt impact
### (implemented 2026-07-08, branch perf/phase0-input-latency)

1. **DONE — `AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)`**
   at startup (`AppDelegate.startAfterPermissionGranted`). Bounds every
   worst-case stall 6 s → 1 s.
2. **DONE — event tap moved to a dedicated thread** (`HyprMac.EventTap`,
   userInteractive QoS). Callback unchanged (O(1), defers to main); chord/
   modifier state now lock-guarded. Added a 5 s `tapIsEnabled` health check
   for the silent-disable case. This breaks the coupling that turned every
   main-thread stall into a system-wide keyboard freeze.
3. **DEFERRED to Phase 1 — de-sleep FrameReadbackPoller.** With the tap off
   the main run loop, the `Thread.sleep` readback no longer stalls system
   input — it only delays HyprMac's own queued work, which a synchronous
   retile does anyway. The async state-machine refactor changes TilingEngine
   control flow and isn't worth the regression risk in this pass.
4. **DONE — per-left-click `getAllWindows()` dropped**
   (`captureMouseDownFrames` now reads live frames of cached windows only).
   Also removed the full-desktop enumerations on FFM focus-onto-floater
   (`updateFocusBorder`) and on Hypr release (`reassertFocusBorderAfterHyprRelease`,
   previously up to 3 walks per release).
5. **DONE (partial) — `currentTiledRects()` memoized** (50 ms TTL,
   invalidated at `updatePositionCache` entry) so one visual pass reads each
   tile frame once instead of 2-3×.
   **SKIPPED — `crossMonitor: false` fast path in the readback poller:**
   callers can't cheaply tell which windows are genuinely crossing screens
   (workspace switches arrive from the park corner on another monitor), the
   saving is ~1 AX call per window, and the open retile-flicker
   investigation shouldn't be contaminated with frame-write behavior changes.
   **DEFERRED — `getFocusedWindow()` full-walk removal:** the walk guards
   against sibling-window misresolution in multi-window apps (see comment at
   AccessibilityManager.swift:281); replacing it with `_AXUIElementGetWindow`
   + cache lookup needs a correctness study. Phase 1.

### Phase 1 — structural

6. **DONE (2026-07-08, branch perf/phase1-event-driven-discovery) —
   event-driven discovery**: `AXNotificationService` owns one `AXObserver`
   per regular app (created/focusChanged app-level; destroyed/miniaturized/
   deminiaturized window-level, attached lazily post-discovery). Events
   funnel into the existing coalescing `PollingScheduler.schedule(after:)`;
   the timer is now a 10 s reconcile safety net. `getFocusedWindow()` gained
   a windowID→cache fast path (full walk only on miss). Two fixes shaken out
   by live testing: (a) suppressed polls now *defer* (0.3 s retry) instead of
   dropping — with no 1 Hz timer behind them, a dropped event meant a window
   went unmanaged until the reconcile; (b) `screenParametersChanged` bails
   before suppressing when the display fingerprint is unchanged — macOS fires
   it spuriously (1 px visibleFrame jitter), and each fire used to cost a 3 s
   discovery suppression. Deliberately NOT subscribed: moved/resized (poll
   storms during drags; the drag system + reconcile cover those).
   Deferred within this item: skipping AX attribute reads for parked
   hidden-workspace windows (needs a hidden-window cache that doesn't exist;
   staleness risk in gone-detection — revisit only if measurements say the
   per-event walks still hurt).
7. **AX off the main thread**: serial AX work queue or AeroSpace-style
   thread-per-app with cancellable jobs. Most invasive (the codebase is
   main-thread-only by design) — do it after 1–6, only if needed; measure first.
8. **Overlay diet**: shape the dim panels to the dimmed regions
   (`SLSSetWindowShape`-style or per-window shaped panels) instead of
   full-screen transparent panels; JankyBorders-style SLS drawing for
   FocusBorder if WindowServer load persists.

### Measurement-gated (re-scoped 2026-07-08 after Phases 0–1 landed)

The remaining items — **readback de-sleep**, **overlay diet (8)**,
**AX-off-main (7)**, **parked-window read skip** — are all gated on a soak
period with Phases 0–1 running, not scheduled work.

Re-scoping rationale for the de-sleep specifically: the readback loop's
while-condition exits immediately when every frame lands within tolerance,
so a compliant retile pays ONE 30 ms sleep, not 360 ms. The 360 ms tail
fires only on genuine min-size conflicts / cross-screen races, and since
Phase 0 it cannot touch system input (tap is off main) — it only delays
HyprMac-internal reactions during a retile whose windows are visibly moving
anyway. Converting the two-pass settle to an async state machine would
touch the most subtle machinery in the codebase (MinSizeMemory ratcheting,
DragSwapHandler's 0.8 s suppression budget, every caller that sequences
retile → focus → border) for that narrow tail. Do it only if soak
measurements show retile-time jank that matters.

### Soak measurement checklist (run after ~a day of normal use)

```bash
# 1. tap timeouts — was 15/day pre-fix; target 0
/usr/bin/log show --last 1d --predicate 'subsystem == "com.zachgray.HyprMac"' --info \
  | grep -c "event tap disabled (timeout)"
# 2. WindowServer CPU-limit diagnostics — should stop appearing
ls -lat /Library/Logs/DiagnosticReports/ | grep -i windowserver | head -5
# 3. AX read failures + focus churn volume (context, not pass/fail)
/usr/bin/log show --last 1d --predicate 'subsystem == "com.zachgray.HyprMac"' --info \
  | grep -cE "AX window-list read FAILED|activate dropped"
```

Plus the subjective checks: typing latency while a retile / workspace
switch is in flight, and whether other apps still hitch during idle.

### Verification metric

Tap timeouts are directly countable — the before/after metric:

```bash
/usr/bin/log show --last 1d --predicate 'subsystem == "com.zachgray.HyprMac"' --info \
  | grep -c "event tap disabled (timeout)"
```

Target after Phase 0: zero occurrences in a full day of use, plus subjective
typing-latency check while a retile/workspace switch is in flight. Also watch
for recurrence of `WindowServer …cpu_resource.diag` reports.

## Scout reports

Full raw findings (file:line detail for every claim) live in the session
transcripts; key file anchors:

- Tap: `HotkeyManager.swift:70-94` (mask keyDown|keyUp|flagsChanged, `.defaultTap`,
  `.cgSessionEventTap`, main run loop), `:238-249` (timeout re-enable)
- Sleep loop: `FrameReadbackPoller.swift:108,124`; constants `TilingConfig.swift:69-84`
- Enumeration: `AccessibilityManager.swift:141-276` (per-window ~8–9 round-trips),
  `:299` (getFocusedWindow re-enumerates)
- Poll: `PollingScheduler.swift:25,48` (hardcoded 1.0 s); extra-poll triggers
  `WindowManager.swift:2153-2235`
- Per-click walk: `WindowManager.swift:685,1667,1675`
- Slider: `GeneralSettingsView.swift:63-77` → `WindowManager.swift:258-260` →
  `MouseTrackingManager.swift:103` (FFM throttle only)
- setFrame cost: `HyprWindow.swift:178-216` (4–6 round-trips/window incl.
  EnhancedUI toggle, double size-write)
- Workspace switch: `WorkspaceOrchestrator.swift:75-137` (2–4 round-trips per
  hidden window + full walk + per-screen readback sleep)
- Dim panels: `DimmingOverlay.swift:476-512` (full-screen, one per display)
