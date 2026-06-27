{
  description = "NixOS access endpoint materialisation renderer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    network-control-plane-model.url = "github:esp0xdeadbeef/network-control-plane-model";
    network-control-plane-model.inputs.nixpkgs.follows = "nixpkgs";

    network-labs.url = "github:esp0xdeadbeef/network-labs";
  };

  outputs =
    { self
    , nixpkgs
    , network-control-plane-model
    , network-labs
    , ...
    }@inputs:
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
            inherit self;
            cpm = network-control-plane-model.libBySystem.${system};
            inherit (inputs) network-labs;
          };
        }
      );
    };
}
