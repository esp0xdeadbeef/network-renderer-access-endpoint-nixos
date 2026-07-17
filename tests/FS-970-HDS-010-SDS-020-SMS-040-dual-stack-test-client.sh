#!/usr/bin/env bash
# GAMP-ID: FS-970-HDS-010-SDS-020-SMS-040
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

result="$(
  REPO_ROOT="${repo_root}" nix eval --impure --json --expr '
    let
      repoRoot = builtins.getEnv "REPO_ROOT";
      flake = builtins.getFlake ("path:" + repoRoot);
      renderer = flake.libBySystem.${builtins.currentSystem}.renderer;
      module = renderer.hostModule {
        hostName = "s-router-test-clients";
        mode = "test";
        cpm = {
          endpointAssignment.reservation-probe = {
            mode = "dhcp";
            name = "reservation-probe";
            bridge = "client";
            dhcp = {
              servedPrefix4 = "10.97.40.0/24";
              servedPrefix6 = "fd42:970:40::/64";
            };
          };
          bridgeNetworks.client = { };
        };
      };
      evaluated = module { config = { }; };
      endpoint = (flake.inputs.nixpkgs.lib.nixosSystem {
        system = builtins.currentSystem;
        modules = [ evaluated.containers.reservation-probe.config ];
      }).config;
      network = endpoint.systemd.network.networks."10-eth0";
    in {
      dhcp = network.networkConfig.DHCP;
      ipv6AcceptRA = network.networkConfig.IPv6AcceptRA;
    }
  '
)"

jq -e '.dhcp == "yes" and .ipv6AcceptRA == true' <<<"${result}" >/dev/null || {
  echo "FAIL FS-970 dual-stack test client: endpoint did not request DHCPv4 and DHCPv6" >&2
  exit 1
}

echo "PASS FS-970-HDS-010-SDS-020-SMS-040 dual-stack test-client construction"
