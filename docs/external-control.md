# Control from other apps

Other apps can run HyprMac actions by opening a `hyprmac://action/…` link.
Anything that can run a shell command works: BetterTouchTool, LeaderKey,
Raycast, Karabiner-Elements, skhd, a script.

```sh
open -g 'hyprmac://action/cycleWorkspace?delta=1'
```

`-g` keeps the calling app in front.

## Turning it on

Settings → General → System → "Allow other apps to control HyprMac". It is
off by default. While it is off, every action link is ignored.

The setting is per Mac. It is saved as `externalControlEnabled` in
`~/Library/Application Support/HyprMac/monitor-config.json`, which never
syncs over iCloud, so turning it on here does not turn it on for your other
Macs. Off writes no key.

## Links

A link runs exactly like the keybind for the same action. While tiling is
paused, only `toggleTiling`, `showKeybinds` and `showWorkspaceOverview` run.
While a display transition is pending, a workspace action, `restoreLayout` and
`retileAll` are dropped with a beep. A workspace action closes the scratchpad first, except
`moveToNextEmptyWorkspace`, which beeps and does nothing while it is up.

| Link | Does |
|---|---|
| `focusDirection?dir=left` | focus the window to the left (`left`, `right`, `up`, `down`) |
| `swapDirection?dir=left` | swap with the window to the left |
| `resizeDirection?dir=left` | move the nearest split one step left |
| `moveWindowToMonitor?dir=left` | move the window to the monitor on the left |
| `switchWorkspace?n=3` | go to workspace 3 (1–10) |
| `moveToWorkspace?n=3` | send the window to workspace 3 |
| `moveToWorkspaceAndFollow?n=3` | send the window to workspace 3 and go there |
| `cycleWorkspace?delta=1` | next occupied workspace on this monitor (`-1` for previous) |
| `toggleFloating` | float or tile the focused window |
| `toggleSplit` | flip the split direction |
| `showKeybinds` | open the keybind list (Hypr+K) |
| `showWorkspaceOverview` | open the workspace overview |
| `focusMenuBar` | move the pointer to the menu bar |
| `focusFloating` | cycle focus through floating windows |
| `moveToNextEmptyWorkspace` | move the window to the next empty workspace |
| `closeWindow` | close the focused window |
| `toggleScratchpad` | show or hide the scratchpad |
| `moveToScratchpad` | send the window to the scratchpad |
| `toggleTiling` | pause or resume tiling |
| `restoreLayout` | restore the saved layout |
| `retileAll` | retile every workspace |

Each link starts with `hyprmac://action/`. Names and `dir` values ignore
case. Extra query keys are ignored, so a tool can tag its links. A wrong
name, a missing or repeated argument, or a value out of range does nothing
and logs `hyprmac:// link not understood: <link>` at `.notice`
(`docs/debugging.md` has the log commands).

The names are frozen once shipped, the same as the keybind JSON keys. They
are the action names, not the legacy JSON keys: use `switchWorkspace`, not
`switchDesktop`.

### Not available

`runCommand`, `launchApp` and `saveLayout` have no link. A web page can open
a `hyprmac://` link once the browser asks you, so no link may run a program
or overwrite saved state.

## Examples

**Trackpad swipes (BetterTouchTool).** Add a three-finger swipe left and
right, each with a "run terminal command" action:

```sh
open -g 'hyprmac://action/cycleWorkspace?delta=1'    # swipe left
open -g 'hyprmac://action/cycleWorkspace?delta=-1'   # swipe right
```

Move macOS's own swipe between full-screen apps to four fingers, or turn it
off (System Settings → Trackpad → More Gestures), so both don't fire.

**LeaderKey or Raycast.** Give a key sequence or a script command any line
from the table:

```sh
open -g 'hyprmac://action/switchWorkspace?n=4'
open -g 'hyprmac://action/toggleScratchpad'
```

## Status bar links

The two older links, `hyprmac://workspace?n=4` and
`hyprmac://focus?workspace=4`, run with either this setting or the status
bar export on. See `docs/status-bar.md`.
