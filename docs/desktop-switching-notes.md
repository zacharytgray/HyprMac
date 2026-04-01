# Desktop/Space Switching — Implementation Notes

## Goal
Hyprland-style workspaces on macOS: `Hypr+N` to switch workspace, `Hypr+Shift+N` to move window.

## Approach: Virtual Workspaces (AeroSpace-style)

After investigating CGS private APIs (which don't work for cross-display moves without SIP disabled)
and yabai's approach (requires SIP disabled for Dock.app injection), we adopted AeroSpace's virtual
workspace model: manage workspaces entirely in userspace via off-screen window hiding.

### How it works
- 9 global workspaces, each visible on at most one monitor at a time
- At startup, workspaces are assigned left-to-right: monitor 1 = ws1, monitor 2 = ws2
- Each workspace tracks its "home screen" — the monitor it was last displayed on
- Switching to an invisible workspace returns it to its home screen, not the cursor's screen
- Inactive workspace windows are hidden at the bottom-right corner of their screen (1px visible)
- Tiling engine uses explicit screen param from workspace→monitor mapping, not window physical position

### Why not CGS private APIs?
- `CGSMoveWindowsToManagedSpace` updates metadata but doesn't visually move windows cross-display
- `CGSRemoveWindowsFromSpaces` + `CGSAddWindowsToSpaces` has the same visual bug
- The fix (calling from Dock.app context) requires SIP partially disabled (yabai's approach)
- `CGSManagedDisplaySetCurrentSpace` works for switching but doesn't help with window movement

### Known tradeoffs
- 1px window sliver visible in screen corner (macOS won't allow fully off-screen windows)
- macOS Spaces are bypassed entirely — use 1 Space per monitor
- No switch animation (instant, like Hyprland)

### Key design decisions
- Cursor position determines the "current screen" for all workspace operations (focused window
  can be stale after switching to an empty workspace)
- Windows on inactive workspaces are kept in `knownWindowIDs` even when they disappear from
  `getAllWindows()` — prevents workspace reassignment drift
- `workspaceHomeScreen` dict tracks where each workspace was last shown, ensuring workspaces
  return to their monitor instead of following the cursor
- `SpaceManager` is still used for space enumeration and window-to-space queries but not for
  workspace switching
