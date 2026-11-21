# Nix and Home Manager

The flake and Home Manager module are community-maintained. They package the
signed, notarized release DMG, so Accessibility trust survives updates. Version
and SHA-256 come from `Casks/hyprmac.rb`. Managed config files need HyprMac
0.25.0 or later; older builds don't reload a re-pointed link. This flake lands
only after a release that includes that support, so the cask pins 0.25.0 or
later from the start.

## Install

Add `github:zacharytgray/HyprMac` as a flake input. Then either add
`inputs.hyprmac.packages.${pkgs.stdenv.hostPlatform.system}.hyprmac` to
nix-darwin's `environment.systemPackages` (or use `overlays.default` and
`pkgs.hyprmac`), or import `inputs.hyprmac.homeManagerModules.default`:

```nix
programs.hyprmac = {
  enable = true;
  launchd.enable = true;               # start at login; off by default
  extraPackages = [ pkgs.sketchybar ]; # PATH for runCommand and the status hook
  showDockIcon = false;                # null leaves these preferences alone
  showMenuBarIcon = true;

  # becomes ~/Library/Application Support/HyprMac/config.json
  settings = {
    gapSize = 10;
    focusFollowsMouse = true;
    keybinds = [
      { keyCode = 36; modifiers = 1; action.launchApp.bundleID = "com.mitchellh.ghostty"; }
    ];
  };

  # becomes monitor-config.json
  monitorSettings.workspaceMonitors."DELL U3225QE" = [ 1 2 3 4 5 ];
};
```

`settings` and `monitorSettings` are attribute sets written as JSON. See
[Keybinds and actions](keybinds-and-actions.md) for every key. The module adds
`version = 2`, `keybinds = [ ]`, `gapSize = 8`, `outerPadding = 8` and
`enabled = true` for any you leave out. Set `settings.version` to override the
schema version. Missing built-in keybinds are added at load, as for any config.

Turn on `targets.darwin.copyApps`. It keeps a real copy in
`~/Applications/Home Manager Apps`, which is what macOS grants Accessibility
to. Running straight from the store path can hit the macOS 26.3 code signature
problem Home Manager
[worked around](https://github.com/nix-community/home-manager/commit/e82d4a4ecd18363aa2054cbaa3e32e4134c3dbf4).

The launchd agent restarts HyprMac after a crash, but not after you quit it. It
runs the copied app when `copyApps` is on, and the store path otherwise. The
agent hasn't been tested by the HyprMac maintainers.

Only one copy of HyprMac runs at a time: a second copy quits as it starts. So
you can turn on `launchd.enable` while HyprMac is open, and the agent can't
double up with the in-app "Launch at login". One of the two is enough. With
both on, the Settings window may open at login, because the login item's launch
reaches the copy the agent already started; this hasn't been checked on a real
login. A Debug build you made yourself counts as a copy too, so quit the Nix
one before you run it. The single copy needs a HyprMac version after 0.25.1. On 0.25.1 and
earlier, keep "Launch at login" off, and quit HyprMac before the switch that
first turns on `launchd.enable`.

After a switch that updates HyprMac, quit it and open it again. With `copyApps`
the agent isn't restarted, so the old version keeps running.

## Read-only behavior

An empty `settings` or `monitorSettings` leaves that file alone, so Settings
can still save it. A non-empty one becomes a read-only link into `/nix/store`:

- Settings shows a read-only notice. Changes made there apply until the next
  reload, and aren't saved.
- HyprMac reloads both files within about two seconds of a switch. No restart.
- The iCloud sync switch stays off.
- In-app updates are off when HyprMac runs from the store, "Nix Apps" or
  "Home Manager Apps". Update through Nix.

## An existing config file

If `config.json` or `monitor-config.json` already exists as a regular file,
Home Manager stops the switch rather than replace it. Move the file aside, or
run `home-manager switch -b backup`. To carry your current settings over, copy
values from the old file into `settings`.

An iCloud sync link at `config.json` blocks the switch the same way. Turn off
Settings → General → "Sync settings via iCloud" first. That puts a regular file
back at the path, which you can then move aside as above.

## Caps Lock

HyprMac remaps Caps Lock to F18 itself through `hidutil`, and takes the
mapping out again while tiling is paused. With nix-darwin's
`system.keyboard.enableKeyMapping`, don't turn on `remapCapsLockToControl`,
`remapCapsLockToEscape` or `swapCapsLockAndEscape` while `hyprKey` is
`"capsLock"`. Each `darwin-rebuild switch` overwrites that mapping. In System
Settings → Keyboard → Keyboard Shortcuts → Modifier Keys, Caps Lock must stay
"⇪ Caps Lock".
