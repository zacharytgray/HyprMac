# Retile All workspace audit

## Result

`Retile All` now enumerates eligible windows from all nine tracked workspaces,
sorts their union with newly discovered windows by window ID, and packs them
into workspace 1, then 2, through 9. Each workspace keeps its static monitor
home and uses that monitor's configured dwindle capacity. Scratchpad members,
minimized or app-hidden windows, semantic auto-float exclusions, and windows on
disabled monitors stay out of redistribution.

## Command and state path

The menu item posts `.hyprMacRetileAll`. `WindowManager.retileAllRequested`
hides the scratchpad and calls `snapshotAndTile`. That method takes one AX
snapshot, classifies it, redistributes eligible IDs, and tiles visible
workspaces. `WorkspaceManager` owns all nine assignment sets and computes each
workspace's static home from enabled monitors. `TilingEngine.maxDepth` supplies
the per-home-monitor packing capacity. `SpaceManager` is not involved in this
virtual-workspace command; it manages native macOS Space enumeration and SPI
movement only.

The redistribution entered in commit `194a8086` with visible workspaces first,
then hidden spillover workspaces. Commit `85e57ded` added frame sorting and
focused-window promotion to address `Set` iteration, but both inputs still
depended on current UI state. Scratchpad exclusions were added in `85e57ded` and
`834a27cb`. Static home-monitor routing followed in `a25b43ba`.

## Root cause and ranked hypotheses

1. Confirmed: candidate gathering read assignment sets only for currently
   visible workspaces. It then appended the current AX snapshot. Parked windows
   on hidden workspaces can be absent from AX, so repeated redistribution
   omitted them and left holes or stale assignments.
2. Confirmed: slot construction placed currently visible workspaces first.
   Switching workspaces before `Retile All` therefore changed the destination
   order even when the window set was unchanged.
3. Confirmed: the focused window was promoted to the first slot. Focus changes
   therefore reshuffled an otherwise identical population.
4. Confirmed adjacent monitor bug: redistribution un-floated every live manual
   floater except semantic auto-float exclusions. A standard window on a
   disabled monitor was classified as floating and then immediately un-floated
   by redistribution. Disabled-monitor windows now remain floating.
5. Lower priority: screen ordering compares only the x origin in several paths.
   Vertically stacked screens with equal x origins rely on source order. A
   shared stable display identity would make this explicit, but changing the
   fleet-wide display ordering policy is outside this fix.
6. Lower priority: stale AX lifecycle state can leave a closed ID assigned until
   discovery's cleanup runs. The planner excludes IDs already classified as
   hidden and relies on the existing lifecycle sweep rather than adding another
   ownership policy to `Retile All`.

## TDD evidence

The hostless audit target builds HyprMac as a dynamic library and never launches
the window-manager application.

The first planner and tests were drafted together before the hostless runner was
available. The two confirmed legacy behaviors were then replayed independently
against focused assertions: discovery-only enumeration for the primary defect,
and auto-float-only preservation for disabled monitors. This is baseline replay
evidence rather than a claim that every draft edit followed strict red-first
chronology.

Observed red command, with the baseline behavior represented by discovery-only
candidate enumeration:

```sh
cd build/audit-harness
xcodebuild build-for-testing -project HyprMacAudit.xcodeproj -scheme HyprMacAudit -derivedDataPath derived CODE_SIGNING_ALLOWED=NO
DYLD_LIBRARY_PATH="$PWD/derived/Build/Products/Debug" DYLD_FRAMEWORK_PATH="$PWD/derived/Build/Products/Debug" xcrun xctest -XCTest HyprMacTests.RetileAllPlannerTests "$PWD/derived/Build/Products/Debug/HyprMacTests.xctest"
```

The first test failed with actual `[10, 50]` versus expected
`[10, 20, 40, 50]`; IDs 40 and 20 represented tracked hidden-workspace
members missing from discovery.

The disabled-monitor replay restored the prior predicate, which considered only
semantic auto-float status, and ran:

```sh
xcodebuild build-for-testing -project build/audit-harness/HyprMacAudit.xcodeproj -scheme HyprMacAudit -derivedDataPath build/spaces-replay-derived CODE_SIGNING_ALLOWED=NO
DYLD_LIBRARY_PATH="$PWD/build/spaces-replay-derived/Build/Products/Debug" DYLD_FRAMEWORK_PATH="$PWD/build/spaces-replay-derived/Build/Products/Debug" xcrun xctest -XCTest HyprMacTests.RetileAllPlannerTests/testDisabledMonitorWindowRemainsFloating "$PWD/build/spaces-replay-derived/Build/Products/Debug/HyprMacTests.xctest"
```

`testDisabledMonitorWindowRemainsFloating` failed at its first `XCTAssertTrue`.
Restoring `isAutoFloat || isOnDisabledMonitor` made that focused assertion pass.
The old visible-first slot algorithm was confirmed directly from history and
source, but it was not replayed through a contrived planner API that never
accepted visible-workspace or focus inputs.

Final green command:

```sh
scripts/test-isolated.sh build/audit-harness/Sparkle.xcframework HyprMacTests.RetileAllPlannerTests
```

Six focused tests pass. They cover hidden-workspace enumeration, visible and
focused state independence, repeat-plan stability, numeric gap-free packing,
all nine per-monitor capacities with overflow, and disabled-monitor floating
policy.

## Manual multi-monitor verification

This change was not installed or run against the live window manager. Before
release, use two enabled monitors with different `maxSplitsPerMonitor` values
and one disabled monitor:

1. Put tiled windows across several visible and hidden workspaces, plus a
   standard floating window on the disabled monitor and a scratchpad member.
2. Record the workspace membership, invoke `Retile All`, and confirm occupied
   workspaces are a numeric prefix beginning at 1 with no empty workspace
   between occupied workspaces.
3. Confirm each workspace appears on its static modulo-anchored home monitor
   and respects that monitor's capacity.
4. Switch visible workspaces and change focus, invoke `Retile All` again, and
   confirm the same IDs receive the same assignments.
5. Confirm the disabled-monitor window remains floating and stationary, and
   the scratchpad member remains on workspace 0.
