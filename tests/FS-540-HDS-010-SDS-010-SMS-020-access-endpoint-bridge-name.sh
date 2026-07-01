#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
      module = flake.libBySystem.${system}.renderer.hostModule {
        hostName = "s-router-test-clients";
        labSource = "FS-540-HDS-010-SDS-010-SMS-020";
        cpm = cpm;
        controlPlane = cpm;
      };
      rendered = module { config = {}; };
      containers = rendered.containers or {};
      container = containers."dns-resolver-config-access-dns" or {};
      bridge = container.hostBridge or null;
      originalBridge = "br-mini-smt-dns-resolver-config-tenant-client";
      renderedBridge = "br-mini--baff8b";
      networks = rendered.systemd.network.networks or {};
      netdevs = rendered.systemd.network.netdevs or {};
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
      stripCidr = cidr: builtins.elemAt (nixpkgsLib.splitString "/" cidr) 0;
      ownAddresses = builtins.map stripCidr (eth0.networkConfig.Address or [ ]);
      routeGateways =
        builtins.filter (gateway: gateway != null)
          (builtins.map (route: route.Gateway or null) (eth0.routes or [ ]));
      checks = {
        access_dns_container_exists = builtins.hasAttr "dns-resolver-config-access-dns" containers;
        access_dns_container_has_config = containerHasConfig;
        host_bridge_is_shortened = bridge == renderedBridge;
        host_bridge_not_overlong = builtins.isString bridge && builtins.stringLength bridge <= 15;
        original_bridge_not_emitted_as_container_bridge = bridge != originalBridge;
        rendered_bridge_network_exists = builtins.hasAttr renderedBridge networks;
        rendered_bridge_netdev_exists = builtins.hasAttr renderedBridge netdevs;
        original_bridge_network_not_emitted = !(builtins.hasAttr originalBridge networks);
        container_routes_do_not_self_gateway =
          builtins.all (gateway: !(builtins.elem gateway ownAddresses)) routeGateways;
      };
    in
    {
      ok = builtins.all (name: checks.${name}) (builtins.attrNames checks);
      failed = builtins.filter (name: !(checks.${name})) (builtins.attrNames checks);
      inherit checks;
      observed = {
        source = sourceRoot;
        inherit bridge originalBridge renderedBridge;
        inherit containerHasConfig;
        inherit ownAddresses routeGateways;
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
