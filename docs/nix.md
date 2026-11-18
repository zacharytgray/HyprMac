# Nix and Home Manager

HyprMac ships a Nix flake (`flake.nix`) for macOS (`aarch64-darwin` and
`x86_64-darwin`). It packages the signed, notarized universal release DMG so
macOS Accessibility permissions stay bound to the upstream Developer ID team
across updates, and provides a Home Manager module (`programs.hyprmac`) for
declarative configuration and `launchd` startup.

## Flake outputs

- `packages.<system>.hyprmac` (`default`): unpacks `HyprMac.app` into
  `$out/Applications/HyprMac.app` with its upstream Developer ID signature and
  notarization intact. Version and SHA-256 come directly from
  `Casks/hyprmac.rb`.
- `overlays.default`: adds `pkgs.hyprmac`.
- `homeManagerModules.hyprmac` (`default`): defines `programs.hyprmac` for
  Home Manager on macOS (standalone or imported inside `nix-darwin`).

## Adding the flake input

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hyprmac = {
      url = "github:zacharytgray/HyprMac";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
```

If you use `nix-darwin` without Home Manager and only want the app installed in
`/Applications/Nix Apps`, add `inputs.hyprmac.packages.${pkgs.stdenv.hostPlatform.system}.hyprmac`
to `environment.systemPackages` (or apply `inputs.hyprmac.overlays.default` and
add `pkgs.hyprmac`).

## Home Manager (`programs.hyprmac`)

Import `inputs.hyprmac.homeManagerModules.default` in your Home Manager modules
(either in standalone `homeConfigurations` or under `home-manager.sharedModules`
/ `home-manager.users.<name>.imports` in `nix-darwin`):

```nix
{ inputs, pkgs, ... }:
{
  imports = [
    inputs.hyprmac.homeManagerModules.default
  ];

  programs.hyprmac = {
    enable = true;

    # Start HyprMac at login via a GUI launchd LaunchAgent.
    launchd.enable = true;

    # Make Nix-installed CLI tools available to `runCommand` keybinds and
    # `statusHookCommand` without hardcoding /nix/store paths.
    extraPackages = [
      pkgs.sketchybar
      pkgs.jq
    ];

    # Written to ~/Library/Application Support/HyprMac/config.json.
    settings = {
      hyprKey = "capsLock";
      gapSize = 10;
      outerPadding = 12;
      focusFollowsMouse = true;
      excludedBundleIDs = [
        "com.apple.FaceTime"
        "com.apple.systempreferences"
      ];
      workspaceNames = {
        "1" = "code";
        "2" = "web";
      };
      windowRules = [
        {
          bundleID = "com.mitchellh.ghostty";
          workspace = 1;
        }
      ];
      keybinds = [
        # Hypr + Return -> Launch Ghostty
        {
          keyCode = 36;
          modifiers = 1;
          action = {
            launchApp = {
              bundleID = "com.mitchellh.ghostty";
            };
          };
        }
        # Hypr + Ctrl + Shift + 3 -> Move window to workspace 3 and follow
        {
          keyCode = 20;
          modifiers = 11;
          action = {
            moveToWorkspaceAndFollow = {
              _0 = 3;
            };
          };
        }
      ];
    };

    # Written to ~/Library/Application Support/HyprMac/monitor-config.json.
    monitorSettings = {
      workspaceMonitors = {
        "DELL U3225QE" = [ 1 2 3 4 5 ];
        "Built-in Retina Display" = [ 6 7 8 9 10 ];
      };
      outerPaddingPerMonitor = {
        "DELL U3225QE" = {
          top = 36;
        };
      };
      statusExportEnabled = true;
      statusHookCommand = "sketchybar --trigger hyprmac_change";
      externalControlEnabled = true;
    };
  };
}
```

### Options summary

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `programs.hyprmac.enable` | `bool` | `false` | Enable HyprMac installation and configuration. |
| `programs.hyprmac.package` | `nullOr package` | `pkgs.hyprmac` | Package to install (`null` skips installing the app bundle). |
| `programs.hyprmac.extraPackages` | `listOf package` | `[ ]` | Extra packages prepended to the launchd agent's `PATH`. |
| `programs.hyprmac.launchd.enable` | `bool` | `false` | Manage a `gui` LaunchAgent (`org.nix-community.home.hyprmac`). |
| `programs.hyprmac.launchd.keepAlive` | `bool` | `true` | Keep the LaunchAgent alive across exits. |
| `programs.hyprmac.settings` | JSON attrset | `{ }` | Serialized to `~/Library/Application Support/HyprMac/config.json`. |
| `programs.hyprmac.monitorSettings` | JSON attrset | `{ }` | Serialized to `~/Library/Application Support/HyprMac/monitor-config.json`. |
| `programs.hyprmac.showDockIcon` | `nullOr bool` | `null` | Set `showDockIcon` in `com.zachgray.HyprMac` `UserDefaults`. |
| `programs.hyprmac.showMenuBarIcon` | `nullOr bool` | `null` | Set `showMenuBarIcon` in `com.zachgray.HyprMac` `UserDefaults`. |
| `programs.hyprmac.disableUpdateCheck` | `bool` | `true` | Set `SUEnableAutomaticChecks = false` so Sparkle does not prompt for in-app updates. |

## How declarative JSON config works

`settings` and `monitorSettings` translate directly to JSON with no intermediate
DSL:

- **Unmanaged when empty.** Leaving `settings = { }` (or `monitorSettings = { }`)
  does not create a symlink, so HyprMac's Settings window can still read and
  write that file normally.
- **Read-only store symlinks when set.** Once `settings` or `monitorSettings`
  is non-empty, Home Manager symlinks the corresponding file into `/nix/store`.
  Changes made in the Settings UI will not be saved to disk while Nix owns the
  file, and `iCloudSyncEnabled` is forced to `false` in `UserDefaults` so iCloud
  sync does not replace the store symlink on launch.
- **Partial `settings` work out of the box.** `SavedConfig` strictly requires
  `keybinds`, `gapSize`, `outerPadding`, and `enabled` on load. When `settings`
  is non-empty, the module fills defaults for any of those four keys you omit
  (`keybinds = [ ]`, `gapSize = 8`, `outerPadding = 8`, `enabled = true`), and
  at runtime HyprMac's `UserConfig.mergeNewDefaults` populates any built-in
  keybind whose action is not already in `keybinds` (unless you already bound
  its chord to something else).
- **Schema reference.** See [Keybinds and actions](keybinds-and-actions.md) for
  all `config.json` and `monitor-config.json` fields, Carbon `keyCode` numbers,
  `modifiers` bitmasks (`1` Hypr, `2` Shift, `4` Option, `8` Control,
  `16` Command), and the frozen `Action` JSON wire keys. See
  [Status bars](status-bar.md) and [Control from other apps](external-control.md)
  for `statusExportEnabled`, `statusHookCommand`, and `externalControlEnabled`.
- **Automatic reload on switch.** When `launchd.enable = true`, changing either
  JSON file triggers `launchctl kickstart -k` during `home-manager switch`, so
  both `config.json` and launch-only `monitor-config.json` updates take effect
  immediately.

## macOS permissions and Caps Lock

1. **Accessibility permission:** On first launch, grant HyprMac permission in
   **System Settings → Privacy & Security → Accessibility** (the app bundle is
   synced to `~/Applications/Home Manager Apps/HyprMac.app` by Home Manager).
2. **Caps Lock in macOS Settings:** When `hyprKey` is `"capsLock"` (the
   default), leave Caps Lock set to **"⇪ Caps Lock"** in **System Settings →
   Keyboard → Keyboard Shortcuts → Modifier Keys** for every connected keyboard.
   Never set it to **"No Action"** — that hides Caps Lock from HyprMac.
3. **`nix-darwin` keyboard remapping:** HyprMac remaps Caps Lock to F18 itself
   through `hidutil`. If you use `nix-darwin` with
   `system.keyboard.enableKeyMapping = true`, do not enable
   `remapCapsLockToControl`, `remapCapsLockToEscape`, or `swapCapsLockAndEscape`
   while `hyprKey` is `"capsLock"`, because `darwin-rebuild switch` overwrites
   the IOKit `UserKeyMapping` table.
4. **Launch at login:** When `programs.hyprmac.launchd.enable = true`, leave
   HyprMac's in-app "Launch at login" toggle off so `launchd` and `SMAppService`
   do not both start the app.
