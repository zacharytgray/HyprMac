# HyprMac

A keyboard-centric tiling window manager for macOS, inspired by [Hyprland](https://hyprland.org/).

HyprMac turns your **Caps Lock** key into a "Hypr" modifier and gives you Hyprland-style window management: BSP dwindle tiling, directional focus, window swapping, split transposing, floating toggle, drag-swap, focus-follows-mouse, and more — all without touching the mouse.

## Features

- **BSP Dwindle Tiling** — Windows automatically tile in Hyprland's dwindle pattern, recursively splitting the screen along the longer axis.
- **Auto-Tiling** — Newly launched, unhidden, or unminimized apps are automatically tiled in.
- **Smart Insertion** — On constrained monitors (vertical, small), automatically backtracks to shallower leaves when the dwindle spiral would create unusably small slots. Produces balanced 2x2 grids on vertical monitors instead of deep spirals.
- **Min-Size Adaptation** — Detects when apps refuse to shrink (Spotify, Messages, etc.) and automatically adjusts split ratios to give them more space.
- **Max Depth Limit** — No window shrinks below 1/8th of the screen. If the screen is full, additional windows auto-float.
- **Directional Focus** — `Hypr + Arrow` moves focus to the nearest window in that direction, across monitors.
- **Window Swapping** — `Hypr + Shift + Arrow` swaps the focused window with its neighbor in the BSP tree.
- **Toggle Split** — `Hypr + J` transposes the focused window's split direction (like Hyprland's `togglesplit`). Turn a vertical stack into side-by-side, or vice versa.
- **Floating Toggle** — `Hypr + Shift + T` pops a window out of tiling (restoring its original size) or pushes it back in.
- **Monitor Switching** — `Hypr + 1-9` focuses monitor N. `Hypr + Shift + 1-9` moves the focused window to monitor N.
- **Drag-Swap** — Drag a window onto another's tiled slot to swap them. Works across monitors.
- **Focus-Follows-Mouse** — Hovering over a tiled window automatically focuses it.
- **App Launcher** — `Hypr + Enter` launches or focuses Terminal (configurable).
- **Cursor Warp** — On keyboard focus changes, the cursor teleports to the center of the focused window.
- **Multi-Monitor** — Each monitor tiles independently with its own BSP tree. Works with ultrawides, verticals, any layout.
- **Configurable** — All keybinds, gap size, and padding are customizable in the Settings UI.

## How It Works

HyprMac remaps **Caps Lock → F18** at the macOS driver level using `hidutil`. This means:
- Caps Lock **never toggles** while HyprMac is running
- F18 acts as a dedicated modifier key that doesn't conflict with any application shortcuts
- Normal Caps Lock behavior is **restored when you quit** HyprMac

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode 15+ (for building)
- **Accessibility** permission granted in System Settings
- **Caps Lock** set to "⇪ Caps Lock" in Modifier Keys (not "No Action")

## Installation

### From Source

```bash
git clone https://github.com/zachgray/HyprMac.git
cd HyprMac

# install XcodeGen if you don't have it
brew install xcodegen

# generate Xcode project
xcodegen generate

# build (replace YOUR_TEAM_ID with your Apple Developer Team ID)
export DEVELOPMENT_TEAM=YOUR_TEAM_ID
xcodebuild -project HyprMac.xcodeproj -scheme HyprMac -configuration Release \
  -derivedDataPath build DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM build

# install
cp -r build/Build/Products/Release/HyprMac.app /Applications/
```

> **Finding your Team ID**: Open Xcode → Settings → Accounts → select your Apple ID → your team ID is shown under the team name. Or run `security find-identity -v -p codesigning` and look for the alphanumeric ID.

### First Launch

1. Open HyprMac — it appears in your menubar (no Dock icon)
2. Grant **Accessibility** permission when prompted (System Settings → Privacy & Security → Accessibility)
3. Relaunch HyprMac after granting permission
4. Start tiling with `Caps Lock + Arrow` to move focus between windows

## Default Keybinds

| Shortcut | Action |
|---|---|
| `⇪ + ←/→/↑/↓` | Focus window in direction |
| `⇪ + Shift + ←/→/↑/↓` | Swap window in direction |
| `⇪ + J` | Toggle split direction (transpose) |
| `⇪ + Shift + T` | Toggle window floating/tiling |
| `⇪ + 1-9` | Focus monitor N |
| `⇪ + Shift + 1-9` | Move window to monitor N |
| `⇪ + Enter` | Launch or focus Terminal |

### Mouse

| Action | Effect |
|---|---|
| Hover over window | Focus follows mouse |
| Drag window onto another | Swap their positions |

All keybinds are configurable in the Settings window (click the menubar icon → Settings).

## Tiling Behavior

HyprMac uses a **dwindle BSP** layout inspired by Hyprland's:

- Each new window splits the most recent window's space in half
- Split direction follows the longer axis (wider → horizontal, taller → vertical)
- **Smart insertion**: if splitting the deepest leaf would create slots below 500px, backtracks to a shallower leaf with more space. This naturally produces 2x2 grids on vertical monitors instead of spiraling into tiny slots.
- **Min-size adaptation**: apps with large minimum sizes (Spotify, Messages) get their split ratios auto-adjusted so they fit without overlapping neighbors.
- **Max depth: 3** — windows can be full, half, quarter, or eighth of the screen
- If the screen is full, new windows are **auto-floated** instead of being shrunk to unusable sizes
- Moving a window to a full monitor is blocked to prevent ghost window state
- Use `⇪ + J` to transpose any split
- Use `⇪ + Shift + T` to pop/push windows in and out of tiling (evicts the most recent window if the screen is full)

## Project Structure

```
HyprMac/
├── project.yml                    # XcodeGen project spec
├── scripts/run-debug.sh           # Build & run for development
├── docs/                          # Internal notes
│   └── desktop-switching-notes.md # What worked/didn't for space switching
├── HyprMac/
│   ├── App/
│   │   ├── HyprMacApp.swift       # @main — menubar + settings window
│   │   ├── AppDelegate.swift      # Permission flow, key remap, starts WindowManager
│   │   └── MenuBarView.swift      # Menubar popover UI
│   ├── Core/
│   │   ├── WindowManager.swift    # Central orchestrator — actions, polling, drag-swap, mouse
│   │   ├── HotkeyManager.swift    # CGEventTap — intercepts F18 combos
│   │   ├── AccessibilityManager.swift  # AXUIElement — single-pass window ID matching
│   │   ├── SpaceManager.swift     # macOS Spaces via private CGS APIs
│   │   ├── DisplayManager.swift   # Multi-monitor tracking + coordinate conversion
│   │   ├── CursorManager.swift    # Mouse warp to focused window
│   │   ├── AppLauncherManager.swift  # NSWorkspace app launch/focus
│   │   └── KeyRemapper.swift      # hidutil Caps Lock → F18 remap
│   ├── Tiling/
│   │   ├── BSPNode.swift          # BSP node — dwindle layout, togglesplit, depth tracking
│   │   ├── BSPTree.swift          # BSP tree — smart insert, split ratio adjustment, swap
│   │   └── TilingEngine.swift     # Per-(space, screen) tiling, two-pass layout, auto-float
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
│   │   ├── GeneralSettingsView.swift
│   │   ├── KeybindsSettingsView.swift
│   │   ├── AppLauncherSettingsView.swift
│   │   └── TilingSettingsView.swift  # Gap/padding config with live preview
│   └── Resources/
│       └── Assets.xcassets
```

## Technical Details

- **Event Capture**: Session-level `CGEventTap` intercepts keyboard events. F18 (remapped Caps Lock) is tracked as a custom modifier — swallowed before any app sees it.
- **Window Management**: macOS Accessibility API (`AXUIElement`) for querying, focusing, resizing, and moving windows. Uses resize-move-resize pattern (from yabai) for cross-screen moves.
- **Window ID Matching**: Single-pass greedy matching with global used-ID tracking. Prevents duplicate CGWindowID assignment for multi-window apps (critical for Finder).
- **Tiling**: Binary Space Partitioning with dwindle layout (split along longer axis). Smart insertion backtracks from deepest-right leaf to shallower leaves when child dimensions would fall below 500px — balances constrained monitors while preserving dwindle on wide ones. Two-pass layout with split ratio adjustment for apps with minimum size constraints. Max depth 3. Split direction overridable per-node via togglesplit.
- **Focus**: Same-app window switching skips `app.activate()` to prevent macOS from refocusing the "main" window. Cross-app uses activate + deferred re-assert.
- **Direction Finding**: Cone-weighted scoring — finds the window most directly along the intended axis, heavily penalizing perpendicular offset.
- **Coordinate System**: NSScreen uses bottom-left origin, AXUIElement uses top-left. Conversion uses primary screen height as reference for all monitors.
- **Auto-Tiling**: Polls for window changes every 1s (catches Cmd+N, close, minimize). Also observes app launch/terminate/hide/unhide notifications.
- **Drag-Swap**: Tracks expected tiled positions. On mouse-up, detects if any window moved >50px from expected position and finds the target slot. Cross-monitor swaps use direct BSP node reference swapping.

## Future Work

### Next Up: Workspace/Desktop Management
The next major feature. Extends `Hypr + 1-9` from monitor switching to full desktop/workspace switching, matching Hyprland's workspace model.

- **`Hypr + N`**: Switch the current monitor to desktop N. Users create desktops manually in macOS (increasing order); each monitor maintains its own set of desktops.
- **`Hypr + Shift + N`**: Move focused window to desktop N. If the target desktop is on the same monitor, the window moves there. If on a different monitor, it moves cross-display.
- **Overflow to next desktop**: When a monitor is completely full (smart insert + split ratio adjustment both say no room), new windows are automatically sent to the next available desktop with a free slot — instead of auto-floating behind tiled windows where they're unreachable via focus-follows-mouse.
- **Implementation notes**: `SpaceManager` already enumerates spaces via CGS private APIs and can map spaces to displays. `CGSManagedDisplaySetCurrentSpace` works for switching. The blocker is `CGSMoveWindowsToManagedSpace` — it updates metadata but doesn't visually move windows cross-display. See `docs/desktop-switching-notes.md` for what's been tried. Approaches still to explore: hide/unhide after CGS move, AX-based repositioning, AppleScript bridge.

### Planned
- **Installer** — DMG distribution and/or Homebrew cask so users don't need Xcode or a developer account.
- **Resize mode** — `Hypr + R` enters resize mode; arrow keys adjust the focused window's BSP split ratio.
- **Scratchpad** — Hyprland-style named scratchpad windows that toggle visibility.
- **Window rules** — Auto-float certain apps (e.g. System Settings), assign apps to specific monitors/desktops.
- **Animations** — Smooth transitions during tiling/swapping.
- **Configurable tiling limits** — Max BSP depth and min slot dimension per monitor in Settings.

## Inspired By

- [Hyprland](https://hyprland.org/) — The Wayland compositor this project aims to bring to macOS
- [yabai](https://github.com/koekeishiya/yabai) — macOS tiling WM (resize-move-resize pattern)
- [AeroSpace](https://github.com/nikitabobko/AeroSpace) — Swift-based macOS tiling WM (virtual workspaces)
- [Amethyst](https://github.com/ianyh/Amethyst) — macOS tiling WM (readback-based layout)
- [skhd](https://github.com/koekeishiya/skhd) — Simple hotkey daemon (event tap approach)

## License

MIT
