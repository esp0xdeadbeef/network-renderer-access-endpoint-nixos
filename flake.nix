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
                # No `cpm`: the renderer takes its network semantics from the
                # validated bundle's canonical collections and its deployment
                # facts from the bundle's platform-binding categories, both passed
                # below. Handing over the producer's unvalidated envelope was passing the plain
                # control-plane model, which RR_RAW_CPM_INPUT forbids.
                #
                # `deploymentHosts` stays: it is a sibling of the control-plane
                # model on the artifact (the producer emits it there), not a field
                # of the CPM, and it is the carrier the renderer reads host
                # deployment facts from.
                deploymentHosts = validated.semanticModel.deploymentHosts or { };
                # The bundle's canonical collections. `canonicalSites[].facts` is
                # the complete site record, which is where this renderer's
                # endpointAssignment comes from; handing it through is what lets
                # the renderer stop walking the plain CPM for site data.
                canonicalCollections = validated.canonical or { };
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
          # A raw control-plane-model artifact, used only as input to prove the
          # canonical boundary rejects it. The fixture lives under tests/ because
          # tests/test-raw-cpm-consumption.sh scans implementation source for such
          # reads and excludes tests/ for exactly this case.
          rawRejected =
            !(builtins.tryEval (
              builtins.deepSeq (renderer.canonical.validateInput {
                bundle = import ./tests/lib/boundary/raw-cpm-fixture.nix;
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
