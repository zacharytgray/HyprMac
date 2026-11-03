# Why workspaces are virtual

CGS private APIs do not work for cross-display moves without disabling SIP,
and yabai's approach needs SIP disabled for Dock.app injection. HyprMac uses
AeroSpace's model instead: workspaces live entirely in userspace, and hidden
windows park off to one side. `docs/architecture.md` "Workspaces" describes how.

## Why not CGS private APIs

- `CGSMoveWindowsToManagedSpace` updates metadata but does not visually move
  windows cross-display.
- `CGSRemoveWindowsFromSpaces` + `CGSAddWindowsToSpaces` has the same visual bug.
- The fix (calling from Dock.app context) requires SIP partially disabled.
- `CGSManagedDisplaySetCurrentSpace` works for switching but does not help
  with window movement.

## Tradeoffs

- A 1 px window sliver stays visible in a screen corner.
- macOS Spaces are bypassed. Use one Space per monitor.
- There is no switch animation.
