# HyprMac — Development Guide

## What is this?
A macOS tiling window manager inspired by Hyprland. Uses Caps Lock (remapped to F18 via `hidutil`) as the "Hypr" key. BSP dwindle tiling with smart insertion, split ratio auto-adjustment, multi-monitor, directional focus/swap, togglesplit, drag-swap, focus-follows-mouse, auto-tiling.

## Build & Run
```bash
# set your Apple team ID (required for code signing)
export DEVELOPMENT_TEAM=YOUR_TEAM_ID

# build
xcodebuild -project HyprMac.xcodeproj -scheme HyprMac -configuration Debug \
  -derivedDataPath build DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM build

# run (must launch directly, NOT through Xcode debugger — TCC won't grant permissions)
build/Build/Products/Debug/HyprMac.app/Contents/MacOS/HyprMac

# or use the script (reads DEVELOPMENT_TEAM from env)
./scripts/run-debug.sh
```

**After rebuilding**, you may need to toggle HyprMac off/on in System Settings -> Accessibility because the binary signature changes.

## Project Generation
Uses XcodeGen. After changing `project.yml` or adding/removing files:
```bash
xcodegen generate
```

## Architecture
```
HotkeyManager (CGEventTap — session level)
    | action
WindowManager (orchestrator)
    |-- AccessibilityManager  (AXUIElement — window queries, focus, resize)
    |-- SpaceManager           (CGS private APIs — space listing, display mapping)
    |-- TilingEngine           (BSP dwindle trees, smart insert, split ratio adjustment)
    |-- DisplayManager         (NSScreen tracking, coordinate conversion, nearest-screen)
    |-- CursorManager          (CGWarpMouseCursorPosition)
    |-- AppLauncherManager     (NSWorkspace launch/focus)
    +-- KeyRemapper            (hidutil — Caps Lock -> F18 at driver level)
```

### Data flow
1. `HotkeyManager` intercepts F18 combos via CGEventTap, dispatches `Action` to `WindowManager`
2. `WindowManager` resolves the action (focus, swap, float, etc.) using sub-managers
3. `TilingEngine` manages per-(space, screen) BSP trees. On any window change, diffs the tree against visible windows, inserts/removes, computes layout rects, applies frames.
4. `AccessibilityManager` handles all AXUIElement queries. Single-pass greedy matching maps AXUIElements to CGWindowIDs (prevents duplicates for multi-window apps).
5. `SpaceManager` uses private CGS APIs for space enumeration and display mapping. Space switching is documented but incomplete (see Future Work).

### Tiling pipeline
```
pollWindowChanges / observer fires
  -> tileAllVisibleSpaces()
    -> for each (space, screen):
      1. diff tree vs visible windows (remove gone, smart-insert new)
      2. reset split ratios to 0.5
      3. compute layout rects from BSP tree
      4. apply frames with setFrameWithReadback (pass 1)
      5. if min-size conflicts: adjust split ratios, re-layout, re-apply (pass 2)
```

## Key Technical Decisions
- **Caps Lock -> F18 via `hidutil`**: Caps Lock can't be intercepted by CGEventTap (it's a toggle at the driver level). `hidutil property --set` remaps it to F18 at the IOKit layer. Restored on app quit.
- **Dwindle BSP layout**: Split direction from rect aspect ratio (wider=horizontal, taller=vertical). `togglesplit` (Caps+J) overrides direction on individual nodes.
- **Smart dwindle insertion** (`BSPTree.smartInsert`): Normal dwindle always splits the deepest-right leaf (spiral). On constrained monitors this creates unusably small slots. Smart insert iterates leaves right-to-left, skipping any where child dimensions would fall below `minSlotDimension` (500px). Backtracks to shallower leaves with more space. Produces 2x2 grids on vertical monitors, normal dwindle on wide monitors.
- **Split ratio adjustment** (two-pass layout): Pass 1 applies frames and reads back actual sizes via `setFrameWithReadback`. If an app refuses to shrink (macOS min-size constraint), pass 2 adjusts the parent node's `splitRatio` to give it more space (clamped [0.15, 0.85]). Ratios reset to 0.5 each retile so adjustments are transient.
- **Max BSP depth = 3**: Limits slots to full, half, quarter, eighth of screen. Beyond this, windows auto-float. Prevents apps from being shrunk to unusable sizes.
- **Resize-move-resize pattern** (from yabai): When moving windows across screens: resize (may be clamped by source screen), move to target, resize again (unclamped). Handles macOS screen-boundary constraints.
- **Single-pass window ID matching**: AXUIElement->CGWindowID matching uses greedy best-fit across all windows for a PID. Global `usedIDs` set prevents duplicate assignments (critical for Finder).
- **Focus without activation for same-app**: `HyprWindow.focus()` skips `app.activate()` when already frontmost. Prevents macOS from refocusing the "main" window when switching between windows of the same app.
- **CGS private APIs with SIP enabled**: Space management uses undocumented CoreGraphics functions declared in `PrivateAPI/CGSPrivate.h`. All work without disabling SIP.
- **NSApp.setActivationPolicy(.accessory)**: Used instead of `LSUIElement=true` in Info.plist to avoid a Sequoia TCC regression that breaks event tap creation.
- **DEVELOPMENT_TEAM via env var**: `project.yml` references `$(DEVELOPMENT_TEAM)` so no personal team IDs are committed. Set in your shell profile or pass to xcodebuild.
- **Multi-monitor**: Each (space, screen) pair gets its own BSP tree. Coordinate conversion accounts for NSScreen bottom-left origin vs CG top-left origin using primary screen height. `screen(at:)` uses nearest-screen fallback.
- **Hidden window tracking**: When a window disappears but its app is still running (minimized/hidden), `originalFrames` and `floatingWindowIDs` are preserved. On return, the window re-enters tiling with its state intact.
- **Move-to-full-monitor blocked**: `moveToMonitor` checks `canFitWindow` before physically moving. If the target screen's BSP tree can't accommodate another window, the move is refused. Prevents ghost window state where the window leaves the source tree but can't enter the target.

## File Structure
- `HyprMac/App/` — SwiftUI app entry, AppDelegate (permissions, KeyRemapper setup), menubar
- `HyprMac/Core/` — All managers (hotkey, accessibility, space, display, cursor, app launcher, key remapper)
- `HyprMac/Tiling/` — BSP node/tree (dwindle layout, smart insert, split ratio adjustment) and tiling engine
- `HyprMac/Models/` — HyprWindow (setFrame, focus), Keybind, Action, UserConfig
- `HyprMac/PrivateAPI/` — C headers for undocumented CGS functions
- `HyprMac/Settings/` — SwiftUI settings views (general, keybinds, app launcher, tiling)
- `docs/` — Internal notes (desktop-switching-notes.md)

## Default Keybinds (Caps Lock = Hypr key)
| Hotkey | Action |
|---|---|
| Hypr + Arrow | Focus window in direction |
| Hypr + Shift + Arrow | Swap window in direction |
| Hypr + J | Toggle split direction (transpose) |
| Hypr + Shift + T | Toggle floating/tiling |
| Hypr + 1-9 | Focus monitor N |
| Hypr + Shift + 1-9 | Move window to monitor N |
| Hypr + Enter | Launch/focus Terminal |

## Mouse Features
- **Focus-follows-mouse**: Hovering over a tiled window focuses it (only tiled windows, suppressed briefly after keyboard actions)
- **Drag-swap**: Drag a window onto another window's tiled slot to swap them (works across monitors)

## Tiling Rules
- Max BSP depth: 3 (smallest slot = 1/8th of screen)
- Smart insertion: backtracks to shallower leaves when splitting the deepest-right would create slots below 500px. Produces balanced layouts on constrained monitors (2x2 grid on vertical).
- Split ratio auto-adjustment: apps with large minimum sizes (Spotify, Messages) get wider slots. Sibling compresses to accommodate. Clamped [0.15, 0.85].
- Windows beyond max depth auto-float with original pre-tile size restored
- Moving a window to a full monitor is blocked
- Caps+Shift+T re-tiles a floating window, evicting the most recent window if full
- Caps+J transposes a split direction

## Permissions Required
- **Accessibility** (System Settings -> Privacy -> Accessibility) — for AXUIElement and CGEventTap
- **Caps Lock set to "Caps Lock"** in Modifier Keys (not "No Action") — `hidutil` needs the OS to pass the keypress through

## Config
Stored at `~/Library/Application Support/HyprMac/config.json`. Delete to reset to defaults.

## Known Limitations
- **Desktop/space switching incomplete**: CGS private APIs update space metadata but don't visually move windows cross-display. See `docs/desktop-switching-notes.md`. Hypr+1-9 currently focuses monitors, not desktops.
- **Overflow windows go to background**: When a monitor is full and a new window auto-floats, focus-follows-mouse can immediately push it behind tiled windows. Workaround: Cmd+Tab to the app. Fix planned as part of workspace/desktop management (see Future Work).
- **No installer**: Must build from source. DMG/Homebrew distribution planned.

## Code Style
- Comments: short lowercase fragments, not narration
- No unnecessary abstractions or error handling
- Prefer editing existing files over creating new ones
- No meta-language ("As an AI...", "According to the spec...")
