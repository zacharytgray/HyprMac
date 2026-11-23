{
  pkgs,
  hyprmac,
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

  projectText = builtins.readFile projectYml;
  projectVersionMatch = builtins.match ".*MARKETING_VERSION:[[:space:]]*\"([0-9A-Za-z._+-]+)\".*" projectText;
  projectVersion =
    if projectVersionMatch == null then
      throw "nix/checks.nix: failed to parse MARKETING_VERSION from ${toString projectYml}"
    else
      builtins.head projectVersionMatch;
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
    assert assertEq "partial settings populates the version and the 4 strict SavedConfig core keys"
      (hyprmacLib.buildConfigJson {
        gapSize = 14;
        dropped = null;
      })
      {
        version = 2;
        keybinds = [ ];
        gapSize = 14;
        outerPadding = 8;
        enabled = true;
      };
    assert assertEq "settings.version overrides the default"
      (hyprmacLib.buildConfigJson { version = 3; }).version
      3;
    assert assertEq "a floating rule with match = null fails evaluation"
      (builtins.tryEval (
        builtins.deepSeq (hyprmacLib.buildConfigJson {
          floatingRules = [
            {
              bundleID = "us.zoom.xos";
              action = "float";
              match = null;
            }
          ];
        }) true
      )).success
      false;
    assert assertEq "a floating rule with no match stays an app rule"
      (hyprmacLib.buildConfigJson {
        floatingRules = [
          {
            bundleID = "us.zoom.xos";
            action = "float";
          }
        ];
      }).floatingRules
      [
        {
          bundleID = "us.zoom.xos";
          action = "float";
        }
      ];
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
    assert assertEq "showMenuBarIcon maps to menuBarStyle"
      (hyprmacLib.buildUserDefaults {
        showDockIcon = null;
        menuBarStyle = null;
        updatesManagedExternally = null;
        showMenuBarIcon = false;
      })
      { menuBarStyle = "hidden"; };
    assert assertEq "menuBarStyle wins over showMenuBarIcon"
      (hyprmacLib.buildUserDefaults {
        showDockIcon = true;
        menuBarStyle = "compact";
        updatesManagedExternally = null;
        showMenuBarIcon = false;
      })
      {
        showDockIcon = true;
        menuBarStyle = "compact";
      };
    assert assertEq "updatesManagedExternally writes the defaults key"
      (hyprmacLib.buildUserDefaults {
        showDockIcon = null;
        menuBarStyle = null;
        updatesManagedExternally = true;
        showMenuBarIcon = null;
      })
      { HyprMacUpdatesManagedExternally = true; };
    pkgs.runCommand "hyprmac-lib-json-check" { } ''
      touch "$out"
    '';
}
