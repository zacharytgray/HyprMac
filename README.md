# HyprMac

A keyboard-driven tiling window manager for macOS, inspired by [Hyprland](https://hyprland.org/).

Caps Lock becomes a **Hypr** modifier key. BSP dwindle tiling, virtual workspaces, directional focus, window swapping, drag-swap, focus-follows-mouse — no SIP required.

> [!NOTE]
> HyprMac is in active development. Contributions and bug reports welcome.

## Features

- **BSP dwindle tiling** with smart insertion, min-size adaptation, and split ratio auto-adjustment
- **9 virtual workspaces** — switch with `Hypr+1-9`, move windows with `Hypr+Shift+1-9`
- **Directional focus & swap** across monitors
- **Toggle split** to transpose horizontal/vertical
- **Floating toggle** — pop windows out of tiling and back in
- **Drag-swap** — drag a window onto another to swap positions
- **Focus-follows-mouse** (toggleable)
- **App launcher** — bind any key to launch/focus an app
- **Keybind overlay** — `Hypr+K` to see all shortcuts
- **Multi-monitor** with per-monitor workspace assignment
- **Fully configurable** — edit keybinds, app launchers, gaps, and padding in-app or via JSON config

See [`AGENTS.md`](AGENTS.md) for architecture, technical decisions, and config file format.

## Requirements

- macOS 13+ (Ventura or later)
- Xcode 15+ (build from source)
- Accessibility permission (System Settings → Privacy → Accessibility)
- Caps Lock set to "⇪ Caps Lock" in Modifier Keys (not "No Action")

## Installation

```bash
git clone https://github.com/zacharytgray/HyprMac.git
cd HyprMac

brew install xcodegen
xcodegen generate

export DEVELOPMENT_TEAM=YOUR_TEAM_ID
xcodebuild -project HyprMac.xcodeproj -scheme HyprMac -configuration Release \
  -derivedDataPath build DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM build

cp -r build/Build/Products/Release/HyprMac.app /Applications/
```

> **Finding your Team ID**: Run `security find-identity -v -p codesigning` or check Xcode → Settings → Accounts.

### First Launch

1. Open HyprMac — it appears in the menubar
2. Grant Accessibility permission when prompted
3. Relaunch after granting permission

## Keybinds

All keybinds are configurable in Settings (menubar icon → Settings → Keybinds).

### Defaults

| Shortcut | Action |
|---|---|
| `⇪ + ←/→/↑/↓` | Focus window in direction |
| `⇪ + ⇧ + ←/→/↑/↓` | Swap window in direction |
| `⇪ + J` | Toggle split direction |
| `⇪ + ⇧ + T` | Toggle floating/tiling |
| `⇪ + 1-9` | Switch to workspace N |
| `⇪ + ⇧ + 1-9` | Move window to workspace N |
| `⇪ + ⌃ + ←/→` | Move workspace to adjacent monitor |
| `⇪ + K` | Show keybind overlay |
| `⇪ + ↵` | Launch/focus Terminal |

| `⇪⇪` (double-tap) | Warp cursor to menu bar |

### Mouse

| Action | Effect |
|---|---|
| Hover over tiled window | Focus follows mouse |
| Drag window onto another | Swap positions |

### Menu Bar Access

With focus-follows-mouse enabled, moving the mouse to the menu bar can accidentally focus a tiled window along the way. HyprMac handles this two ways:

1. **Menu tracking detection** — FFM is automatically suppressed while any app's menu dropdown is open, so you won't lose the menu once you've clicked it.
2. **Double-tap Caps Lock** — Instantly warps your cursor to the menu bar on the current monitor. Faster than mousing up there, and avoids the focus-switching problem entirely. Configurable in Settings → General (change the action or disable it).

## Virtual Workspaces

HyprMac manages 9 global workspaces in userspace, bypassing macOS Spaces entirely. No SIP required.

- Workspaces are assigned to monitors left-to-right on startup (monitor 1 → ws 1, monitor 2 → ws 2)
- Each workspace remembers its **home monitor** — switching back returns it there
- Switching to a workspace already visible on another monitor focuses that monitor
- Inactive windows are hidden off-screen (1px visible in corner — macOS limitation)

Recommended: use a single macOS Space per monitor.

## Known Limitations

- **1px window sliver** — hidden workspace windows leave a tiny artifact in the screen corner. Also serves as crash recovery.
- **No animation** — workspace switches are instant, matching Hyprland's behavior.
- **Build from source only** — DMG/Homebrew distribution planned.

## Roadmap

- Installer (DMG / Homebrew cask)
- Workspace overflow (auto-send to next workspace when monitor is full)
- Resize mode (`Hypr+R` + arrows)
- Scratchpad windows
- Window rules (auto-float, workspace assignment)
- Animations

## Inspired By

- [Hyprland](https://hyprland.org/) — Wayland compositor, the model for this project
- [yabai](https://github.com/koekeishiya/yabai) — macOS tiling WM
- [AeroSpace](https://github.com/nikitabobko/AeroSpace) — Swift macOS tiling WM with virtual workspaces
- [Amethyst](https://github.com/ianyh/Amethyst) — macOS tiling WM
- [skhd](https://github.com/koekeishiya/skhd) — Hotkey daemon

## License

MIT
