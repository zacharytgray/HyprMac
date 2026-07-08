# Robustness: layout memory + stable identity

Follow-up plan from the 2026-07 architecture audit (`plans/architecture-audit-findings.md`).
The audit's 13 dual-verified findings split into two groups: mechanical bugs
(fixed directly — see "Landed fixes" below) and one structural gap that three
auditors independently confirmed as fundamental: **nothing anywhere remembers
a window's arrangement**. Workspace *assignment* survives everything; tree
*position* survives nothing. Every transient disappearance is answered by
heuristic re-derivation.

## Landed fixes (2026-07-05)

| Fix | Where | Symptom killed |
|---|---|---|
| No `compact()` on removal — sibling promotion preserves the arrangement | TilingEngine / BSPTree | closing/hiding one window reshuffled everything (tree-jumble) |
| Merge colliding trees in `handleDisplayChange` instead of dropping the smaller | TilingEngine | whole arrangements vanished on sleep/reconnect |
| Ratios reset before insert decisions | TilingEngine | insert landed differently depending on previous cycle's min-size conflicts |
| Deterministic batch-insert + redistribute order (left-to-right, id tiebreak) | TilingEngine / WindowManager | "different every time" quality of rebuilds |
| Drift by majority overlap, gated on substantial visibility | WindowDiscoveryService | crammed windows bounced to neighbor monitor; park slivers drifting |
| Returned windows with hidden recorded ws reassigned to where they opened | WindowDiscoveryService | recycled-CGWindowID reopens (Teams/Mail) ghosting then teleporting |
| Mass-gone guard (skip cycle when >50% vanish, bounded) | WindowDiscoveryService | partial post-wake AX snapshots dismantling trees |
| Discovery suppressed 4s around sleep/wake/lock | WindowManager | wake polls drift-reassigning OS-moved windows |
| Reconcile debounced on 2s topology stability; retiles deferred mid-transition | WindowManager | transient wake topologies reconciled as real; duplicate z-ordered trees born in the settle gap |
| Park self-repair each poll | WindowManager | hidden-ws windows piling on the visible layout after wake |
| AX read failures excluded from readback "accepted" set | FrameReadbackPoller | min-size memory corrupted downward → cram/overlap admitted |

All are instrumented at `.notice` — a recurrence now leaves evidence in
Console (`mass-gone guard`, `park repair`, `retile deferred`, `tree collision`,
`drift:` lines) instead of being silent.

## 1. Layout memory via dormant nodes (the umbrella fix)

The audit's strongest design recommendation (independently proposed by two
verifiers): when a window disappears but its app lives, **keep its leaf in the
tree, marked dormant**, instead of removing it.

- `BSPNode` leaf state becomes occupied / dormant(CGWindowID) / empty.
  A dormant leaf stores only the id (no `HyprWindow` retained).
- Layout math treats a dormant leaf as absent: the parent hands the full rect
  to the live sibling — identical visible output to today's removal, but the
  topology, split direction, `splitOverride`, and ratio survive.
- Return path (`WindowChanges.returned`): if any tree holds a dormant leaf
  with the window's id, re-occupy it — the window lands in exactly its old
  slot. Multi-window returns are shape-lossless by construction, which also
  covers wake blips (a window missing for one poll returns to its slot, not
  wherever smartInsert prefers).
- Eviction: `fullyForgottenIDs` (pid dead) prunes dormant leaves; smartInsert
  may cannibalize a dormant leaf when a live window needs the space (live
  windows outrank memory). Depth accounting ignores dormant leaves so stale
  memory can't push new windows past maxDepth into auto-float.
- Float-toggle and move-to-workspace remove for real (deliberate user
  actions), only the discovery gone path goes dormant.

Estimated scope: BSPNode/BSPTree leaf-state plumbing + TilingEngine gone/return
hooks + layout-math skip. Medium. Test first: hide/unhide round trip, 2×2 grid
with one dormant corner, dormant eviction under insert pressure.

## 2. Stable display identity

`TilingKey.screenID` and `WorkspaceManager.screenID` both hash
`frame.origin` — identity follows *position*, not the physical display
(flagged in-code as deferred at TilingEngine.swift:132-135). Wake transients
shift origins; two monitors swapping positions swap their trees.

- Key both by display UUID (`CGDisplayCreateUUIDFromDisplayID`) resolved via
  `NSScreen.deviceDescription[NSScreenNumber]`.
- Falls out for free: trees survive origin shifts without migration, the
  "same workspace, two live trees" dup state becomes near-impossible, and the
  merge path becomes a rare fallback rather than a wake-time regular.
- Do this *after* dormant nodes: it shrinks the migration surface the dormant
  bookkeeping has to survive.

## 3. Visible-workspace restore

`monitorWorkspace` self-heals to defaults when a screen's origin key changes
— which workspace each monitor was showing is forgotten on every reconnect.
Remember the last visible workspace per display UUID (in-memory first;
persisting to disk alongside #4 later) and restore it in
`initializeMonitors` instead of defaulting to the lowest anchored workspace.

## 4. Optional: persistence across restarts

Serialize per (workspace, displayUUID): tree topology + per-slot window
fingerprint (bundleID + title prefix) + float set. Restore best-effort at
launch before `distributeWindowsAcrossWorkspaces`, which then only handles
windows the snapshot doesn't claim. This is what makes HyprMac feel like it
"remembers" across relaunches the way AeroSpace does. Do last — items 1-3
remove the daily pain; this one is polish.

## Interaction with the scratchpad plan

`plans/scratchpad-floating-design.md` depends on two things from this plan:
- **Dismiss-on-display-change** — the scratchpad layer must dismiss at the top
  of `reconcileAfterDisplayChange`; the new `displayTransitionPending` flag is
  the natural hook (dismiss when it goes up, not when reconcile finally runs).
- **Park self-repair** (landed) — scratchpad members are parked hidden-ws
  windows; the repair loop is what guarantees "hidden" stays hidden after
  wake, which the quasimodal illusion depends on.

Dormant nodes are orthogonal to ws-0 members (scratchpad windows are floating
and never in a tree), so items here and the scratchpad build can proceed in
either order.

## Sequencing

1. Dormant nodes (#1) — biggest daily-feel win, self-contained.
2. Scratchpad layer (waiting on Zach's 3 open questions in its plan doc).
3. Display-UUID keying (#2) + visible-workspace restore (#3) — one PR, they
   touch the same key plumbing.
4. Restart persistence (#4) — optional polish.
