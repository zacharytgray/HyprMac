# Tiling algorithm

HyprMac uses a binary space partition (BSP) tree with dwindle layout.
This document is the algorithm walkthrough; for the orchestration
surface that drives it, see `docs/architecture.md`.

## Stability hardening, September 13 evening

Geometry-fit refusals return as data and leave assigned windows
on their workspace. A preflight-refused newcomer floats at the scheduled
recovery turn without another sizing attempt. Count-based initial assignment
is unchanged. Float-to-tile never evicts a neighbor into scratchpad.

Verified incumbent identity survives temporary tree removal and display
migration. It ends when the window leaves by an explicit move or is
admitted to another workspace, so a window that drifted to another screen
and is moved back is a newcomer again. Returning incumbents take slots
before newcomers and never become admission fallback targets. If returning
incumbents cannot all fit, the engine
writes nothing and keeps the whole key unverified. Adjustment uses guarded
refusal evidence and skips an adjusted write when the proposed frames cannot
accommodate the refused axes within the existing candidate allowance.

Display fingerprints refresh their input and include physical ID and usable
bounds. Every display reconcile invalidates active sizing, including a mode
change that leaves tree keys unchanged. Focus and informational actions keep
pending admission recovery. See [the stability audit](stability-audit-2026-09-13.md)
for regression evidence and unresolved display/focus limitations.

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
split); the one exception is a slot restoring a remembered boundary,
where the new window takes the side the old one vacated (see
**Ratio memory**). The pattern produces the characteristic dwindle
spiral on wide monitors:

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

Smart insert pins the axis it chose on the split as well, marked
automatic (`splitOverrideIsAutomatic`). Read off the rect at every
layout, the axis flipped whenever a ratio change or a min-size
adjustment made a child rect taller than wide, turning a stack into
columns. A tree that migrates to a screen of the other orientation drops
its automatic pins and dwindle chooses again there; `togglesplit` pins
stay, and only those go into a layout snapshot.

## Slot memory
Two members that leave together come back together, and one's remembered
neighbour may be the other: the restores run until none is left that can,
the first that cannot is inserted in the batch order, and the next restore
may find its neighbour in the tree. A memory is kept while its neighbours
are not in the tree and spent once they are, or by a smart insert.

When discovery takes a window out of its tree — an AX read that failed, a
minimize, Cmd-H, a tab switch — the engine records which subtree it
shared a split with, the side it was on, and the split's axis and ratio.
A window that comes back to the same key goes back beside that subtree,
when those windows still form one and the pair still fits; otherwise it
is a newcomer and smart insert places it. An explicit move, float or send
drops the memory. Before this, a returning window landed at the first
leaf with room and every window after it moved.

Inserting a window resets only the ratios the user did not set. It used
to clear the user-set flag on the whole tree, so a window opening or
coming back cost every manual resize on the workspace.

## Ratio memory

A native tab switch or a Cmd-H looks like a close followed by an open
a poll or two later. Without help, the window comes back at 50/50 and
the user's manual resize is gone.

When a leaf leaves a split, `BSPNode.remove` promotes the sibling and,
if the vanishing split was user-set and the sibling is a leaf, records
the boundary on it: `savedSplitRatio`, `savedChildWasLeft`, and
`savedSplitOverride`. The next `insert` on that leaf puts the new
window on the side the old one vacated and stashes the ratio in
`pendingSplitRatio` / `pendingSplitOverride`.
`TilingEngine.updateTreeMembership` calls `applySavedRatios` last, after
`clearUserSetRatios` and `resetSplitRatios`, so the restored boundary
survives the reset and comes back flagged `userSetRatio`.

Three limits are deliberate:

- **Only user-set ratios.** `adjustAxisRatio` writes min-size fudges
  without setting `userSetRatio`, and removals run before
  `resetSplitRatios`. Remembering those would pin a fudge forever.
- **Only leaves.** An internal sibling already carries its own split.
  Saving the outer ratio onto it would push the boundary into an
  unrelated pair of windows.
- **Only the pending fields are consumed.** A node that inherited a
  leaf's saved boundary on the way up is never a restore target, so a
  promoted subtree keeps the split it already had.

The memory has no expiry, so a Cmd-H and an unhide seconds later both
work. Whichever window next lands in that slot takes the boundary,
which is the intended trade: the slot is remembered, not the window.

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
dimensions — the pass logs `no fitting tile slot: wid=<id> ws<N> — staying
in place` and reports the window as refused on its `AdmissionResult`. The
window is not routed to another workspace and it is not floated on the spot.
It stays on its assigned workspace, exactly where it is, and
`AdmissionRecovery` decides what becomes of it.

## Max depth

`TilingConfig.defaultMaxDepth` is 3. A depth-3 tree has 8 leaves;
the smallest slot is 1/8 of the screen. Beyond depth 3, smart insert
returns no fitting leaf, and the window takes the refusal path above.

Per-monitor overrides live in `TilingEngine.maxSplitsPerMonitor`,
keyed by `NSScreen.localizedName`. The settings UI exposes this so a
user can ratchet a wide monitor up to 4 splits (16 slots) or a
vertical monitor down to 2 (4 slots).

## Two-pass layout

macOS apps with hard min-size constraints (Spotify, Messages, Xcode)
refuse to shrink past their floor. The first pass writes target
frames and reads back what the OS actually accepted. When pass 1
reveals an oversize, pass 2 redistributes the parent's split ratio.

The engine first captures every affected window's actual position and
size. A pass whose every target is where its window already is, within
the verdict's own tolerances, and whose captured frames pass the
aggregate checks as they are, is accepted from that capture: nothing is
written and nothing is waited for (`verdict=accepted in place` in the
`frame attempt` line). Most passes are this — a workspace switch retiles
the other screen, a move retiles its source twice, a poll re-applies a
tree — and each used to send three setters per window and wait a settle
and a stable readback of frames that never moved. Any window off its
target runs the ordinary pass for the whole key.
The tiled drop never takes that shortcut: its originals are the press-time
capture, not where the windows stand at the release, and a drop always
changes the layout.
`FrameSizingAttempt` applies each requested frame in resize–move–resize
order, retains AX write errors, and reads the complete layout back. Two
stable samples are required. Position may differ by at most one AX point.
Candidate size may differ by at most twenty points in either direction, which
covers apps that round a target to whole character cells, and the observed
frame is retained. Restoration uses one point in both size directions.
Aggregate safety does not borrow that tolerance. It runs on a separate
one-point slack, which is room for a readback that lands a fraction off a
half-point target. Containment holds the origin to one point and the far
edges to the slack, measured against the unpadded screen rect, so a
rounded-up window grows into its own outer padding and stops there. Two
frames that overlap by more than the slack on both axes are rejected however
well each matched its own target. Gap erosion is capped at
`min(sizeOvershootTolerance, max(0, gap - slack))`: a rounded-up window may
eat a positive gap down to one point and no further, contact is a
`gapViolation`, past contact is an `overlap`, and a zero gap asks for no
separation at all.

The budget follows the gap, so a small gap leaves little room to round into.
Gap 2 tolerates one point; gap 1 tolerates none, and is only reachable from a
hand-edited config, since the settings slider runs 0 to 32 in steps of two. At
gap 0 there is no gap to erode and the pair falls to the overlap check, which
rejects an intersection over one point on both axes — and two tiles sharing a
full edge always share the other axis. So an app that quantizes its frame to
character cells will not hold a verified tiling at gap 0. At the shipping 8 pt
gap the budget is 7, which is one point short of the +8 height rounding this
repo measured from Terminal.app: a terminal on the shared axis of a top/bottom
split is refused, while the same rounding in a left/right split goes into the
window's own padding and passes.

Each attempt has a 0.36-second monotonic deadline and a 12-sample limit.
Time inside AX calls counts toward that deadline. Individual AX calls use
a 0.1-second messaging timeout; synchronous calls cannot be interrupted by
the Swift deadline. Stable off-target frames wait at least 0.24 seconds
before becoming a geometry rejection. Failed reads and superseded work
never become accepted geometry.

A call that AX gives up on after using nearly all of its messaging timeout
returns `cannotComplete`. That covers a setter, a frame read, or the
enhanced-UI read that opens a window's writes. Such a call is a timeout,
not a refusal, and gets one more try with a 0.25-second call timeout and a
0.75-second deadline (`withTimeoutRecoveryBudget`). A verified layout takes
that try after its rollback verifies. A tiled drag takes it straight away,
on the settle read, the release screen's read, each candidate and each
rollback. A `cannotComplete` that comes back at once is AX refusing, and
gets no second try.

A pass that moves a window onto a screen with a different backing scale
factor gets a 1-second deadline instead, with the sample limit raised to
match. The engine compares the scale of the screen holding most of each
captured original with the scale of the destination screen. The app redraws
everything at the new scale while the attempt's calls wait behind it. On the
MacBook (2x panel, 1x externals) every Hypr+Shift+N onto the panel ran out of
the 0.36 s budget with nothing read back, and the retry 250 ms later usually
verified. The per-call messaging timeout does not change. A rollback gets the
longer deadline only when it carries such a window back. A parked window
counts for the screen it is parked on, and hidden windows all park in one
corner of the rightmost screen, so on the MacBook desk every reveal onto the
2x panel gets the longer deadline and logs the scale change. The budget only
costs time when the app is slow to answer.

A window crossing screens picks its write order per window. It is crossing
when its captured original is less than half on the destination. Each one
logs a `write order:` notice. Resize-move-resize stays the default: when the
target size fits the usable frame of the screen holding most of the
original, the window is resized there, moved whole, and resized again. It
moves first only when it is parked, hidden or on no screen, or when its
target is bigger than that screen. A size written there would be clamped by
it, which is how a parked reveal onto the portrait settled 1528 tall against
1874. The size-first default exists for the other case: a 3424-wide
ultrawide window moved first onto the 1512-wide panel lay over the portrait
next to it on the way.

A position-first window waits for two stable on-target position reads
before its size goes out, but for at most a third of the deadline. After
that the size goes out anyway and the readback judges. Without the cap, a
position that never read back steady used the whole deadline with no size
written, and the attempt could only time out. The cap is per window, and
the deadline grows by it for every position-first target, so a reveal of
several parked windows has the time their settles take: two parked
windows used to spend the whole base deadline in the write phase with
both settles succeeding, time out before a single readback, and get the
same layout accepted by the recovery's retry a quarter second later. A
cut wait also changes how a failure is counted. The attempt
used to end as `attemptsExhausted`, a timeout that the admission recovery
retries. It now ends with the readback's verdict, and a
`geometryMismatch` there is a refusal, which can float the window.

A minimum the memory already knows (`observed` provenance) shapes the
first pass: the candidate is adjusted for it before any frame is written,
and its ratios are kept while the membership stays the same. Asking the
app to take a slot it refused last time only repeated the resize the user
watched, and then the adjusted pass, on every retile.

A window that rounds its size up by less than the size tolerance passes
its own match and can still fail the pair or the screen — a terminal a
cell wider than its slot eats the gap. Such an aggregate rejection
records a conflict at the aggregate slack, so the adjusted pass runs with
room for the rounding; it teaches no minimum, since a cell of rounding is
not a floor.

The deadline grows by 80 ms for every target past three and by the
position settle budget for every position-first target, and the sample
limit with it: one deadline for every setter and every sample of the
whole key ran out on eight healthy windows.

Only a known, stable size conflict permits a second pass.
`BSPTree.adjustForMinSizes` adjusts constrained ratios, and the final
adjusted layout goes through the same complete verification. A split the
user set by hand is left alone as long as another ancestor on the axis
can make room; when none can, the verified pass lets it give way by the
minimum, since the alternative is a layout refused and rolled back on
every retile. Fit checks never ask for that, so a hand-set ratio still
refuses a swap or an arrival up front. The second
pass runs on the apparent conflict; what the memory is allowed to learn
from it is a narrower question, decided per window under "Min-size
memory" below. Membership and
adjusted ratios are prepared privately and publish only after acceptance.
Failed first tiles do not create a live tree; failed scratchpad migrations keep
the source tree. The engine checks captured
original frames against the usable screen before writing them back. Parked
workspace frames are not valid restoration targets for a visible workspace;
the result remains degraded without moving windows back offscreen. An
original is a restoration target when it lies within the restoration rect
by the same one-point slack the rollback's own validation grants its
readback, so a half-point rounding or a window a point past the Dock
edge still goes back where it was. The one
exception is a newcomer the pass itself inserted, one neither in the live
tree nor admitted to the workspace: its off-screen original says nothing
about the tree being rolled back. It stays wherever the candidate left it,
and the incumbents are restored and verified without it. An ordinary tiling
pass reports it stranded for the admission recovery. Valid
original frames are written once and restoration is verified. Scratchpad
restoration uses the full display bounds, even when its candidate layout uses
an inset region. Results distinguish
accepted geometry, rejected geometry with verified restoration, and a
degraded state whose restoration could not be verified. Superseded work
does not restore frames over a newer operation.

### What may publish

Only an accepted layout becomes the live tree. Acceptance is the one state
that carries every condition at once: all three setters returned success for
every target, the final readback was complete and stable, every window
matched its target within the per-window tolerances, and the aggregate
geometry passed. The caller's generation check is the ownership half of the
gate. There is no exception for a candidate whose originals were parked:
those frames are on screen, but nothing verified them, so the prior
membership and the prior ratios stay. A partial write, an unreadable or
unsettled readback, a cleanup error after frames that read back fine, and a
window that stops hundreds of points short of its slot all keep the prior
tree. A layout with no targets publishes, because that is how a workspace
that lost its last window empties its tree; an empty target set is never
treated as evidence that writes completed.

### Restoration correspondence is not tiled validity

A rollback asks every window to go back exactly where it was. It is verified
per window against the strict one-point size and position bound. It runs
under the timeout recovery's 0.75-second cap rather than the candidate's:
it is the safety net, a rollback that fails leaves the candidate's frames
under the old tree, and it returns as soon as its frames read back stable,
so the larger cap costs a healthy rollback nothing. The
pairwise checks are not verdicts on it: two originals that overlapped before
the candidate ran still overlap after it, and calling that a failed rollback
would be a lie about correspondence. The overlap is reported separately on
the result and in the `verified layout ...` log line as `originalOverlap=`.
Restored originals are never published as a tiled layout — the publication
gate only accepts a candidate — so a verified rollback onto overlapping
frames says the windows are back where they were, and nothing more.

### Unverified geometry

Every layout attempt records, per `(workspace, screen)`, whether it left
verified geometry behind. An accepted layout clears the mark; every other
outcome sets it, including a rejection whose rollback verified, because the
frames the tree describes are not the frames the screen ended up with. A
superseded attempt records nothing: a newer generation already owns the key.
A key's mark is dropped when the key is, on display-change pruning or when
an empty tree is removed. A tree that *migrates* to another screen carries
its mark to the new key: the claim belongs to the tree, not to the
coordinates, and a migrated tree has still never had a layout accepted.

`intendedTileRects` omits every window under a marked key. Directional focus
and directional swap then fall back to the window's own frame for all of
them together, which is the only consistent thing to do when the tree and the
screen disagree. A visible nonfloating window that is in no tree at all — a
newcomer stranded by a discarded candidate — is never dropped from the
candidate set for having no intended rect; it is picked on its actual frame.

`TilingEngine.unverifiedLayouts` exposes the marked keys with their window
ids and the ids the failed attempt had just inserted, and
`clearUnverifiedGeometry(forWorkspace:screen:)` drops one. The state dump
prints the ids as `unverified=`.

### Admission recovery

A tiling pass that inserted a new window and was then refused keeps its
prior tree, which leaves the newcomer visible, assigned, not floating and in
no tree at all. `TilingEngine.tileWindows` reports that as an
`AdmissionResult`: the ids the pass inserted, the ids the live tree holds
afterwards, and the difference between them — the newcomers it stranded.
The newcomer is never read off the failure's own window id. A candidate
fails on whichever window refused its frame, and that is usually an
incumbent: Safari 21611 refused while 26016 was the window that had just
opened.

`AdmissionRecovery` finishes those windows in at most two steps, or a few
more when the app does not answer in time (step 3).

1. **One retry, about 250 ms later**, through an injected scheduler and
   under a fresh generation. It honours everything the failed attempt
   observed. That readback passed the learning guards — complete writes, a
   complete stable readback at the target origin, a geometric refusal — so
   it is the best thing anyone knows about the window, and writing the same
   frames again only repeats the resize the user just watched. What the
   retry does ignore is an observed bound recorded *before* its own
   admission: evidence old enough that the app may have changed its mind
   since. The reach is per window: two newcomers retried together were
   admitted at different generations, and neither inherits the other's.
   Seeded hints, app hints and every other window's memory all still count,
   and `MinSizeMemory` is never cleared.

   The retry the verified layout itself runs after an AX messaging
   timeout (`verified layout AX timeout recovery`) is reconciled like
   every other pass, so a floor it reads back is known to this retry.

   With every tenant's floor in hand the retry runs the structural fit check
   first, over the newcomers it is retrying and the live tree's incumbents
   and nothing else: a held window or a second stranded newcomer sitting on
   the same workspace is not part of the arrangement being judged, and the
   ordinary pass would simply leave it out. When the arrangement cannot exist — the Outlook case, where a
   938 pt floor, a 574 pt floor, the gap and the padding do not fit in
   1496 pt of usable width — it resolves there, without a single setter, and
   logs `admission retry refused pre-write`. When only some of the newcomers
   are the problem, the retry gives them up one at a time — the one whose
   tightest axis takes the largest share of the usable frame first — until
   what is left fits, tiles the rest in the same pass, and reports the
   dropped ones as `refusedIDs` (`admission retry narrowed pre-write`). Eight
   windows opening on a laptop screen used to float as a set because two of
   them could not share it with anyone. Before acting the recovery
   re-checks the assignment, the workspace's home screen, whether the
   workspace is visible, whether the app is running, whether the window
   still exists and can be read, and whether the user has floated it.
2. **The recovery outcome.** A second failure — geometry, I/O, or a
   pre-write refusal — ends in the outcome policy, `AdmissionRecovery.Outcome`.
   `.floatInPlace` is the default and the only one wired: a readable visible
   newcomer is left floating exactly where it is, with both floating flags
   set and the cause and the policy logged. It is not sent to another
   workspace. `.routeToFittingWorkspace` is the placeholder for the other
   answer; nothing implements it, and selecting it still floats the window
   so nothing is left untracked. One named policy point, one line to change.

   A second failure that names some of the newcomers still waiting and not
   all of them — the window that would not take its frame, both of an
   overlapping pair, plus whatever the engine refused pre-write — floats
   those and runs the pass again for the rest without them, inside the same
   retry and without a new timer, up to `narrowingRounds` (three) times.
   Every round floats at least one window, so the loop ends on its own; the
   bound keeps a key that refuses every arrangement from becoming a visible
   resize storm. A failure that names an incumbent or nobody says nothing
   about which newcomer to give up on, and a timeout is not a refusal;
   neither narrows (`admission recovery narrowed`). A newcomer the engine
   dropped pre-write floats as `noFittingSlot`, its own reason, not the
   verdict of the pass that tiled the rest; a pending window a fallback
   retile or a newer layout tiled meanwhile is resolved, never floated
   off its tile. The pre-write check and the choice of the newcomer to
   give up on take the windows in the order the pass inserts them, so
   the verdict does not change with the window server's z-order.

   The recovery then asks the engine to drop the key's unverified
   mark, and the engine decides: `clearUnverifiedGeometry` drops it only if
   every attempt on that key since the last accepted layout put its own
   originals back. A restoration restores the frames it captured when it
   started, not the tree's layout, so once one rollback fails, every later
   one faithfully restores wherever that left the incumbents. The mark then
   stands until a layout for the key is accepted, which is the one thing
   that redeems it.
3. **A timeout is not a refusal.** `FrameSizingFailure.isTimeout` covers
   `deadlineExceeded`, `attemptsExhausted`, and read, write or cleanup
   failures with `cannotComplete`, which is what an AX messaging timeout
   returns. A retry that fails that way gets another retry, 500 ms later,
   and then one more after 1 s (`timeoutRetryDelays`). The last one runs
   with `keepingUnverifiedOnTimeout`. If it times out too, and all three
   setters returned success for every window it lays out, the engine skips
   the rollback,
   publishes the tree with the newcomer in it and leaves the key marked
   unverified. Only an accepted layout clears that mark. A last retry that
   timed out before every window got its whole frame (in the capture, or
   after a newcomer's first size write) has nothing to keep: the window is
   held, as below, and never floated. A held window is a newcomer to every
   later pass on its key, so the next one that tiles it releases it.
   Two limits: a readback that never settles counts as a timeout, so an app
   that refuses its size too slowly to settle is kept rather than floated;
   and keeping skips the AX timeout recovery's relaxed retry. A
   refusal on any retry, before or after a timeout, still takes step 2.
   The live case was Safari moved onto the MacBook's 2x panel: the move's
   layout and the 250 ms retry both timed out, and the window was floated
   at a size that did not fill the screen.

The retry cannot re-arm itself except after a timeout, which step 3
bounds, and a window already in recovery does not collect a second one from
a later failed pass. A newcomer that is
unreadable, or whose workspace is hidden, when its turn comes keeps its
place in the pending set and waits for a real discovery event or a
workspace reveal rather than a renewed timer; no frame is invented for it.
A close, a stop, a later key press, a display change, a workspace move, a
user float, or a later layout that tiles the window all cancel the pending
work. Switching or cycling workspaces is the exception: a reveal is the
evidence a parked newcomer is waiting for, so those two actions leave the
records alone. Focus and informational presses leave them alone too, and so
do resize, swap and split-toggle presses: those only rework the live tree,
which never holds a stranded window, so nothing they do would ever give it
another attempt. Cancelling there is how a move followed quickly by a resize
left a window assigned, in no tree, and with nothing scheduled. A retry that
comes due while the screens are being reconfigured waits as well, rather
than tiling into keys that are about to move. So does one that comes due
while the session is locked, the displays sleep or the user session is
switched out: the window list is partial then, and an attempt from it would
lay the key out without the windows it is missing. It gets its attempt from
the first poll or retile after the span ends. Scratchpad tiling never enters
this path.

Every visible nonfloating assignment is therefore a verified tile, a window
under a marked key, or a tracked recovery member. The state dump's
`recovery pending=` lists the last group.

A newcomer in recovery is drawn over the tiles, so a click is hit-tested
against it before the tiled rects — otherwise the click lands on the
incumbent whose slot it overlaps and `syncTracker-tiled` pulls focus away
from the window the user just clicked.

### Same-screen drift

An accepted layout is not a promise the app will stay put. Safari's Start
Page takes its own saved frame back a moment after the write verifies, so a
second Safari window covered the screen for two minutes — until an unrelated
Terminal window triggered a retile. Nothing was watching: discovery's `drift`
only ever noticed a window that changed *screens*.

`TiledDriftMonitor` watches the other case, on the ordinary discovery poll
and with no timer of its own. A window is offered to it only if it is a
member of a published tree on a visible workspace and is not floating;
`intendedTileRects` omits an unverified key whole, so a window whose geometry
the engine cannot speak for never produces a reading, and the scratchpad
layer is skipped outright. A poll that retiled is skipped too — that retile
is the re-apply.

Drift is more than a point of position or twenty points of size away from the
intended rect, the same tolerances a candidate pass accepts. One reading is
never enough: two consecutive polls must agree on the drifted frame, so a
window mid-animation is not chased. Then one re-apply of that workspace's
layout goes out through the ordinary verified path — one per workspace per
poll, however many of its windows drifted, because the pass lays out the
whole key.

The bound is the point. If the app takes its frame back again within five
seconds — two consecutive polls agreeing on the drifted frame, the same rule
the entry uses, so a layout still landing is not mistaken for a fight — the
monitor stops and marks the key unverified instead of trading writes with
it. A window back on its tile ends the episode, and a window that
drifts again long after the re-apply held gets a fresh one. Nothing runs
while something else owns the geometry: a mouse press, a tiled drag settling,
a display reconfiguration, or a workspace transition.

### Forced insertion

`forceInsertWindow` is the float→tile entry point. It works on a private
candidate and returns `.alreadyPresent`, `.inserted` or `.failed(reason)`.
It never evicts anyone. It looks for a free slot the same way an ordinary
insert does, and the only thing it adds is that the user asked explicitly,
so a capacity refusal from smart insert is worth one attempt anyway.

Two things can refuse it. `.failed(.noFittingSlot)` means no leaf took the
window. `.failed(.layoutRejected(reason))` means the tree took it but the
screen would not accept the frames. Either way the candidate is discarded
whole, so the live tree survives untouched, and the caller's window stays
floating with both flags set and the existing rejection flash. Nothing is
written until the layout is accepted.

A new window that no leaf fits is a different path, and nothing routes it.
It stays on the workspace it was assigned, the pass logs `no fitting tile
slot`, and `AdmissionRecovery` gives it one bounded retry and then floats it
in place. It is never offered to another workspace, and no other workspace is
probed, activated or retiled on its behalf.

Initial assignment is a separate policy. Choosing which workspace a brand-new
window belongs to happens before any fit check, and it counts windows rather
than measuring them. Discovery fills the active workspace up to `2^maxDepth`,
then visits every regular workspace in cyclic numeric order. This sequence
crosses monitor homes: overflow from workspace 2 goes to workspace 3 before
workspace 4. Each destination uses its home monitor's configured capacity.
Only new IDs are assigned; existing workspace membership, floating windows,
and scratchpad members are preserved. New windows assigned to a hidden
workspace retain that destination's home assignment while parked. A visible
destination is tiled on its home monitor in the discovery pass. Startup and
Retile All first fill each monitor's visible workspace in stable screen,
focus, and frame order. Only the excess probes later workspace numbers across
monitor homes, wrapping after workspace 10.

A window rule changes only the starting workspace. A new window of a pinned
app starts at its pinned workspace instead of the active one and spills the
same way; if every workspace is full it stays on the active one, as it would
unpinned. Startup and Retile All place pinned windows in their own batches
ahead of the per-monitor ones, so a pin claims its workspace first. See
"Window rules" in `docs/keybinds-and-actions.md`. This count limit does not guarantee
that every application's dimensions will fit.
Hidden assigned nonfloating windows reserve capacity in admission and startup
packing. Discovery events wait until the initial snapshot completes.
The old post-readback overflow auto-floating path remains disabled. Target
insertion uses one candidate pass and one possible restoration, without
ratio adjustment, eviction, or automatic floating.

## Min-size memory

`MinSizeMemory` is the per-window record of the lowest accepted
size. macOS apps do not expose reliable `AXMinimumSize`; the engine
learns the floor from readback.

**What may teach a minimum.** `FrameReadbackPoller.learningRefusal`
decides, per window, whether a readback is evidence at all. All of the
following must hold, or the window teaches nothing and the `min
evidence:` line says which guard stopped it:

- the pass is a candidate or adjusted tiling pass, never a restoration;
- the attempt ended in a geometric refusal, not a write, cleanup or read
  error, a supersession or a deadline;
- all three frame setters for *this* window returned success;
- every target read back, and every target reached its stable sample
  count;
- this window sits at the origin it was given, within the one-point
  position tolerance;
- its actual size exceeds its target by more than the overshoot
  tolerance (20 px) on that axis.

The verdict is judged per window. An aggregate rejection names one id,
but another window in the same pass may still have refused its own size,
and a window that fails a guard is skipped without silencing the rest. A
window that never moved is the case this exists for: its size is whatever
it already was, and reading it as a minimum is how a stale full-screen
bound gets invented.

**Provenance.** Each entry records one of three things. `seeded` is an
`AXMinimumSize` value or a per-bundle-id guess, which nothing has refused.
`observed` is a bound the app actually refused to shrink below. `appHint`
is another window of the same app's `observed` bound, carried across.
Fit checks read all three the same way; the state dump and the logs print
the source. A bypass keys on `observed`, and an explicit user request — a
float→tile, a move, the fit diagnostic — sets an `appHint` aside as well,
because a hint is somebody else's evidence and the window it is refusing has
never been asked. Real evidence
*replaces* a hint of either kind rather than merging with it, so the axis a
readback did not refuse goes back to unknown instead of inheriting a guess
under an `observed` label.

**Per-app hints.** Every `observed` bound also raises a per-bundle-id hint,
the per-axis max of what that app's windows have refused. A new window of
that app with no entry of its own is primed from the hint, marked `appHint`,
so the structural fit check can refuse it before a single frame is written —
the second Outlook window does not have to prove the same 938 pt floor with
its own visible resize. The hint outranks the `AXMinimumSize` seed: one of
the app's own windows really refused that size, while the seed is a number
the app published without being asked. An empty bundle id names no app and
gets no hint.

A hint is session-only, it moves both ways, and the user can always step
past it:

- **It rises** on a window's `observed` refusal, per axis, and only on real
  readback evidence — a hint never feeds a hint, so it cannot ratchet itself
  upward window after window.
- **It falls** when a window of that app accepts a size below it, by the
  same `lowerMinSizeAcceptedDeltaPx` margin the per-window bound uses. One
  stubborn window's floor is not the app's floor: Safari has many kinds of
  window, and the one that refused 938 is not the Start Page.
- **An explicit user action sets it aside** for one attempt: a float→tile,
  a move, and the fit diagnostic all ignore the `appHint` the way they
  ignore an `observed` bound, so the window is probed for real instead of
  being refused on a sibling's word. When that attempt is accepted the entry
  becomes the window's own `observed` record at the size it took, and the
  app's hint comes down with it. Without this a hinted window could never
  get back into a tree — the recovery floats it, and a floating window never
  reaches the code that would lower anything.
- **It is gone on restart**, because a floor depends on the UI state the
  window was in.

Watch `min-size app hint: bundle=…` at `[debug] [lifecycle]` to see a hint
rise (`from=<id>`) or fall (`source=accepted`).

Per-axis evidence stays per axis, and zero means unknown: a window with a
1200-point width floor and no height evidence is remembered as `1200x0`,
and a fit check reads the zero as no constraint.

Hysteresis on both ends:

- **Record (raise the floor):** when a guarded oversize is observed, the
  recorded min is `max` of the existing *observed* value and the observed
  size, on the affected axis only. Sentinels above
  `usableMinSizeMaxPx` (10 000 px) are rejected — apps occasionally
  report `INT_MAX` when AX cannot resolve.
- **Lower (relax the floor):** the 10 px
  `lowerMinSizeAcceptedDeltaPx` gate is an *either-axis* trigger. When
  one axis comes at least that far below the bound, the new floor is the
  per-axis `min` of the bound and the accepted size, so the other axis
  can come down by less than the delta in the same step. That is not the
  hysteresis it looks like, but it is not wrong either: the window did
  accept that size, so a floor above it was false. What the gate stops is
  a purely sub-pixel accept relaxing anything at all. Lowering keeps the
  entry's provenance: relaxing an estimate is not the same as watching
  the app refuse something.

Both tiling passes reconcile against the memory. The adjusted pass is
where a window that was given a bigger tile finally accepts a frame
smaller than the one it refused, so its accepted readback lowers the
bound — the readback, never the tile that was asked for. A whole-slot
accept changes nothing: a window that only ever fits its whole slot
accepts its whole slot, which is not evidence it can be smaller. A
minimum is never capped against the screen either; a constraint wider
than most of a display still fits above or below something.

The memory mirrors back onto each `HyprWindow.observedMinSize` and
`HyprWindow.minSizeProvenance` so other subsystems (drag-swap fit check,
floating toggle) read consistent values.

### Explicit revalidation

A learned bound is a memory of one refusal, and every later fit check treats
it as a standing fact. Two things get to ask the app again, and only these
two: the admission recovery's one retry, and the user's own explicit
request. Ordinary polling and ordinary retiles never do — that is how a
recovery turns into an unlimited min-size probe.

"Learned" means `observed` provenance. A `seeded` entry is an
`AXMinimumSize` value or a per-bundle guess that nothing has tested, and
setting it aside would mean writing a frame the app said up front it will
not take. The refusal diagnostics name `learned`, `seeded` and `structural`
separately for the same reason.

`TilingEngine.admissionOutlook` is the question. It runs the ordinary fit
check, and if that refuses, runs it again with every observed bound for the
incoming window and for the destination's tenants set aside. Widening it to
the tenants is the point: the bound that refuses an incoming window is
usually a tenant's, not its own. The answer is `.fits`, `.revalidatable` —
memory alone refused, so one real attempt would settle it — or `.refused`,
which the bypass did not change. Both checks read the same tree under the
same structural rules — depth, slot geometry and topology — and no frame is
written either way. The workspace count limit is not one of them. That
check lives in the caller, `WorkspaceOrchestrator.moveToWorkspace`, and it
runs only when the destination workspace is hidden.
Priming can still record a new `seeded` entry and asking about an untiled
workspace still creates its empty tree — both inherited from the plain fit
check — but no `observed` bound is touched.

Where the bypass reaches differs by who is asking. Both spell it as one
generation per window, and both set aside observed bounds recorded *below*
it. The admission retry passes its own admission's generation, so what that
admission learned stands and only older evidence is distrusted. An explicit
request passes `revalidationBypassBefore`, which is past every generation
there will ever be, because the user asking by hand is distrusting the whole
observed record for those ids. Neither erases anything: the entries stand
unless an attempt is accepted and lowers them through the ordinary reconcile
path. The retry is also the only one that can refuse before writing: an
explicit request is a request for a real attempt, so it always makes one.

The bypass belongs to the request, not to the pass. A window the request
never named — an unrelated newcomer that happens to be assigned to the same
workspace — is judged by the ordinary rules, with the bypass suspended for
that decision. Only the request's own windows are inserted under it.

A window that still does not fit is a structural no-fit. It is reported on
the `AdmissionResult` as `refusedIDs` and the caller finishes it. There is no
overflow router to hand it to: a fit refusal never moves a window to another
workspace, in a bypassed pass or an ordinary one.

### Moving a window to another workspace

`WorkspaceOrchestrator.moveToWorkspace` asks for the outlook before it
touches anything. A structural or seeded refusal beeps and flashes as it
always has, without a single frame write. A `.revalidatable` refusal takes
one of two paths.

**Visible destination.** The window is laid out into the destination
alongside its tenants before anything about the source changes, and only a
published layout commits the move. A refusal rolls back: the incumbents go
back on their originals, the window goes back to the screen it came from, it
keeps its place in the source tree, its floating flag goes back, and the
ordinary rejection happens.

The rollback has to be told it may reach that far. A visible destination is
always a different screen, so the window is standing on the source screen
when the attempt captures its original frame. A newcomer whose original is
outside the restoration rect is left where the candidate put it. Left alone
that would strand the window on the destination screen while it is still
assigned to the source, which the next poll reads as screen drift and acts
on — completing the move the user was just told was impossible.
`revalidateAdmission` takes a `restorationReach` for this, and the
orchestrator passes the source screen's rect.

**Visible destination, ordinary move.** A window that fits takes the other
order: it leaves the source tree, is reassigned, and the retile that
follows lays out the destination with it. By then the destination is where
it belongs, so a refused layout does not send it back. The incumbents are
restored and verified; the mover stays where the candidate left it, in no
tree, and the admission recovery retries it about 250 ms later. When the
candidate's writes reached the mover, that is the destination screen and
the retry is a same-screen write: a terminal that settled short after a 2x
to 1x hop (issue #19, 1366×1136 against a 1394 target) gets its second
write on the screen it now stands on. When the candidate failed on an
incumbent before reaching the mover, the mover is still on the source
screen and the retry is its first write. If the retry is refused too, the
window floats in place and the fallback retile gives the incumbents their
slots back. Rolling it back across the screens instead
would leave a nonfloating window on a screen that does not show its
workspace, and the rollback would be a second scale hop that can land short
of the strict restoration bound itself.

**Hidden destination.** Nothing is written. Unparking a hidden workspace's
tenants over the visible one to run an experiment is not what the user
asked for. The move follows the existing assignment and parking, and
`MinimaRevalidation` holds a marker carrying the destination, its screen and
the source. The first retile after that workspace is shown spends the
marker, as one `revalidateAdmission` pass. Accepted, the disproved bound is
lowered. Refused, the newcomer is stranded and the bounded admission
recovery takes it from there — one retry, then a float in place, or the
timeout path in step 3 when the app did not answer in time.

The marker is spent by that one reveal whatever the answer, and only by a
pass that can actually judge the window: an id AX did not return keeps its
marker instead. It is dropped when the window is moved again, when it is
forgotten, on a display change and on a stop. Reassignment and a user float
drop it too, but lazily — the reveal notices rather than the action. It
deliberately survives a later key press, unlike an armed admission retry:
the key press it is waiting for is the workspace switch.

The float→tile toggle asks the same question, but only when
`forceInsertWindow` returns `.failed(.noFittingSlot)` — the tree refusing
the window. `.failed(.layoutRejected)` is the screen refusing real frames,
which is evidence rather than memory, and buys nothing. The outlook and
forced insertion ask the same structural question — the same depth ceiling,
the same slot geometry, no eviction on either side — so a tree out of depth
reads as structural on both and buys no retry.

### Refusal diagnostics

A refusal reports one line per leaf the search tried, with the incoming id,
the tenant that refused, the slot, both required sizes, the axis and the
source. There is deliberately no single "largest free slot" figure: which
leaf can take a window depends on the split direction, the ratios and the
tenant already sitting there, so one number would be a fiction.
`minSlotDimension` never appears as a source, because `fittingLeaf`'s second
pass ignores it — it is a preference, not a refusal.

## Swap

Direction swap (`Hypr+Shift+Arrow`) goes through
`canSwapWindows` first. The check:

1. Snapshot the tree.
2. Trial-swap the two windows with cleared `userSetRatio` flags.
3. Reset every internal node's `splitRatio` to the default so the
   trial layout matches what the actual swap will produce.
4. Ask `LayoutEngine.layoutCanAccommodateKnownMinimums` whether the
   resulting layout fits every recorded min size.
5. Restore the snapshot and return the answer.

The synchronous `swapWindows` path returns true only after verified
acceptance. A rejected attempt restores the prior tree and captured actual
frames, with restoration verified separately. Keyboard rejection retains
its existing feedback behavior.

## Pointer target insertion

`TiledDragHandler` owns a press snapshot and a deferred release. It captures
the actual frames of the source tree and visible floating occluders once.
A press must hit exactly one tile and no occluder. Floating and scratchpad
presses do not start tiled insertion.

The mouse-up event supplies the release point. The mouse lifecycle latches the
logical Hypr key when it is held at press, pressed during the drag, or still
held at release. Option at release remains a compatibility shortcut. After
the 100 ms settle delay, a bounded read of the captured dragged window
separates manual resizing from movement (`TiledDragSnapshot.gesture`). The
window is unmoved when its position and size are each within a point of the
captured frame, so text selection does not rearrange unmoved windows. It is a
resize only when all three of these hold:

- The press landed on the window's resize border. The border is a band just
  inside the captured frame: 8 points at the left, right and bottom edges and
  4 at the top, corners giving two edges. The top band is narrow because the
  title bar starts right below it. There is no outer band: a press outside
  the frame is not a tile press at all.
- The edge opposite every grabbed edge stayed within 3 points: maxX for a
  left edge, minY for a bottom edge, and so on.
- At least one grabbed axis changed size by more than 4 points.

Anything else is a move. A size change on an axis nobody grabbed counts
neither way. An aspect-locked side resize moves the other axis, and a corner
press the band reads as one edge is still that edge's resize. A small resize
reads as one from its first few points, which keeps the live preview from
flashing at the start of an edge drag.

A real edge or corner drag keeps the far edge still. A move keeps no edge
still, even when the app changes its own size on the way. Messages changes
its height by up to 279 points when it is dragged onto the ultrawide. Reading
that as a resize rejected the drop, or grew its tile on the source, and a
press in the top of the title bar would still have done it under a band
alone. A capture by window id has no press point, so size alone decides
there, a change over 20 points as before.

An ordinary move chooses a target from the release point within the source
workspace and physical display. The nearest normalized target edge selects
left, right, top, or bottom insertion; ties use that order. A latched Hypr
gesture or Option at release requests a same-tree swap instead. A release on
the source display without a target restores and verifies the captured
frames, silently: nothing was written before the refusal, the window goes
back to its slot, and the key keeps speaking for its geometry. Every other
refusal beeps, flashes and marks the key. A release on another display is a
drop across monitors, described below.

`BSPTree.candidateTree` clones the source, removes the dragged leaf, and
splits the target on the selected side. Horizontal splits create columns;
vertical splits create rows. The candidate preserves unrelated node state
and exact membership. Every leaf must satisfy Max Splits before candidate
writes. Restoration writes remain available when a candidate fails preflight.
This hard limit also applies to modifier swaps and manual resize candidates;
an existing tree deeper than a newly lowered limit is restored rather than
applied. Keyboard swapping retains its existing path.

The engine applies the candidate through the verified sizing transaction
and replaces the mapped tree only after all resulting frames are accepted.
Failure leaves the old topology in place and verifies actual pre-drag frame
restoration. Failed restoration is reported as degraded; stale work stops
without overwriting newer geometry. Anything short of a committed drop marks
the `(workspace, screen)` geometry unverified.

A finished drag decides, per member, what its cached geometry is worth, and
every cache holding drag geometry takes the same decision, so the tiled
positions and the per-window frame cache cannot drift apart. A committed drop
and a verified rollback refresh every member from the readback. A degraded
drop invalidates every id either attempt may have written, plus the dragged
id — macOS moved that one, so an unverified outcome says nothing about where
it is — and preserves the members nothing touched. A degraded drop that
carries no provenance clears every member, because then nothing is provably
untouched. Clearing only the dragged id would be wrong: a rollback writes
every captured original. The finishing flag suppresses polling
through the settle delay and transaction, without a fixed expiry timer.

### Dropping on another monitor

A plain move released on another display lands in the workspace visible
there (`WorkspaceManager.workspaceForScreen`). The release screen is the one
whose whole display frame holds the point, menu bar and Dock included. The
drop places the window the way a same-tree drop does:

- Over a tile, the window is split in beside it on the nearest normalized
  edge, with the same edge rule and the same split.
- In a gap or the padding, the nearest tile takes it, the lower id on a tie.
  The edge is measured from the point clamped into that tile.
- A latched Hypr gesture or Option at release swaps it with that tile. The
  two windows trade leaves, trees and workspaces. Both topologies stay as
  they were. Ratios move only for a known-minimum conflict, as on any drop.
- A workspace with no tiles takes the window as its tree root, swap or not.

The source tree loses the window the way it would on a close, and a source
tree left empty is dropped. Visible floaters on the release screen do not
block the drop. The same-tree release ignores them too.

The release screen's tree is read before anything is written, and its
members' actual frames become its originals for a rollback. The target tile is
chosen from that tree's own layout slots, the same ones the live preview uses.
Both candidates are private clones from `BSPTree`, built in the engine's drop
path. Each must stay within its own screen's Max Splits. Each layout gets the
same known-minimum ratio adjustment as a same-tree drop. If a known minimum
still overflows its slot by more than 20 points
(`TilingConfig.frameToleranceXPx`, the overshoot a readback may show), the
drop is refused (`noRoom`) before any candidate write. The release screen's
frames go out first, then the source's. Each screen has its own
`FrameSizingAttempt` against its own usable frame. A window crossing screens
takes the engine's write order, and two displays with different backing
scales get the scale-change budget. Both trees publish together, and only
after every frame on both screens was accepted.

A call that times out on either screen gets its one longer try first.
Messages took 101 ms to answer a position write right after crossing
displays, just past the 100 ms call timeout. All of a drop's attempts share
one 2.5-second budget for those longer tries (`TiledDragBudget`). Once it is
spent, a timeout gets no longer try, and the drop goes on with its plain
attempts to its plain outcome. The cut logs `frame attempt AX timeout
recovery skipped`. The budget bounds the retries, not the drop. Each
capture, candidate and rollback still runs with its own deadline of 0.36
seconds, or 1 second under the scale-change budget. So a drop that ends up
rolling both trees back can still hold the main thread past 2.5 seconds,
though no longer for the ten or more that every retry could add up to.

A refusal before the first write puts back only the source. The release
screen was read but never written. These refusals are no target, no room,
Max Splits, and an invalid candidate, and they report as an ordinary
same-tree restore that marks only the source key.

A sizing failure after the writes began puts both trees back. The source's
captured originals go first, the dragged window's among them, then the
release screen's. Each set is verified against its own screen. Neither
topology changes, and every key that has a tree is marked unverified. A
release screen with no tree has no key to mark. So does a commit whose frames
were accepted but whose setters did not all return success
(`unverifiedCommit`). The dragged window may already stand on the release
screen, and publishing nothing while it stays there would leave the source's
tree and membership claiming it. Superseded work writes nothing more, on
either screen, as on a same-tree drop: a newer operation owns the geometry.
A failure whose drop went stale before the rollback is reported degraded
without one. The cache rules above cover both trees' members, and deferred
degraded feedback waits for both keys to verify again.

Workspace membership changes only on a commit, through
`WorkspaceManager.moveWindow`, for the dragged window and for a swapped one.
It moves in the same synchronous step that published the trees, before the
drop is reported. After a commit the dragged window keeps focus, and the
border is drawn on its verified frame rather than on a live AX read.

These cases restore exactly as a release without a target always has: a
disabled release screen, the scratchpad layer up on any screen, a scratchpad
source, a point on no screen, and a resize candidate, which keeps the
same-tree resize rule. A window that did not move is still ignored.

### Live drop preview

While a tiled drag is in progress, a translucent highlight shows where the
window will land. It uses the focus color the user picked, at low alpha: the
bracket color when brackets are on, else the focus border color when the
border is on, else brand cyan (`UserConfig.resolvedDropPreviewColor`). It has a
thin border and the window corner radius. It appears only after all of these
hold:

- the press was captured as a tiled press
- the pointer has passed the drag threshold
- the drag is a move by the drop's own rule (`TiledDragSnapshot.gesture`),
  applied to the dragged window's frame from the window list
  (`CGWindowListCreateDescriptionFromArray`, not AX) at every update. A press
  that selects text leaves the window unmoved, and an edge drag becomes a
  resize, so neither shows a preview. The drop reaches the same verdict from
  its settle read.

What it shows:

- **Plain insert, on either monitor:** the rect the dragged window would get.
  That is its slot in the candidate tree the drop would build, with the same
  known-minimum adjustment.
- **Swap (Hypr latched or held, or Option):** the whole target tile.
- **An empty workspace on another monitor:** that screen's tiling rect, inside
  the outer padding.
- **Nothing** wherever the drop would restore: a gap on the source, a disabled
  monitor, the scratchpad, a point on no screen, past Max Splits, or no room
  for a known minimum.

Preview and drop cannot disagree, because both come from the same parts:

- `TiledDropPlanner` picks the target and edge. The drop calls it too: its
  same-tree target at release, and its target on another monitor.
- The source tiles are the press capture, which the drop resolves against as
  well.
- Another monitor's tiles are that tree's own layout slots
  (`TiledDropPlanner.slots`), not a live read. The drop now picks its target
  from those slots too. It still reads that screen's frames first, for the
  rollback.
- The rect comes from `TiledDragTransaction.previewFrame`, which builds the
  same candidates as `drop` and `dropAcrossTrees`.

No AX call runs while the pointer moves. Another monitor's tree is kept
between updates only while its workspace is still the one visible there and
the tree is unchanged. A workspace switch, the scratchpad, or any layout since
the press (which supersedes the drop) shows through at the next update. A
workspace change or a hotkey action also asks again straight away. Updates come at most 60
times a second. A move inside that interval is held and applied when it ends,
so the last position always shows. The panel redraws only when the rect
changes. A Hypr press or an Option change asks again at the last point. The
highlight hides at mouse-up, on a stop, and when there is nowhere to land.
Nothing keeps running after the drag: one held update at most, and it does
nothing once the drag has ended.

## `prepareTileLayout` / `prepareSwapLayout` / `prepareToggleSplitLayout`

These methods calculate layouts after provisional tree changes.
`prepareSwapLayout` and `prepareToggleSplitLayout` capture actual frames
and the prior tree state for a later verified `applyComputedLayout` call.
They currently have test callers; keyboard actions use synchronous verified
paths. A superseding operation invalidates prepared rollback data.

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

### Restored ratio versus the smart-insert fit check

Smart insert judges whether a leaf has room by splitting its rect
50/50, but a restored boundary is applied afterwards by
`applySavedRatios`. A remembered 0.85 can therefore starve the small
side of a slot that the fit check passed. This is the same exposure a
manual resize already has, so it is left alone.

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
`swapWindows`, `toggleSplit`, `resizeInDirection`,
`prepareSwapLayout`, `prepareToggleSplitLayout`,
`forceInsertWindow`, `canFitWindows`) plus verified drag capture/drop and
`retile` make up the engine's orchestration surface;
extracting them would require splitting the engine into a thin
orchestrator over a sibling type, which produces ceremony without
removing duplication. The decomposition is left for a future cycle.
