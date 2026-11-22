{ lib }:
let
  inherit (lib)
    filter
    filterAttrs
    isAttrs
    isList
    mapAttrs
    mkOption
    optionalAttrs
    types
    ;

  # Recursively strip `null` attributes and `null` list elements, matching
  # Home Manager and nix-darwin `pkgs.formats` module conventions.
  filterNullsRecursive =
    value:
    if isAttrs value then
      mapAttrs (_: filterNullsRecursive) (filterAttrs (_: v: v != null) value)
    else if isList value then
      map filterNullsRecursive (filter (v: v != null) value)
    else
      value;

  # `SavedConfig.init(from:)` strictly requires the four keys after `version`
  # on every load (`HyprMac/Persistence/ConfigStore.swift`); missing optional
  # keys fall back to `UserConfigDefaults`, and missing built-in keybinds are
  # injected at load time by `UserConfig.mergeNewDefaults`. `version` is the
  # current schema (`ConfigMigration.currentVersion`). Without it the file
  # reads as version 1, and the v1 keybind migrations run on every load.
  # Set `settings.version` to override it.
  coreConfigDefaults = {
    version = 2;
    keybinds = [ ];
    gapSize = 8;
    outerPadding = 8;
    enabled = true;
  };

  buildConfigJson =
    settings:
    let
      cleaned = filterNullsRecursive settings;
    in
    if cleaned == { } then null else coreConfigDefaults // cleaned;

  buildMonitorConfigJson =
    monitorSettings:
    let
      cleaned = filterNullsRecursive monitorSettings;
    in
    if cleaned == { } then null else cleaned;

  buildUserDefaults =
    cfg:
    optionalAttrs (cfg.showDockIcon != null) {
      inherit (cfg) showDockIcon;
    }
    // optionalAttrs (cfg.showMenuBarIcon != null) {
      inherit (cfg) showMenuBarIcon;
    };

  standardSystemPaths = [
    "/opt/homebrew/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
    "/usr/sbin"
    "/sbin"
  ];

  mkSharedOptions =
    { jsonFormat }:
    {
      settings = mkOption {
        type = types.attrsOf jsonFormat.type;
        default = { };
        example = lib.literalExpression ''
          {
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
            keybinds = [
              {
                keyCode = 36;
                modifiers = 1;
                action = {
                  launchApp = {
                    bundleID = "com.mitchellh.ghostty";
                  };
                };
              }
            ];
          }
        '';
        description = ''
          Configuration serialized directly to
          `~/Library/Application Support/HyprMac/config.json` as a read-only
          `/nix/store` symlink.

          See `docs/keybinds-and-actions.md` for supported keys and the JSON
          keybind format. When left empty (`{}`), `config.json` is not managed
          by Nix so HyprMac's in-app Settings remain writable.
        '';
      };

      monitorSettings = mkOption {
        type = types.attrsOf jsonFormat.type;
        default = { };
        example = lib.literalExpression ''
          {
            workspaceMonitors = {
              "Built-in Retina Display" = [ 6 7 8 9 10 ];
              "DELL U3225QE" = [ 1 2 3 4 5 ];
            };
            # wins over workspaceMonitors when exactly these displays are connected
            workspaceMonitorsPerDisplaySet = [
              {
                displays = [ "DELL U3225QE" "LG HDR 4K" ];
                workspaceMonitors = {
                  "DELL U3225QE" = [ 1 2 3 4 5 6 ];
                  "LG HDR 4K" = [ 7 8 9 10 ];
                };
              }
            ];
            outerPaddingPerMonitor = {
              "DELL U3225QE" = {
                top = 36;
              };
            };
            statusExportEnabled = true;
            statusHookCommand = "/etc/profiles/per-user/alice/bin/sketchybar --trigger hyprmac_change";
            externalControlEnabled = true;
          }
        '';
        description = ''
          Per-machine monitor, status-bar export, and external-control
          configuration serialized directly to
          `~/Library/Application Support/HyprMac/monitor-config.json` as a
          read-only `/nix/store` symlink.

          See `docs/keybinds-and-actions.md`, `docs/status-bar.md`, and
          `docs/external-control.md` for supported keys. When left empty (`{}`),
          `monitor-config.json` is not managed by Nix.
        '';
      };

      showDockIcon = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = ''
          Whether to show HyprMac in the macOS Dock (`com.zachgray.HyprMac`
          `showDockIcon` preference). `null` leaves the preference unmanaged.
        '';
      };

      showMenuBarIcon = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = ''
          Whether to show HyprMac's menu bar icon (`com.zachgray.HyprMac`
          `showMenuBarIcon` preference). `null` leaves the preference unmanaged.
        '';
      };
    };
in
{
  inherit
    buildConfigJson
    buildMonitorConfigJson
    buildUserDefaults
    coreConfigDefaults
    filterNullsRecursive
    mkSharedOptions
    standardSystemPaths
    ;
}
