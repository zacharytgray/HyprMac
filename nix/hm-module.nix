{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  inherit (lib)
    concatStringsSep
    makeBinPath
    mkEnableOption
    mkIf
    mkOption
    optional
    types
    ;

  cfg = config.programs.hyprmac;
  hyprmacLib = import ./lib.nix { inherit lib; };
  jsonFormat = pkgs.formats.json { };

  defaultPackage = pkgs.hyprmac or (pkgs.callPackage ./package.nix { });

  configJsonData = hyprmacLib.buildConfigJson cfg.settings;
  monitorConfigJsonData = hyprmacLib.buildMonitorConfigJson cfg.monitorSettings;
  userDefaults = hyprmacLib.buildUserDefaults cfg;

  # With `targets.darwin.copyApps`, Home Manager keeps a real copy of the app
  # under ~/Applications, and that copy is the one macOS grants Accessibility
  # to. Older Home Manager releases have no such option.
  copiesApps =
    lib.hasAttrByPath [ "targets" "darwin" "copyApps" ] options
    && config.targets.darwin.copyApps.enable;

  appPath =
    if copiesApps then
      "${config.home.homeDirectory}/${config.targets.darwin.copyApps.directory}/HyprMac.app"
    else
      "${cfg.package}/Applications/HyprMac.app";

  agentPath = concatStringsSep ":" (
    optional (cfg.extraPackages != [ ]) (makeBinPath cfg.extraPackages)
    ++ [
      "${config.home.profileDirectory}/bin"
      "/etc/profiles/per-user/${config.home.username}/bin"
      "/run/current-system/sw/bin"
      "/nix/var/nix/profiles/default/bin"
    ]
    ++ hyprmacLib.standardSystemPaths
  );
in
{
  options.programs.hyprmac = {
    enable = mkEnableOption "HyprMac tiling window manager";

    package = mkOption {
      type = types.nullOr types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "pkgs.hyprmac";
      description = ''
        The HyprMac package to install. Set to `null` if HyprMac is already
        installed outside Home Manager (for example via `nix-darwin` or
        Homebrew).
      '';
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.sketchybar pkgs.jq ]";
      description = ''
        Extra packages added to `PATH` for the HyprMac launchd agent so bare
        commands in `runCommand` keybinds and `statusHookCommand` resolve.
      '';
    };

    launchd.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Start HyprMac at login with a launchd agent. launchd restarts it
        after a crash, but not after you quit it from the menu.

        When enabled, leave HyprMac's in-app "Launch at login" off so
        startup is managed from one place.
      '';
    };
  }
  // hyprmacLib.mkSharedOptions { inherit jsonFormat; };

  config = mkIf cfg.enable {
    assertions = [
      (lib.hm.assertions.assertPlatform "programs.hyprmac" pkgs lib.platforms.darwin)
      {
        assertion = cfg.launchd.enable -> cfg.package != null;
        message = "`programs.hyprmac.package` must not be `null` when `programs.hyprmac.launchd.enable = true`.";
      }
    ];

    home = {
      packages = mkIf (cfg.package != null) [ cfg.package ];

      # HyprMac watches both files and reloads them when a switch re-points
      # the links, so no restart is needed
      file = {
        "Library/Application Support/HyprMac/config.json" = mkIf (configJsonData != null) {
          source = jsonFormat.generate "hyprmac-config.json" configJsonData;
        };

        "Library/Application Support/HyprMac/monitor-config.json" = mkIf (monitorConfigJsonData != null) {
          source = jsonFormat.generate "hyprmac-monitor-config.json" monitorConfigJsonData;
        };
      };

      # load the agent only once the copied app is in place
      activation.hyprmacAfterCopyApps = mkIf (cfg.launchd.enable && copiesApps) (
        lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "copyApps" ] ""
      );
    };

    targets.darwin.defaults."com.zachgray.HyprMac" = mkIf (userDefaults != { }) userDefaults;

    launchd.agents.hyprmac = mkIf (cfg.launchd.enable && cfg.package != null) {
      enable = true;
      config = {
        ProgramArguments = [ "${appPath}/Contents/MacOS/HyprMac" ];
        ProcessType = "Interactive";
        KeepAlive = {
          SuccessfulExit = false;
        };
        RunAtLoad = true;
        EnvironmentVariables = {
          PATH = agentPath;
        };
      };
    };
  };
}
