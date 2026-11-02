# Architecture assessment and refactor path

Assessed at `670626a` (v0.20.1). Line numbers refer to that commit. Comment
fixes on this branch move some lines slightly, so search by symbol if a line
looks off. Baseline at that commit: 1716 tests, 28 skipped, 0 failures.

Tests do not prove window behavior. Nothing in this file was checked live.
"Read" means the code was read at the cited line. "Inferred" means the reasoning
follows from the code, but nobody has seen it happen.

## Verdict

HyprMac does not need a rewrite. Its large files are not its main problem.

`TilingEngine.swift` (3778 lines) is big mostly because macOS window behavior is
hard. Its rules hold: nothing outside `Tiling/` mutates a tree. Its tests use
behavior-level fakes, so its private parts can be rearranged safely. It stays
large after any safe refactor, and that is fine.

`WindowManager.swift` (4196 lines) is the real structural problem. Its header
said it holds no policy. In fact 13% of it is wiring, and 81% is logic or
presentation. No test can construct it, because its `init` starts a real event
tap. So its most-changed logic is its least-tested logic. Three test files copy
its logic by hand instead.

What actually costs time:

1. **Steps every caller must remember.** Fixes keep arriving one path at a time.
2. **Hidden state machines in `WindowManager`,** especially the display settle.
3. **Silent failure in config persistence.** This is the only area with real
   risk of losing user data.
4. **Two parallel sizing flows that have drifted** (tile pass and tiled drag).
5. **About 800 lines of dead or test-only code,** which readers cannot tell from
   live code.
6. **Stale docs and comments.** Fixed on this branch.

## What is wrong, ranked

### 1. Steps every caller must remember

Each of these has git history showing a real bug from a caller that missed a
step.

| Rule callers must follow | Where it is copied | Evidence it costs |
|---|---|---|
| Before a pass: walk, prime minima, stamp `isFloating` | `WindowManager.swift:3085-3091`, `:4084-4090`, `:4131-4137`, part at `:2100-2107`; `WorkspaceOrchestrator.swift:665,914` | `92ce417`, `fde1b86`: passes "ran bare" and dropped tiles |
| Hold unreadable windows out of a pass | Now in the engine, except the tiled drag | `80779fe`, `92ce417`, `fde1b86`, `dcba3bc`, `c48a255` |
| Don't switch workspaces mid display transition | `handleAction`, pin follow, URL focus. Missing at the overview pick, dock affordance, menu Retile All | `f96fbc8` fixed the same class |
| A key's side tables die with its tree | Six functions, each clearing a different subset (`TilingEngine.swift:636,1111,1220,2364,2632,3634`) | Maintenance trap today |
| Ghost windows don't count as occupancy | Menu bar and Hypr+F destination follow it. Hypr+Tab and Hypr+F source do not | `a7cbace` |
| `recordFocus` before `tiledFocusRouter.focus` | `WindowManager.swift:1641,1675,1699`. A swap makes the router report "superseded" | The old comment said the opposite. Fixed on this branch |

The repair is small helpers and shared types, not a redesign.

### 2. `WindowManager` holds untested state machines

The file has 15 responsibilities. Five carry real logic and churn:

| Responsibility | Lines | Commits since August | Tests |
|---|---:|---:|---|
| Tiled drag host | 522 | 14 | Mapping around the reconciler: none |
| Tile passes and placement | 463 | 16 | None for classify and distribute |
| Mouse gesture | 406 | 15 | Partial, through `MouseDragLifecycleState` |
| Display transition | 217 | 14 | **None**, patched in `7ab1b0c`, `8ed9969`, `b25afea`, `70b103f` |
| Poll and drift | 159 | 15 | Hand-copied in tests |

Wiring has the most commits (46), but that is safe churn: most features add a
closure there.

The display settle is a state machine spread over five variables, an expiring
suppression key and a self-rescheduling closure. It has traps a mechanical move
would break:

- `displayFingerprint()` looks like a getter, but it refreshes `DisplayManager`.
  `:3352` short-circuits it, so hoisting it into a `let` changes when screens
  refresh.
- `displayTransitionPending = false` must come before the tile, or the tile
  defers itself and never runs.

### 3. Config persistence fails silently

`LayoutSnapshotStore` does this right: atomic write, throw and roll back, move a
bad file aside. `ConfigStore` does none of it.

| Situation | What happens | Evidence |
|---|---|---|
| `config.json` corrupt or truncated | `try?` gives nil, app takes defaults with no log and no backup, the next settings change overwrites the file. **All keybinds and settings gone** | `ConfigStore.swift:72-76`, `UserConfig.swift:215` |
| Crash or full disk during save | Not atomic, error dropped, so a truncated file leads to the row above | `ConfigStore.swift:87-91` |
| One core field has a wrong type after a hand edit | Whole decode throws, same result on next launch | `ConfigStore.swift:342-347` |
| Bad hand edit while running | Reload returns with no log, and the next change overwrites the edit | `UserConfig.swift:494` |
| iCloud repair at launch | Loads config, then replaces the local file with the iCloud link, and never reloads. The next change writes old values over iCloud. Inferred | `UserConfig.swift:207,284-293` |
| `resetToDefaults()` | 34 saves and 28 runtime signals with half-reset state. End state is right. `resetAppearanceToDefaults` next to it does it correctly | `UserConfig.swift:393-428` |

A plain `.atomic` is not a one-line fix. It can replace the iCloud symlink with a
regular file, and it swaps the inode the watcher follows.

### 4. The tile pass and the tiled drag have drifted

They are two rollback orchestrators, and they should stay two: the differences
in retry order, in-place shortcut and rollback filter are real. But some gaps
look accidental:

| Gap | Evidence |
|---|---|
| Drag has no per-target deadline growth, so a large workspace can run out of time | `scaled` only called at `FrameReadbackPoller.swift:180` |
| Drag rollback has no 0.75 s floor | `FrameReadbackPoller.swift:128-136` vs `FrameSizingTransaction.swift:1177-1184` |
| Cross-monitor drop has no staging origins (issue #43's fix did not reach it) | `TiledDragTransaction.swift:616-618` |
| Drag ignores the hold, so a drop can write frames to a held window | No hold code in `TiledDragTransaction.swift` |
| `retryAdmission` sorts its first judged list, not its second | `TilingEngine.swift:2482-2483` vs `:2503-2505` |

No repro exists for any of them. Log first, and keep them out of refactor PRs.

### 5. Dead and test-only code

**Dead everywhere (no production caller):** `DragManager` (155 lines, only
constructed), `forgetWindow`, `findWindow`, `hasVisibleFloatingWindows`, `restart`,
the write-only `retileSkippedDuringTransition`, the second `hotkeyManager.start()`,
`onHideFocusBorder`, `autoFloatOverflow`, `capturedWindowIDs`, `pendingKey`, five
`TilingConfig.readback*` constants, `ScratchpadController.adopt`, three
`FocusBorder.Tuning` values, `MenuBarRow.shortcut` with the `Font.hyprMono` it alone
uses, `HyprMotion.physical`, `HyprSpacing.xxl`.

**Empty stubs with live calls:** `WindowCornerRadius.prime/forget`. Delete the calls
too.

**Effectively dead:** `SpaceManager` (207 lines). Only `setup()` runs, and nothing
reads the result. `pendingInsertedWindowIDs` is written only from test-only code,
and every read is discarded.

**Test-only in production code:** `prepareSwapLayout`, `prepareToggleSplitLayout`,
`applyComputedLayout`, `pendingSwapRevert`, `addWindow`, `applyResize` (172 engine
lines). Also `BSPTree.compact`, `BSPTree.smartInsert` and `RetileAllPlanner.pack`,
whose `testVisibleWorkspaceAndFocusDoNotChangePlan` pins a rule production does not
follow. They are left from the animated path `76e2817` removed in May. They still
draw maintenance: `701c551` extended `pendingSwapRevert` in September. Their tests
pin behavior production lacks: the prepared swap resets ratios (`:2990`), the real
one does not (`:2909`). `prepareTileLayout` is the tests' standard fixture (about
75 hits), so rename it rather than delete it.

**Scripts:** `scripts/build-release.sh` swallows signing errors and
`scripts/run-debug.sh` can launch a stale app. Nothing references either.
`.swiftlint.yml` is unenforced and cites a missing plan.

### 6. `HyprWindow` is a live handle that looks like a model

It is a reference type around an `AXUIElement`. `frame`, `size`, `position` and
`title` are blocking AX calls. `isFloating` and `cachedFrame` are per-instance
copies, and every walk builds new instances, so a window usually has several.
Fresh objects say `isFloating == false` until stamped.

Do not convert it to a struct. Centralize the flag writes (step 3.3) and keep the
doc comment honest (done on this branch).

### 7. Time is coordinated by convention

About 30 bare delays, no central record. Three pairs are load-bearing:

- A 1.5 s `workspace-transition` hold appears at six sites as a literal.
- After a click, the raise sets `mouse-focus` until +0.19 s and the refocus checks
  it at +0.20 s. A main-thread stall can swap them. Inferred.
- The settle beat and its poll hold (2 s and 3 s, 5 s and 6 s) keep their margin
  by hand.

Name them and record them. Do not build a timer service.

## Not problems: leave alone

- **`TilingEngine.swift`'s size,** and `updateTreeMembership`, `handleDisplayChange`,
  `perform`. Their complexity is the job.
- **Closure counts as such.** `WindowManager` assigns 141. Most are the test seams
  `AdmissionRecovery`, `MouseTrackingManager`, `TiledFocusRouter` and
  `FloatingWindowController` rely on. Only the 8 scratchpad forwards on
  `ActionDispatcher` and the 9 on `ScratchpadController` are plain indirection.
- **Long incident comments** in `WindowManager` and `TilingEngine`. They record why
  an order matters. Only false ones were changed.
- **Different frame preference orders** (`frame ?? cachedFrame` vs
  `cachedFrame ?? frame`). They set AX cost and staleness.
- **`Action`'s hand-written Codable,** `SavedConfig`'s tolerant decoder, and
  `ConfigMigration`'s unused version hook. They freeze the wire format.
- **`TourView` (846) and `KeybindOverlayController` (843).** Static views and pure
  tested enums. Only the tour's instruction strings are worth moving.
- **Test file size.** Fakes at the behavior level are why refactors are cheap.
- **`LayoutSnapshotStore`.** The best code in its area. Copy it.

## Likely bugs found

These are not refactors. Fix each alone, with its own check. Per the repo's rule,
intermittent ones get a `.notice` log first, then a fix once the cause is seen.

| # | Bug | Evidence | Status | First step |
|---|---|---|---|---|
| B1 | Corrupt `config.json` loses every setting | Section 3 | Read | Step 4.2 |
| B2 | Deleting a default keybind does not stick: `mergeNewDefaults` re-adds it on reload and at launch | `UserConfig.swift:301-316,215,497`; test pins the mechanism at `ConfigUpdateCoordinatorTests.swift:657` | Read, not run live | Decision D5 |
| B3 | Layout save loses `unplaced` windows, those on a hidden workspace not yet in a tree: `capture` reads `cachedWindows`, which holds visible windows only. The test rig fills the cache by hand | `LayoutRestorer.swift:157`, `WindowManager.swift:2640-2644`, `LayoutRestorerTests.swift:119` | Inferred | Hypr+Shift+N to a hidden workspace, Hypr+Ctrl+S, read `unplaced` in `layout-snapshots.json` |
| B4 | Pausing during a display settle can re-park and retile while paused: `stop()` leaves the settle armed, and its closure has no `isRunning` check | `WindowManager.swift:924-956,3392` | Inferred | `.notice` in the closure when not running |
| B5 | Menu Retile All, the overview pick and the dock affordance skip the display-transition guard. Retile All rewrites assignments mid-transition | `WindowManager.swift:3470,326,3201`; guard at `:1726` | Inferred | `.notice` when each fires while pending |
| B6 | AX walk's position fallback can bind one window's element to another's id. It also fires when the SPI succeeded but the id is off screen, with no distance limit and no log | `AccessibilityManager.swift:471-507` | Inferred | `.notice` when the fallback fires, separating SPI nil from off-screen id |
| B7 | `AXNotificationService` dedupes by window id and never prunes. A reused id on a new element gets no destroy subscription, and closed windows' elements stay retained until the app quits | `AXNotificationService.swift:146-156` | Read | `CFEqual` check on the stored element; close and reopen Mail or Teams, then close again |
| B8 | A floater reveal deletes the saved frame even when the AX write failed, leaving it parked until Retile All, or Hypr+Shift+T recentres it | `WorkspaceManager.swift:417-425`, `HyprWindow.swift:259-266` | Inferred | `setFrame` returns its worst error and `placeFloating` logs it |
| B9 | A stuck `mouseButtonDown` stops all discovery. There is no watchdog, unlike `menuTracking` and `dockIsActive` | `PollingScheduler.swift:63,124` | Inferred | `.notice` when deferrals repeat |
| B10 | `NSScreen.main!` is reachable with no screens: from a poll through `ensureFocusInvariant` (`WindowManager.swift:1787`), and from `cycleFocus` on a hotkey (`FloatingWindowController.swift:535`) | Same | Inferred, no crash logs checked | Guard; check by disconnecting all displays |
| B11 | The tour's menu bar legend shows `● ○`; the menu bar draws `■ □` | `TourView.swift:578-586`, `MenuBarView.swift:286-289` | Read | Decision D7 |
| B12 | Settings footer and overlay hard-code Hypr+Ctrl+S/R and their own chord, which is wrong after a rebind | `GeneralSettingsView.swift:323`, `KeybindOverlayController.swift:553-554` | Read | Use the live chord, as the tour does |
| B13 | A degraded restoration after a refused move leaves the window on the destination. The next poll reads drift and completes the move the user saw refused. No recovery owns it | `WorkspaceOrchestrator.swift:674-681`, `ActionDispatcher.swift:232-233` | Inferred | `.notice` when drift follows a degraded restoration |

## Decisions

Decided on 2026-11-02: D1, D3, D4 (resume only), D5. The rest are still open.

| # | Question | Why it matters | Recommendation or decision |
|---|---|---|---|
| D1 | Is the animated layout path ever coming back? | It decides whether step 1.3 runs | **Decided: no.** Delete it, and port tests that exercise shared code to `swapWindows` and `toggleSplit` |
| D2 | Delete `SpaceManager`? | One CGS read at startup, no reader | Yes |
| D3 | Should Hypr+Tab and Hypr+F's source check ignore ghosts? | They count ghosts today, against the stated rule | **Decided: yes, for both.** It changes behavior, so it ships as its own fix |
| D4 | Should resuming from pause redistribute every window and un-float manual floaters? Should a Max Splits change? | `start()` always runs `snapshotAndTile`, then `distributeWindowsAcrossWorkspaces`. Documented on this branch as it stands | **Decided: resume keeps assignments and floaters.** Max Splits is still open; the recommendation is to leave it |
| D5 | Should a deleted default keybind stay deleted? | The fix needs a "removed defaults" list, which is a schema change with a `ConfigMigration` step | **Decided: yes.** See the notes below |
| D6 | Enabling iCloud sync overwrites the iCloud copy with no prompt. Keep? | Last Mac to enable wins | Add a prompt when an iCloud copy exists |
| D7 | Fix the tour's legend to `■ □`, and keep its tints? | The real label is plain text | Fix glyphs, drop tints |
| D8 | Window titles appear in `.notice` logs with `.public` privacy | Now documented. Is it what you want shipped? | Keep ids and bundle ids at `.notice`, move titles to `.debug` |
| D9 | Add minimal CI? Delete `.swiftlint.yml`? | No CI exists, and lint is unenforced | Delete lint config. CI is optional: `xcodegen` diff and `test-release-pipeline.sh` need no secrets |

Notes on D5:

- Record a removal only when the user deletes a bind (`KeybindsSettingsView.swift:114`). Check
  whether editing a bind can change its action (`KeybindsSettingsView.swift:98`); if so, treat
  that as a removal of the old action too.
- Don't use a "defaults already seen" list. Decoder tolerance depends on `mergeNewDefaults`
  restoring a bind it dropped (`ConfigStore.swift:320-321`), and a seen list would lose it.
- New defaults in later versions must still arrive. `testDiskReloadInjectsMissingPauseBinding`
  must keep passing.
- Both resets clear the list (`KeybindsSettingsView.swift:77`, `UserConfig.swift:393`). Adding a
  bind for a removed action takes it off the list.
- Binds deleted before this fix have already come back. Users delete them once more.

## Safe path

Each step is one PR with no behavior change unless marked **Fix**. Move code
verbatim first, with no cleanup in the same commit. Keep each delay and statement
order exact.

Common checks for every step:

```bash
git diff --check
plutil -lint HyprMac.xcodeproj/project.pbxproj
for s in scripts/*.sh; do bash -n "$s"; done
bash scripts/test-release-pipeline.sh
./scripts/test-isolated.sh --debug-variant    # nonzero Executed N, 0 failures
```

Run `xcodegen generate` after adding or removing files. **Live** means the Debug
app on the MacBook, using the checklist below.

### Phase 0: docs and comments (this branch)

Done. Comment-only in Swift. See "Documentation changes" below.

### Phase 1: remove what nothing uses

Risk is very low, since the compiler catches misses.

Status on 2026-11-02: done, except `.swiftlint.yml`, which waits on D9. `BSPTree.compact`,
`BSPTree.smartInsert` and `RetileAllPlanner.pack` remain as well: tests call them, and no step
here removes them. `prepareTileLayout` is now `seedTree`.

The suite went from 1716 tests to 1712. Removed on purpose:

- `testPrepareSwapLayoutResetsNonUserSetRatios`: pinned behavior production never had.
- `testPreparedToggleFailureRestoresPreAnimationFramesAndTree`: `testFailedDirectMutationsRestoreTreeStateAndFrames`
  covers `toggleSplit`.
- `testMembershipChangeInvalidatesPreparedSwapWithoutRestoringOldState`: prepared state no longer exists.
- `testPreparedSwapCarriesItsScopedRevalidationIntoFinalApply`: same path and assertion as
  `testSwapProbesPastAStaleObservedMinimumAndLowersItOnAcceptance`.

`applyResize` left `testFailedDirectMutationsRestoreTreeStateAndFrames` with the method. The
other prepared tests now run through `swapWindows`, `toggleSplit` and `tileWindows`.

| Step | Change | Extra check |
|---|---|---|
| 1.1 | Delete the "dead everywhere" list in section 5. Make `mouseButtonDown` setters getters | Full suite |
| 1.2 | Delete `pendingInsertedWindowIDs`, `retile(inserted:)`, the `success:` param of `commitForceInsert`, and `flashError(window:)`'s unused param (14 call sites, signature only; the shake stays) | `FocusStateControllerTests` |
| 1.3 | After D1: delete the prepare family, rename `prepareTileLayout` to a test-seed name | Compare test counts. Port tests covering timeout recovery and bypass, don't drop them |
| 1.4 | After D2: delete `SpaceManager` | Full suite |
| 1.5 | Delete `build-release.sh`, `run-debug.sh`, and `.swiftlint.yml` if D9 agrees | `test-release-pipeline.sh` |

### Phase 2: guard tests before touching anything

Status on 2026-11-02: done. The suite is at 1751 tests. New pure types: `ActionPolicy`,
`ScratchpadActionRoute`, `DisplaySettle`, `FocusResolution`, `DockAffordance`. So steps 5.1 and
5.3 are mostly done: what is left is moving their effects, not their decisions. None of the
wiring in `WindowManager` has a test or a live check yet.

Things this phase found:

- `discovery.isSessionInterrupted` has a side effect: past its cap it ends the interruption.
  `DisplaySettle` takes it as an autoclosure so it is read only when the old code read it. Treat
  it like `displayFingerprint()`.
- The harness flag must be `'<false/>'`. A bare `NO` reaches `UserDefaults` as a string, which
  `RuntimeVariant` ignores.
- `FocusBorder.subtract` and `WindowStacking.subtract` differ on an empty hole. Both cover the
  whole rect, but `FocusBorder` returns four strips. `RectSubtractionTests` pins this for step 3.5.
- `testWhatsNewDescribesOnlyThe<version>Changes` is now checked before the release script bumps
  anything.

| Step | Change | Why |
|---|---|---|
| 2.1 | Table test of all 24 `Action` wire keys, encode and decode | `toggleScratchpad`, `moveToScratchpad`, `resizeDirection`, `toggleTiling`, `showWorkspaceOverview` have no literal assertion. A rename would still round-trip, against a hard rule |
| 2.2 | Fix the harness trap: delete `home/Library/Application Support/HyprMac` and `home/Library/Mobile Documents` before xctest, and set the iCloud flag false for the whole xctest process. `UserConfig.shared` and other suites also inherit it | "Isolated" tests read the hub's real prefs and inherit `iCloudSyncEnabled = 1`. So the isolated `config.json` is a symlink, and `restore` deletes only the link. Confirmed on this worktree after a full run |
| 2.3 | `release.sh` fails on `Executed 0 tests`, and checks that the What's New test name matches the new version | Today it passes on zero tests, and bumping a version with old notes passes the gate |
| 2.4 | Pin `resetToDefaults` end state and direct `subtract` tests | Cover steps 3.5 and 4.4 |
| 2.5 | Characterization tests, each with a pure extraction in the same commit, following the existing static pattern: settle decisions, action gates and scratchpad table, `currentFocusedWindow` order, `isSelectableInCurrentContext`, dock affordance | The next phases depend on them |

### Phase 3: one helper per copied rule

Low risk. These target the repeated bug class.

| Step | Change | Traps | Tests |
|---|---|---|---|
| 3.1 | `freshWalk` helper: walk, prime, stamp | Keep prime before the pass and the stamp before `:4143`'s read. Keep the walk count (`c179b0a` cut walks on purpose) | `TilingEngineVerifiedLayoutTests`, `AdmissionRecoveryTests`, `TiledDriftMonitorTests`, `WorkspaceBatchMoveTests`. **Live**: open, close, float, tile |
| 3.2 | In the engine: `dropKey`, `withPassHold`, `publish` for `adopt` sites | Keep each site's exact clears. `adopt` and replace stay separate: `===` reads identity | `TilingEngineMembershipTransactionTests`, `LayoutTreeRebuildTests`, `HandleDisplayChangeTests` |
| 3.3 | `stateCache.setFloating(_:window:)` at paired sites | Leave Hypr+F's temporary flips, which roll back on purpose. Medium risk from site count | `WindowStateCacheTests`, `ForceInsertWindowFallbackTests`, `TileScratchpadTests`, `QuickLookPanelTests`. **Live**: Hypr+T both ways, scratchpad, Retile All |
| 3.4 | `enum SuppressionKey`, named delays, a timing table in `docs/architecture.md` | Same values, literal for literal | `SuppressionRegistryTests`, `PollingSchedulerTests`, `WorkspaceFollowTests` |
| 3.5 | Pure helpers: `Verdict.failure` (7+ copies), `restorationStrict`, shared rect strip, CG to NS rect, `badgeLabels(hyprLabel:)`, `screenUnderCursor` on `DisplayManager` | Keep `WindowStacking`'s strip order: `exposedPoint` breaks ties on it. Compare rect split output before deleting copies | `FloatingFocusStackingTests`, `DwindleLayoutTests`, `DimmingOverlayTests`, `InterfaceSnapshotTests`. **Live**: border and dim with a screen left of primary |
| 3.6 | Move already-internal types out: `FrameSizingFailure`, `FrameSizingIO`, `FrameSizingConfiguration`, `TiledDragSnapshot`, `TiledDragFeedbackReconciler`. Rename `DragSwapHandler.swift` to `TiledDragHandler.swift` | None. No access level changes | Full suite |

### Phase 4: make config safe (**Fix**)

Do this before larger moves, since it is the only area that can lose user data.
Back up `~/Library/Application Support/HyprMac/` before each live test.

| Step | Change | Check |
|---|---|---|
| 4.1 | `UserConfig.init(store:)`, inject paths into `ConfigStore`. No behavior change | `ConfigStoreWatcherTests`, `ConfigMigrationTests` |
| 4.2 | Tell missing from unreadable. Log at `.warning`. Save `config.json.unreadable` before the first overwrite, as `LayoutSnapshotStore.moveAside` does. Act at launch only, since a mid-sync read can look unreadable. Keybind tolerance, `Action` and the schema do not change, so no migration step | New tests for truncated, garbage, wrong-typed core field, missing file. **Live** with a backup |
| 4.3 | Log write failures, by error code. Then atomic writes: resolve the symlink first and suppress the self-triggered rearm | `ConfigStoreWatcherTests`, new symlink tests. **Live** with iCloud on, editing from a second machine |
| 4.4 | Make `resetToDefaults` one update, as `resetAppearanceToDefaults` is | New atomic test, `ConfigUpdateCoordinatorTests`. **Live**: press Reset |
| 4.5 | Reload after iCloud repair, before the watcher starts. Retry the watcher when `open` fails. Do not push defaults through a dangling link | New tests through 4.1. **Live** with a backup |

### Phase 5: shrink `WindowManager`

Pull out leaves first. Each step needs the phase 2 tests for its region.

| Step | New type | Lines | Traps |
|---|---|---:|---|
| 5.1 | `ActionPolicy`, `ScratchpadActionRoute` (pure) | 1737-1771, 2515-2554 | Gate order: overview, cancel recovery, transition drop, scratchpad. A dropped press still cancels a recovery. `.launchApp` falls through |
| 5.2 | `FloatingDimDragTracker` | 172-189, 2398-2480 | Arm after `handleMouseDown`. `updateDimDrag` stays above the guard at 1135, or it stops after one event |
| 5.3 | `DisplaySettle` pure decisions, effects stay in place. **Live**: plug, unplug, lock, sleep | 3344-3449 | See section 2. Generation supersede must survive a re-arm. `settledDisplayKey` is updated before `restoresAfterSettle` reads its saved old value |
| 5.4 | `TiledDragFeedbackCoordinator` | 88-91, 504-513, 3752-3784, 3904-3986 | Apply uses the old pending completion, then the new one overwrites it (3872-3876). Poll calls it after `repairParkedWindows` |
| 5.5 | `TiledDragController`, after 5.4. **Live**: drags on one monitor and across | 3478-3903 | The membership move at 3514-3519 stays inside the `drop` closure. `mouseDownPointCG` is written before `handleMouseDown` |
| 5.6 | `WorkspaceStatusPresenter` (read-only) | 958-998, 1800-1821, 2755-2789, 2793-2889, 2940-2949 | Keep the snapshot lazy so a closed overview pays no AX walk. Keep `main.async` at 2781 |
| 5.7 | `WindowPlacement` | 1833-1871, 1908-1946, 2162-2260, 3990-4035 | Order is classify, distribute, tile. Pass the same array, don't re-walk: `isFloating` is set on objects a later pass reads |
| 5.8 | `FocusResolver`, queries first | 2292-2346, then 1597-1703 | **`recordFocus` stays before `tiledFocusRouter.focus`.** Precomputing frames changes AX read counts |

Skip unless pain remains: moving the display settle's state, and a `ChromePresenter`
(low churn).

### Phase 6: real types in `TilingEngine`

Pure types with direct tests, one per PR. All tree mutators stay in
`TilingEngine.swift`.

| Step | New type | Lines | Notes |
|---|---|---:|---|
| 6.1 | `LayoutTreeCodec` | 489-504, 646-703 | Builds fresh nodes only |
| 6.2 | `PassBudget` | 1306-1331, 1619-1636 | `eca498b` was a clock bug here. Rollbacks stay outside it (`1eda0df`) |
| 6.3 | `RollbackPlan` | 1762-1796 | `70aa9fe`, `2ece30d` both fixed this. **Live**: one cross-monitor refusal |
| 6.4 | `CrossScreenWriteOrder` decision, `newcomersToRefuse` with closures | 1955-2042, 2518-2538 | Keep the "write order:" notice in the engine |
| 6.5 | `GeometryLedger` for `unverified` and `vacatedKeys` | About 25 sites | Medium risk. Also strengthens the ownership guard |
| 6.6 | Split `applyVerifiedLayoutAttempt` into private steps, after 6.2 and 6.3 | 1569-1868 | Medium risk, touched by 27 commits since August. **Live**: a real refusal and a real timeout |
| 6.7 | `ParkAttempt` over `FrameSizingIO` | 3497-3598 | Must not add per-window messaging timeouts. Keep the 1 pt stable check. **Live**: Hypr+F with a tall window |

Afterward: an explicit `keptUnverified` signal, replacing the shape decode at
`:2382-2386`.

### Phase 7: move folders last

`git mv` plus `xcodegen generate`, no code changes. Group `Core/` by domain:
`Core/Chrome/`, `Core/Focus/`, more of `Core/Input/`, `Core/Discovery/`,
`Core/Workspace/`. Notification names go to `Shared/`, and `@_silgen_name`
declarations to `PrivateAPI/`. Add the Release universal build from
`docs/testing.md`.

This has no runtime risk, but it conflicts with every open branch, so it goes when
the queue is empty.

## Do not do these

| Idea | Why not |
|---|---|
| `extension TilingEngine` file splits for mutating code | Cross-file extensions need `internal`, so `engine.trees[key] = …` compiles anywhere. The hard rule then stands on review alone. If files must shrink, move read-only and pure groups only |
| `WindowManager+X.swift` extensions | Same widening, and the design does not change |
| One transaction for tile and drag | Retry order, in-place shortcut, rollback filter, learning and budgets differ on purpose. `d161a2f` shows wiring across them already caused a bug |
| One outcome enum | Payloads differ. It would force optionals everywhere |
| `PassContext` replacing scoped engine flags | `minimumSize(for:)` is captured as a closure, and flags nest. A missed thread silently changes which minima count |
| `MouseGestureController` wholesale | Mouse-up runs a timeline at 0.04, 0.06, 0.1, 0.12, 0.18, 0.2 s with different guards |
| Rewriting the poll as a pipeline | Each line's position has a bug behind it |
| Merging the removal trio | Admission identity, slot memory, generation bump and retile all differ on purpose |
| Re-keying `TilingKey` by display id | Behavior change. Display ids also change across wakes |
| Converting `HyprWindow` to a struct | A rewrite |
| A protocol or context object replacing closures | It trades explicit seams for one large interface and breaks 11 test files |
| A central timer service | Delays belong to their owners. Name and record them instead |

## Open PRs

#58, #62, #63, #64, #65 and #66 are open. `perf/reveal-relayout` and
`perf/fixed-size-window` touch `Tiling/`, `fix/same-app-window-retile` also does.
Phases 1 to 4 are small enough to merge around them. Decide those PRs before
phases 5 to 7. Docs deleted on this branch may also conflict with those branches,
trivially.

## Live checklist

Run on the MacBook Debug build for any step marked **Live**. It extends
`docs/testing.md`:

- Click a tile under a floater. Drag a floater with dim on.
- Tile drag on one monitor and across. Hypr+drag and Option+drag swap. Press Hypr
  during a drag.
- Menu open plus Hypr key.
- Monitor unplug and replug. Lock and unlock. Sleep and wake. Pause inside a settle.
- Scratchpad up during each of the above.

## Documentation changes on this branch

- Corrected wrong claims in the README, `docs/architecture.md`,
  `docs/tiling-algorithm.md`, `docs/coordinate-systems.md`, `docs/debugging.md`,
  `docs/testing.md`, `docs/release.md`, `docs/keybinds-and-actions.md`,
  `docs/laptop-debug-deployment.md`, `docs/external-control.md`.
- Added a verified component map to `docs/architecture.md`.
- Deleted dated audits and shipped plans whose facts had gone stale. Durable facts
  moved to current docs, and git history keeps the rest.
- Fixed stale code comments in 161 places. Swift diffs are comment-only.

Facts these docs state as true but only macOS can confirm were left alone. They
need a live check, not a code read.
