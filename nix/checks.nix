{
  pkgs,
  hyprmac,
  hmModule,
  projectYml ? ../project.yml,
}:
let
  inherit (pkgs) lib;
  hyprmacLib = import ./lib.nix { inherit lib; };

  assertEq =
    name: actual: expected:
    if actual == expected then
      true
    else
      throw "hyprmac check '${name}' failed:\n  actual:   ${builtins.toJSON actual}\n  expected: ${builtins.toJSON expected}";

  assertTrue =
    name: cond:
    if cond then true else throw "hyprmac check '${name}' failed";

  projectText = builtins.readFile projectYml;
  projectVersionMatch = builtins.match ".*MARKETING_VERSION:[[:space:]]*\"([0-9A-Za-z._+-]+)\".*" projectText;
  projectVersion =
    if projectVersionMatch == null then
      throw "nix/checks.nix: failed to parse MARKETING_VERSION from ${toString projectYml}"
    else
      builtins.head projectVersionMatch;

  hmLib = lib // {
    hm = (lib.hm or { }) // {
      assertions = {
        assertPlatform =
          name: p: platforms: {
            assertion = lib.meta.availableOn p.stdenv.hostPlatform { meta.platforms = platforms; };
            message = "${name} is not available on ${p.stdenv.hostPlatform.system}";
          };
      };
    };
  };

  # Minimal Home Manager module harness so `nix flake check` can evaluate
  # `nix/hm-module.nix` cleanly without adding `home-manager` to flake inputs.
  hmStubModule =
    { lib, ... }:
    {
      config._module.args = {
        inherit pkgs;
      };

      options = {
        assertions = lib.mkOption {
          type = lib.types.listOf (
            lib.types.submodule {
              options = {
                assertion = lib.mkOption { type = lib.types.bool; };
                message = lib.mkOption { type = lib.types.str; };
              };
            }
          );
          default = [ ];
        };

        home = {
          username = lib.mkOption {
            type = lib.types.str;
            default = "alice";
          };
          profileDirectory = lib.mkOption {
            type = lib.types.str;
            default = "/Users/alice/.nix-profile";
          };
          packages = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = [ ];
          };
          file = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule {
                options = {
                  source = lib.mkOption { type = lib.types.path; };
                  onChange = lib.mkOption {
                    type = lib.types.lines;
                    default = "";
                  };
                };
              }
            );
            default = { };
          };
        };

        targets.darwin.defaults = lib.mkOption {
          type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
          default = { };
        };

        launchd.agents = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule (
              { name, ... }:
              {
                options = {
                  enable = lib.mkEnableOption name;
                  domain = lib.mkOption {
                    type = lib.types.enum [
                      "gui"
                      "user"
                    ];
                    default = "gui";
                  };
                  config = lib.mkOption {
                    type = lib.types.submodule {
                      freeformType = lib.types.attrsOf lib.types.anything;
                      options.Label = lib.mkOption {
                        type = lib.types.str;
                        default = "org.nix-community.home.${name}";
                      };
                    };
                    default = { };
                  };
                };
              }
            )
          );
          default = { };
        };
      };
    };

  evalHm =
    userConfig:
    (lib.evalModules {
      specialArgs = {
        lib = hmLib;
      };
      modules = [
        hmStubModule
        hmModule
        { programs.hyprmac = userConfig; }
      ];
    }).config;

  hmMinimal = evalHm {
    enable = true;
    package = hyprmac;
  };

  hmFull = evalHm {
    enable = true;
    package = hyprmac;
    extraPackages = [ pkgs.jq ];
    launchd = {
      enable = true;
      keepAlive = false;
    };
    settings = {
      gapSize = 12;
      unusedNullKey = null;
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
    };
    monitorSettings = {
      statusExportEnabled = true;
      externalControlEnabled = true;
      outerPaddingPerMonitor = {
        "DELL U3225QE" = {
          top = 37;
          bottom = null;
        };
      };
    };
    showDockIcon = false;
    showMenuBarIcon = true;
  };

  hmNullPackageWithLaunchd = evalHm {
    enable = true;
    package = null;
    launchd.enable = true;
  };

  failedAssertions = cfg: map (a: a.message) (builtins.filter (a: !a.assertion) cfg.assertions);

  fullConfigPath = hmFull.home.file."Library/Application Support/HyprMac/config.json".source;
  fullMonitorConfigPath = hmFull.home.file."Library/Application Support/HyprMac/monitor-config.json".source;

  expectedFullConfig = pkgs.writeText "expected-config.json" (
    builtins.toJSON {
      enabled = true;
      gapSize = 12;
      outerPadding = 8;
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
  );

  expectedFullMonitorConfig = pkgs.writeText "expected-monitor-config.json" (
    builtins.toJSON {
      statusExportEnabled = true;
      externalControlEnabled = true;
      outerPaddingPerMonitor = {
        "DELL U3225QE" = {
          top = 37;
        };
      };
    }
  );
in
{
  package = hyprmac;

  version-sync =
    assert assertEq "cask version matches project.yml MARKETING_VERSION" hyprmac.version projectVersion;
    pkgs.runCommand "hyprmac-version-sync" { } ''
      printf '%s\n' ${lib.escapeShellArg hyprmac.version} > "$out"
    '';

  lib-json =
    assert assertEq "empty settings returns null" (hyprmacLib.buildConfigJson { }) null;
    assert assertEq "all-null settings returns null" (hyprmacLib.buildConfigJson { a = null; }) null;
    assert assertEq "empty monitorSettings returns null" (hyprmacLib.buildMonitorConfigJson { }) null;
    assert assertEq "partial settings populates 4 strict SavedConfig core keys"
      (hyprmacLib.buildConfigJson {
        gapSize = 14;
        dropped = null;
      })
      {
        keybinds = [ ];
        gapSize = 14;
        outerPadding = 8;
        enabled = true;
      };
    assert assertEq "nulls stripped recursively in lists and nested attrsets"
      (hyprmacLib.filterNullsRecursive {
        items = [
          1
          null
          {
            keep = "yes";
            drop = null;
          }
        ];
      })
      {
        items = [
          1
          { keep = "yes"; }
        ];
      };
    pkgs.runCommand "hyprmac-lib-json-check" { } ''
      touch "$out"
    '';

  hm-module =
    assert assertEq "minimal assertions pass" (failedAssertions hmMinimal) [ ];
    assert assertEq "minimal installs package" hmMinimal.home.packages [ hyprmac ];
    assert assertEq "minimal leaves home.file unmanaged" (builtins.attrNames hmMinimal.home.file) [ ];
    assert assertEq "minimal defaults disable Sparkle only"
      hmMinimal.targets.darwin.defaults."com.zachgray.HyprMac"
      {
        SUEnableAutomaticChecks = false;
      };
    assert assertTrue "minimal leaves launchd agent disabled" (
      !(hmMinimal.launchd.agents ? hyprmac) || !hmMinimal.launchd.agents.hyprmac.enable
    );

    assert assertEq "full assertions pass" (failedAssertions hmFull) [ ];
    assert assertEq "full manages both config files" (builtins.attrNames hmFull.home.file) [
      "Library/Application Support/HyprMac/config.json"
      "Library/Application Support/HyprMac/monitor-config.json"
    ];
    assert assertEq "full sets UserDefaults including iCloudSyncEnabled = false"
      hmFull.targets.darwin.defaults."com.zachgray.HyprMac"
      {
        SUEnableAutomaticChecks = false;
        iCloudSyncEnabled = false;
        showDockIcon = false;
        showMenuBarIcon = true;
      };
    assert assertTrue "full enables launchd agent" hmFull.launchd.agents.hyprmac.enable;
    assert assertEq "full respects keepAlive = false" hmFull.launchd.agents.hyprmac.config.KeepAlive false;
    assert assertEq "full sets ProcessType = Interactive" hmFull.launchd.agents.hyprmac.config.ProcessType "Interactive";
    assert assertTrue "full injects extraPackages into launchd PATH" (
      lib.hasPrefix "${lib.makeBinPath [ pkgs.jq ]}:" hmFull.launchd.agents.hyprmac.config.EnvironmentVariables.PATH
    );
    assert assertTrue "full sets kickstart onChange hook" (
      lib.hasInfix "launchctl kickstart -k" hmFull.home.file."Library/Application Support/HyprMac/config.json".onChange
    );
    assert assertEq "null package + launchd triggers assertion" (builtins.length (failedAssertions hmNullPackageWithLaunchd)) 1;

    pkgs.runCommand "hyprmac-hm-module-check"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        jq -S . ${lib.escapeShellArg fullConfigPath} > actual-config.json
        jq -S . ${lib.escapeShellArg expectedFullConfig} > expected-config.json
        diff -u expected-config.json actual-config.json

        jq -S . ${lib.escapeShellArg fullMonitorConfigPath} > actual-monitor.json
        jq -S . ${lib.escapeShellArg expectedFullMonitorConfig} > expected-monitor.json
        diff -u expected-monitor.json actual-monitor.json

        touch "$out"
      '';
}
