#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

result_json="$(mktemp)"
trap 'rm -f "${result_json}"' EXIT

RENDERER_ROOT="${repo_root}" \
nix eval \
  --extra-experimental-features 'nix-command flakes' \
  --impure \
  --json \
  --expr '
    let
      rendererRoot = builtins.getEnv "RENDERER_ROOT";
      flake = builtins.getFlake ("path:" + rendererRoot);
      system = builtins.currentSystem;
      labs = flake.inputs.network-labs;
      cpmLib = flake.inputs.network-control-plane-model.libBySystem.${system};
      activeLab = "${labs}/active-lab";
      current = import "${labs}/current-lab/metadata.nix";
      cpm = cpmLib.compileAndBuildFromPaths {
        inputPath = "${activeLab}/intent.nix";
        inventoryPath = "${activeLab}/inventory-nixos.nix";
      };
      module = flake.libBySystem.${system}.renderer.hostModule {
        hostName = "s-router-test-clients";
        labSource = "active-lab";
        cpm = cpm;
        controlPlane = cpm;
        inventory = "${activeLab}/inventory-nixos.nix";
        clients = "${activeLab}/clients.nix";
        sops = "${activeLab}/sops-routing-s-router-test-clients.nix";
      };
      rendered = module { config = {}; };
      containers = rendered.containers or {};
      container = containers."dns-resolver-config-access-dns" or {};
      bridge = container.hostBridge or null;
      originalBridge = "br-mini-smt-dns-resolver-config-tenant-client";
      renderedBridge = "br-mini--baff8b";
      networks = rendered.systemd.network.networks or {};
      netdevs = rendered.systemd.network.netdevs or {};
      checks = {
        active_lab_selector_is_fs540 = current.traceId == "FS-540-HDS-010-SDS-010";
        access_dns_container_exists = builtins.hasAttr "dns-resolver-config-access-dns" containers;
        host_bridge_is_shortened = bridge == renderedBridge;
        host_bridge_not_overlong = builtins.isString bridge && builtins.stringLength bridge <= 15;
        original_bridge_not_emitted_as_container_bridge = bridge != originalBridge;
        rendered_bridge_network_exists = builtins.hasAttr renderedBridge networks;
        rendered_bridge_netdev_exists = builtins.hasAttr renderedBridge netdevs;
        original_bridge_network_not_emitted = !(builtins.hasAttr originalBridge networks);
      };
    in
    {
      ok = builtins.all (name: checks.${name}) (builtins.attrNames checks);
      failed = builtins.filter (name: !(checks.${name})) (builtins.attrNames checks);
      inherit checks;
      observed = {
        selector = current.traceId;
        inherit bridge originalBridge renderedBridge;
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
