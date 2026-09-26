# Debugging

HyprMac logs through `os.Logger`. The subsystem is the running app's
bundle id: `com.zachgray.HyprMac` for release and
`com.zachgray.HyprMac.debug` for the Debug app. The recipes below use
the release id; swap in the debug id when reading the Debug app. This
document covers how to read the logs, how to enable verbose logging in
Release builds for support sessions, and the smaller knobs available
for narrowing the output.

Quick rules:

- Call `/usr/bin/log` by full path. A shell function can shadow `log`,
  especially over SSH.
- Only `.notice` and above persist. `.debug` lines show up only in a
  live stream started before the repro:
  `/usr/bin/log stream --level debug --predicate 'subsystem == "com.zachgray.HyprMac.debug"'`.
- Debug builds also keep a file log at
  `~/Library/Logs/HyprMac/<bundle id>.log` (see below).
- The running build's source is `HyprMacSourceRevision` in the app's
  Info.plist. `scripts/build-debug.sh` fills it in as
  `<sha12>+<content hash>`; other builds leave it empty or `unknown`.
- Intermittent bugs: no repro, no guess fix. Add `.notice` logs at the
  suspect paths, ship them in the Debug app, and fix only once the logs
  confirm a cause. Keep those logs afterward.

## Log tiers

Two tiers, defined in `Shared/Log.swift`:

- **Diagnostic** — `.notice`, `.warning`, `.error`, `.fault`.
  Always emits via `os.Logger`. Visible in Console.app for support
  even on shipping Release builds. Used for fallback / suppression
  decisions, error paths, and anything a user might be asked to
  share when reporting a bug.
- **Trace** — `.debug`, `.info`. Developer-only. In DEBUG builds,
  emits when the level is at or above `LogConfig.traceMinimum` and
  the category is in `LogConfig.enabledCategories`. In Release,
  emits only when the `HyprMacVerboseLogging` `UserDefault` is
  set.

`privacy: .public` is applied to every message because the only
metadata that enters log strings is safe (window IDs, workspace
numbers, screen names, action names, durations). Free-text user
input must not enter log strings.

## Categories

Each log site picks a category from `LogCategory`:

```
orchestration  state         focus         tiling        workspace
discovery      input         mouse         drag          hotkey
floating       ui            animator      border        dimming
overlay        config        persistence   migration     sync
lifecycle      accessibility space         display
```

Categories surface as the `category` field in Console, so you can
filter by subsystem + category to scope logs to one subsystem
without scrolling through everything.

## Console.app filter recipes

Open Console.app, set the device dropdown to your Mac, and apply
these filters via Action → Search.

### Everything HyprMac

```
subsystem:com.zachgray.HyprMac
```

### One category

Replace `tiling` with the category you want.

```
subsystem:com.zachgray.HyprMac category:tiling
```

### Errors and warnings only

```
subsystem:com.zachgray.HyprMac category:any messageType:error,fault,default
```

(`messageType:default` covers `.notice`. `messageType:info` covers
`.info`. `messageType:debug` covers `.debug`.)

Save the filter via Action → Save Search so it lands in the sidebar.

## Streaming to a file

```
log stream --predicate 'subsystem == "com.zachgray.HyprMac"' --info
```

Add `--debug` for trace logs (DEBUG builds, or Release with the
verbose toggle below). Pipe through `tee` to keep a copy:

```
log stream --predicate 'subsystem == "com.zachgray.HyprMac"' --info | tee hyprmac.log
```

Predicate variants:

```
# one category
--predicate 'subsystem == "com.zachgray.HyprMac" && category == "tiling"'

# multiple categories
--predicate 'subsystem == "com.zachgray.HyprMac" && (category == "tiling" || category == "discovery")'

# warnings and above only
--predicate 'subsystem == "com.zachgray.HyprMac"' --level warning
```

## Debug builds keep a file log

macOS never persists os_log `.debug` lines. By the time you run `log
show` after a bug, only `.notice` and above survive — every `retile:
workspace=`, `workspace N full`, `window gone:` and poll-timing line
is already gone. So debug builds also append every `hyprLog` call, at
every level and every category, to a plain text file.

Path (one file per bundle id, so the debug app and a release build
never share):

```
~/Library/Logs/HyprMac/com.zachgray.HyprMac.debug.log
```

One line per call, format stable:

```
2026-09-12T19:41:02.123-0500 [notice] [discovery] window gone: 1304
```

Timestamp, then `[level]`, then `[category]`, then the message.
Levels are `debug info notice warning error fault`; categories are the
`LogCategory` names listed above.

The file rotates at 20 MB: the current file is renamed to
`<name>.log.1` (replacing any previous `.1`) and a fresh one starts.
So the log costs at most ~40 MB on disk.

Tail it from another machine:

```bash
tail -f ~/Library/Logs/HyprMac/com.zachgray.HyprMac.debug.log
```

`WindowManager.start()` logs the exact path at `.notice`, so
`log show` tells you which file the running instance is writing to:

```bash
/usr/bin/log show --predicate 'subsystem BEGINSWITH "com.zachgray.HyprMac"' --last 5m | rg 'file log:'
```

The switch is `LogConfig.persistentFileLog` in `Shared/Log.swift`. It
defaults to `true` under `#if DEBUG`; in Release it follows the same
`HyprMacVerboseLogging` user default as trace logging (below). If the
directory or the file cannot be created the log disables itself
silently — one `.notice` says so and the app runs unchanged.

### Frame write tracing

`FrameSizingAttempt` traces every AX frame write and every readback at
`.debug` under `category: tiling`, so the file log shows what was asked
for and what actually came back — not just the final `verified layout`
verdict. Every line carries `phase=`, one of `candidate`, `adjusted` or
`restoration`: `candidate` is the first try at a layout, `adjusted` the
retry after min-size ratio adjustment, `restoration` the rollback to
captured original frames. The fourth phase, `capture`, writes nothing and
logs no trace line; it appears only in typed results. Four line names:

- `frame write: wid=<id> phase=<…> target=(x,y,w,h)` — once per window,
  before its writes. The target is the frame the layout asked for.
- `frame write: wid=<id> phase=<…> steps=<label>:<raw>/<n>ms,… complete=<bool>`
  — once per window after its writes, listing every AX setter that went
  out with its raw `AXError` code (0 is success) and how long it took.
  `size2` is the second size write of the resize-move-resize pattern.
  `complete=true` means all three setters returned success; it is
  evidence that the writes were issued, not proof the app applied them.
  A window that never got past the EnhancedUI bracket logs `steps=none`.
- `frame readback: wid=<id> phase=<…> sample=<n> actual=(x,y,w,h)
  delta=(dw,dh) dx=<>,dy=<> onTarget=<bool> at=<n>ms` — one per
  settle-loop sample that did not land exactly on target. `delta` is
  size (actual minus target), `dx`/`dy` position, `at` the time since
  the attempt started. `onTarget` is the verdict's own tolerant matcher:
  a dwindle split lands on a half point and the app answers on the
  integer, so the sample is off by 0.5 and `onTarget=true`. A
  cell-quantizing app (terminals) shows a steady non-zero delta with
  `onTarget=true` for the same reason. `onTarget=false` on a stable
  sample is what actually costs the settle floor.
- `frame attempt: phase=<…> gen=<n> wids=[…] verdict=<…> written=[…]
  complete=[…] readback=<complete|partial>/<stable|unstable>
  write=<n>ms read=<n>ms settle=<n>ms elapsed=<n>ms headroom=<n>ms` —
  once at the end of every attempt, the restore attempt after a
  rejection included. `written` is every window a setter was issued
  for, `complete` every window whose three setters all returned
  success. `write` covers the write pass, `read` the settle loop,
  `settle` just the sleeps inside it, and `headroom` is what was left
  of the 0.36 s deadline.

`FrameReadbackPoller` logs one `min evidence:` line per window it treats
as a min-size conflict, under the same category and tier:
`min evidence: wid=<id> phase=<…> target=<w>x<h> actual=<w>x<h>
axis=<width|height|width+height> written=<bool> complete=<bool>
stable=<bool> learn=<bool> refused=<reason> source=readback`. `learn`
is the whole point of the line: `false` means the oversize taught
nothing, and `refused` names the guard — `ioFailure`,
`writesIncomplete`, `readbackIncomplete` or `originMismatch`.
`originMismatch` is the common one: the window is not where it was told
to go, so its size is whatever it already was. `refused=none`
accompanies `learn=true`. The enum has two more cases,
`restorationPhase` and `notRejected`, that this line can never carry:
the line is only reached inside a rejected candidate or adjusted pass,
and a restoration pass classifies nothing, so it logs no `min evidence:`
lines at all.

`MinSizeMemory` then logs what it did with that evidence under
`category: lifecycle`, in three shapes:

- `min-size record: wid=<id> old=none new=<w>x<h> axis=width+height
  source=<seeded|appHint|observed>` — the mirror on a window being picked
  up as a starting estimate. No `target=` or `actual=`: nothing was
  measured in this step. `source=appHint` means the number came from
  another window of the same app; `seeded` is the ordinary case
  (`AXMinimumSize` or a per-bundle-id guess); it could only read
  `observed` for a window object that outlived the memory being told to
  forget it.
- `min-size app hint: bundle=<id> old=<none|<w>x<h>> new=<w>x<h>
  from=<id>` — one of the app's windows refused something no earlier
  window of that app had, so the app's hint rose. Per-axis max, and only
  real readback evidence ever writes it.
- `min-size app hint: bundle=<id> old=<w>x<h> new=<<w>x<h>|none> from=<id>
  source=accepted` — the same hint coming down: a window of that app took a
  size below it, which is the app saying one window's floor is not the
  app's. Hints are session-only and move both ways; an empty bundle id
  never gets one.
- `min-size record: wid=<id> old=<w>x<h> new=<w>x<h> actual=<w>x<h>
  source=own-measurement was=appHint` — an explicit request set the app's
  hint aside, the attempt was accepted, and the entry became this window's
  own record at the size it actually took.
- `min-size record: wid=<id> old=<none|<w>x<h> source=<seeded|observed>>
  new=<w>x<h> target=<w>x<h> actual=<w>x<h> axis=<…> phase=<…>
  source=readback` — guarded refusal evidence. The `old=` field names
  the provenance of the entry being replaced, because observed evidence
  replaces a seeded hint rather than merging with it. When the new value
  fails the sanity check the line ends `refused=unusable` and carries no
  `new=`.
- `min-size lower: wid=<id> old=<w>x<h> new=<<w>x<h>|none> actual=<w>x<h>
  axis=<…> source=accepted was=<seeded|observed>` — an accepted readback
  relaxing a bound. `was=` is the provenance the entry keeps.

### Why a move or a float→tile was refused

`TilingEngine.admissionOutlook` logs the whole question at `.notice` under
`category: tiling`, one line per leaf the search tried and then a verdict:

```
fit refusal: incoming=<id> ws<N> tenant=<id|none> slot=<w>x<h>
  needIncoming=<w>x<h> needTenant=<w>x<h>
  axis=<width|height|width+height|depth> source=<learned|appHint|seeded|structural>
fit outlook: incoming=<id> ws<N> verdict=<fits|revalidatable|refused> refusals=<n>
```

`source` is where the bound that said no came from. `learned` is
`observed` provenance — the app actually refused that size once. `appHint`
is a bound another window of the same app refused, carried across; an
explicit request sets it aside the way it sets a `learned` bound aside, so
it reads as `revalidatable` rather than `refused`. `seeded`
is an `AXMinimumSize` value nothing has tested, and it
covers a bound `MinSizeMemory` holds no entry for: priming refuses a value at
or above `usableMinSizeMaxPx` or one that is not finite, and the fit check
still reads it off the window's own mirror. That is the app talking, not
geometry.
`structural` is the depth ceiling, or a slot too small for the gap alone
whatever the memory says. `needIncoming` or `needTenant` reading `0x0`
means that side has no recorded bound on the axis in question.

There is one line per leaf on purpose. Which leaf can take a window depends
on the split direction, the ratios and the tenant already sitting there, so
a single "largest free slot" figure would be a fiction. `minSlotDimension`
never appears as a source: `fittingLeaf`'s second pass ignores it, so it is
a preference rather than a refusal.

`verdict=revalidatable` means only learned bounds or app hints refused, and
the request gets one attempt with them set aside. Look for what follows:

- `minima revalidation attempt: ws<N> incoming=[…] bypassing=[…]` — the
  attempt itself. `bypassing` is the incoming window plus every tenant of
  the destination tree.
- `minima revalidation parked: <id> → ws<N> from ws<M> — verified when that
  workspace is shown` — a hidden destination. Nothing was written.
- `minima revalidation revealed: spent=[…] tiled=[…]` — the marker being
  spent on the reveal. Ids in `spent` but not `tiled` were stranded, and
  the next line for them is `admission retry scheduled:`.
- `minima revalidation cancelled: <id> reason=<…>` — the marker dropped
  before its reveal.
- `float→tile revalidation: <id> ws<N>` — the toggle's one bypassed
  `forceInsertWindow`.
- `no fitting tile slot: wid=<id> ws<N> — staying in place` — the pass could
  not smart-insert that window into the BSP tree for that workspace. Any
  tiling pass can log it, not just a bypassed one. Nothing routes the window
  anywhere: a fit refusal never sends a window to another workspace. It stays
  on its assigned workspace, where it already is, and `AdmissionRecovery`
  decides what becomes of it.

The workspace-full check uses the same vocabulary on its own line:
`workspace <N> full: incoming=<id> tiled=<n> max=<m> axis=count
source=structural — rejected move`.

`WindowManager` logs one `gesture:` line per left-mouse release under
`category: mouse`: `gesture: sawDragEvent=<bool> travel=<n>
threshold=8 drag=<bool>`. macOS fires `.leftMouseDragged` on a pixel of
hand jitter, so `sawDragEvent=true drag=false` is an ordinary click that
travelled less than the threshold. A completed tiled drag adds
`tiled drag result: dragged=<id> members=[…] outcome=<…>` under
`category: tiling`.

A degraded drop adds `written=[...]`, the ids either the candidate or the
rollback issued a setter for. Those, plus the dragged id, are the entries
every drag cache drops; the members not listed keep their cached frames.

`AXFrameWriteBatch` logs its AXEnhancedUserInterface toggle at the same
tier, and only when it fails: `enhanced ui: pid=<pid> begin disable
err=<raw>`, plus the `begin timeout`, `begin toggle timeout`, `begin
read`, `begin read gave a non-boolean` and `end` variants. A healthy run
logs none of them.

Window ids only; no titles.

## On-demand state dump

`WindowManager.dumpState(reason:)` logs a `.notice` block under
`category: lifecycle` describing workspace, cache and tree state. It
runs once at startup right after the initial tile (`reason: startup`)
and on every `SIGUSR1`:

```bash
kill -USR1 $(pgrep -x 'HyprMac Debug')
```

Then read the file log. The block looks like:

```
state dump (SIGUSR1)
screen=Built-in Retina Display visible=ws1
screen=S34C65xT visible=ws2
ws1 home=Built-in Retina Display visible=true assigned=[104, 118] hidden=[] reserved=[] floating=[118] tree(Built-in Retina Display)=[104]
ws2 home=S34C65xT visible=true assigned=[221] hidden=[] reserved=[] floating=[] tree(S34C65xT)=[221]
scratchpad=[319]
minima=[104:400x260(seeded), 118:938x0(appHint), 221:1496x841(observed)]
recovery pending=[] unverified=[221]
known=4 hidden=0 reserved=0 floating=1
```

Screens first, then each workspace 1–10 that has at least one window
(empty workspaces are omitted), then the scratchpad, then learned
minima, then recovery state, then cache totals. `tree(...)` is the leaf
membership of that workspace's BSP tree on its home screen — compare it
against `assigned` minus `floating` minus `hidden` to spot a window that
holds a workspace slot but is missing from the tree. Window ids only;
titles never enter the dump.

`minima` is everything `MinSizeMemory` believes, with the evidence
behind each entry in brackets: `observed` is a bound the app refused to
shrink below, `seeded` a hint from `AXMinimumSize` or a per-bundle-id
guess that nothing has tested, and `appHint` a bound another window of the
same app refused, carried over so this one does not have to prove it again.
A window refused by a fit check should have an entry here explaining why,
and the source says how much that entry is worth. Zero on an axis means
nothing has refused anything there.

`unverified` lists every window under a `(workspace, screen)` whose last
layout attempt did not end accepted — a partial write, an unreadable or
unsettled readback, a cleanup error, a window that stopped short of its
slot, or a tiled drag that did not commit. Those windows advertise no
intended rect, so directional focus and swap judge them by their live
frames instead. The mark clears when a layout for that key is accepted, or
when the key itself goes away. A window listed here is one the tree cannot
speak for; compare it against `tree(...)` to see whether the tree even
holds it.

`recovery pending` reports newcomers a failed admission left outside the
tree and that admission recovery has not finished with. A window is listed
while its one retry is armed, and while it is waiting for evidence — it was
unreadable, or its workspace was hidden, when its turn came. It leaves the
list when the retry tiles it, when a later layout tiles it, when the
fallback floats it in place, when the user acts on it, or when it goes
away. An id that stays here across several dumps is a window nothing can
read; check whether its app is alive.

The recovery's own lines, all `[notice] [tiling]`:

```
admission retry scheduled: ids=[26016] ws2 in 250ms cause=geometryMismatch(21611)
admission refusal judged: ids=[26017] ws2 — floating in place at the next turn cause=geometryMismatch(21611)
admission retry attempt: ws2 bypassMinimaBefore=[26016:418]
admission retry refused pre-write: ids=[26016] ws2 — the known minima do not fit the usable frame
admission retry cancelled: ids=[26016] reason=later press
admission recovery pending: 26016 not judgeable yet — waiting for evidence
admission recovery held: ids=[26018] ws2 — in no tree, not floated
admission recovery resolved: 26016 (retry tiled it)
admission recovery policy routeToFittingWorkspace is not wired — floating 26016 in place instead
admission recovery fallback: policy=floatInPlace floated 26016 in place on ws2 first=geometryMismatch(21611) retry=geometryMismatch(21611)
```

One stranded window gets one of the first two lines, never both.
`admission retry scheduled:` names the windows with a bounded retry armed
about 250 ms out. `admission refusal judged:` names the windows that get no
retry at all: the pass already judged them with the bounds it was told to
ignore, so a second attempt would decide the same way. Their next turn floats
them where they stand.

Same-screen drift has two lines of its own, both `[notice] [tiling]`:

```
tiled drift: 32913 ws1 actual=(0,0,1512,900) intended=(8,41,744,841) — re-applying the layout once
tiled drift: 32913 ws1 took its frame back after the re-apply — leaving ws1 unverified rather than fighting the app
unverified mark set for ws1: 32913 drifted again after its one re-apply
```

The first needs two consecutive polls reading the same drifted frame, and
there is exactly one per workspace per poll. The second needs two of its own
after the re-apply, so a layout still landing does not read as the app
fighting back. It is the bound: the app won, and the key stops advertising
intended rects until a layout for it is accepted. Neither fires while a mouse button is down, while a tiled drag
is settling, during a display change or a workspace transition, or on a poll
that retiled anyway.

`admission recovery held:` is the other end of the fallback. After the
fallback floats a workspace's newcomers, one ordinary retile runs for that
key. A window this line names is visible, not floating, and in no tree even
after that retile. It is held: no timer, no float, an explicit record so the
state dump's `recovery pending=` shows it. It clears when a later layout for
that key publishes it, when the window is removed, or when it is forgotten.

`admission retry refused pre-write:` is a retry that wrote nothing. Every
bound it was honouring came from a guarded readback of the admission it was
retrying, and with all of them in hand the arrangement does not fit the
usable frame. It goes straight to the fallback instead of repeating the
resize the user just watched. There is no `frame write:` line between this
and the fallback.

`cause` and `first`/`retry` are the layout failures, which name whichever
window refused — usually an incumbent, not the newcomer being recovered.
`bypassMinimaBefore` maps each newcomer in the attempt to the generation
*below* which it ignores observed minima — normally its own admission's
generation, so anything that admission learned still counts and only older,
possibly stale evidence is set aside. One reach per window, because two
newcomers retried together were admitted at different times.
`policy=` on the fallback line names the end-state policy that applied;
`floatInPlace` is the only one wired. Cancellation
reasons are `stop`, `later press`, `display change`, `moved workspace`,
`screen changed` and `user floated it`; showing another workspace is not one
of them. A separate `unverified mark kept for wsN: a rollback did not
verify` line says the fallback floated a window but the key still cannot
speak for its incumbents.

## `--probe-frame` (debug builds)

One AX frame write against one window, in isolation, with the window
manager and the key remap not started. Use it when a window reads back
a size nobody asked for and you want to know whether the app or the
layout is responsible.

```
--probe-frame <windowID> <x> <y> <w> <h> [--order size-position-size|position-size|size-only] [--out <path>] [--wrapper] [--restore]
```

It reads the AX minimum size if the app exposes one, reads position and
size, performs the writes in the requested order with a 1.0 s messaging
timeout, reads back twice — at 0.3 s and at 1.0 s after the last write,
each line stamped with its own `t=`— and records every screen's `frame`
and `visibleFrame` in both NS and CG coordinates. The report goes to
`--out` (default `/tmp/hyprmac-probe-frame.txt`). Exit status is 0 on a
clean run and 1 when any AX call failed — the raw error code is in the
file either way. The default order, `size-position-size`, is the one
`FrameSizingAttempt` uses.

Two opt-in flags, both off by default so an old invocation behaves
exactly as before:

- `--wrapper` brackets the writes in the same `AXEnhancedUserInterface`
  toggle production uses (`AXFrameWriteBatch`), so a probe and a real
  layout differ only in timing. The report gains `wrapper begin=…` and
  `wrapper end=…` lines, and a failed begin or end fails the probe.
  Without it the probe writes raw, as it always has.
- `--restore` writes the frame read before the probe back at the end,
  in the resize-move-resize order, then reads it back. Its lines are
  prefixed `restore` and it carries its own `restore result=ok|error`.
  A failed restoration fails the whole probe on its own, so a good
  measurement with a window left in the wrong place is never reported
  as a clean run. With no readable baseline the probe refuses to
  restore rather than guessing.

`ax minimum=` reports `AXMinimumSize`/`AXMinSize` when the app exposes a
usable one and `unreadable` otherwise. Most apps do not expose one —
that is why `MinSizeMemory` learns the floor from readback — so
`unreadable` is normal and does not fail the probe.

Launch it through Launch Services, not by exec'ing the binary: the
Accessibility grant belongs to the bundle, and a direct exec from SSH
comes back untrusted (see
[laptop-debug-deployment.md](laptop-debug-deployment.md)).

```bash
/usr/bin/open -n -W --stdout /tmp/probe.out --stderr /tmp/probe.err \
  '/Users/zgray/Applications/HyprMac Debug.app' \
  --args --probe-frame <wid> <x> <y> <w> <h>
cat /tmp/hyprmac-probe-frame.txt
```

Window ids come from the state dump above, or from
`frame write:` lines in the file log.

## Verbose logging in Release

Trace-tier logs (`.debug`, `.info`) are gated off by default in
Release builds. To enable for a support session:

```
defaults write com.zachgray.HyprMac HyprMacVerboseLogging -bool YES
```

Relaunch HyprMac. The `LogConfig.verboseInRelease` getter reads the
`UserDefault` on every `hyprLog` call so the toggle takes effect on
the next emission — no further configuration needed.

To turn it back off:

```
defaults write com.zachgray.HyprMac HyprMacVerboseLogging -bool NO
```

(or `defaults delete com.zachgray.HyprMac HyprMacVerboseLogging` to
remove the key entirely.)

## DEBUG-only knobs

Two compile-time knobs in `LogConfig`, both in DEBUG builds only:

- `LogConfig.traceMinimum` — raises the trace-tier ceiling.
  Setting it to `.info` suppresses every `.debug` log;
  `.notice` would suppress every trace-tier log.
- `LogConfig.enabledCategories` — narrows trace output to a subset
  of categories. Diagnostic-tier logs always emit regardless.

Both default to "everything emits". Adjust them in `Log.swift` (or
ad hoc in `AppDelegate.applicationDidFinishLaunching`) when chasing
a noisy bug.

## Common debugging recipes

### "Why did focus end up there?"

```
subsystem:com.zachgray.HyprMac category:focus
```

Every `FocusStateController.recordFocus` call logs the
`from → to` transition with a short reason tag (`ensureFocus-tiled`,
`syncTracker-floating`, `cycleFocus`, etc.). Walk the log
backwards from the unexpected focus state to find the trigger.
`syncTracker-recovery` is the click hit-test landing on a newcomer in
admission recovery: it is drawn over the tiles like a floater but it is
not floating, so it gets its own tag rather than borrowing
`syncTracker-floating`.

### Same-app tiled/floating focus flicker

A Safari capture on September 14, 2026 exposed a focus/z-order feedback
loop. On build `1d4818448504+f0bab264c279`, hovering tiled window `42533`
while Safari floater `44870` was visible caused repeated reconciliation
passes about 200 ms apart. Each pass raised the floater, then restored
`tiled` focus through `focusWithoutRaise`, which generated another Safari
focused-window notification and poll. The logged suppression pair identifies
`raiseBehind` as the writer; the old build did not log its individual raise
IDs or AX raise return codes. The former Hypr+F binding (now Hypr+Shift+T) recorded `42533 → 44870` at
21:20:33.700 CDT, followed by a stale restore to `42533` at 21:20:33.763.
A later tiled hover restarted the loop. These are stable window IDs, not
page titles.

Automatic raising now leaves floating siblings of the focused tiled app
alone. Safari can reorder sibling windows when main/key focus is restored,
so repeatedly enforcing floater-on-top conflicts with the selected tile.
Cross-app raising and explicit Hypr+Shift+T remain available. Hover can select a
visible topmost floater by its physical window ID. A delayed restore must
still refer to the current, visible, known tiled focus target and must not
run during menu tracking or scratchpad display.

Actual reconciliation writes log `raise behind: wids=[…] under=[…] focus=<id>
front=<pid>`, `raise behind failed: wid=<id> rc=<AXError>`, and
`raise behind restore: wid=<id>` at notice level. Same-app passes that write
nothing stay silent. Correlate these with `ffm-topmost-floating`, ordinary
`ffm-topmost`, `cycleFocus`, and `ax event: focusedWindowChanged pid=<pid>`.
The next section covers the lines added for issue #10.

Live acceptance requires two overlapping Safari windows, one tiled and one
floating after admission refusal. Hover each exposed window in turn, move
to another app, then press Hypr+Shift+T. Check exact AX window identity and stable
z-order as well as the visible result; unit tests cannot establish macOS AX
behavior. Keep existing logs before restarting the app.

### Floaters, open menus and no-raise focus (issue #10)

The report: with tiled windows and a floater on the same workspace, a
Chrome bookmark-folder menu closed as soon as it opened, and some apps
(Zoom) flickered between focused and unfocused. A related problem with
focus-follows-mouse: moving off a floater onto the tile behind it lifted
the tile over the floater.

What the source showed:

- `raiseBehind` ran 50 ms after every app activation and at the end of every
  discovery pass. A click on a tile lifts it over the floater, so the next
  pass raised the floater and, 20 ms later, restored focus to the tile with
  `focusWithoutRaise`. That restore writes kAXMain, may call
  `activate()`, and posts key-window events, and its own comment said those
  events dismiss menus. Chrome's bookmark folders are not NSMenus
  (chromium maps a views `TYPE_MENU` widget to `kCGPopUpMenuWindowLevel`,
  101), so the HIToolbox menu-tracking guard never saw them.
- Hover hit-testing skipped every window whose layer is not 0. With a menu
  hanging over a floater, the pointer "hit" the floater and focus-follows-mouse
  focused it with a synthetic click.
- Nothing limited `raiseBehind`. An app that activates itself when raised,
  or a raise Tahoe ignores, could repeat raise and restore on every
  activation.
- `focusWithoutRaise` is not raise-free: kAXMain plus
  `NSRunningApplication.activate` bring the app's main and key windows
  forward, and the hover path adds a synthetic title-bar click.

What changed:

- `WindowStacking` reads the window list. An open popup is a window of the
  frontmost app at layer 101 or above (below the screen saver). Hover focus,
  `refocusUnderCursor`, `raiseBehind`, its restore, the focus invariant, the
  focus repair on a bare Hypr press, and the no-raise fallback all stand
  down while one is open. A popup-level window open longer than 30 s is
  treated as part of its app and stops counting. A raised window of the
  frontmost app under the pointer (a menu, a floating panel) is never
  hit-tested through. Other apps' high windows are still skipped, so a
  click-through overlay does not freeze focus.
- `raiseBehind` only raises a floater a tile actually overlaps, checks the
  stack 50 ms later, and restores focus only when the raise moved the front
  app away from the focused tile. `RaiseBehindThrottle` cools a
  floater/tile pair down after a raise that did not lift it (30 s), a raise
  within 1 s of our own restore (15 s, the loop), or 4 raises in 5 s (10 s).
- `TiledFocusRouter` handles hover, Hypr+Arrow, Hypr keydown, the focus
  invariant and the raise restore. Workspace switches, window moves and the
  scratchpad still use their own focus calls, which can lift a tile. When a
  floater
  covers the target tile it sends only `_SLPSSetFrontProcessWithOptions` and
  the key-window event records, as yabai does, plus yabai's lost/gained pair
  when focus moves inside the frontmost app. No kAXMain write, no
  `activate()`, no click. 80 ms later it checks whether the target app is
  frontmost and the target window is AX-focused. If not, it falls back to
  the usual path and logs it, unless a menu opened or the user switched to
  another app meanwhile. Hypr+Arrow warps the cursor to the part of the
  tile the floater leaves uncovered.

Log lines, all at notice level:

| Line | Category | Meaning |
|---|---|---|
| `ffm paused: popup wid=<id> pid=<pid> layer=<n> bounds=<rect>` | mouse | hover focus stopped for an open menu |
| `ffm resumed: popup <id> gone` | mouse | hover focus back |
| `ignoring popup <id> pid=<pid> layer=<n>: open 30s, treated as part of the app` | mouse | a menu-level window that never closes no longer counts for any guard |
| `refocus under cursor skipped: popup …` | mouse | post-click refocus held off |
| `raise behind deferred: popup wid=<id> pid=<pid> layer=<n>` | floating | raise held until the menu closes |
| `raise behind: wids=[…] under=[…] focus=<id> front=<pid>` | floating | floaters raised, and the tiles that covered them |
| `raise behind ineffective: wid=<id> still under <id> — cooldown 30s` | floating | the window server kept the tile on top |
| `raise behind kept focus: wid=<id> front=<pid>` | floating | no restore sent |
| `raise behind restore: wid=<id> (front moved <pid> → <pid>)` | floating | the raised app took focus; it went back |
| `raise behind cooldown: pair=<floater>/<tile> reason=loop\|burst for <n>s` | floating | loop or burst stopped |
| `no-raise focus: wid=<id> pid=<pid> reason=<why> floaters=[…] front=<pid> prevKey=<id>` | focus | a covered tile was focused without activate or click |
| `no-raise focus verify: wid=<id> … front=<pid> (want <pid>) key=<id> floatersAbove=[…] buried=[…] → landed\|missed` | focus | whether it worked |
| `no-raise focus fallback: wid=<id> path=activate\|activate+click` | focus | it did not; the usual path ran |
| `no-raise focus superseded: wid=<id>` | focus | a newer focus replaced a same-app hand-off |
| `no-raise focus verify: wid=<id> superseded` | focus | a newer focus came before the check |
| `no-raise focus fallback skipped: …` | focus | a menu opened, or the user switched apps, meanwhile |
| `focus invariant skipped: popup …` | focus | the invariant held off |
| `ensureFocus skipped: popup …` | focus | a bare Hypr press left the menu open |

One repro answers the Tahoe question. If `verify` says `landed` with the
floater in `floatersAbove` and an empty `buried`, the no-raise path works
there. If it says `missed` and a `fallback` line follows, Tahoe refused it
and hover onto a covered tile still lifts the tile, as before.

### Rejected drag feedback and source restoration

A September 14 capture exposed two drag regressions. At 21:47:17.362 CDT,
a rejected Terminal move restored its frames; the delayed cursor refocus
started at .371. With `showFocusBorder=false`, that ordinary focus refresh
called `hide()` and canceled the rejection panel after only a few frames.
Persistent border refreshes now defer to the bounded error feedback interval.
Explicit teardown (fullscreen, workspace changes, shutdown, or disabling
chrome) still cancels it. Natural completion resolves current focus afresh;
it does not replay a captured window or frame. Notice lines
`error feedback begin/end/cancel: wid=<id>` distinguish completion from
cancellation without recording titles.

The message now holds still for 1.15 seconds after the brief shake, one
second longer than before. The error panel does not supply focus identity
during that interval; keyboard actions follow the latest recorded focus.
Float-to-tile feedback distinguishes no fitting slot from an app returning
different geometry: the latter says it did not accept the tile size.

At 21:49:23.963, a cross-monitor Terminal drag was classified as a manual
resize because its released size differed from the captured size. There was
no target on the source monitor, but that did not prevent the resize from
changing the source tree ratios to 0.85 and 0.59. The accepted pass placed
Terminal `45845` in a 162-point-high band; the app read back 169 points.
A later rejected drag correctly restored that already-corrupted layout.
A resized no-target release whose frame center is outside the source usable
frame now restores the captured source frames without replacing its tree.
Ordinary on-source resize behavior remains available.

Trying to return Terminal beside Messages also exposed a mismatch between
ordinary tiling and drag insertion. Ordinary tiling had verified an adjusted
619-point Messages window beside a 437-point Terminal slot. Drag insertion
started with equal halves and rejected Messages at 528 points. Drag candidates
now adjust their private ratios for known minimum sizes before AX writes,
then pass through the existing readback and restoration checks. This does
not publish unverified frames or change admission recovery.

### Tab detach followed by a false restoration warning

A September 15, 2026 capture separates two Safari events. Window `64757`
was admitted with complete, stable readback at 18:58:11.138 CDT. It did not
produce the restoration failure. A later tab detach produced this sequence:

- 18:58:21.710 and .735: AX window-created notifications arrived during the drag.
- 18:58:22.240: drag `61918` ended degraded. Its release-time frame read failed;
  restoring the captured three-window layout failed on `51138` when the
  Enhanced UI read returned `-25204`. No restoration writes completed.
- 18:58:22.723: error feedback began for `61918`.
- 18:58:22.780: the deferred discovery poll ran.
- 18:58:22.852: discovery's ordinary admission transaction, generation `3457`,
  verified all four windows (`51138`, `61918`, `64724`, and newcomer `64765`)
  with complete, stable readback.
- 18:58:24.350: the error feedback ended, about 1.5 seconds after recovery.

This was successor-transaction recovery, not a logged admission retry. The
release path in `TiledDragTransaction.dropRelease` calls restoration when
its classification read fails. Failed restoration returns `.degraded`.
`WindowManager.completeTiledDrag` originally treated that local result as
final and immediately emitted the restoration warning. `PollingScheduler`
keeps discovery suppressed until drag completion, so the queued discovery
could only establish the successful full-operation outcome afterward.
The focus border's bounded error interval then preserved the stale warning.

Degraded drag feedback now waits for the existing post-drag discovery poll.
The poll passes its actual admission results to feedback reconciliation; only
a newer result for the same workspace and physical display can resolve it.
Cancellation requires accepted, complete membership, including newcomers a
failed successor admission stranded. A successful retile of only the old
incumbents cannot conceal floating fallback. The existing bounded admission
retry may finish the operation; unreadable or held recovery reports failure
without waiting indefinitely.

Failure diagnostics and cache invalidation remain immediate. A persistent
failure emits once. If a later transaction verifies the complete operation
while its warning is visible, cancellation uses that flash's render token.
It cannot hide a newer unrelated error. No app identity, title, or added
timing grace period participates in the decision.

Verification on the isolated branch based on `46c2496`:

- The exact release-read failure, restoration-write failure, and accepted
  four-window successor sequence fails on the unmodified baseline solely
  because the warning survives (`build/investigation/exact-baseline-red.log`).
- The fixed-screen regression passes for Safari and TextEdit newcomers.
  Focused feedback, drag, admission recovery, and border tests: 120 tests,
  zero failures (`build/sizing/isolated-tests/safari-feedback-final.log`).
- `scripts/test-isolated.sh --debug-variant`: 884 tests, 23 existing skips,
  zero failures (`build/investigation/verified-suite.log`).
- The dedicated Debug scheme builds unsigned for arm64 and x86_64
  (`build/investigation/verified-debug-build.log`).
- Independent source review and `git diff --check` pass. The tests exercise
  real sizing transactions plus feedback and border components; they do not
  replace live verification of the complete macOS notification path.

Live acceptance update, September 15, 2026: the signed universal Debug build
`f66ba8ac2692+972a10741228` replaced the canonical MacBook debug app at the
user's request. Its signature and installed checksum verified; startup logged
Accessibility trust and successful manager startup. HyprMac configuration
JSON hashes were unchanged, and the previous app was archived for rollback.
The user then confirmed that the fix works and authorized landing it on main.
This confirms the reported Safari symptom; the broader manual matrix for
another app and deliberately unrecovered failures was not separately run.

### "Why didn't a swap take effect?"

```
subsystem:com.zachgray.HyprMac (category:tiling || category:orchestration)
```

Both refusals log under `category: orchestration` at `.debug`, so the file
log is where you will find them. Watch for `swap overflows min-size
constraints (post-readback) — rejected swap` (the seeded min lied) or `swap
would violate min-size constraints — rejected swap` (rejected up front by
`canSwapWindows`).

Keyboard swaps revalidate refusals based on old observed or app-hint minima
through a bounded AX attempt. Seeded and structural constraints remain hard
preflight limits. Accepted readback can update the remembered minimum;
failed attempts restore the original tree and frames. Prepared swaps keep
this revalidation scope only through their matching final application.

### "Why is dimming wrong?"

```
subsystem:com.zachgray.HyprMac (category:dimming || category:focus || category:lifecycle)
```

The dim mask reacts to focus changes; mismatches usually trace back
to `WindowStateCache.tiledPositions` going stale between
poll/retile cycles. `WindowManager.currentTiledRects` re-reads live
AX before `refreshDimming` and `refreshBorderOcclusion` to avoid
the "half-dim" artifact — if you see stale-rect dimming, that read
path is the place to look first.

### "Why did discovery think this was a new window?"

```
subsystem:com.zachgray.HyprMac category:discovery
```

`window returned`, `new window`, `window hidden`, and `window
gone` log every transition. `WindowStateCache.knownWindowIDs`
tracks the "seen since launch" set; a window appearing as `new`
when the user un-hides it usually means it was forgotten too
aggressively (e.g. on app terminate before the visibility change
flowed through).

Two trace lines measure the gap between "the OS told us" and "we
looked", which only the file log keeps:

- `ax event: windowDestroyed pid=1304` — one per AX notification, kind
  and pid only.
- `poll: 14 windows, 213ms since last` — at the top of every
  `pollWindowChanges`, with the snapshot size and the elapsed wall
  clock since the previous poll.

## Retile churn / full-screen flicker

Symptom: two tiled windows, one keeps snapping full-screen and back
every ~1 s while the other stays put; dimming redraws with each snap.
Mechanism: an app whose main thread stalls fails its AX reads for a
poll cycle, all its windows drop from that `getAllWindows` snapshot,
discovery marks them gone→hidden, the sibling's node is promoted and
retiled to the full rect; the next healthy cycle returns them and
retiles back. Notice-tier evidence chain (all `category: discovery`):

- `AX window-list read FAILED for <bundle>` / `recovered after N
  failed cycle(s)` — the root cause, logged on outage edges only.
- `AX frame read FAILED for N window(s) of <bundle>` — per-window
  variant of the same failure.
- `window hidden: <id> (<bundle>)` / `window returned` — the
  discovery transitions.
- `FLAP: '<title>' returned <ms>ms after vanishing` — a return within
  5 s of vanishing, i.e. almost certainly not a real minimize.
- `discovery retile: gone=[...] returned=[...]` — one line per
  discovery-driven re-layout naming its cause.

Pull with:

```bash
/usr/bin/log show --predicate 'subsystem == "com.zachgray.HyprMac" AND category == "discovery"' --last 10m --info
```

## Where the logs come from

- `WindowManager` lifecycle — `category: lifecycle`.
- Action dispatch and routing — `category: orchestration`.
- Focus transitions — `category: focus`.
- Tile mutations and swap decisions — `category: tiling`.
- Workspace switches and moves — `category: workspace`.
- Discovery diff results — `category: discovery`.
- Drag classification — `category: drag`.
- Floating window operations — `category: floating`.
- Suppression registry decisions — `category: state`.
- Config load/save — `category: config`.

`grep -rn 'hyprLog(.notice\|hyprLog(.warning\|hyprLog(.error\|hyprLog(.fault' HyprMac/`
gives a complete index of diagnostic-tier sites.


## Stability audit log changes, September 13 evening

A preflight refusal logs `no fitting tile slot: wid=<id> ws<N> — staying
in place`. It routes the window nowhere. Its recovery turn checks ownership
and floats without running another sizing attempt. An
impossible adjusted layout logs `adjusted layout cannot resolve observed
constraints — restoring`; there is no adjusted write in that case.

An incompatible returning incumbent produces `noFittingSlot(id)` and keeps the
whole key unverified without writing. It is excluded from recovery fallback
IDs. See [the audit](stability-audit-2026-09-13.md) for the exact test evidence
and remaining manual gates. Earlier log examples describe their dated builds.

## Portrait startup admission recovery

A depth-two batch on a 1064×1874 usable portrait display previously chose a
two-column grid. Its half-width slots were 528 points, while four observed
window widths were 574, 528, 708, and 640. The same four windows fit at the
same depth when both child splits use the vertical axis.

The startup failure had two stages. The initial write failed before readback,
so it learned no constraints. The automatic retry built the same grid from
seeded minima, then learned the real widths. Ratio adjustment could not make
that topology fit, so recovery floated the batch.

Smart insertion now tries the alternate axis when the preferred aspect-ratio
split cannot satisfy both windows. If an automatic retry starts from an empty
live key and its first write learns constraints that ratio adjustment cannot
resolve, it gets one private topology rebuild using that evidence. The rebuilt
layout must pass normal verified readback before publication; otherwise the
existing rollback runs. Ordinary retiles, explicit insertion, drag, incumbent
trees, saved split directions, hidden windows, disabled windows, and scratchpad
layouts do not opt into this rebuild. A workspace overflow router was not
needed because the four-window batch fits the original workspace and depth.
