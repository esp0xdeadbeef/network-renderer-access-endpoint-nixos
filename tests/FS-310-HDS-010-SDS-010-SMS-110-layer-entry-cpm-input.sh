#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-010-SDS-010-SMS-110
# GAMP-SCOPE: access-endpoint renderer CPM-direct entry contract; not HAT/SAT evidence
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
labs_root="${NETWORK_LABS_ROOT:-${repo_root}/../network-labs}"
fixture="${labs_root}/GAMP/SMT/layer-entry-poc/renderer-input/minimal-access-endpoint-cpm.nix"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/access-endpoint-cpm-entry.XXXXXX")"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
  echo "FAIL access-endpoint-cpm-entry: $*" >&2
  exit 1
}

[[ -f "${fixture}" ]] || fail "missing renderer-input fixture at ${fixture}"

nix eval --impure --json --expr "
  let
    flake = builtins.getFlake \"path:${repo_root}\";
    system = builtins.currentSystem;
    renderer = flake.libBySystem.\${system}.renderer;
    cpm = (import ${fixture}).controlPlane;
    moduleFn = renderer.hostModule {
      hostName = \"s-router-test-clients\";
      labSource = \"active-lab\";
      inherit cpm;
      controlPlane = cpm;
      inventory = \"${labs_root}/active-lab/inventory-nixos.nix\";
      clients = \"${labs_root}/active-lab/clients.nix\";
      sops = \"${labs_root}/active-lab/sops-routing-s-router-test-clients.nix\";
    };
    result = moduleFn { config = {}; };
  in
  {
    containers = builtins.attrNames (result.containers or {});
    services = builtins.attrNames (result.systemd.services or {});
    netdevs = builtins.attrNames (result.systemd.network.netdevs or {});
    networks = builtins.attrNames (result.systemd.network.networks or {});
  }
" >"${tmp_dir}/direct-cpm.json" \
  || fail "hostModule did not accept direct CPM/controlPlane input"

jq -e '
  (.containers | length) > 0
  and (.services | index("access-endpoint-isolate-bridges") != null)
  and (.services | index("s-router-test-clients-endpoint-ready") != null)
  and (.netdevs | index("client") != null)
  and (.networks | index("client") != null)
' "${tmp_dir}/direct-cpm.json" >/dev/null \
  || fail "hostModule direct CPM output missed endpoint surfaces"

if nix eval --impure --expr "
  let
    flake = builtins.getFlake \"path:${repo_root}\";
    renderer = flake.libBySystem.\${builtins.currentSystem}.renderer;
    moduleFn = renderer.hostModule {
      hostName = \"s-router-test-clients\";
      labSource = \"active-lab\";
      inventory = \"${labs_root}/active-lab/inventory-nixos.nix\";
    };
    result = moduleFn { config = {}; };
  in
    builtins.attrNames (result.containers or {})
" >/dev/null 2>"${tmp_dir}/missing-cpm.err"; then
  fail "hostModule accepted path-only input without cpm/controlPlane"
fi

grep -Fq "'cpm' or 'controlPlane' is required" "${tmp_dir}/missing-cpm.err" \
  || fail "hostModule missing-CPM diagnostic was not explicit"

echo "PASS access-endpoint-cpm-entry"
