# HyprMac

**A keyboard-driven tiling window manager for macOS, inspired by [Hyprland](https://hyprland.org).**
Free, open source, and the first real job your Caps Lock key has ever had.

[![Watch the HyprMac demo](docs/screenshots/demo-card.jpg)](https://hyprmac.app/hyprmac-demo-github.mp4)

**▶ [Watch the one-minute demo](https://hyprmac.app/hyprmac-demo-github.mp4)** ·
**[Try it in your browser](https://hyprmac.app/#try)** ·
**[hyprmac.app](https://hyprmac.app)**

## What it does

If your Mac usually looks like a pile of windows stacked on top of each other, and the one you
want is always at the bottom, HyprMac is for you.

- **Windows arrange themselves.** Open an app and it slots into a tidy tiled layout. No
  dragging, no resizing, no digging.
- **Your keyboard drives.** Hold Caps Lock, which becomes your **Hypr** key out of the box (there
  are a bunch of alternatives!), and tap an arrow to jump between windows. Add Shift to swap
  them. Tap a number to switch workspaces.
- **You can't get lost.** Forgot a shortcut? **Hypr + K** shows every one of them.

A handful of keys covers the basics, and most people have them down in a few minutes. When you
want more, every keybind is remappable and you can point keys at your own scripts.

## The five keys to know

| Keys | What happens |
|------|--------------|
| `Hypr + ←/→/↑/↓` | Move between windows |
| `Hypr + Shift + ←/→/↑/↓` | Swap windows around |
| `Hypr + 1–9` / `Hypr + 0` | Jump to workspace 1–9 / 10 |
| `Hypr + Return` | Open Terminal |
| `Hypr + K` | Show every keybind |

## Install

Homebrew:

```sh
brew trust --cask zacharytgray/hyprmac/hyprmac
brew install --cask zacharytgray/hyprmac/hyprmac
```

Homebrew refuses to load casks from third-party taps until you trust them. The first line trusts
only the HyprMac cask, which also lets `brew upgrade --cask hyprmac` work later.

Or grab the DMG: [HyprMac.dmg](https://github.com/zacharytgray/HyprMac/releases/latest/download/HyprMac.dmg),
open it, and drag HyprMac to Applications. Older versions live on the
[releases page](https://github.com/zacharytgray/HyprMac/releases).

Then follow the [install guide](https://hyprmac.app/guides/install/) for first-run setup,
permissions, and the recommended macOS settings.

### Requirements

- macOS 13 (Ventura) or later
- Accessibility permission, in System Settings → Privacy & Security → Accessibility. HyprMac uses
  the Accessibility APIs only, so there's no need to disable System Integrity Protection.
- For the default Caps Lock Hypr key: Caps Lock must stay set to **"⇪ Caps Lock"** in System
  Settings → Keyboard → Keyboard Shortcuts → Modifier Keys, not "No Action". The pane is per
  keyboard, so check each one you use. HyprMac remaps Caps Lock to F18 itself.
- The same holds if Option or Command is your Hypr key: leave it on its default there.
  Backslash and F13–F20 are not in that pane and need nothing.
- macOS gives apps no way to read that setting, so HyprMac shows this as a reminder in
  onboarding and in Settings → Keys, with an Open Keyboard Settings button.

## For Hyprland folks

You'll feel at home. The differences are mostly macOS being macOS:

- **Tiling:** BSP dwindle, like Hyprland's default layout. New windows split the focused one,
  and **Hypr + J** flips the split direction. Drag a tiled window onto another tile's edge to
  insert it there, or hold Hypr while dragging to swap the two.
- **Workspaces:** ten of them (keys 1–9 and 0), plus a scratchpad and an overview on
  **Hypr + O**. macOS has no public API for this, so HyprMac keeps its own virtual workspaces and
  hides the other workspaces' windows when you switch.
- **Hypr + F:** native macOS fullscreen spawns its own Space and wrecks the layout, so HyprMac
  gives the window a dedicated empty workspace on its display instead.
- **Focus follows mouse:** there if you want it, with an adjustable hover rate.
- **Hypr key:** Caps Lock by default. Settings → Keys also offers backslash, F13–F20, and
  Option or Command on either side. If you pick the left Option or Command key, that key plus
  a key HyprMac uses goes to HyprMac, so type shortcuts like ⌘S or ⌘T with the right-hand
  key. Shift and Control are not offered because many default shortcuts add them to Hypr. Tab
  and backtick are not offered because Hypr+Tab, Hypr+Shift+Tab, and Hypr+` are default
  shortcuts. A config that already uses one of these keys keeps working, and Settings → Keys
  says why it is no longer recommended.
- **Config:** everything, including the Hypr key itself, lives in Settings and is saved as JSON
  at `~/Library/Application Support/HyprMac/config.json`. The schema is in
  [Keybinds and actions](docs/keybinds-and-actions.md).
- **Your own tools:** Settings → Keys → Add → Command… binds a chord to any program or script.
  It runs directly, not through a shell, so keep pipes and redirects inside a script.

## All default keybinds

Everything below is configurable in Settings → Keys. The full reference lives at
[hyprmac.app/guides/keybinds](https://hyprmac.app/guides/keybinds/).

| Shortcut | Action |
|----------|--------|
| `Hypr + ←/→/↑/↓` | Focus window in direction |
| `Hypr + Shift + ←/→/↑/↓` | Swap window in direction |
| `Hypr + Ctrl + ←/→` | Move window to adjacent monitor |
| `Hypr + Ctrl + Shift + ←/→/↑/↓` | Resize focused window in direction |
| `Hypr + 1–9` / `Hypr + 0` | Switch to workspace 1–9 / workspace 10 |
| `Hypr + Shift + 1–9` / `Hypr + Shift + 0` | Move window to workspace 1–9 / workspace 10 |
| `Hypr + Ctrl + Shift + 1–9` / `Hypr + Ctrl + Shift + 0` | Move window to workspace 1–9 / 10 and switch there with it |
| `Hypr + Tab` / `Hypr + Shift + Tab` | Cycle occupied workspaces on this monitor |
| `Hypr + F` | Move window to a dedicated workspace on its display |
| `Hypr + T` | Toggle floating and tiled |
| `Hypr + Shift + T` | Cycle focus through floating windows |
| `Hypr + J` | Toggle split direction |
| `Hypr + S` / `Hypr + Shift + S` | Toggle scratchpad / send window to scratchpad |
| `Hypr + W` | Close window |
| `Hypr + P` | Pause or resume tiling |
| `Hypr + K` | Show the keybind overlay |
| `Hypr + O` | Show workspace overview |
| `Hypr + Ctrl + S` / `Hypr + Ctrl + R` | Save / restore the layout for this display setup |
| `Hypr + Return` | Launch or focus Terminal |
| ``Hypr + ` `` | Warp the cursor to the menu bar |

## Saved layouts

**Hypr + Ctrl + S** saves which workspace each tiled window is on and how each workspace is
split, across every monitor, for the displays you have connected right now. **Hypr + Ctrl + R**
puts all of it back. Restore only moves windows that are open; it doesn't reopen closed apps,
and a saved window that isn't open is skipped. A HUD like the workspace switch one says whether
the layout was saved, restored, or only partly restored.

HyprMac also saves on its own just before your displays change, and restores when you return to
a display setup it has saved. To restore at launch too, turn on "Restore saved layout at launch"
in Settings → General.

Saved layouts stay on this Mac in `~/Library/Application Support/HyprMac/layout-snapshots.json`.
The file keeps window titles so it can tell windows apart. To clear it, quit HyprMac and delete
the file, plus `layout-snapshots.json.unreadable` if it exists. Setups with the same monitor
models at the same resolutions share one saved layout, however they are arranged.

## The reality of macOS

macOS was not built to let other apps manage its windows, and every tiling window manager on the
Mac is working against that. Some apps push back, and now and then a window will insist on doing
its own thing. HyprMac is in active development and very usable day to day. When something
misbehaves, [open an issue](https://github.com/zacharytgray/HyprMac/issues) and tell me about it.

## Updating

HyprMac checks for updates on its own through Sparkle and offers to install them, or use the
menu bar icon → "Check for Updates...". Homebrew installs can run `brew upgrade --cask hyprmac`.
After any update, macOS may ask you to re-grant Accessibility permission, because the signature
changes with each release.

## Build from source

```sh
git clone https://github.com/zacharytgray/HyprMac.git
cd HyprMac

brew install xcodegen
xcodegen generate

export DEVELOPMENT_TEAM=YOUR_TEAM_ID
xcodebuild -project HyprMac.xcodeproj -scheme HyprMac -configuration Debug \
  -derivedDataPath build DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM build

cp -r build/Build/Products/Debug/HyprMac.app /Applications/
```

## Docs

- [Architecture](docs/architecture.md): subsystems, ownership rules, threading
- [Tiling algorithm](docs/tiling-algorithm.md): BSP dwindle, smart insert, two-pass layout
- [Keybinds and actions](docs/keybinds-and-actions.md): the `Action` enum and its JSON schema
- [Debugging](docs/debugging.md): Console filters, verbose logging, common recipes
- [Release pipeline](docs/release.md): how a release is built, signed, and published

## Contributing

Bug reports, ideas, and pull requests are all welcome. Before you open a pull request, run the
test gate:

```sh
./scripts/test-isolated.sh --debug-variant
```

## Inspired by

- [Hyprland](https://hyprland.org): the Wayland compositor this project takes after
- [yabai](https://github.com/koekeishiya/yabai): macOS tiling window manager
- [AeroSpace](https://github.com/nikitabobko/AeroSpace): Swift tiling window manager with virtual workspaces
- [Amethyst](https://github.com/ianyh/Amethyst): macOS tiling window manager
- [skhd](https://github.com/koekeishiya/skhd): hotkey daemon

## License

[MIT](LICENSE)
