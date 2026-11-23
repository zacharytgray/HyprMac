{ lib }:
let
  inherit (lib)
    any
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

  # the null-strip would turn `match = null` into no match, and the app reads
  # a rule with no match as covering the whole app. JSON `"match": null` drops
  # the rule; here it stops the switch with a message instead
  checkFloatingRules =
    settings:
    let
      rules = settings.floatingRules or null;
      nullMatch = rule: isAttrs rule && rule ? match && rule.match == null;
    in
    if isList rules && any nullMatch rules then
      throw "programs.hyprmac.settings.floatingRules: a rule has `match = null`. Leave `match` out for a rule that covers the whole app, or set `match.titleIs` or `match.titleContains`."
    else
      settings;

  buildConfigJson =
    settings:
    let
      cleaned = filterNullsRecursive (checkFloatingRules settings);
    in
    if cleaned == { } then null else coreConfigDefaults // cleaned;

  buildMonitorConfigJson =
    monitorSettings:
    let
      cleaned = filterNullsRecursive monitorSettings;
    in
    if cleaned == { } then null else cleaned;

  # The app reads `showMenuBarIcon` only once, to pick a first `menuBarStyle`,
  # so the deprecated option is written as `menuBarStyle` instead.
  # `menuBarStyle` wins when both are set.
  resolveMenuBarStyle =
    cfg:
    if cfg.menuBarStyle != null then
      cfg.menuBarStyle
    else if cfg.showMenuBarIcon == null then
      null
    else if cfg.showMenuBarIcon then
      "full"
    else
      "hidden";

  buildUserDefaults =
    cfg:
    let
      menuBarStyle = resolveMenuBarStyle cfg;
    in
    optionalAttrs (cfg.showDockIcon != null) {
      inherit (cfg) showDockIcon;
    }
    // optionalAttrs (menuBarStyle != null) {
      inherit menuBarStyle;
    }
    // optionalAttrs (cfg.updatesManagedExternally != null) {
      HyprMacUpdatesManagedExternally = cfg.updatesManagedExternally;
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
            floatingRules = [
              {
                bundleID = "us.zoom.xos";
                action = "float";
                match.titleIs = "Zoom Meeting";
              }
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

      menuBarStyle = mkOption {
        type = types.nullOr (
          types.enum [
            "full"
            "compact"
            "hidden"
          ]
        );
        default = null;
        description = ''
          HyprMac's menu bar item (`com.zachgray.HyprMac` `menuBarStyle`
          preference): `"full"`, `"compact"` or `"hidden"`. `null` leaves the
          preference unmanaged.
        '';
      };

      updatesManagedExternally = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = ''
          Turn off HyprMac's in-app updater for a copy something else updates,
          such as Homebrew with `package = null` (`com.zachgray.HyprMac`
          `HyprMacUpdatesManagedExternally` preference). A copy installed from
          the Nix store already has it off. Quit and reopen HyprMac after a
          switch that changes it. `null` leaves the preference unmanaged.
        '';
      };

      showMenuBarIcon = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = ''
          Deprecated: use `menuBarStyle`. `true` sets `menuBarStyle` to
          `"full"` and `false` to `"hidden"`, unless `menuBarStyle` is set.
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
    resolveMenuBarStyle
    standardSystemPaths
    ;
}
