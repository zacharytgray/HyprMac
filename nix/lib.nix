{ lib }:
let
  inherit (lib)
    filter
    filterAttrs
    isAttrs
    isList
    isString
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

  # `SavedConfig.init(from:)` strictly requires these four top-level keys on
  # every load (`HyprMac/Persistence/ConfigStore.swift`); missing optional keys
  # fall back to `UserConfigDefaults`, and missing built-in keybinds are
  # injected at load time by `UserConfig.mergeNewDefaults`.
  coreConfigDefaults = {
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
    {
      cfg,
      managesConfigJson,
    }:
    optionalAttrs cfg.disableUpdateCheck {
      SUEnableAutomaticChecks = false;
    }
    // optionalAttrs managesConfigJson {
      # Keep iCloud sync off while Nix owns `config.json`, otherwise
      # `ConfigStore.ensureICloudSymlinkIntegrity` would replace the store
      # symlink with an iCloud Drive symlink on launch.
      iCloudSyncEnabled = false;
    }
    // optionalAttrs (cfg.showDockIcon != null) {
      inherit (cfg) showDockIcon;
    }
    // optionalAttrs (cfg.showMenuBarIcon != null) {
      inherit (cfg) showMenuBarIcon;
    };

  effectiveHyprKey =
    settings:
    if isAttrs settings && (settings.hyprKey or null) != null && isString settings.hyprKey then
      settings.hyprKey
    else
      "capsLock";

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
        inherit (jsonFormat) type;
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
        inherit (jsonFormat) type;
        default = { };
        example = lib.literalExpression ''
          {
            workspaceMonitors = {
              "Built-in Retina Display" = [ 6 7 8 9 10 ];
              "DELL U3225QE" = [ 1 2 3 4 5 ];
            };
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

      disableUpdateCheck = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Disable Sparkle's automatic background update checks
          (`SUEnableAutomaticChecks = false` in `com.zachgray.HyprMac`
          UserDefaults) since upgrades are managed declaratively through Nix.
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
    effectiveHyprKey
    filterNullsRecursive
    mkSharedOptions
    standardSystemPaths
    ;
}
