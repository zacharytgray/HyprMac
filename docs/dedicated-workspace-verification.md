# Dedicated workspace and ten-workspace verification

## MacBook deployment — September 18, 2026

Latest deployment: portrait restoration fix, 15:45 CDT. Source marker
`c02bc66a667a+e3869a9152c8`, PID 34097. Startup logged Accessibility trusted
and `started`. Installed SHA-256 matches the signed universal hub build:
`96fbcb139340462849e1168e2a48916c05be288a49d2b181d538fbc67a2536d7`.
Both isolated app variants pass 947 tests, with 24 skips and zero failures.
Rollback bundle: `~/Library/Caches/HyprMacDeployment/before-portrait-restore-fix.zip`.
Zach confirmed “Full height now.” Live logs at 15:46:15, 15:46:17, and
15:46:18 show accepted portrait restores of window 109601 to its full-height
target after workspace switches. Evidence: `build/deployment-fullscreen/portrait-post-fix.log`.
No release was published.

Earlier deployments follow for provenance.

The parking/no-op correction was deployed at 15:28 CDT. Current source marker:
`c02bc66a667a+612bcadf5f2d`, PID 32536. The normal GUI launch logged
`AXIsProcessTrusted=true` and `started`. Installed executable SHA-256 matches
the hub: `6a88853c1483f7061af9de0dd89b342920b106037327a074fab5cc2bf9db91af`.
Both isolated app variants pass 942 tests with 24 skips and zero failures.
The signed universal Debug build passes signature verification. The updated
website passes seven tests and its production build. The prior app is backed
up at `~/Library/Caches/HyprMacDeployment/before-fullscreen-parking-fix.zip`.
Live acceptance of the corrected behavior is pending.

After explicit approval, the old Debug process was quit gracefully and the
verified signed build replaced `/Users/zgray/Applications/HyprMac Debug.app`
on `zachbook-pro`. Launch Services started PID 31644 at 15:19 CDT. Its own
log recorded `AXIsProcessTrusted=true` and `started`. The installed source
marker is `c02bc66a667a+d99494e93a2f`; executable SHA-256 is
`9850a5c25434ece668514723880f939641c26ce8ba88ca410189d5d0ea996e04`, matching
the verified hub build. No release process is running.

The prior Debug bundle is backed up on the MacBook at
`~/Library/Caches/HyprMacDeployment/before-fullscreen-c02bc66.zip`.
The release bundle and user settings were not edited by deployment.
Startup is confirmed; this is not a pass of the full live acceptance matrix.

## Follow-up: repeated F and parking clamp

The September 18 MacBook trace at 15:21:12 CDT showed a successful mover
layout followed by source parking at x=3439. macOS returned y=1284 and
1316 rather than the requested 1347, preserving both source window sizes.
The exact-frame restoration predicate incorrectly rejected these hidden
windows and rolled the move back. Evidence is retained locally in
`build/deployment-fullscreen/reported-failure.log`.

Parking now writes position only under the checked EnhancedUI guard and
verifies two readback samples. It accepts preserved-size windows with at most
one pixel of horizontal visibility on every physical display, allowing the
observed titlebar clamp. Substantially visible windows still reject and roll
back. Ordinary tiling and restoration retain their strict geometry checks.
The focused window also stays put when it is the only assigned workspace
window, whether tiled or floating. The website reducer matches that rule.

## Source

Implementation branch: `feature/fullscreen-workspace-shortcut`.
Base: `c02bc66a667a0321beb4c3937bc7a3610bdb1b68`, matching remote
`origin/main` when rechecked on September 18, 2026.

## Behavior

- Hypr+F moves the actual focused window to the next empty workspace anchored
  to that window's display. The scan wraps, skips every assigned workspace,
  and excludes its source. No vacancy leaves membership unchanged with error
  feedback. A sole assigned window stays put, including on repeated key presses.
  This is a dedicated workspace, not native macOS fullscreen.
- Eligible floating windows become tiled. Hypr+T can restore their captured
  floating size. Subsequent windows can join the destination; it is not locked.
- Hypr+Shift+T cycles floating windows. This is the intended interpretation
  of the dictated “Hypr+Shift+.+T.” Hypr+T still toggles floating.
- Hypr+0 selects workspace 10; Hypr+Shift+0 moves a window there. Scratchpad
  remains internal workspace 0. Overview cards use two rows of five.
- Old default shortcuts migrate only when unambiguous and collision-free.
  Custom chords and custom action bindings survive.
- The overview omits verified-closed stale entries while retaining live,
  deliberately reserved hidden/minimized, and temporarily unavailable windows.
  It does not delete assignments to clean up a visual list.

The transfer stages and verifies destination geometry and source parking before
publishing workspace membership. Ordinary failures use verified restoration.
A superseded generation or changed display topology can interrupt geometry
after partial writes. It must not apply stale restoration over newer state;
normal reconciliation owns recovery. This needs live disconnection testing.

## Reproducible automated checks

Run from this worktree, without launching or installing the app:

```sh
scripts/test-isolated.sh --debug-variant
HYPRMAC_RENDER_OVERVIEW=1 scripts/test-isolated.sh --debug-variant HyprMacTests.WorkspaceOverviewPresentationTests
xcodebuild -resolvePackageDependencies -project HyprMac.xcodeproj -scheme HyprMac -clonedSourcePackagesDirPath "$PWD/build/SourcePackages"
scripts/test-isolated.sh "$PWD/build/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework"
xcodegen generate
xcodebuild -project HyprMac.xcodeproj -scheme HyprMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$PWD/build/dedicated-workspace-release" -clonedSourcePackagesDirPath "$PWD/build/SourcePackages" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
scripts/build-debug.sh "$PWD/build/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework"
git diff --check
```

Run the isolated test scripts sequentially: they share a generated build tree.
They use an isolated settings home and do not start the window manager.
The overview renderer creates offscreen images at widths 852, 976, and 1400.

Verified on September 18, 2026:

- Debug-variant isolated suite: 940 tests, 24 skips, zero failures.
- Sparkle-enabled isolated suite: 940 tests, 24 skips, zero failures.
- Offscreen overview suite: 13 tests, zero failures, including render checks.
- Signed Debug application: universal arm64/x86_64 build and signature checks
  passed. It was not installed or launched.
- Release application: unsigned universal arm64/x86_64 build passed.
- Website: six reducer tests, production build, and lint passed. Lint retains
  seven existing React warnings; the build reports its existing large chunk.
- Website overview DOM: ten cards measured in five equal columns and two
  rows, with labels 1–10. Screenshot validation was blocked by the existing
  Three.js background failing to create a headless WebGL context.

App logs are under `build/verification/`. The full-suite skips include live
desktop checks and opt-in rendering; the renderer ran separately. Passing
the isolated suites does not replace the live matrix below.

The website source is an isolated local copy under `build/website-source`,
based on Grove's `site/hyprmac` commit
`32b06f31cc77e940563a733890793cfa0d9a08eb`.
The original Grove checkout is unchanged. The portable website diff is
`build/website-workspace-update.patch`; both paths are ignored build artifacts.
In `build/website-source/hyprmac-site/web`, run `pnpm test`, `pnpm build`, and
`pnpm lint`. Apply the patch to the website branch in a later integration
session. Deployment is a separate action.

## Live acceptance matrix — still required before release

| Scenario | Expected result |
| --- | --- |
| Tiled and floating Safari/ChatGPT windows | F moves only the focused window, fills the padded usable area, retains focus, and shows the destination HUD. |
| Several windows belonging to one app | Only the AX-focused window moves; sibling windows remain assigned to the source. |
| Cursor on a different monitor | Destination follows the focused window's display, not the pointer. |
| Two and three enabled monitors | Scan follows anchored sets, including workspace 10, and wraps within its display. |
| Hidden/minimized/floating destination tenant | Workspace remains reserved and is skipped. No vacancy gives error feedback. |
| Excluded, system, modal, fixed-size, minimized, fullscreen, scratchpad window | Action refuses safely; no native fullscreen or scratchpad reassignment. |
| AX permission loss or sizing/parking refusal | No false successful switch; verified rollback or explicit failure feedback. |
| Unplug/rearrange/disable a display during action | No stale-coordinate rollback or commit to the wrong display; reconciliation recovers. |
| Hold F, then press F again | Auto-repeat does not keep moving; subsequent presses leave a sole window on its workspace. |
| Existing/custom settings | Exact old defaults migrate; occupied F, Shift+T, 0, and Shift+0 remain customized. |
| Overview after closing windows while apps keep running | Closed entries disappear; actual ChatGPT/Safari windows remain; minimized reservations remain accurate. |
| Overview on small/large displays | Ten cards in two rows of five, usable search, scrolling for heavy content, keyboard 0 selects 10. |
| Website demo/help/docs | F, Shift+T, 0/Shift+0, and ten-workspace overview agree with app behavior. |

## Joops' pending work

PR #14 (`fd486fe17fd68dedddd91c60e18c80e6b5c8201a`) adds per-display
layout persistence. PR #20 (`47d9ab661eaf492dba5f338841f44035e5767e34`)
builds on that work with `TilingEngine.rebuildTree`. Both were open and
conflicting against main at the final remote check. Neither is a prerequisite
or included here. Land/reconcile #14 before #20. Regenerate the Xcode project
after resolving file lists, preserve the new keybind/category entries, and
reconcile tree publication/generation checks with the verified transfer path.
Re-run workspace-count, migration, restoration, and persistence tests after
integration. No PR or branch was modified as part of this work.

## Portrait restore regression — investigation

The September 18 trace at 15:37:15 CDT shows BL450 workspace 3 switching
back to workspace 1. Window 109601 requested `(-1072,-88,1064,1874)` but
settled at `(-1072,-88,1064,1528)`. Its bottom was exactly 1440, the
landscape display's bottom, instead of the portrait target's 1786. The
same result occurred for ChatGPT window 107331 on workspace 3. Later
float/tile actions restored height 1874. Evidence is retained locally in
`build/deployment-fullscreen/portrait-height-report.log`.

The original size-position-size sequence returned successful AX writes;
readback correctly rejected the shortened result. The suspected cause is
resizing before the move from the global parking corner has settled onto
the taller display. This investigation does not justify relaxing layout
geometry checks or learning the shortened height as an app constraint.

The correction selects only windows whose captured original frame is less
than half visible on the destination. Their restore moves first, observes
two stable on-target positions, then sizes and runs the unchanged strict
frame validation. The same deadline and generation checks cover every step.
Other windows in the layout retain the existing resize-move-resize ordering.
This avoids treating a refused or unreadable move as permission to resize.

Later change (2026-09-26): a crossing window moves first only when it is
parked or its target does not fit the screen it stands on. The position wait
is capped at a third of the deadline. A move that has not read back on target
by then is sized anyway, so a refused move no longer holds back the resize;
the readback judges the result. See "Two-pass layout" in `tiling-algorithm.md`.
