#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-020-SDS-010-SMS-060
# GAMP-SCOPE: software-module-test
set -euo pipefail

# One route authority, one next-hop set — asserted on the endpoint's networks.
#
# URS "Canonical Realization and Renderer Boundary": a platform binding shall
# not create or duplicate routing. FS-310-HDS-020-SDS-010-SMS-060: "One
# route-selection authority shall have one modeled semantic next-hop set.
# Different next-hop sets for the same authority shall fail unless explicit
# multipath policy names the complete authorized member set."
#
# Authority here is (endpoint container, family, table, destination, metric).
# An endpoint handed two gateways for one destination is one authority with two
# next hops; the platform cannot hold both.
#
# Harness guards, so a broken comparison cannot masquerade as a finding: the
# endpoint must render at least one network containing at least one route.

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
trace_id="FS-310-HDS-020-SDS-010-SMS-060"
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

eval_file="${scratch}/eval.nix"
cat >"${eval_file}" <<NIX
let
  flake = builtins.getFlake "${repo_root}";
  nixpkgsLib = flake.inputs.nixpkgs.lib;
  system = builtins.currentSystem;
  renderer = flake.libBySystem.\${system}.renderer;
  api = flake.libBySystem.\${system}.renderer;
  # Migrated off the plain CPM (RR_RAW_CPM_INPUT): host deployment facts come from
  # `deploymentHosts`, a sibling of control_plane_model on the artifact, and site
  # records -- including endpointAssignment -- from canonicalSites[].facts. Both
  # carriers already exist in the producer; nothing here invents one.
  cpmFixture = {
    deploymentHosts.s-router-test-clients = {
      bridgeNetworks.client = { mode = "vlan"; parent = "eth0"; vlan = 302; };
      uplinks.management = {
        bridge = "vlan2";
        ipv4 = { dhcp = true; enable = true; method = "dhcp"; };
        ipv6 = { acceptRA = false; dhcp = false; enable = false; method = "none"; };
        mode = "vlan"; parent = "eth0"; role = "management"; vlan = 2;
      };
    };
  };
  canonicalCollections = {
    canonicalSites.sites = [
      {
        enterprise = "mini-smt";
        site = "${trace_id}";
        facts.endpointAssignment.prod-like-vlan4-client01 = {
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
      }
    ];
  };
  moduleFn = api.hostModule {
    hostName = "s-router-test-clients";
    cpm = cpmFixture;
    inherit canonicalCollections;
    mode = "test";
  };
  result = moduleFn { config = {}; };
  endpoint = (result.containers or {}).prod-like-vlan4-client01 or null;
  endpointConfig =
    if endpoint == null then null
    else (nixpkgsLib.nixosSystem { inherit system; modules = [ endpoint.config ]; }).config;
  networks = if endpointConfig == null then {} else (endpointConfig.systemd.network.networks or {});
  routes = builtins.concatLists (map
    (name:
      let net = networks.\${name};
      in map (r: {
           iface = net.matchConfig.Name or name;
           dst = r.Destination or "";
           gateway = r.Gateway or null;
           table = r.Table or null;
           metric = r.Metric or null;
           family = if builtins.match ".*:.*" (r.Destination or "") != null then 6 else 4;
         })
         (net.routes or [ ]))
    (builtins.attrNames networks));
  keyOf = r: "\${toString r.family}|\${toString r.table}|\${r.dst}|\${toString r.metric}";
  grouped = builtins.groupBy keyOf routes;
  duplicates = map
    (k: "\${k}  gateways: \${builtins.concatStringsSep ", " (map (r: if r.gateway == null then "dev" else r.gateway) grouped.\${k})}")
    (builtins.filter
      (k: (builtins.length (nixpkgsLib.unique (map (r: r.gateway) grouped.\${k}))) > 1)
      (builtins.attrNames grouped));
in {
  endpointPresent = endpointConfig != null;
  networkCount = builtins.length (builtins.attrNames networks);
  routeCount = builtins.length routes;
  inherit duplicates;
}
NIX

json="$(nix eval --impure --json -f "${eval_file}")"

if [[ "$(jq -r '.endpointPresent' <<<"${json}")" != "true" ]]; then
  printf 'FAIL %s: harness error -- the renderer produced no endpoint container\n' "${trace_id}" >&2
  exit 1
fi
if [[ "$(jq -r '.routeCount' <<<"${json}")" == "0" ]]; then
  printf 'FAIL %s: harness error -- the endpoint rendered no route, so the clause is vacuous\n' "${trace_id}" >&2
  exit 1
fi

if [[ "$(jq -r '.duplicates | length' <<<"${json}")" != "0" ]]; then
  printf 'FAIL %s: one route authority carries more than one next hop\n' "${trace_id}" >&2
  jq -r '.duplicates[] | "  \(.)"' <<<"${json}" >&2
  printf '  SMS-060: one authority, one next-hop set.\n' >&2
  exit 1
fi

printf 'PASS %s (%s network(s), %s route(s), one next-hop set per authority)\n' \
  "${trace_id}" "$(jq -r '.networkCount' <<<"${json}")" "$(jq -r '.routeCount' <<<"${json}")"
