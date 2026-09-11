# UX and stability audit — September 11, 2026

Scope: close/removal retiling, disabled colored borders, scratchpad membership,
and deterministic packing across HyprMac's nine virtual workspaces. Work is
isolated on `feature/astra-ux-stability-audit`. The initial audit did not change
the live app. Zach subsequently authorized the separate MacBook debug deployment;
its current status and rollback are recorded in [the deployment report](laptop-debug-deployment.md).
Zach subsequently authorized merging and pushing the verified work.

## User acceptance and Git landing

Zach reported on September 11, 2026 that the deployed changes were working well.
The implementation is recorded in commit
`c82446001012f2ad97839c3ffe184e0c7039eeb1`. Application sources match the verified
deployed build's source marker `08ec4f1adbef+51764a1a18cb`.

Initial staging attempts failed with `index.lock: Operation not permitted`.
The original worktree's Git metadata is explicitly read-only in the session
sandbox, although normal filesystem ownership is correct. GitHub SSH access
works. To complete the authorized landing, a separate normal clone was created
under the permitted temporary directory. All 34 changed or newly added files
were copied with byte-for-byte checks before committing. No build artifacts or
live settings were copied. The original checkout and its Git metadata remain
unchanged by the landing; branch history on GitHub is the authoritative landing
record.

Future sessions need a supported permission profile that permits writes to the
worktree, its resolved Git metadata/common directory, and the main checkout when
merging there. Hermes's native-session launcher currently supplies only the
working directory as a writable root. Additional roots alone may not override
explicit read-only Git protection. This is a sandbox configuration issue, not a
GitHub credential failure. No launcher or global security settings were changed.

## Investigation and fixes

- [Window lifecycle investigation](audit-lifecycle.md): AX destruction routing,
  startup subscriptions, coalesced polling, and mass-close reconciliation.
- [Border and scratchpad investigation](audit-borders.md): renderer policy,
  delayed transitions, tiled entry defaults, and explicit floating preferences.
- [Workspace investigation](audit-spaces.md): eligible-window enumeration,
  numeric packing, repeatability, and disabled-monitor exclusions.

These reports contain the ranked hypotheses, history, focused regression
evidence, and manual checks. The rendering and WindowServer behavior still
requires a later authorized visual check. Passing deterministic tests alone
does not establish that the reported visual defects are resolved on Zach's
desktop.

Scratchpad migration limit: an existing saved `scratchpadTileByDefault: false`
remains authoritative. The current format cannot distinguish a saved old
default from an intentional floating preference. The new tiled default applies
when that field is absent; existing members keep their per-window mode. This
audit does not rewrite Zach's live configuration.
Read-only inspection on the hub found `showFocusBorder: false` and
`scratchpadTileByDefault: true`. The old default therefore does not, by itself,
explain floating scratchpad entries on that installation; fit rejection and
overflow adoption remain intentional floating paths to check visually.

TDD qualification: some initial implementation drafts were made before an
executable assertion-level red run was available. Those paths were replayed
with baseline behavior to record the expected failures, then the fixes were
reapplied and tested. This is red/green regression evidence, but the initial
drafting sequence did not uniformly satisfy the requested strict red-first
order. Compiler and sandbox failures are not counted as regression reds.

## Verification environment

The checked-in test target uses the HyprMac application as `TEST_HOST`.
`AppDelegate.applicationDidFinishLaunching` starts the manager or opens its
permission gate; the SwiftUI entry also starts Sparkle. Running that host would
violate this audit's live-app constraints.

`scripts/test-isolated.sh` generates an ignored hostless test project, compiles
the production sources as a testable dynamic library, and directly runs the
entire XCTest bundle. It excludes only the SwiftUI `@main` entry and resources.
`CFFIXED_USER_HOME` redirects Foundation's home and Application Support paths
into `build/isolated-tests/home`; both paths were verified with a Swift probe.
The script accepts an existing Sparkle XCFramework to avoid changing or
installing dependencies:

```sh
scripts/test-isolated.sh build/audit-harness/Sparkle.xcframework
scripts/test-isolated.sh build/audit-harness/Sparkle.xcframework HyprMacTests.RetileAllPlannerTests
```

The framework used here was copied from the main checkout's cached Sparkle
2.9.1 package artifact into this worktree. Build artifacts and detailed logs
remain under ignored `build/`.

The ordinary documented `xcodebuild` commands were attempted. SwiftPM could
not write its default manifest diagnostics cache under the sandbox; redirecting
the home exposed a second restriction on nested `sandbox-exec`. Xcode's test
launcher also could not connect to `com.apple.testmanagerd.control`. The
hostless direct XCTest runner avoids the latter restriction. Application
builds use a generated copy of `project.yml` with the same application sources
and settings, replacing the SwiftPM reference with that cached binary.

The first complete hostless run exposed an existing test-harness defect:
`DimmingOverlayTests` dereferenced absent panel state when `NSScreen.screens`
was empty. Those display-dependent tests now explicitly skip without a screen,
matching the existing tiling test convention. Skips must be rerun in a display
session; they are not passes.

SwiftLint 0.61.0 was downloaded into ignored `build/swiftlint/`, without a
system installation. The full command was
`build/swiftlint/swiftlint lint --no-cache --reporter json`. The baseline was
linted from a `git archive HEAD` extraction under `build/lint-baseline` using
the same configuration and binary. Final lint has 200 violations, including
15 errors, versus 201 violations and 16 errors on the baseline. There are no
new lint errors. The expanded border implementation has a new class-size
warning; the large WindowManager class moved below the error threshold. Lint
therefore remains failing overall rather than being reported as a clean gate.

Application builds passed in both Debug and Release with signing disabled:

```sh
xcodebuild build -project build/app-harness/HyprMac.xcodeproj -scheme HyprMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/app-build CODE_SIGNING_ALLOWED=NO
xcodebuild build -project build/app-harness/HyprMac.xcodeproj -scheme HyprMac \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build/app-build CODE_SIGNING_ALLOWED=NO
```

Logs: `build/final-debug.log` and `build/final-release.log`. Neither build was
installed or launched. `bash -n scripts/test-isolated.sh` and
`git diff --check` also passed.

Initial audit complete test run:

```sh
scripts/test-isolated.sh build/audit-harness/Sparkle.xcframework \
  > build/final-tests-verified.log 2>&1
```

Result: **277 tests, 55 skipped, 0 failures** (222 executed without skips).
The skips require a display and remain a verification limit. Two preceding
complete runs each exposed a test-timing issue: the new error-cleanup test
waited for headless Core Animation completion, and an existing scheduler test
asserted a count at a fixed wall-clock deadline. They now wait for the actual
state/callback respectively. Production code was unchanged for those test
refinements. The first full run's no-display dimming crash is documented above.

Independent review was performed with fresh context before the commit attempt.
It caught and prompted fixes for fades surviving disable, strong panel
inventory retention, interrupted shake restoration, and a generation token
that could strand an error flash after a redundant `show`. The final reread
found no remaining blockers. Platform acceptance and the deferred findings
below remain open.

## Final debug-deployment validation

After adding the dedicated debug variant, the complete isolated suite passed
with **281 tests, 55 skips, and 0 failures** (226 non-skipped passes). Command:
`scripts/test-isolated.sh build/audit-harness/Sparkle.xcframework`; log:
`build/deployment/final-suite-green.log`. The same SwiftLint command still
reports 200 findings / 15 errors. A signed universal debug build and a fresh
unsigned release compatibility build passed. Deployment-specific independent
review passed. Four new runtime-variant policy tests cover preference isolation
and onboarding; those new tests were not captured red before implementation.

The final full-suite attempt first exposed another existing timer test's
wall-clock assumption under build load. It now checks the installed timer's
identity across repeated starts and its invalidation on stop. Production code
was unchanged by that test stabilization. Focused and full reruns passed.
See [deployment and rollback](laptop-debug-deployment.md) for exact commands,
installed identity, preservation checks, and successful live Accessibility and
window-manager startup verification after Zach's manual grant.
The original checkout could not be staged because of read-only Git metadata.
The later temporary-checkout landing is recorded above.

## Changed files

- Lifecycle: `Core/Discovery/AXNotificationService.swift`,
  `Core/Discovery/WindowDiscoveryService.swift`,
  `Core/Orchestration/PollingScheduler.swift`, and `Core/WindowManager.swift`.
- Rendering and scratchpad: `Core/FocusBorder.swift`,
  `Core/ScratchpadController.swift`, and `Models/UserConfigDefaults.swift`.
- Packing: `Core/Workspace/RetileAllPlanner.swift`, `Core/WorkspaceManager.swift`,
  and the shared WindowManager integration. Source paths above are under
  `HyprMac/`.
- Tests: `AXNotificationServiceTests`, `WindowDiscoveryServiceTests`,
  `PollingSchedulerTests`, `FocusStateControllerTests`, `ConfigMigrationTests`,
  `RetileAllPlannerTests`, and the headless guard in `DimmingOverlayTests`, all
  under `HyprMacTests/`.
- Harness/project/reporting: `scripts/test-isolated.sh`, generated
  `HyprMac.xcodeproj/project.pbxproj`, and these four audit reports.

## Remaining audit findings

| Priority | Finding | Evidence and next step |
| --- | --- | --- |
| P1 | Live AX and visual acceptance is outstanding | Test permission revocation, app-specific close notifications, border toggles during transitions, and physical monitor layouts with the scripts below and in the focused reports. No live behavior claim is made here. |
| P2 | Settings subscriptions accumulate across stop/start | `WindowManager.start()` adds subscriptions to the same `configObservers` set that holds lifetime observers. `stop()` does not remove the per-run subscriptions. A later settings change can invoke duplicate retiles after repeated enable toggles. Separate lifetime and running subscriptions, with an isolated lifecycle test, in a follow-up. |
| P2 | Per-window AX subscriptions retain stale IDs and ignore add errors | `ensureWindowSubscriptions` records IDs regardless of each notification registration result and retains window elements until app termination. Long-lived apps can accumulate dead entries; a failed subscription is not retried. Track successful subscriptions and prune confirmed destruction without dropping minimized-window restore notifications. |
| P2 | Partial or unavailable AX snapshots still need a richer recovery policy | `AccessibilityManager.getAllWindows()` omits an app when its window-list read fails, and returns empty if trust is revoked. Discovery eventually interprets missing windows as lifecycle changes. Distinguish unavailable snapshots from confirmed absence before changing cleanup semantics. |
| P2 | Monitor identity and equal-x ordering remain fragile | Screen keys use `x * 10000 + y`; left-to-right ordering does not define a tie-break for vertically aligned displays. Monitor preferences use localized names, which can collide. A stable display-ID migration needs its own compatibility and multi-display tests. |
| P2 | Main-thread frame readback can delay event handling | `FrameReadbackPoller.applyLayout` sleeps and performs synchronous AX reads during layout. Event-driven discovery reduces idle work but does not remove stalls from busy apps or multiple retile passes. Measure real latency before introducing asynchronous layout generations. |
| P3 | Native Space helpers and naming obscure the command boundary | `SpaceManager` wraps native CGS Spaces, while Retile All changes virtual `WorkspaceManager` assignments. Several comments claim identical display ordering without an identity join. Clarify or retire unused native helpers separately. |
| P3 | Lint has an existing backlog | The untouched baseline contains 201 violations, including 16 errors, under SwiftLint 0.61.0. Avoid sweeping unrelated formatting or force-cast changes into these fixes. |

## Manual acceptance checklist

Run only after Zach authorizes a test build launch and live setting changes.

1. Tile three windows from two apps. Leave the pointer stationary. Close the
   focused window using Hypr+W, then repeat with the title-bar button and the
   app's close command. Surviving windows should occupy the freed layout slot
   without a hover or focus action. Repeat app quit, minimize, restore, and a
   batch close while the owning app stays alive. Also test a cancelled unsaved
   document close: the document must remain tiled.
2. With borders disabled, send a window to the scratchpad, summon and dismiss
   it, and trigger a rejected operation. Record transitions if necessary to
   inspect individual frames. Repeat disabling borders during an active focus,
   floating, info, or error fade. No colored border should remain or reappear.
3. With the scratchpad tiled default enabled, send a new member to both a hidden
   and a visible layer. Summon it and confirm tiling. Explicitly float a member,
   hide/show the layer, and verify its choice survives. Test an explicit saved
   false preference and a layer too full to accept another tile.
4. With two enabled monitors, distribute windows across workspaces 1–9 and
   switch to workspace 4 before Retile All. Occupied workspaces should become
   a numeric prefix from 1, using each workspace's existing home monitor and
   configured capacity. Change focus and visible workspaces and repeat; the
   same eligible IDs should retain the same assignment. Scratchpad, minimized,
   excluded, and disabled-monitor windows must retain their intended treatment.
5. Repeat with vertically arranged monitors, one disabled monitor, a fullscreen
   native Space, and a monitor disconnect/reconnect. These platform cases remain
   outside the deterministic planner tests.
