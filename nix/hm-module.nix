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

  managesConfigJson = configJsonData != null;
  managesMonitorConfigJson = monitorConfigJsonData != null;

  userDefaults = hyprmacLib.buildUserDefaults {
    inherit cfg managesConfigJson;
  };

  hasDomainOption = options.launchd.agents.type.getSubOptions [ ] ? domain;
  agentDomain = if hasDomainOption then config.launchd.agents.hyprmac.domain else "gui";
  agentLabel = config.launchd.agents.hyprmac.config.Label;

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

  restartAgentHook = mkIf cfg.launchd.enable ''
    /bin/launchctl kickstart -k "${agentDomain}/$(id -u)/${agentLabel}" >/dev/null 2>&1 || true
  '';
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

    launchd = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Configure a launchd LaunchAgent in the `gui` domain to start HyprMac
          at login.

          When enabled, prefer this over HyprMac's in-app "Launch at login"
          toggle so startup is managed from a single place.
        '';
      };

      keepAlive = mkOption {
        type = types.bool;
        default = true;
        description = "Whether launchd should keep the HyprMac process alive.";
      };
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

      file = {
        "Library/Application Support/HyprMac/config.json" = mkIf managesConfigJson {
          source = jsonFormat.generate "hyprmac-config.json" configJsonData;
          onChange = restartAgentHook;
        };

        "Library/Application Support/HyprMac/monitor-config.json" = mkIf managesMonitorConfigJson {
          source = jsonFormat.generate "hyprmac-monitor-config.json" monitorConfigJsonData;
          onChange = restartAgentHook;
        };
      };
    };

    targets.darwin.defaults."com.zachgray.HyprMac" = mkIf (userDefaults != { }) userDefaults;

    launchd.agents.hyprmac = mkIf (cfg.launchd.enable && cfg.package != null) {
      enable = true;
      config = {
        ProgramArguments = [
          "${cfg.package}/Applications/HyprMac.app/Contents/MacOS/HyprMac"
        ];
        ProcessType = "Interactive";
        KeepAlive = cfg.launchd.keepAlive;
        RunAtLoad = true;
        EnvironmentVariables = {
          PATH = agentPath;
        };
        StandardOutPath = "/tmp/hyprmac.log";
        StandardErrorPath = "/tmp/hyprmac.err.log";
      };
    };
  };
}
