# Scratchpad layer — floating windows redesign

Synthesis of a 4-lens design panel (Hyprland-fidelity, macOS-native, minimal-change,
blue-sky; 12 concepts, each adversarially judged against the real code). All four
lenses independently converged on the same shape.

## The core insight

macOS with SIP on will never let us hold other processes' windows on top — the
current floating model fights a continuous z-order war it can't win (three separate
mitigation strategies in FloatingWindowController are the tell). The fix is
structural, not tactical:

1. **Summoning IS raising.** Scratchpad windows live parked off-screen and only
   exist on screen immediately after we raised them. Dismissal is spatial
   (re-park), never z-restore — the operation macOS forbids is designed out.
2. **Transience is the z-order fix.** The layer is quasimodal, Spotlight
   semantics: any deliberate interaction with the world behind it dismisses it.
   "Clicked tile jumps above floaters" stops being a bug and becomes the
   intended dismiss gesture. A buried scratchpad window is unrepresentable.

## Interaction model

- **Hypr+S** — toggle the scratchpad layer.
  - Show: unpark every member at its remembered free-form frame, carry any member
    whose frame isn't on the cursor's monitor to it, AXRaise back-to-front in MRU
    order, focus the MRU member (full activation — user is about to type).
    DimmingOverlay switches to scrim mode (bumped intensity, covers all tiled
    windows on every monitor, member rects carved out).
  - Hide: save member frames, park all, restore dim, return focus to the
    pre-show window.
- **Hypr+Shift+S** — send focused window to scratchpad. Leaves the BSP tree
  (same path as float-toggle), frame saved, assigned ws 0, parked. Tiles close
  the gap via the normal retile. Symmetric: on an already-summoned member the
  same key banishes it ("put it away" means the same thing from both sides).
  Send can never be rejected — no tree, no capacity check (unique among
  workspace moves; keep that invariant).
- **Dismissal triggers**: (a) Hypr+S again; (b) mouse-down outside every member
  frame (global NSEvent monitor) — park in the same runloop tick so the click
  lands on the tile it was aimed at, first click works; (c) activation switch to
  a non-member app (Cmd-Tab, Dock), debounced ~200ms and gated on a show-time
  grace suppression; (d) workspace switch / move-to-workspace dismisses first,
  then runs; (e) **display change or wake dismisses the layer** (see pitfall 3).
- **Focus restore is conditional on dismissal reason**: only (a)/(d)/(e) restore
  focus to the pre-show window. On (b)/(c) the user chose a new focus target —
  restoring would yank focus from the thing they just clicked. (Judge-flagged:
  as naively spec'd this is a daily-visible bug.)
- **FFM while shown**: hover between members moves keyboard focus via
  focusWithoutRaise. FFM onto the dimmed tiles is suppressed.
- **Multi-monitor**: toggle while shown on another monitor migrates the layer to
  the cursor monitor (Hyprland monitor-follow). Scrim dims all monitors.
- **Feedback ("where did it go")**:
  - Neutral `flashInfo` banner cloned from FocusBorder's flashError (accent
    stroke, no shake): "→ scratchpad" at the departing window's frame.
  - Menu bar dot string gains a trailing glyph: `◇ˢ` occupied-hidden,
    `◆ˢ` shown, absent when empty. Dropdown lists members by app/title.
  - Hypr+K overlay shows scratchpad occupancy.

## Substrate (verified against code by the panel judges)

- **ws 0 as the pseudo-workspace.** `assignWindow` has no 1-9 guard
  (WorkspaceManager.swift:165); `homeScreenForWorkspace` returns nil for 0, so
  ws 0 falls out of every switch/home/anchor path automatically. Members also
  stay in `floatingWindowIDs`.
- **Drift immunity is free**: `detectScreenDrift` skips floaters
  (WindowDiscoveryService.swift:306) and never drifts hidden-workspace windows
  (:318). No new drift-guard code.
- **One predicate propagates visibility**: a `scratchpadVisible` branch inside
  `isWorkspaceVisible`/`isWindowVisible` flows to FFM
  (MouseTrackingManager.swift:175/207/254), cycleFocus
  (FloatingWindowController.swift:161), floatingWindowsBehindTiled (:274), and
  discovery (:198).
- `assignToScreenWorkspace`'s nil-guard (WindowManager.swift:1357) preserves
  ws-0 assignment across polls and reconciles.
- `savedFloatingFrames` + off-screen save-refusal already protect member frames
  across rapid toggling.
- Park/unpark = existing `hideInCorner` / restore machinery.
- Scrim = DimmingOverlay intensity bump + full-coverage panels + existing
  floatingRects carve-out (~30 lines).

## Pitfall ledger (judge-verified, must handle)

1. **Dock-affordance bypass** — WindowManager.swift:1762-1783 reads workspace
   visibility directly, not through the predicate. Clicking a member whose app
   has ALL windows in the scratchpad → `switchWorkspace(0)` → empty-workspace
   fallback (WorkspaceOrchestrator.swift:130-134) warps the cursor and kills the
   scrim. Special-case ws 0 here — and turn it into a feature: activating a
   scratchpad app via Cmd-Tab/Dock auto-shows the layer (discoverability gift).
2. **Second visibility bypass** at WindowDiscoveryService.swift:301 — audit all
   raw `monitorWorkspace` consumers when adding the predicate branch.
3. **Wake/display-change while shown** — `reparkHiddenWorkspaceWindows`
   (WindowManager.swift:1174-1182) checks `isWorkspaceVisible(ws)` and would
   park visibly-open members under a live scrim. Dismiss the layer at the top of
   `reconcileAfterDisplayChange` and on wake.
4. **Scrim carve-out lag while dragging a member** — DimmingOverlay updates via
   delayed position-cache refresh; the dim hole trails a dragged window. Feed
   carve-outs live from DragManager during member drags (or drop the scrim
   during drag).
5. **Never prune membership against `cachedWindows`** —
   `updatePositionCache` (WindowManager.swift:1544) excludes non-visible
   windows, so parked members are absent by design. Prune against
   `knownWindowIDs` on the discovery gone-hook instead; clear MRU order there
   and refresh MenuBarState. Last member dying while shown → drop scrim,
   restore focus.
6. **Raise pulls sibling windows** — AXRaise + activation can bring along other
   same-app windows that are NOT scratchpad members. Accept for v1 (raise
   member last so it wins), note in docs.

## Deliberate divergence from Hyprland

Hyprland's special workspace is sticky — it stays up while you work underneath.
The panel's sticky variant ("Pinned Special", active z-defense via re-raise
polling) scored worst (4/10): clicks on the already-active app fire no
activation event, so burial lasts up to a full 1Hz poll tick, and re-raising can
cover modal Save sheets — genuinely dangerous. Stickiness is not portable to
macOS under SIP; quasimodal is the honest translation. iTerm's hotkey window
made the same call.

## v2 candidates (ship after the layer feels solid)

- **Named summons** — config-defined per-app scratchpads (name, bundleID,
  keybind, fractional frame preset e.g. "top 45% drop-down terminal").
  Tri-state key: not running → launch-and-adopt (date-gated pending-adoption
  table keyed by bundleID at the WindowDiscoveryService new-window seam,
  :163-182); hidden → summon at preset frame on cursor monitor; visible+focused
  → hide. Straight superset of the launchApp action's wire shape.
- **Hold-to-peek** — the event tap already observes keyUp (HotkeyManager:71-73):
  tap = toggle, hold >300ms = show-while-held, release = hide. Same grammar as
  the Hypr-held FocusBrackets. Needs autorepeat filter.
- **Park-corner cover strip** — a slim in-process panel over the 1px park sliver
  on the rightmost monitor turns a documented wart into deliberate chrome, with
  optional per-window tabs as one-click rescue affordances.

## Open questions for Zach

1. Default scrim intensity while shown (panel suggested ~0.45 vs the normal
   dim's 0.2) — and should scrim be on at all, or a config toggle?
2. Should Hypr+F (floater cycle) keep existing semantics for ordinary
   per-workspace floaters, with scratchpad members excluded while hidden
   (panel's recommendation), or fold all floating into the scratchpad?
3. Auto-show on Cmd-Tab to a scratchpad app (pitfall 1's feature version):
   default on or off?

---

# v2 revisions (2026-07-06, after a day of daily-driving)

Three items from Zach: Shift+T must stop removing members; the scrim
carve-out lags dragged members (worst UX defect of the layer); consider
folding all floating into the scratchpad.

## 1. Shift+T is not an exit (guard SHIPPED; within-layer tiling designed)

Membership is sticky: only Shift+S and Shift+N take a window out of the
scratchpad. Shift+T on a summoned member no longer ejects — it flashes the
rejection (WindowManager handleAction hook). That guard is landed.

The full v2 semantic: Shift+T toggles a summoned member between free-floating
and **tiled within the layer** (Hyprland's special workspace tiles; ours can
too, and ws 0 makes it nearly free):

- A tiled member is exactly a tiled window on ws 0: assigned ws 0, NOT in
  `floatingWindowIDs`, living in the (ws 0, screen) BSP tree — TilingEngine
  already keys trees by (workspace, screen), so the tree machinery needs no
  new concepts. Floating members keep today's behavior.
- Show: retile the ws-0 tree into the cursor monitor (inset the layout rect
  ~6-8% so the tiled cluster reads as a layer, not a workspace replacement),
  then place floating members from saved frames, raise all, focus MRU head.
- Shift+T while summoned: floating → smart-insert into the ws-0 tree (reject
  with error flash if depth-full — never auto-float, they already float);
  tiled → remove from tree, restore saved free-form frame.
- Hide: park everyone as today; the tree persists across show/hide. Monitor
  migration: let the show-time diff rebuild the tree on the new screen
  (ratios reset anyway each retile).
- Eject (Shift+S / Shift+N) works identically from either member state.

## 2. Scrim fix — normal-level scrim, stacked once (recommended)

Root cause of the carve-out jank: our chrome panels sit at level 2
(.floating − 1), above every normal window — including the members. The only
way to keep members bright under a panel that covers them is to carve holes,
and the holes chase live window positions through a polled cache. Carving is
downstream of a z-order choice, not inherent to dimming.

**The fix: put the scrim at `.normal` level and rely on stack order.** Within
a level, ordering is plain recency: `orderFrontRegardless` the scrim above
the tiles, THEN raise the members above the scrim. No carve-outs, no
geometry updates ever — a member drag/resize needs zero scrim work, so lag
is structurally impossible. No new private APIs.

Why this is safe here and nowhere else: the layer is **quasimodal**. The
normal dim can't live at level 0 because tiles get raised constantly during
normal use. While the scratchpad is up, any raise of the world behind IS a
dismissal trigger — the same invariant that designed out the member z-war
also freezes the stack under the scrim for the layer's lifetime. The two dim
modes need two levels: normal dim stays level 2 + carve-outs, scrim mode
drops to level 0 + stack-once.

Implementation notes:
- Ordering discipline in show(): scrim panels orderFront FIRST, then unpark/
  raise members. Today refreshDimming runs after the raises (via
  updatePositionCache) — reorder, or re-raise members after the scrim comes
  up. update()'s `if !panel.isVisible` guard already prevents later re-raises.
- DimmingOverlay: per-mode panel level flip; scrim mode becomes one
  full-screen rect per monitor (the fake-id screenCovers in refreshDimming
  simplify — no member carve filter at all).
- Bonus: a background app's attention dialog now pops above the scrim
  instead of being veiled under it (level-2 scrim dims it today).
- New pitfall: a background app spawning a window mid-show lands above the
  scrim (level-0 recency). Discovery tiles it behind; visually it sits
  bright until dismissal. Rare; if it grates, re-assert scrim + member
  raises on the new-window hook while visible.

Alternatives considered and cut:
- **Live carve during drags** (pitfall 4's original patch): feed carve rects
  from DragManager mouse events (grab-offset math, not AX reads). Works,
  still a frame or two behind, keeps all the carve machinery. Fallback only.
- **Drop scrim during member drag**: simplest patch, reads as intentional,
  but the backdrop flashing bright mid-drag is its own jank.
- **SLSOrderWindow relative ordering** (JankyBorders trick): same result as
  stack-once but via private API. Unnecessary — quasimodality gives us the
  ordering guarantee for free.
- **Scratchpad as a real workspace visit** (park the tiles, wallpaper
  backdrop, no dim at all — Zach's suggestion): genuinely works and kills
  the whole chrome class, but show/hide gains a park/unpark of every visible
  tile on every monitor (Tahoe AX write latency × N windows, on BOTH edges
  of a quick-peek gesture), wake/display-change mid-show has two layers to
  restore instead of one, and the overlay context ("my work is right there
  behind it") is lost. Level-0 scrim buys the same visual result — members
  bright, world uniformly dimmed, zero lag — without touching the tiles.
  Revisit only if stack-once disappoints in practice.

## 3. Folding floating into the scratchpad — yes, incrementally

The v1 doc's own core insight argues for the fold: summon-is-raise designs
out the z-war, but ordinary always-visible floaters keep that war alive
(floatingWindowsBehindTiled re-raising, FFM exemptions, normal-mode floater
carve-outs, focus-border level fights — all exist only to defend them).

**Fold now:** user float-toggles and max-depth overflow. Shift+T on a
workspace tile becomes send-to-scratchpad (floating member) — under the fold
"floating" and "scratchpad membership" are the same state, so Shift+T and
Shift+S converge outside the layer and diverge inside it (tile-toggle vs
eject). Depth overflow auto-sends with the existing `flashInfo`
"→ scratchpad" banner at the departing frame — strictly better feedback
than today's silent auto-float to who-knows-where.

**Do NOT fold (yet):** excluded apps (`excludedBundleIDs`). The killer case
is FaceTime: a call window must stay visible while you work; under fold
semantics the first click-outside would park your live call off-screen.
Exclusions stay loose visible floaters exactly as today — a tiny, mostly
transient population, so the retained z-machinery defends almost nothing and
can be deleted later if a "pinned member" concept (visible while the layer
is hidden, never parked) proves worth building.

Known regression to accept: no persistent user floater (PiP-style "video in
the corner while I work"). System PiP is high-window-level and untouched;
for everything else the z-war made that use case half-broken anyway. If it's
missed, "pinned members" is the v3 answer.

Junk-drawer risk: membership accumulates until window close (`forget()`
prunes on death). With exclusions kept loose this stays user-curated — only
things Zach deliberately floated or that overflowed depth. Acceptable.

## Sequencing

1. ~~Shift+T guard~~ (shipped)
2. ~~Level-0 scrim~~ (SHIPPED 2026-07-06 — panelLevel mode switch in
   DimmingOverlay, raiseScrim hook before the member raise loop, carve-outs
   deleted. gotcha found in implementation: isFloatingPanel's setter coerces
   .level to .floating, so it must be assigned BEFORE level. pinned by
   testPanelLevelAppliesAndFlipsOnReusedPanels.)
3. ~~Within-layer tiling for Shift+T~~ (SHIPPED 2026-07-06 — ws-0 trees via
   TilingEngine.tileScratchpad(_:screen:in:) with caller-supplied 6%-inset
   rect; rejects returned, never onAutoFloat; scratchpadTileRects feeds
   lastShownFrames. all four landmines fixed: handleDisplayChange skips ws 0,
   Retile All gather excludes members, drag no-ops while layer visible,
   explicit ws-0 drift guard.)
4. ~~The fold, scoped to overflow~~ (SHIPPED 2026-07-06 as decided: Zach kept
   ordinary floating. Only tree-fit failures (onAutoFloat) and full-tree
   evictions adopt into the scratchpad, via ScratchpadController.adopt —
   parked + "→ scratchpad" banner when hidden, summoned when visible, MRU
   tail. exclusions/disabled-monitor floats untouched.)

Post-ship verification still owed (unit tests can't see live z-order): with
the app running, confirm a raised member actually sits above the .normal
scrim panel, and that dragging a member shows zero dim lag. 213/213 tests
green at ship time.
