{
  description = "fprintd + libfprint with the native validity/VCSFW driver (MR !626) for the ThinkPad X280 (06cb:009a) and related Synaptics sensors";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      mkPackages = pkgs: rec {
        libfprint-validity-data = pkgs.callPackage ./nix/libfprint-validity-data.nix { };
        libfprint = pkgs.callPackage ./nix/libfprint-validity.nix { inherit libfprint-validity-data; };
        fprintd = pkgs.fprintd.override { inherit libfprint; };
        default = fprintd;
      };
    in
    {
      packages = forAllSystems mkPackages;

      overlays.default = final: prev: {
        libfprint-validity-data = final.callPackage ./nix/libfprint-validity-data.nix { };
        libfprint-validity = final.callPackage ./nix/libfprint-validity.nix { };
        fprintd-validity = prev.fprintd.override { libfprint = final.libfprint-validity; };
      };

      nixosModules.default = import ./nix/module.nix self;

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
