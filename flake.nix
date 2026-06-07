{
  description = "NixOS access endpoint materialisation renderer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self
    , nixpkgs
    , ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            inherit system;
            pkgs = import nixpkgs { inherit system; };
            lib = nixpkgs.lib;
          }
        );
    in
    {
      libBySystem = forAllSystems (
        { system, pkgs, lib }:
        {
          renderer = import ./lib/renderer.nix {
            inherit system pkgs lib;
          };
        }
      );
    };
}
