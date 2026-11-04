# Status bars

HyprMac can hand its workspace state to a status bar such as
[sketchybar](https://github.com/FelixKratz/SketchyBar): a JSON file written on
every change, a command run after each write, and `hyprmac://` links a bar's
click handler opens. It is off by default.

It is a power-user setting with no switch in Settings. It is set per Mac in
`~/Library/Application Support/HyprMac/monitor-config.json`, the local file
that never syncs over iCloud. Add the two keys to the object already in that
file and keep its other keys:

```json
{
  "maxSplitsPerMonitor": {},
  "disabledMonitors": [],
  "statusExportEnabled": true,
  "statusHookCommand": "sketchybar --trigger hyprmac_change"
}
```

If the file is not there yet, an object with just the two keys works.

Quit HyprMac before the edit and open it again afterwards. HyprMac reads
`monitor-config.json` at launch. Its file watcher follows only `config.json`,
so an edit to this file while HyprMac runs is not picked up. The next
change HyprMac saves (any Settings change) writes its in-memory copy over the
file and drops the edit. To turn the export off, set `statusExportEnabled` to
`false` or remove it, the same way. "Reset all settings…" in Settings → General also turns
it off and clears the command.

With `statusExportEnabled` off or missing, nothing below happens: no file, no
hook, and the links are ignored unless "Allow other apps to control HyprMac"
is on (see `docs/external-control.md`). HyprMac leaves `statusExportEnabled` out of
the file while it is off, and `statusHookCommand` out while it is empty. An
unreadable value costs only that key; the rest of the file still loads. An
older build ignores both keys and drops them the next time it saves the file.
Neither key goes in `config.json`, which can sync to other Macs.

## State file

`~/Library/Application Support/HyprMac/state.json`, replaced atomically (a
temp file renamed over it), so a reader never sees half a file. It is written
off the main thread after a workspace switch on any monitor, a window opening,
closing, moving between workspaces, floating or tiling, focus moving to
another window or monitor, a workspace name change, a monitor connecting or
leaving, and the scratchpad showing or hiding. Changes within 50 ms produce one
write, and a state equal to the last one written is not written again.

When HyprMac quits or tiling pauses, it removes `state.json` and runs the hook
once with the focus variables empty, so a bar can clear itself. The file
comes back with the next write after tiling resumes.

```json
{
  "version": 1,
  "focusedWorkspace": 4,
  "focusedMonitor": "DELL U3225QE",
  "monitors": [
    { "name": "DELL U3225QE", "visibleWorkspace": 4, "focused": true },
    { "name": "Built-in Retina Display", "visibleWorkspace": 2, "focused": false }
  ],
  "workspaces": [
    { "id": 1, "monitor": "DELL U3225QE", "visible": false, "windows": [] },
    { "id": 4, "name": "term", "monitor": "DELL U3225QE", "visible": true,
      "windows": [
        { "id": 123, "app": "Ghostty", "bundleID": "com.mitchellh.ghostty",
          "floating": false, "focused": true }
      ] }
  ],
  "scratchpad": [ { "id": 456, "app": "Notes", "bundleID": "com.apple.Notes" } ],
  "scratchpadVisible": false
}
```

- `workspaces` lists every workspace 1–10 with its home monitor, empty ones
  included. `name` is there only when the workspace has one.
- Windows are those on screen or parked on a hidden workspace. A window that
  closed while its app keeps running, a minimized window and a hidden app's
  windows are left out, as in the menu bar.
- `focusedWorkspace` is the workspace of the focused window. With no focused
  window (an empty workspace was just switched to), it is the one showing on
  the monitor under the cursor.
- Window titles are never written. Monitors are named as macOS names them, so
  two monitors of one model share a name.
- Keys are written sorted. A reader should ignore keys it does not know.

## Hook

After each write HyprMac runs `statusHookCommand` the way a `runCommand`
keybind runs (see `docs/keybinds-and-actions.md`): no shell, so point it at a
script for pipes or `$VAR`. Its environment adds:

| Variable | Value |
|---|---|
| `HYPRMAC_STATE_FILE` | path of `state.json` |
| `HYPRMAC_FOCUSED_WORKSPACE` | `4` |
| `HYPRMAC_FOCUSED_WORKSPACE_NAME` | `term`, empty when unnamed |
| `HYPRMAC_FOCUSED_MONITOR` | `DELL U3225QE` |

One hook runs at a time. A change while it runs is remembered, and the hook
runs once more, with the latest state, when it ends. A hook still running
after 2 s is killed (logged once at `.notice`), so a hung bar never holds
later updates or HyprMac back. Its output goes to `/dev/null`.

## Links

Opened with `open -g` so the bar keeps focus. Each takes a whole number
1–10. Anything else is ignored.

- `hyprmac://workspace?n=4` switches to workspace 4, as Hypr+4 does.
- `hyprmac://focus?workspace=4` switches to workspace 4 and focuses a window
  there. Opened again while a window of workspace 4 has focus, it focuses the
  next window of that workspace, wrapping.

Both also run with "Allow other apps to control HyprMac" on, which adds
`hyprmac://action/…` links for every other action (`docs/external-control.md`).
Both are dropped while tiling is paused, and the switch follows the keybind's
rules (dropped with a beep while displays settle, closes the scratchpad).

## sketchybar example

`hyprmac_change` is a custom event, so add it once in `sketchybarrc`:

```bash
sketchybar --add event hyprmac_change
for ws in 1 2 3 4 5 6 7 8 9 10; do
  sketchybar --add item space.$ws left \
             --subscribe space.$ws hyprmac_change \
             --set space.$ws label="$ws" \
                   script="$CONFIG_DIR/plugins/hyprmac_space.sh $ws" \
                   click_script="open -g 'hyprmac://focus?workspace=$ws'"
done
```

`plugins/hyprmac_space.sh` reads the file with `jq`:

```bash
#!/bin/bash
ws=$1
state=${HYPRMAC_STATE_FILE:-"$HOME/Library/Application Support/HyprMac/state.json"}
read -r focused count name < <(jq -r --argjson ws "$ws" \
  '[.focusedWorkspace == $ws, (.workspaces[] | select(.id == $ws) | (.windows | length), (.name // ""))] | @tsv' \
  "$state")
sketchybar --set "$NAME" label="${name:-$ws}" \
  background.drawing="$([ "$focused" = true ] && echo on || echo off)" \
  drawing="$([ "$focused" = true ] || [ "$count" -gt 0 ] && echo on || echo off)"
```

Then set `statusHookCommand` to `sketchybar --trigger hyprmac_change` as shown at the top.
