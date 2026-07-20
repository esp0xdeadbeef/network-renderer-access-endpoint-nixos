{
  description = "NixOS access endpoint materialisation renderer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    network-control-plane-model.url = "github:esp0xdeadbeef/network-control-plane-model";
    network-control-plane-model.inputs.nixpkgs.follows = "nixpkgs";

    network-labs.url = "github:esp0xdeadbeef/network-labs";

    network-realization-model.url = "github:esp0xdeadbeef/network-realization-model";
    network-realization-model.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      network-control-plane-model,
      network-labs,
      network-realization-model,
      ...
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
        {
          system,
          pkgs,
          lib,
        }:
        let
          legacyRenderer = import ./lib/renderer.nix {
            inherit system pkgs lib;
            inherit self;
            cpm = network-control-plane-model.libBySystem.${system};
            inherit (inputs) network-labs;
          };
          canonicalInput =
            {
              bundle,
              platformBinding ? null,
            }:
            network-realization-model.lib.validateRendererInput {
              inherit bundle platformBinding;
              expectedTarget = "access-endpoint-nixos";
            };
          canonicalHostModule =
            {
              bundle,
              platformBinding ? null,
              ...
            }@rendererInput:
            let
              validated = canonicalInput { inherit bundle platformBinding; };
              forwarded = builtins.removeAttrs rendererInput [
                "bundle"
                "platformBinding"
              ];
            in
            legacyRenderer.hostModule (
              forwarded
              // {
                cpm = validated.controlPlaneEnvelope;
                canonicalBundleIdentity = validated.bundleIdentity;
                canonicalBindingIdentity = validated.bindingIdentity;
              }
            );
        in
        {
          renderer = legacyRenderer // {
            canonical = {
              hostModule = canonicalHostModule;
              validateInput = canonicalInput;
            };
          };
        }
      );

      checks = forAllSystems (
        { system, pkgs, ... }:
        let
          renderer = self.libBySystem.${system}.renderer;
          bundle = network-realization-model.lib.realize {
            input = import "${network-realization-model}/examples/cpm-result.nix";
            requestScope = {
              kind = "complete-artifact";
              identity = "access-endpoint-renderer-boundary";
            };
            rootLockIdentity = "network-renderer-access-endpoint-flake-lock";
            producerRevision = network-realization-model.rev;
          };
          accepted = renderer.canonical.validateInput { inherit bundle; };
          rawRejected =
            !(builtins.tryEval (
              builtins.deepSeq (renderer.canonical.validateInput {
                bundle = {
                  control_plane_model = { };
                };
              }) true
            )).success;
        in
        assert accepted.bundleIdentity == bundle.bundleIdentity;
        assert rawRejected;
        {
          canonical-renderer-input = pkgs.runCommand "network-renderer-access-endpoint-canonical-input" { } ''
            touch "$out"
          '';
        }
      );
    };
}
