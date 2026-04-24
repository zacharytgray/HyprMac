# Investigation notes

## What's in this folder

`failed-fix-attempts.patch` — a full git diff captured just before rolling the
working tree back to commit `aade0c0`. It contains every change the agent made
during a ~12-hour session trying to fix three user-reported issues:

1. Keyboard focus didn't visually light up window chrome the way mouse-click did (neutral focus indicator style).
2. Dim overlay bled onto focused window when tiles overlapped.
3. Tiling allowed windows to physically overlap ("cram") when min-size constraints couldn't fit.

The session also surfaced secondary symptoms, several of which the patch
attempts to address:

- Tree-mangle bug: one window intermittently grows to ~75% width, siblings squish to <1/16. Persists across cycles once triggered.
- Over-rejection: can't move 2 windows onto the same monitor even when the resulting split would fit.
- Bounce-back: after a cram, clicking any window bounces the crammed window back to its source workspace.
- Swap can recreate overlap: after cram, swapping two tiled windows can produce overlap without triggering any revert.
- Startup / menu-bar retile allow cramming with no defense at all.
- Delay: revert-on-overflow path has ~300-600ms of main-thread blocking.
- System-wide sluggishness.

## Why it was rolled back

None of the fix attempts fully solved issue 3 (the cram problem) without
introducing worse regressions (auto-float cascades, visible flicker, perf
degradation, system-wide sluggishness). User directed "I can't ship this" and
asked for a rollback plus a detailed investigation plan.

## What was kept

- `HyprMac/Core/DimmingOverlay.swift` — the dim-inactive-windows overlay (solves issue 2 cleanly via rect subtraction with nonZero fill).
- The Settings UI toggle + intensity slider.
- UserConfig `dimInactiveWindows` + `dimIntensity` properties.
- WindowManager integration (`dimmingOverlay` property, config sinks, hide-on-border-hide, refreshDimming in updatePositionCache + updateFocusBorder).

Everything else was reset to commit `aade0c0`. The patch file contains the
rolled-back-from state of each tracked file under `HyprMac/` and
`HyprMac.xcodeproj/`.

## Why the cram issue is a shipping blocker

The dim overlay reveals a macOS-native behavior that can't be suppressed from
our process: when tiled windows physically overlap, the underlying window's
drop shadow renders across the foreground window in the overlap region. That
shadow is drawn by the window server — it's not part of our overlay. Any
residual overlap, even a few pixels, reads as visibly broken tiling. The user
therefore cannot accept ANY overlap, not a cosmetic improvement to hide it.
Rejection (flashError + no move) is the only acceptable UX. Auto-float was
explicitly rejected.

## How to use the patch

To see what approaches the previous agent tried for a given issue:

```bash
# view the full diff
less docs/investigation/failed-fix-attempts.patch

# show only the hunks for one file
git apply --check docs/investigation/failed-fix-attempts.patch       # sanity
filterdiff -i 'HyprMac/Tiling/TilingEngine.swift' docs/investigation/failed-fix-attempts.patch

# try applying subsets to a branch
git checkout -b investigate-cram
git apply docs/investigation/failed-fix-attempts.patch
# then experiment on top
```

Specific things in the patch to look at for each issue:

- **Per-axis stale detection** in TilingEngine.applyLayout (line ~73 of the diffed file): split the "both dims match prev" AND-gate into independent `wStale` / `hStale` flags. Helps but didn't fully solve the stale-readback inflation.
- **Walk-up adjustForMinSizes** in BSPTree: the pre-session version only adjusted the immediate parent. The attempted fix walks up to the first matching-axis ancestor. Makes a real difference for width conflicts under vertical splits.
- **HyprWindow.observedMinSize**: new property, set only when applyLayout witnesses a refusal to shrink. Attempt to distinguish "known min" from "last frame". Still empirical — first-attempt moves have no data to reject on.
- **canFitWindow with pairFits**: pre-move leaf-search using observedMinSize. Rejects if no slot fits both existing occupant + incoming. Correct structure, but relies on observedMinSize being populated.
- **treeHasOverflow + revertMoveToWorkspace / revertSwapIfOverflow**: post-op check that reverts the move if the tree ended up overlapping. Works but is slow and visible.
- **DragManager resize skip**: prevents the click-after-cram from classifying overflow as a manual resize and locking userSetRatio.
- **majorityOverlapScreen in reconcileWindowScreens**: replaces center-point detection so an overflowed window doesn't get reassigned to the neighbor workspace just because its center shifted.

## Investigation prompts

See the chat transcript for the full set. Summary index:

1. Keyboard-vs-mouse focus chrome activation
2. Tree-mangle bug (largest window grows to 3/2)
3. Over-rejection on basic moves
4. System-wide sluggishness
5. Initial tile doesn't enforce no-cram
6. Bounce-back on click after cram
7. Dim overlay reveals shadow artifact (research whether shadows can be suppressed)

The dim-overlay shadow context (issue 7 rationale) should inform prompts 2, 3,
5 — the visual cost of any residual overlap is what makes the cram problem
ship-blocking.
