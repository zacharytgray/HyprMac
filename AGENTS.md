# HyprMac — Development Guide

## What is this?
A macOS tiling window manager inspired by Hyprland. Uses Caps Lock (remapped to F18 via `hidutil`) as the "Hypr" key. BSP dwindle tiling with smart insertion, split ratio auto-adjustment, virtual workspaces, multi-monitor, directional focus/swap, togglesplit, drag-swap, focus-follows-mouse, auto-tiling.

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
    |-- WorkspaceManager    (virtual workspaces — hide/show, home screen tracking)
    |-- AccessibilityManager  (AXUIElement — window queries, focus, resize)
    |-- SpaceManager           (CGS private APIs — space enumeration only)
    |-- TilingEngine           (BSP dwindle trees, smart insert, split ratio adjustment)
    |-- DisplayManager         (NSScreen tracking, coordinate conversion, nearest-screen)
    |-- CursorManager          (CGWarpMouseCursorPosition)
    |-- AppLauncherManager     (NSWorkspace launch/focus)
    +-- KeyRemapper            (hidutil — Caps Lock -> F18 at driver level)
```

### Data flow
1. `HotkeyManager` intercepts F18 combos via CGEventTap, dispatches `Action` to `WindowManager`
2. `WindowManager` resolves the action (focus, swap, float, workspace switch, etc.) using sub-managers
3. `WorkspaceManager` tracks which workspace is visible on each monitor, which workspace each window belongs to, and each workspace's "home screen" (last monitor it was shown on). Hides/shows windows by moving them off-screen.
4. `TilingEngine` manages per-(workspace, screen) BSP trees. On any window change, diffs the tree against visible windows, inserts/removes, computes layout rects, applies frames.
5. `AccessibilityManager` handles all AXUIElement queries. Single-pass greedy matching maps AXUIElements to CGWindowIDs (prevents duplicates for multi-window apps).
6. `SpaceManager` uses private CGS APIs for space enumeration and window-to-space queries. Not used for workspace switching (virtual workspaces bypass macOS Spaces).

### Tiling pipeline
```
pollWindowChanges / observer fires
  -> tileAllVisibleSpaces()
    -> for each screen:
      1. get active workspace for this screen from WorkspaceManager
      2. get windows assigned to that workspace
      3. diff tree vs workspace windows (remove gone, smart-insert new)
      4. reset split ratios to 0.5
      5. compute layout rects from BSP tree
      6. apply frames with setFrameWithReadback (pass 1)
      7. if min-size conflicts: adjust split ratios, re-layout, re-apply (pass 2)
```

### Workspace switching flow
```
Hypr+N pressed:
  -> screenUnderCursor() determines which monitor the user is on
  -> WorkspaceManager.switchWorkspace(N):
    if ws N is visible on some screen: just focus that screen
    if ws N is not visible:
      find ws N's home screen (last monitor it was on)
      hide old workspace's windows in that screen's corner
      show ws N's windows via tiling engine
      update home screen tracking for both workspaces
```

## Key Technical Decisions
- **Virtual workspaces (AeroSpace approach)**: 9 global workspaces managed in userspace. Windows on inactive workspaces are hidden at the bottom corner of their screen (1px visible — macOS limitation). No CGS private APIs needed for workspace management. Works without SIP.
- **Workspace home screen tracking**: Each workspace remembers which monitor it was last shown on (`workspaceHomeScreen`). Switching to an invisible workspace returns it to its home screen, NOT the cursor's screen. Prevents workspace drift across monitors.
- **Cursor-based screen detection**: All workspace operations use `screenUnderCursor()` instead of `getFocusedWindow()`. The focused window can be stale after switching to an empty workspace.
- **Inactive workspace window tracking**: Windows on invisible workspaces stay in `knownWindowIDs` even when they disappear from `getAllWindows()`. Prevents rediscovery as "new" windows and workspace reassignment drift.
- **Caps Lock -> F18 via `hidutil`**: Caps Lock can't be intercepted by CGEventTap (it's a toggle at the driver level). `hidutil property --set` remaps it to F18 at the IOKit layer. Restored on app quit.
- **Dwindle BSP layout**: Split direction from rect aspect ratio (wider=horizontal, taller=vertical). `togglesplit` (Caps+J) overrides direction on individual nodes.
- **Smart dwindle insertion** (`BSPTree.smartInsert`): Normal dwindle always splits the deepest-right leaf (spiral). On constrained monitors this creates unusably small slots. Smart insert iterates leaves right-to-left, skipping any where child dimensions would fall below `minSlotDimension` (500px). Backtracks to shallower leaves with more space. Produces 2x2 grids on vertical monitors, normal dwindle on wide monitors.
- **Split ratio adjustment** (two-pass layout): Pass 1 applies frames and reads back actual sizes via `setFrameWithReadback`. If an app refuses to shrink (macOS min-size constraint), pass 2 adjusts the parent node's `splitRatio` to give it more space (clamped [0.15, 0.85]). Ratios reset to 0.5 each retile so adjustments are transient.
- **Max BSP depth = 3**: Limits slots to full, half, quarter, eighth of screen. Beyond this, windows auto-float. Prevents apps from being shrunk to unusable sizes.
- **Resize-move-resize pattern** (from yabai): When moving windows across screens: resize (may be clamped by source screen), move to target, resize again (unclamped). Handles macOS screen-boundary constraints.
- **Single-pass window ID matching**: AXUIElement->CGWindowID matching uses greedy best-fit across all windows for a PID. Global `usedIDs` set prevents duplicate assignments (critical for Finder).
- **Focus without activation for same-app**: `HyprWindow.focus()` skips `app.activate()` when already frontmost. Prevents macOS from refocusing the "main" window when switching between windows of the same app.
- **Focus-without-raise (SkyLight private APIs)**: `HyprWindow.focusWithoutRaise()` uses `_SLPSSetFrontProcessWithOptions` + `SLPSPostEventRecordTo` (same technique as yabai/Amethyst) to give keyboard focus to a window without changing z-order. Used by FFM and `focusInDirection` so floating windows aren't disturbed. Linked via SkyLight.framework, declared with `@_silgen_name`. The original `focus()` with raise is kept for cases that need it (drag-swap, workspace switch).
- **Floating window z-order**: macOS doesn't allow setting another process's window level without SIP disabled (yabai injects into Dock.app for this). HyprMac uses three strategies: (1) `focusWithoutRaise()` for hover/keyboard focus prevents z-order changes entirely, (2) z-order-aware re-raising — `floatingWindowsBehindTiled()` checks actual z-positions via `CGWindowListCopyWindowInfo` and only raises floaters that are actually behind tiled windows, then immediately restores focus to the tiled window via `focusWithoutRaise()` to break the raise→FFM→refocus feedback loop, (3) FFM exemption — `handleMouseMove()` skips focus changes when cursor is over a floating window's region. Hypr+F explicitly cycles through and raises floating windows. HyprMac's own settings window uses `NSWindow.level = .floating` which is flicker-free since it's in-process.
- **Menu bar workspace indicator**: Dynamic `MenuBarExtra` label showing workspace state via shared `MenuBarState` observable. Active workspaces shown as `[N]`, occupied as `N`, floating indicator `◆`. Updated by `WindowManager.updateMenuBarState()` after every position cache refresh. Toggleable via `config.showMenuBarIndicator`.
- **Keybind auto-migration**: `UserConfig.mergeNewDefaults()` injects default keybinds for new actions into existing saved configs on load, so upgrades add new shortcuts without resetting user customizations.
- **CGS/SLS private APIs with SIP enabled**: Space enumeration uses undocumented CoreGraphics functions declared in `PrivateAPI/CGSPrivate.h`. SkyLight framework linked for `_SLPSSetFrontProcessWithOptions` and `SLPSPostEventRecordTo`. All work without disabling SIP.
- **NSApp.setActivationPolicy(.accessory)**: Used instead of `LSUIElement=true` in Info.plist to avoid a Sequoia TCC regression that breaks event tap creation.
- **DEVELOPMENT_TEAM via env var**: `project.yml` references `$(DEVELOPMENT_TEAM)` so no personal team IDs are committed. Set in your shell profile or pass to xcodebuild.
- **Multi-monitor**: Each (workspace, screen) pair gets its own BSP tree. Coordinate conversion accounts for NSScreen bottom-left origin vs CG top-left origin using primary screen height. `screen(at:)` uses nearest-screen fallback.
- **Hidden window tracking**: When a window disappears but its app is still running (minimized/hidden), `originalFrames` and `floatingWindowIDs` are preserved. On return, the window re-enters tiling with its state intact.
- **App exclusions**: Quick Look windows are hard-excluded in AccessibilityManager (not real windows). User-configurable exclusions (`config.excludedBundleIDs`) auto-float windows on discovery — still tracked for workspace assignment but never enter the BSP tree. Default: FaceTime, System Settings. Configurable in Settings → General → "Never Tile" or via config JSON.

## File Structure
```
HyprMac/
├── project.yml                    # XcodeGen project spec
├── scripts/run-debug.sh           # Build & run for development
├── docs/
│   └── desktop-switching-notes.md # Implementation notes for virtual workspaces
├── HyprMac/
│   ├── App/
│   │   ├── HyprMacApp.swift       # @main — menubar + settings window
│   │   ├── AppDelegate.swift      # Permission flow, key remap, starts WindowManager
│   │   └── MenuBarView.swift      # Menubar popover UI + workspace indicators
│   ├── Core/
│   │   ├── WindowManager.swift    # Central orchestrator — actions, polling, drag-swap, mouse
│   │   ├── WorkspaceManager.swift # Virtual workspaces — hide/show, home screen tracking
│   │   ├── HotkeyManager.swift    # CGEventTap — intercepts F18 combos
│   │   ├── AccessibilityManager.swift  # AXUIElement — single-pass window ID matching
│   │   ├── SpaceManager.swift     # macOS Spaces via private CGS APIs (enumeration only)
│   │   ├── DisplayManager.swift   # Multi-monitor tracking + coordinate conversion
│   │   ├── CursorManager.swift    # Mouse warp to focused window
│   │   ├── AppLauncherManager.swift  # NSWorkspace app launch/focus
│   │   └── KeyRemapper.swift      # hidutil Caps Lock → F18 remap
│   ├── Tiling/
│   │   ├── BSPNode.swift          # BSP node — dwindle layout, togglesplit, depth tracking
│   │   ├── BSPTree.swift          # BSP tree — smart insert, split ratio adjustment, swap
│   │   └── TilingEngine.swift     # Per-(workspace, screen) tiling, two-pass layout, auto-float
│   ├── Models/
│   │   ├── HyprWindow.swift       # Window model — setFrame (resize-move-resize), focus
│   │   ├── Keybind.swift          # Keybind model + default keybind table
│   │   ├── Action.swift           # All possible actions enum
│   │   └── UserConfig.swift       # Persisted JSON config
│   ├── PrivateAPI/
│   │   ├── CGSPrivate.h           # Private CoreGraphics function declarations
│   │   └── HyprMac-Bridging-Header.h
│   ├── Settings/
│   │   ├── SettingsView.swift     # Tab view container
│   │   ├── GeneralSettingsView.swift  # Enable toggle, focus-follows-mouse toggle
│   │   ├── KeybindsSettingsView.swift # In-app keybind editor with key recording
│   │   ├── AppLauncherSettingsView.swift  # App launcher editor with Finder picker
│   │   └── TilingSettingsView.swift  # Gap/padding config with live preview
│   └── Resources/
│       └── Assets.xcassets
```

## Default Keybinds (Caps Lock = Hypr key)
| Hotkey | Action |
|---|---|
| Hypr + Arrow | Focus window in direction |
| Hypr + Shift + Arrow | Swap window in direction |
| Hypr + J | Toggle split direction (transpose) |
| Hypr + Shift + T | Toggle floating/tiling |
| Hypr + F | Focus/cycle floating windows |
| Hypr + 1-9 | Switch to workspace N |
| Hypr + Shift + 1-9 | Move focused window to workspace N |
| Hypr + Ctrl + Left/Right | Swap workspace with adjacent monitor |
| Hypr + K | Show/hide keybind overlay |
| Hypr + Enter | Launch/focus Terminal |
| Double-tap Caps Lock | Warp cursor to menu bar (configurable action) |

## Mouse Features
- **Focus-follows-mouse**: Hovering over a tiled window focuses it via `focusWithoutRaise()` (toggleable in Settings, suppressed briefly after keyboard actions, suppressed during menu bar interaction). Uses SkyLight private APIs to change keyboard focus without disrupting window z-order.
- **Drag-swap**: Drag a window onto another window's tiled slot to swap them (works across monitors)
- **Double-tap Caps Lock**: Fires a configurable action (default: warp cursor to menu bar). Configurable in Settings → General or config.json. Won't trigger if Caps Lock was used as a modifier between taps.

## Tiling Rules
- Max BSP depth: 3 (smallest slot = 1/8th of screen)
- Smart insertion: backtracks to shallower leaves when splitting the deepest-right would create slots below 500px. Produces balanced layouts on constrained monitors (2x2 grid on vertical).
- Split ratio auto-adjustment: apps with large minimum sizes (Spotify, Messages) get wider slots. Sibling compresses to accommodate. Clamped [0.15, 0.85].
- Windows beyond max depth auto-float with original pre-tile size restored
- Caps+Shift+T re-tiles a floating window, evicting the most recent window if full
- Caps+J transposes a split direction

## Permissions Required
- **Accessibility** (System Settings -> Privacy -> Accessibility) — for AXUIElement and CGEventTap
- **Caps Lock set to "Caps Lock"** in Modifier Keys (not "No Action") — `hidutil` needs the OS to pass the keypress through

## Config
Stored at `~/Library/Application Support/HyprMac/config.json`. Delete to reset to defaults.
Users can also edit keybinds in the Settings UI (Keybinds tab — add, edit, delete with key recording).

### Config file format (for agents editing config directly)
The config is a JSON file with this structure:
```json
{
  "keybinds": [
    {
      "keyCode": 123,
      "modifiers": { "rawValue": 1 },
      "action": { "focusDirection": { "_0": "left" } }
    }
  ],
  "gapSize": 8,
  "outerPadding": 8,
  "enabled": true,
  "focusFollowsMouse": true,
  "doubleTapAction": { "focusMenuBar": {} },
  "excludedBundleIDs": ["com.apple.FaceTime", "com.apple.systempreferences"]
}
```

**Modifier rawValues** (combine with bitwise OR):
- `1` = Hypr (Caps Lock), `2` = Shift, `4` = Option, `8` = Control, `16` = Command
- Example: Hypr+Shift = `3`, Hypr+Ctrl = `9`

**Common key codes** (decimal, from Carbon `kVK_*`):
- Arrows: Left=123, Right=124, Up=126, Down=125
- Letters: A=0, S=1, D=2, F=3, H=4, G=5, Z=6, X=7, C=8, V=9, B=11, Q=12, W=13, E=14, R=15, Y=16, T=17, O=31, U=32, I=34, P=35, L=37, J=38, K=40, N=45, M=46
- Numbers: 1=18, 2=19, 3=20, 4=21, 5=23, 6=22, 7=26, 8=28, 9=25, 0=29
- Return=36, Space=49, Tab=48, Delete=51, Escape=53

**Action encoding** (Codable enum, key = case name):
- `{"focusDirection": {"_0": "left"}}` — direction: left/right/up/down
- `{"swapDirection": {"_0": "right"}}`
- `{"switchDesktop": {"_0": 3}}` — workspace number 1-9
- `{"moveToDesktop": {"_0": 3}}`
- `{"moveWorkspaceToMonitor": {"_0": "left"}}` — left/right only
- `{"toggleFloating": {}}`, `{"toggleSplit": {}}`, `{"showKeybinds": {}}`, `{"focusMenuBar": {}}`, `{"focusFloating": {}}`
- `{"launchApp": {"bundleID": "com.apple.Terminal"}}`

**`doubleTapAction`** — the action fired by double-tapping Caps Lock. Uses the same action encoding as keybinds. Set to `null` to disable. Default: `{"focusMenuBar": {}}`.

**`excludedBundleIDs`** — array of bundle IDs for apps that should never be tiled (auto-float on launch). Configurable in Settings → General → "Never Tile" or via config. Default: `["com.apple.FaceTime", "com.apple.systempreferences"]`.

To add a custom keybind via config, append to the `keybinds` array and restart HyprMac.
Example — bind Hypr+B to launch Safari:
```json
{"keyCode": 11, "modifiers": {"rawValue": 1}, "action": {"launchApp": {"bundleID": "com.apple.Safari"}}}
```

### App launchers
App launchers are keybinds with a `launchApp` action. They can be added:
1. **In-app**: Settings → App Launcher tab → Add App Launcher (opens Finder to pick an .app, then record a key)
2. **Via config**: add a keybind entry with `{"launchApp": {"bundleID": "..."}}` action

Common bundle IDs:
- `com.apple.Terminal`, `com.apple.Safari`, `com.apple.finder`
- `com.googlecode.iterm2`, `com.microsoft.VSCode`, `com.brave.Browser`
- `io.alacritty`, `com.github.wez.wezterm`, `net.kovidgoyal.kitty`
- Find any app's bundle ID: `mdls -name kMDItemCFBundleIdentifier /Applications/AppName.app`

## Known Limitations
- **1px window sliver**: Hidden workspace windows leave a 1px sliver visible in the screen corner. macOS limitation. Also serves as crash recovery.
- **macOS Spaces bypassed**: Use 1 macOS Space per monitor. HyprMac's virtual workspaces replace native Spaces.
- **No animation**: Workspace switches are instant (like Hyprland).
- **Floating windows may go behind tiled**: macOS doesn't allow setting another process's window level without SIP disabled. Floating windows can end up behind tiled windows, especially with a single full-screen tiled app. Workaround: Hypr+F cycles through and raises floating windows. Smart re-raising also triggers automatically on app activation.
- **No installer**: Must build from source. DMG/Homebrew distribution planned.

## Code Style
- Comments: short lowercase fragments, not narration
- No unnecessary abstractions or error handling
- Prefer editing existing files over creating new ones
- No meta-language ("As an AI...", "According to the spec...")
