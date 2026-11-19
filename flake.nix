{
  description = "HyprMac — tiling window manager for macOS inspired by Hyprland";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      darwinSystems = builtins.filter (
        system:
        nixpkgs.legacyPackages ? ${system}
        && (builtins.tryEval nixpkgs.legacyPackages.${system}.stdenv.hostPlatform.system).success
      ) [
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs darwinSystems;

      mkPackage = pkgs: pkgs.callPackage ./nix/package.nix { };

      hmModule =
        { pkgs, lib, ... }:
        {
          imports = [ ./nix/hm-module.nix ];
          programs.hyprmac.package = lib.mkDefault (
            self.packages.${pkgs.stdenv.hostPlatform.system}.hyprmac or (mkPackage pkgs)
          );
        };
    in
    {
      overlays.default = _final: prev: {
        hyprmac = mkPackage prev;
      };

      homeManagerModules = {
        hyprmac = hmModule;
        default = hmModule;
      };

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          hyprmac = mkPackage pkgs;
        in
        {
          inherit hyprmac;
          default = hyprmac;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        import ./nix/checks.nix {
          inherit pkgs;
          inherit (self.packages.${system}) hyprmac;
        }
      );
    };
}
