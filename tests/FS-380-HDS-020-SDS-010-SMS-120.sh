#!/usr/bin/env bash
# FS-380-HDS-020-SDS-010-SMS-120
# Proves the s-router-test-clients substrate needed for prod-like IPv4 egress:
# CPM deployment host management uplink -> eth0.2/vlan2, CPM bridgeNetworks.client
# -> eth0.302/client, and endpointAssignment -> static client container.
set -euo pipefail

TEST_NAME="FS-380-HDS-020-SDS-010-SMS-120"
RENDERER_FLAKE="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d /tmp/test-${TEST_NAME}-XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

fail() {
  echo "FAIL ${TEST_NAME}: $*" >&2
  exit 1
}

pass() {
  echo "PASS ${TEST_NAME}: $*"
}

eval_file="${SCRATCH}/eval.nix"
cat >"${eval_file}" <<NIX
let
  flake = builtins.getFlake "${RENDERER_FLAKE}";
  nixpkgsLib = flake.inputs.nixpkgs.lib;
  system = builtins.currentSystem;
  renderer = flake.libBySystem.x86_64-linux.renderer;
  cpmFixture = {
    control_plane_model = {
      deployment.hosts.s-router-test-clients = {
        bridgeNetworks.client = {
          mode = "vlan";
          parent = "eth0";
          vlan = 302;
        };
        uplinks.management = {
          bridge = "vlan2";
          ipv4 = {
            dhcp = true;
            enable = true;
            method = "dhcp";
          };
          ipv6 = {
            acceptRA = false;
            dhcp = false;
            enable = false;
            method = "none";
          };
          mode = "vlan";
          parent = "eth0";
          role = "management";
          vlan = 2;
        };
      };
      data."mini-smt"."FS-380-HDS-020-SDS-010-SMS-120".endpointAssignment.prod-like-vlan4-client01 = {
        bridge = "client";
        family = "dual";
        mode = "static";
        name = "prod-like-vlan4-client01";
        static = {
          address = "10.38.120.10";
          address6 = "fd42:380:120::10";
          gateway4 = "10.38.120.1";
          gateway6 = "fd42:380:120::1";
          prefixLength = 24;
          prefixLength6 = 64;
          dnsServers = [ "10.38.120.1" ];
        };
      };
    };
  };
  moduleFn = renderer.hostModule {
    hostName = "s-router-test-clients";
    cpm = cpmFixture;
    mode = "test";
  };
  result = moduleFn { config = {}; };
  netdevs = result.systemd.network.netdevs or {};
  networks = result.systemd.network.networks or {};
  containers = result.containers or {};
  endpointConfig = (nixpkgsLib.nixosSystem {
    inherit system;
    modules = [ containers.prod-like-vlan4-client01.config ];
  }).config;
in
{
  netdevs = builtins.attrNames netdevs;
  networks = builtins.attrNames networks;
  eth0Vlans = networks."20-eth0".networkConfig.VLAN or [];
  eth0Dhcp = networks."20-eth0".networkConfig.DHCP or null;
  vlan2Netdev = netdevs."40-eth0.2".vlanConfig.Id or null;
  clientNetdev = netdevs."40-eth0.302".vlanConfig.Id or null;
  vlan2BridgeKind = netdevs.vlan2.netdevConfig.Kind or null;
  clientBridgeKind = netdevs.client.netdevConfig.Kind or null;
  vlan2Attachment = networks."40-eth0.2".networkConfig or {};
  clientAttachment = networks."40-eth0.302".networkConfig or {};
  vlan2Bridge = networks.vlan2.networkConfig or {};
  clientBridge = networks.client.networkConfig or {};
  container =
    let c = containers.prod-like-vlan4-client01 or {};
    in {
      autoStart = c.autoStart or null;
      hostBridge = c.hostBridge or null;
      privateNetwork = c.privateNetwork or null;
    };
  containerDns = endpointConfig.systemd.network.networks."10-eth0".networkConfig.DNS or [];
  useNetworkd = result.networking.useNetworkd or null;
  useDHCP = result.networking.useDHCP or null;
}
NIX

json="$(nix eval --impure --json -f "${eval_file}")"

jq -e '
  .vlan2Netdev == 2
  and .clientNetdev == 302
  and .vlan2BridgeKind == "bridge"
  and .clientBridgeKind == "bridge"
  and (.eth0Vlans | index("eth0.2") != null)
  and (.eth0Vlans | index("eth0.302") != null)
  and .eth0Dhcp == "no"
  and .vlan2Attachment.Bridge == "vlan2"
  and .vlan2Attachment.DHCP == "no"
  and .clientAttachment.Bridge == "client"
  and .clientAttachment.DHCP == "no"
  and .vlan2Bridge.DHCP == "ipv4"
  and (.vlan2Bridge.IPv6AcceptRA == false or .vlan2Bridge.IPv6AcceptRA == "no")
  and .clientBridge.DHCP == "no"
  and .container.hostBridge == "client"
  and .container.autoStart == true
  and .container.privateNetwork == true
  and .containerDns == ["10.38.120.1"]
  and .useNetworkd == true
  and .useDHCP == false
' <<<"${json}" >/dev/null || {
  jq . <<<"${json}" >&2
  fail "renderer did not materialize CPM management/client host substrate"
}

pass "CPM management uplink and client VLAN bridge substrate rendered"
