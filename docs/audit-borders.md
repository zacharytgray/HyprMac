# Border and scratchpad audit

## Findings

The disabled-border flash came from policy being enforced only in selected callers. `WindowManager.updateFocusBorder` checked `showFocusBorder`, and the settings observer hid the persistent focus and floating panels. Several one-shot paths called the renderer directly: scratchpad send/adopt used `flashInfo`, while rejected scratchpad, workspace, and action operations used `flashError`. Those calls could create colored panels even when the setting was false. Scratchpad transitions made the bug especially visible because sending a window to a hidden layer always issued `flashInfo("→ scratchpad")` after parking it.

The fix places the policy at the renderer boundary. `FocusBorder.show`, `updateFloatingBorders`, `flashError`, and `flashInfo` all consult `allowsPanelCreation`, which reflects `isEnabled`. `WindowManager.start()` pushes the initial setting before discovery starts, and the existing settings subscription pushes later changes. The existing hide calls still remove panels when the setting changes from on to off.

The scratchpad floating default was intentional in commit `5f539d8`: `UserConfigDefaults.scratchpadTileByDefault` was introduced as `false`, and `ScratchpadController.sendFocusedWindow()` branches directly on that value. This explains floating behavior for new or field-missing configurations, but not every observed floating window: the read-only hub configuration already stores `true`. With `true`, a new member can still float after a tile-fit rejection, and overflow adoption deliberately floats. The default now changes to `true`. A saved `false` remains authoritative because persistence cannot distinguish a deliberate choice from the old saved default; only a missing field uses the new value.

## Ranked hypotheses checked

1. Direct one-shot renderer calls bypassed `showFocusBorder`. Confirmed by tracing every `flashInfo` and `flashError` call; scratchpad send was unconditional when the layer was hidden.
2. Delayed focus or floating-border animations recreated chrome after the setting observer hid it. Possible before the fix because later direct calls had no renderer gate; the renderer policy now makes delayed callers inert. Existing panel hide behavior remains unchanged.
3. The scratchpad restored stale `isFloating` state during show/hide. Rejected as the default cause: membership is derived consistently from `floatingWindowIDs`, and the send path deliberately inserted new members there when the default was false.
4. Settings decoding lost an explicit preference. Rejected: the saved field is optional and explicit `false` survives Codable; only `nil` falls back to the new tiled default.

## TDD evidence

The regression tests were written before the behavior change. A pure policy seam avoided creating AppKit panels during the test.

Red command:

```sh
CFFIXED_USER_HOME="$PWD/build/audit-home" \
DYLD_LIBRARY_PATH="$PWD/build/borders-red-derived/Build/Products/Debug" \
DYLD_FRAMEWORK_PATH="$PWD/build/borders-red-derived/Build/Products/Debug" \
xcrun xctest -XCTest FocusBorderCornerRadiusTests/testDisabledBorderRejectsPanelCreation,ConfigMigrationTests/testScratchpadTilesNewMembersByDefault \
"$PWD/build/borders-red-derived/Build/Products/Debug/HyprMacTests.xctest"
```

Observed September 11, 2026: two tests executed with three expected assertion failures. The disabled renderer still allowed panel creation, and both the scalar and empty-config scratchpad defaults were false. Log: `build/audit-harness/borders-red-xctest.log`.

Green build and command:

```sh
CFFIXED_USER_HOME="$PWD/build/audit-home" xcodebuild build-for-testing \
-project build/audit-harness/HyprMacAudit.xcodeproj -scheme HyprMacAudit \
-destination 'platform=macOS' -derivedDataPath "$PWD/build/borders-green-derived" \
CODE_SIGNING_ALLOWED=NO

CFFIXED_USER_HOME="$PWD/build/audit-home" \
DYLD_LIBRARY_PATH="$PWD/build/borders-green-derived/Build/Products/Debug" \
DYLD_FRAMEWORK_PATH="$PWD/build/borders-green-derived/Build/Products/Debug" \
xcrun xctest -XCTest FocusBorderCornerRadiusTests/testDisabledBorderRejectsPanelCreation,ConfigMigrationTests/testScratchpadTilesNewMembersByDefault \
"$PWD/build/borders-green-derived/Build/Products/Debug/HyprMacTests.xctest"
```

The hostless production and test build succeeded. Both focused tests passed with zero failures. Logs: `build/audit-harness/borders-green-build.log` and `build/audit-harness/borders-green-xctest.log`.

The ordinary app test target was not launched because its `TEST_HOST` starts HyprMac. One initial ordinary `build-for-testing` attempt stopped during SwiftPM resolution when the sandbox denied a diagnostics write under `~/Library/Caches`; it did not compile or launch the app.

Follow-up transition tests exposed two additional races in the first implementation. Disabling used the normal fade path, so focused chrome remained visible for the configured fade duration, and an info panel became untracked when its fade began. Public-API tests observed both failures. The final disable path synchronously cancels animations, orders out every weakly tracked owned panel, clears focused and floating state, and restores any window displaced by an error shake. A generation token prevents an old error callback from hiding newer chrome; idempotent same-frame shows do not advance that token.

The first implementation was made before the initial assertion RED because the original app test harness was unsafe. It was reverted to the pre-fix behavior, the hostless bundle then produced the recorded RED assertions, and the production fix was replayed. Later transition tests were also observed failing before their synchronous cleanup changes.

## Manual visual verification

Not run. The audit constraints prohibit launching or relaunching the live window manager and changing live settings. A later authorized visual pass should start with the border disabled, send a tiled window to a hidden scratchpad, show and hide the layer, trigger a rejected operation, and confirm that no cyan, magenta, or red panel appears. It should then enable the border and repeat the same actions to confirm normal focus, floating, info, and error feedback.
