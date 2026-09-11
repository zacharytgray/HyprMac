# Lifecycle audit

## Findings

1. **Fixed: destroy notifications could be discarded before discovery.** `AXNotificationService` resolved the PID only from the firing window element. A destroyed AX element can already be unreadable, so `AXUIElementGetPid` fails and the callback returned without scheduling discovery. The callback now falls back to the PID of the retained per-app observer that delivered the event.
2. **Fixed: initial windows lacked destroy subscriptions for up to 10 seconds.** Startup attached app observers after the initial snapshot, but subscribed the snapshot's windows only on the first later poll. Startup now passes that same snapshot through app attachment and window subscription in order.
3. **Fixed: the mass-gone safety guard could postpone a real batch close for about 30 seconds.** A guarded partial snapshot now requests another check after 100 ms. The existing three-pass guard remains. A real batch removal therefore schedules three short retries before the fourth snapshot reaches the normal gone/retile path. AX work and active suppression can add time.
4. **Fixed: a stopped scheduler closure could consume a new schedule.** `stop()` cleared a shared Boolean. If a new poll was scheduled before the old closure's deadline, the old closure saw the new `true` value and fired early. Delayed fires now carry a generation token invalidated by `stop()`.
5. **Verified: gone IDs are removed from BSP trees before retile.** `ActionDispatcher.applyChanges` calls `removeWindowID` for every gone ID before `animatedRetile`. This path does not depend on pointer motion or focus recovery.

## Trace and hypotheses

The event-driven discovery change entered in commit `452e627`. Before that change, regular polling eventually observed every close. The new path made AX create, focus, minimize, and destroy events primary and reduced periodic discovery to a 10-second safety check. The existing apply path already removes every gone ID from its tree before retile, so the regression sat between the OS event and discovery rather than in BSP removal.

Ranked hypotheses from the trace were:

1. Destroy delivery was dropped because the destroyed element no longer exposed its PID. The callback guard and the observer-owned PID provided direct code evidence; the new regression test reproduced the dropped route.
2. Initial windows had no window-level subscriptions until a later discovery poll. Startup ordering confirmed a blind interval of up to the 10-second reconcile period.
3. A real batch removal triggered the partial-snapshot guard and then waited for 10-second timer ticks. Three guarded passes could defer it for roughly 30 seconds.
4. Scheduler teardown reused a Boolean token, allowing a stale closure to consume a later schedule. This was independently reproduced but is most relevant to restart and teardown paths.
5. Pointer/focus handling caused the cavity. Rejected as the root cause: pointer and focus events merely scheduled the discovery poll that the lost destroy event had failed to schedule.
6. BSP removal or animation left stale nodes. Rejected for the reported steady cavity: the existing apply loop proactively removes gone IDs before animation. It remains dependent on discovery receiving the gone ID.

## TDD evidence

Tests ran through the hostless audit library and direct `xctest`. `CFFIXED_USER_HOME` redirected user directories into `build/audit-home`; the live app and live settings were not opened.

- Destroy fallback red: `CFFIXED_USER_HOME="$PWD/build/audit-home" DYLD_LIBRARY_PATH="$PWD/build/lifecycle-derived-red/Build/Products/Debug" DYLD_FRAMEWORK_PATH="$PWD/build/lifecycle-derived-red/Build/Products/Debug" xcrun xctest -XCTest HyprMacTests.AXNotificationServiceTests build/lifecycle-derived-red/Build/Products/Debug/HyprMacTests.xctest` — 2 tests, 2 failures; observer PID was dropped.
- Scheduler generation red: the same direct runner with `-XCTest HyprMacTests.PollingSchedulerTests/testStoppedClosureCannotConsumeNewSchedule` — 1 test, 1 failure; the pre-stop closure fired the post-stop schedule.
- Startup subscription red: the same direct runner against `build/lifecycle-startup-red`, filtered to `testStartupAttachesAppsBeforeSubscribingInitialWindows` — 1 test, 1 failure; only app attachment occurred.
- Mass-gone red: the same direct runner against `build/lifecycle-mass-red`, filtered to `testMassGoneGuardRequestsPromptRecheck` — 1 test, 1 failure; no prompt recheck was requested.
- Final build: `xcodebuild build-for-testing -project build/lifecycle-harness/HyprMacAudit.xcodeproj -scheme HyprMacAudit -configuration Debug -destination 'platform=macOS' -derivedDataPath build/lifecycle-final CODE_SIGNING_ALLOWED=NO` — succeeded.
- Final focused runs: direct `xctest` against `build/lifecycle-final/Build/Products/Debug/HyprMacTests.xctest` — AX notification tests 3/3, scheduler tests 13/13, discovery tests 19/19.

## Manual verification

1. Launch a development build with three tiled windows. Close the focused window with Hypr+W while keeping the pointer still. The remaining windows should fill the space promptly.
2. Repeat with the native close button and Cmd+W. No pointer or focus event should be needed.
3. Immediately after launch, close an already-open window before ten seconds elapse. It should retile through the initial window subscription.
4. Close at least three of four windows quickly. On a responsive app with no active suppression, the remaining tile should normally expand in under one second. Record AX stalls or suppression if it takes longer.
5. Minimize and restore a window, and repeat during a workspace-transition suppression. The deferred poll should still fire once suppression lifts.
