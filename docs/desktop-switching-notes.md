# Desktop/Space Switching — What Worked and What Didn't

## Goal
Hypr+N to switch to Desktop N, Hypr+Shift+N to move focused window to Desktop N.
Desktops map to macOS Spaces across multiple monitors.

## What worked
- CGSCopyManagedDisplaySpaces correctly enumerates all spaces per display
- Space-to-display mapping (displayForSpace, spacesByDisplay) is accurate
- CGSManagedDisplaySetCurrentSpace switches the correct display to the target space
- Window focus + cursor warp for cross-monitor "switching" (when space is already visible)
- Sentinel windows: created and placed on correct spaces, but unreliable for triggering switches

## What didn't work
- CGSMoveWindowsToManagedSpace: windows get assigned to the target space metadata
  but don't visually leave the source display. They overlay on top of the current
  desktop like two spaces stacked. The window server treats them as grouped on
  the target space (they move in unison) but they render on the wrong display.
- CGSRemoveWindowsFromSpaces + CGSAddWindowsToSpaces: same visual bug.
  The space assignment updates but the window physically stays on the source monitor.
- Repositioning window coordinates after CGS move: we set position to the target
  display rect but the window snaps back or stays overlaid.
- The core issue: macOS doesn't support programmatic cross-display window migration
  the way Hyprland does on Wayland. The CGS space APIs update metadata but don't
  trigger the visual transition that Mission Control does when you drag a window
  between spaces.

## Approaches not yet tried
- NSWorkspace.shared.open with activation to force app to front on target space
- AppleScript "move window to desktop N" (Accessibility scripting bridge)
- CGSMoveWindowsToManagedSpace combined with hiding/unhiding the window
- Simulating Mission Control drag via accessibility APIs
- Using CGSSetWindowTransform or similar to force window to new coordinates
  after the space move

## Current state
Feature removed from keybinds. switchDesktop and moveToDesktop action types
still exist in the code but no keybinds trigger them. The CGS private APIs
and SpaceManager display mapping code remain for future use.
