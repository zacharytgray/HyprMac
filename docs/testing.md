# Testing

## The test gate

`scripts/test-isolated.sh` is the test gate for contributors and for
`scripts/release.sh`. It generates a separate project that builds HyprMac as a
testable library. It never starts the window manager or reads live settings.
Home, cache, and tmp are redirected under `build/sizing/isolated-tests/`. The
test run itself takes about 35 seconds. The build comes on top of that. Each
run deletes the isolated config first and passes `-iCloudSyncEnabled '<false/>'`, because a debug build would
otherwise inherit the release app's real preference.

```bash
./scripts/test-isolated.sh --debug-variant                  # full suite, no Sparkle
./scripts/test-isolated.sh --debug-variant BSPTreeTests     # one class
./scripts/test-isolated.sh --debug-variant BSPTreeTests/testName
./scripts/test-isolated.sh /path/to/Sparkle.xcframework     # release variant, as release.sh runs it
```

## Supported environments

The suite is maintained and verified on the hub: macOS 15.8 with Xcode 26.3,
through `./scripts/test-isolated.sh --debug-variant`. That run gives 1870
tests, 28 skipped, 0 failures. macOS 26 or 27 and Xcode 27 are
welcome, but the maintainer has not verified them.

The harness loads the test library through rpaths. It runs `xctest` directly
and needs no `DYLD_*` variables.

## Traps

- The second argument goes straight to `xctest -XCTest`. It must start with
  a bare class name. A `HyprMacTests/` prefix runs 0 tests and still exits 0.
  Always check that `Executed N tests` shows a nonzero N and `0 failures`.
- After config schema or `Action` changes, also run
  `KeybindDecoderToleranceTests` and `ConfigMigrationTests` by name.

## Headless runs

The hub runs tests with no display. Tests that need a real `NSScreen` throw
`XCTSkip`, so skips are expected. Engine tests still run: they pass a
synthetic screen through `DisplayManager(screenSource:)`. New test screens
subclass `SyntheticScreen` in `HyprMacTests/BSPTestSupport.swift`, never
`NSScreen` directly: on macOS 26 and 27 AppKit traps on `localizedName`,
`isEqual:`, `deviceDescription` and `backingScaleFactor` of a detached
`NSScreen`, and `SyntheticScreen` answers those four (a unique screen number
from 1000 up, scale 1, identity equality). Override `frame` and
`visibleFrame` as before. Examples: `TilingEngineTiledDragTests`,
`FullscreenWorkspaceOrchestratorTests`.

Snapshot tests render only on request: `HYPRMAC_RENDER_UI=<dir>` for
`InterfaceSnapshotTests`, `HYPRMAC_RENDER_OVERVIEW=1` for
`WorkspaceOverviewPresentationTests`.

## Other builds

Release universal build, unsigned (resolves Sparkle over the network):

```bash
xcodebuild -project HyprMac.xcodeproj -scheme HyprMac -configuration Release \
  -derivedDataPath build/release-check ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build
lipo -archs build/release-check/Build/Products/Release/HyprMac.app/Contents/MacOS/HyprMac
```

Static analyzer:

```bash
xcodebuild -project HyprMac.xcodeproj -scheme HyprMac -configuration Debug \
  -derivedDataPath build/analyze CODE_SIGNING_ALLOWED=NO build analyze
```

Lint: `.swiftlint.yml` exists, but `swiftlint` is not installed on the hub and
the last recorded baseline already had errors. Do not claim a lint pass.

Tests do not prove window behavior. For behavior changes, run the Debug app on
the MacBook ([laptop-debug-deployment.md](laptop-debug-deployment.md)).

## Live acceptance checklist

Unit tests do not cover these. Run them on the MacBook with the Debug app, after
live setting changes are approved. There are ten workspaces; Hypr+0 selects 10.

Closing and lifecycle:

1. Tile three windows from two apps and leave the pointer still. Close the
   focused window with Hypr+W, then with the title-bar button, then with the
   app's close command. The other windows should grow into the freed slot with
   no hover or focus action. Repeat for app quit, minimize, restore, and a batch
   close while the app stays alive. A cancelled unsaved-document close must
   leave the document tiled.

Borders and scratchpad:

2. Turn persistent borders off. Send a window to the scratchpad, summon and
   dismiss it, and trigger a rejected operation. Turn borders off again during a
   focus, floating, info or error fade. No persistent colored border should
   stay or come back. The red rejection shake is expected and must end.
3. With the scratchpad tiled default on, send a new member to a hidden layer and
   to a visible one, then summon it. It should tile. Float a member by hand,
   hide and show the layer, and check the choice holds. Repeat with the default
   off, and with a layer too full for another tile.

Retile All (Hypr+R):

4. With two monitors, spread windows over workspaces 1 to 10 and switch to
   workspace 4. Press Hypr+R. Each screen's windows should fill the workspace
   showing on that screen first, and only the excess goes to the next workspaces
   in numeric order.
   Windows a window rule pins should land on the pinned workspace. Changing the
   visible workspace changes the result, and changing focus can change which
   windows overflow. Scratchpad, minimized, excluded and disabled-monitor windows
   keep their own handling.
5. Repeat with vertically stacked monitors, one disabled monitor, a native
   fullscreen Space, and a monitor unplug and replug.

Hypr+F (next empty workspace):

6. Move tiled and floating windows. Only the focused window moves. It fills the
   padded usable area, keeps focus, and the destination HUD shows. If the app
   has several windows, its siblings stay on the source workspace.
7. Put the pointer on a different monitor. The destination follows the focused
   window's display, not the pointer.
8. With two and three monitors, the scan stays on the window's display, wraps,
   and reaches its highest anchored workspace (10 on the display that owns it).
9. A workspace holding only hidden windows (minimized, app-hidden, closed but
   the app still running) counts as empty and can be the destination. A
   workspace with a floating window does not, and neither does one already
   showing on a screen. With no empty workspace,
   expect error feedback and no move.
10. Excluded, system, modal, fixed-size, minimized, fullscreen and scratchpad
    windows refuse safely. None becomes native fullscreen or changes scratchpad
    membership.
11. Hold F, then press it again. Auto-repeat must not keep moving the window. A
    sole window on its workspace stays put.
12. Revoke Accessibility, or unplug, rearrange or disable a display during the
    action. There should be no false success, no rollback onto a stale
    coordinate, and the next reconcile should recover.

Overview and settings:

13. Close windows while their apps keep running. The overview should drop the
    closed entries and keep live and minimized ones.
14. On a small and a large display the overview shows ten cards in two rows of
    five, search works, heavy content scrolls, and key 0 selects workspace 10.
15. With an existing config, old default shortcuts migrate. Occupied F,
    Shift+T, 0 and Shift+0 chords keep their custom bindings.

A short real sleep can run long on the hub: `Thread.sleep(0.03)` measured about 210 ms there in November 2026, against 35 ms on the MacBook. A test that races a sleep against a wall-clock deadline fails on some runs. Give it a virtual clock through `FrameSizingIO`.
