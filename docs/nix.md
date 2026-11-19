# Nix and Home Manager

The flake and Home Manager module are community-maintained. They package the
signed, notarized release DMG, so Accessibility trust survives updates. Version
and SHA-256 come from `Casks/hyprmac.rb`. Managed config files need HyprMac
0.25.0 or later; older builds don't reload a re-pointed link.

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

The launchd agent restarts HyprMac after a crash, but not after you quit it. It
runs the copy in `~/Applications/Home Manager Apps` when
`targets.darwin.copyApps` is on, and the store path otherwise. Leave the in-app
"Launch at login" off when you use it. The agent hasn't been tested by the
HyprMac maintainers.

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

## Caps Lock

HyprMac remaps Caps Lock to F18 itself through `hidutil`. With nix-darwin's
`system.keyboard.enableKeyMapping`, don't turn on `remapCapsLockToControl`,
`remapCapsLockToEscape` or `swapCapsLockAndEscape` while `hyprKey` is
`"capsLock"`. Each `darwin-rebuild switch` overwrites that mapping. In System
Settings → Keyboard → Keyboard Shortcuts → Modifier Keys, Caps Lock must stay
"⇪ Caps Lock".
