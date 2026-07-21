#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
network_labs_path="${NETWORK_LABS_PATH:-}"

result_json="$(mktemp)"
trap 'rm -f "${result_json}"' EXIT

NETWORK_LABS_PATH="${network_labs_path}" \
	RENDERER_ROOT="${repo_root}" \
	nix eval \
	--extra-experimental-features 'nix-command flakes' \
	--impure \
	--json \
	--expr '
    let
      rendererRoot = builtins.getEnv "RENDERER_ROOT";
      networkLabsPath = builtins.getEnv "NETWORK_LABS_PATH";
      flake = builtins.getFlake ("path:" + rendererRoot);
      system = builtins.currentSystem;
      labs =
        if networkLabsPath == "" then
          flake.inputs.network-labs
        else
          builtins.getFlake ("path:" + networkLabsPath);
      nixpkgsLib = flake.inputs.nixpkgs.lib;
      cpmLib = flake.inputs.network-control-plane-model.libBySystem.${system};
      sourceRoot = "${labs}/GAMP/SMT/FS-540-HDS-010-SDS-010-SMS-020";
      cpm = cpmLib.compileAndBuildFromPaths {
        inputPath = "${sourceRoot}/intent-test-clients.nix";
        inventoryPath = "${sourceRoot}/inventory-test-clients.nix";
      };
      replacement = {
        kind = "network-control-plane-artifact";
        artifactIdentity = builtins.hashString "sha256" (builtins.toJSON cpm.control_plane_model);
        control_plane_model = cpm.control_plane_model;
      };
      bundle = flake.inputs.network-realization-model.lib.realize {
        input = replacement;
        requestScope = {
          kind = "complete-artifact";
          identity = "FS-540-HDS-010-SDS-010-SMS-020";
        };
        rootLockIdentity = builtins.hashString "sha256" (builtins.readFile (rendererRoot + "/flake.lock"));
        producerRevision = flake.inputs.network-realization-model.rev;
      };
      renderer = flake.libBySystem.${system}.renderer;
      module = renderer.canonical.hostModule {
        hostName = "s-router-test-clients";
        labSource = "FS-540-HDS-010-SDS-010-SMS-020";
        inherit bundle;
      };
      rendered = module { config = {}; };
      containers = rendered.containers or {};
      networks = rendered.systemd.network.networks or {};
      netdevs = rendered.systemd.network.netdevs or {};
      stripCidr = cidr: builtins.elemAt (nixpkgsLib.splitString "/" cidr) 0;
      endpoint = name: expectedBridge:
        let
          container = containers.${name} or {};
          containerHasConfig = container ? config;
          evaluatedContainer =
            if containerHasConfig then
              (nixpkgsLib.nixosSystem {
                inherit system;
                modules = [ container.config ];
              }).config
            else
              {};
          eth0 =
            if containerHasConfig then
              evaluatedContainer.systemd.network.networks."10-eth0"
            else
              { networkConfig.Address = [ ]; routes = [ ]; };
          ownAddresses = builtins.map stripCidr (eth0.networkConfig.Address or [ ]);
          routeGateways = builtins.filter (gateway: gateway != null)
            (builtins.map (route: route.Gateway or null) (eth0.routes or [ ]));
          nameservers = eth0.networkConfig.DNS or [ ];
        in {
          inherit name expectedBridge containerHasConfig ownAddresses routeGateways nameservers;
          bridge = container.hostBridge or null;
          ok =
            builtins.hasAttr name containers
            && containerHasConfig
            && (container.hostBridge or null) == expectedBridge
            && builtins.stringLength expectedBridge <= 15
            && builtins.hasAttr expectedBridge networks
            && builtins.hasAttr expectedBridge netdevs
            && ownAddresses == [ "10.54.10.10" "fd42:540::10" ]
            && routeGateways == [ "10.54.10.1" "fd42:540::1" ]
            && nameservers == [ "10.54.10.1" "fd42:540::1" ]
            && builtins.all (gateway: !(builtins.elem gateway ownAddresses)) routeGateways;
        };
      endpoints = [
        (endpoint "dns-resolver-nixos-client" "dns540n")
        (endpoint "dns-resolver-clab-client" "dns540c")
      ];
      checks = {
        canonical_bundle_accepted =
          (renderer.canonical.validateInput { inherit bundle; }).bundleIdentity
          == bundle.bundleIdentity;
        raw_cpm_rejected =
          !(builtins.tryEval (builtins.deepSeq (renderer.canonical.validateInput { bundle = cpm; }) true)).success;
        exact_endpoint_set = builtins.attrNames containers == [
          "dns-resolver-clab-client"
          "dns-resolver-nixos-client"
        ];
        both_substrates_materialized = builtins.all (entry: entry.ok) endpoints;
        distinct_isolated_bridges =
          (builtins.elemAt endpoints 0).bridge != (builtins.elemAt endpoints 1).bridge;
      };
    in
    {
      ok = builtins.all (name: checks.${name}) (builtins.attrNames checks);
      failed = builtins.filter (name: !(checks.${name})) (builtins.attrNames checks);
      inherit checks;
      observed = {
        source = sourceRoot;
        inherit endpoints;
        containerNames = builtins.attrNames containers;
        networkNames = builtins.attrNames networks;
        netdevNames = builtins.attrNames netdevs;
      };
    }
  ' >"${result_json}"

if ! jq -e '.ok == true' "${result_json}" >/dev/null; then
	echo "FAIL FS-540 access endpoint bridge name materialization" >&2
	jq . "${result_json}" >&2
	exit 1
fi

echo "PASS FS-540 access endpoint bridge name materialization"
