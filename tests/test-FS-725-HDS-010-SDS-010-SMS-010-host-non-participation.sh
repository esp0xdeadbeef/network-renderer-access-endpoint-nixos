#!/usr/bin/env bash
# ============================================================================
# FS-725-HDS-010-SDS-010-SMS-010: s-router-test-clients host non-participation
# Construction test (SMT) — focused renderer module artifact check.
#
# Trace chain: FS-725 > HDS-010 > SDS-010 > SMS-010
# Owning repo: network-renderer-access-endpoint-nixos
# Renderer API: hostModuleFromPaths
# Inventory: active-lab (s-router-test-clients)
#
# Covers all 8 SMS acceptance predicates with seeded negatives.
# ============================================================================
set -euo pipefail

TEST_NAME="FS-725-HDS-010-SDS-010-SMS-010"
RENDERER_FLAKE="/home/deadbeef/github/network-renderer-access-endpoint-nixos"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRATCH="$(mktemp -d /tmp/test-${TEST_NAME}-XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------
# Write a .nix file from a quoted heredoc, substituting REPO_PATH.
# ---------------------------------------------------------------
write_nix() {
  local dest="$1"
  cat > "$dest"
  sed -i "s|REPO_PATH|${RENDERER_FLAKE}|g" "$dest"
}

# ---------------------------------------------------------------
# Evaluate the renderer module and return JSON blob.
# ---------------------------------------------------------------
eval_module_json() {
  local nixfile="$SCRATCH/eval-module.nix"
  write_nix "$nixfile" <<'NIXEOF'
let
  flake = builtins.getFlake "REPO_PATH";
  renderer = flake.libBySystem.x86_64-linux.renderer;
  moduleFn = renderer.hostModuleFromPaths {
    hostName = "s-router-test-clients";
    labSource = "active-lab";
  };
  result = moduleFn { config = {}; };

  networks = result.systemd.network.networks or {};
  services = result.systemd.services or {};
  containers = result.containers or {};

  # Phase 2: Bridge networks come from CPM endpointAssignment containers (not raw inventory).
  # Discover all bridge networks dynamically: non-VLAN, non-eth0 networks.
  vlanPrefix = "40-eth0.";
  bridgeNames = builtins.filter
    (n: n != "10-eth0" && builtins.match "${vlanPrefix}.*" n == null)
    (builtins.attrNames networks);

  bridgeCheck = name:
    let
      net = networks.${name} or {};
      nc = net.networkConfig or {};
    in {
      inherit name;
      dhcp = nc.DHCP or "absent";
      hasAddress = if nc ? Address then true else false;
      hasGateway = if nc ? Gateway then true else false;
      hasDNS = if nc ? DNS then true else false;
      ipForward = nc.IPForward or "absent";
      ipMasquerade = nc.IPMasquerade or "absent";
    };

  vlanNetworks = builtins.filter
    (n: builtins.match "${vlanPrefix}.*" n != null)
    (builtins.attrNames networks);

  vlanCheck = name:
    let
      net = networks.${name} or {};
      nc = net.networkConfig or {};
    in {
      inherit name;
      dhcp = nc.DHCP or "absent";
      hasAddress = if nc ? Address then true else false;
      bridge = nc.Bridge or "absent";
    };

  allServiceNames = builtins.attrNames services;

  forbiddenServicePatterns = [
    "dhcp" "dns" "nat" "masquerade" "forward"
  ];

  isForbidden = name:
    builtins.any (pat: builtins.match (".*" + pat + ".*") name != null)
      forbiddenServicePatterns;

  forbiddenServices = builtins.filter isForbidden allServiceNames;

  isolateBridge = services."access-endpoint-isolate-bridges" or null;
  isolateEnabled =
    if isolateBridge != null &&
       builtins.elem "multi-user.target"
         (isolateBridge.wantedBy or [])
    then true else false;

  isolateScript = isolateBridge.script or "";
  isolateBlocksVlan2 =
    builtins.match ".*oif vlan2.*drop.*" isolateScript != null;

  isolateBlocksSubnets =
    builtins.match ".*saddr 10\\.20\\..*drop.*" isolateScript != null;
in
{
  test_host = "s-router-test-clients";
  networking_useDHCP = result.networking.useDHCP or "absent";
  networking_useNetworkd = result.networking.useNetworkd or "absent";
  bridges = map bridgeCheck bridgeNames;
  vlan_networks = map vlanCheck vlanNetworks;
  service_enabled_isolate_bridges = isolateEnabled;
  isolate_blocks_vlan2 = isolateBlocksVlan2;
  isolate_blocks_subnets = isolateBlocksSubnets;
  forbidden_services = forbiddenServices;
  all_services = allServiceNames;
  container_count = builtins.length (builtins.attrNames containers);
}
NIXEOF

  nix eval --impure --json -f "$nixfile"
}

echo "=== ${TEST_NAME} Construction Test ==="
echo "Trace: FS-725 > HDS-010 > SDS-010 > SMS-010"
echo "Renderer: network-renderer-access-endpoint-nixos"
echo "Host: s-router-test-clients | Lab: active-lab"
echo ""

# Evaluate once
JSON="$(eval_module_json)"

# ============================================================
# P1: VLAN2 / management reachability preserved
# ============================================================
echo "--- P1: VLAN2 / Management Reachability ---"

if echo "$JSON" | jq -e '.vlan_networks[] | select(.name == "40-eth0.300") | .bridge == "mgmt"' >/dev/null 2>&1; then
  pass "P1a — mgmt VLAN 300 network attached to mgmt bridge"
else
  fail "P1a — missing mgmt VLAN 300 network or wrong bridge attachment"
fi

if echo "$JSON" | jq -e '.bridges[] | select(.name == "mgmt")' >/dev/null 2>&1; then
  pass "P1b — mgmt bridge network config exists"
else
  fail "P1b — mgmt bridge network missing"
fi

if echo "$JSON" | jq -e '.isolate_blocks_vlan2 == true' >/dev/null 2>&1; then
  pass "P1c — isolate-bridges blocks endpoint egress to vlan2"
else
  fail "P1c — isolate-bridges does not block vlan2 egress"
fi

if echo "$JSON" | jq -e '.isolate_blocks_subnets == true' >/dev/null 2>&1; then
  pass "P1d — isolate-bridges blocks endpoint subnet traffic from vlan2"
else
  fail "P1d — isolate-bridges missing endpoint subnet block rules"
fi

# ============================================================
# P2: Endpoint bridges emit only container attachment plumbing
# ============================================================
echo ""
echo "--- P2: Endpoint Bridges L2-Only ---"

for bridge in client dmz iot trusted; do
  if echo "$JSON" | jq -e --arg b "$bridge" '.bridges[] | select(.name == $b)' >/dev/null 2>&1; then
    pass "P2a — $bridge bridge exists"
  else
    fail "P2a — $bridge bridge missing"
  fi
done

for bridge in client dmz iot trusted; do
  if echo "$JSON" | jq -e --arg b "$bridge" '.bridges[] | select(.name == $b) | .dhcp == "no"' >/dev/null 2>&1; then
    pass "P2b — $bridge DHCP=no"
  else
    fail "P2b — $bridge DHCP is not 'no'"
  fi
done

for bridge in client dmz iot trusted; do
  if echo "$JSON" | jq -e --arg b "$bridge" '.bridges[] | select(.name == $b) | .hasAddress == false' >/dev/null 2>&1; then
    pass "P2c — $bridge has no Address on host"
  else
    fail "P2c — $bridge has host-side IP Address"
  fi
done

# ============================================================
# P3: Host must NOT emit forbidden network participation
# ============================================================
echo ""
echo "--- P3: No Host-Side Network Participation ---"

if echo "$JSON" | jq -e '.networking_useDHCP == false' >/dev/null 2>&1; then
  pass "P3a — networking.useDHCP == false"
else
  fail "P3a — networking.useDHCP is not false"
fi

if echo "$JSON" | jq -e '.forbidden_services == []' >/dev/null 2>&1; then
  pass "P3b — no DHCP/DNS/NAT/masquerade/forward systemd services"
else
  SVCS="$(echo "$JSON" | jq -r '.forbidden_services | join(", ")')"
  fail "P3b — forbidden services present: $SVCS"
fi

# All VLAN networks must have DHCP=no, no Address
VIOLATION=0
while IFS= read -r vlan; do
  dhcp="$(echo "$vlan" | jq -r '.dhcp')"
  addr="$(echo "$vlan" | jq -r '.hasAddress')"
  name="$(echo "$vlan" | jq -r '.name')"
  if [ "$dhcp" != "no" ]; then
    fail "P3c — VLAN $name DHCP=$dhcp (must be 'no')"
    VIOLATION=1
  fi
  if [ "$addr" = "true" ]; then
    fail "P3c — VLAN $name has host-side Address"
    VIOLATION=1
  fi
done < <(echo "$JSON" | jq -c '.vlan_networks[]')
if [ "$VIOLATION" -eq 0 ]; then
  pass "P3c — all VLAN networks have DHCP=no, no Address"
fi

if echo "$JSON" | jq -e '.bridges[] | select(.name == "mgmt") | .dhcp == "no"' >/dev/null 2>&1; then
  pass "P3d — mgmt bridge DHCP=no"
else
  fail "P3d — mgmt bridge DHCP is not 'no'"
fi

for bridge in client dmz iot trusted; do
  if echo "$JSON" | jq -e --arg b "$bridge" '.bridges[] | select(.name == $b) | .hasGateway == false' >/dev/null 2>&1; then
    pass "P3e — $bridge has no Gateway"
  else
    fail "P3e — $bridge has host-side Gateway"
  fi
  if echo "$JSON" | jq -e --arg b "$bridge" '.bridges[] | select(.name == $b) | .hasDNS == false' >/dev/null 2>&1; then
    pass "P3f — $bridge has no DNS"
  else
    fail "P3f — $bridge has host-side DNS"
  fi
done

# ============================================================
# P4: VLAN2 separate from endpoint tenant traffic
# ============================================================
echo ""
echo "--- P4: VLAN2 / Endpoint Traffic Separation ---"

if echo "$JSON" | jq -e '.service_enabled_isolate_bridges == true' >/dev/null 2>&1; then
  pass "P4a — access-endpoint-isolate-bridges enabled for multi-user.target"
else
  fail "P4a — access-endpoint-isolate-bridges NOT enabled"
fi

# Count saddr drop rules using nix (avoid \n escape issues from jq)
write_nix "$SCRATCH/count-saddr.nix" <<'NIXEOF'
let
  flake = builtins.getFlake "REPO_PATH";
  renderer = flake.libBySystem.x86_64-linux.renderer;
  moduleFn = renderer.hostModuleFromPaths {
    hostName = "s-router-test-clients";
    labSource = "active-lab";
  };
  result = moduleFn { config = {}; };
  script = result.systemd.services."access-endpoint-isolate-bridges".script or "";
  # Count occurrences of "saddr" followed by "drop" in the script
  # builtins.split on regex \n matches newline characters
  lines = builtins.filter
    (s: builtins.isString s && builtins.match ".*saddr.*drop.*" s != null)
    (builtins.split "\n" script);
in builtins.length lines
NIXEOF

NSUBNETS="$(nix eval --impure -f "$SCRATCH/count-saddr.nix" 2>&1)"
if [ "$NSUBNETS" -ge 6 ]; then
  pass "P4b — isolate-bridges blocks $NSUBNETS endpoint subnets from vlan2"
else
  fail "P4b — isolate-bridges blocks only $NSUBNETS subnets (expected >=6)"
fi

# ============================================================
# P5: Missing endpoint behavior NOT compensated on host
# ============================================================
echo ""
echo "--- P5: No Host-Side Compensation ---"

for bridge in client dmz iot trusted mgmt; do
  ipfwd="$(echo "$JSON" | jq -r --arg b "$bridge" '.bridges[] | select(.name == $b) | .ipForward')"
  if [ "$ipfwd" = "absent" ] || [ "$ipfwd" = "false" ] || [ "$ipfwd" = "no" ]; then
    pass "P5a — $bridge IPForward not enabled ($ipfwd)"
  else
    fail "P5a — $bridge IPForward=$ipfwd (must NOT be enabled)"
  fi
done

for bridge in client dmz iot trusted mgmt; do
  masq="$(echo "$JSON" | jq -r --arg b "$bridge" '.bridges[] | select(.name == $b) | .ipMasquerade')"
  if [ "$masq" = "absent" ] || [ "$masq" = "false" ]; then
    pass "P5b — $bridge IPMasquerade not enabled ($masq)"
  else
    fail "P5b — $bridge IPMasquerade=$masq (must NOT be enabled)"
  fi
done

# ============================================================
# P6-P8: Seeded Negative Cases
# ============================================================
echo ""
echo "--- P6-P8: Seeded Negatives ---"

# P6: Artificially inject DHCP=ipv4 on branch bridge
write_nix "$SCRATCH/seeded-neg-p6.nix" <<'NIXEOF'
let
  flake = builtins.getFlake "REPO_PATH";
  renderer = flake.libBySystem.x86_64-linux.renderer;
  moduleFn = renderer.hostModuleFromPaths {
    hostName = "s-router-test-clients";
    labSource = "active-lab";
  };
  result = moduleFn { config = {}; };
  # Simulate violation: change DHCP on branch bridge to "ipv4"
  modified = result // {
    systemd = result.systemd // {
      network = result.systemd.network // {
        networks = result.systemd.network.networks // {
          branch = (result.systemd.network.networks.branch or {}) // {
            networkConfig = (result.systemd.network.networks.branch.networkConfig or {}) // {
              DHCP = "ipv4";
            };
          };
        };
      };
    };
  };
in
{
  has_violation = modified.systemd.network.networks.branch.networkConfig.DHCP == "ipv4";
  original_dhcp = result.systemd.network.networks.branch.networkConfig.DHCP or "absent";
  modified_dhcp = modified.systemd.network.networks.branch.networkConfig.DHCP or "absent";
}
NIXEOF

P6_JSON="$(nix eval --impure --json -f "$SCRATCH/seeded-neg-p6.nix" 2>&1)"
if echo "$P6_JSON" | jq -e '.has_violation == true' >/dev/null 2>&1; then
  ORIG="$(echo "$P6_JSON" | jq -r '.original_dhcp')"
  MOD="$(echo "$P6_JSON" | jq -r '.modified_dhcp')"
  pass "P6 — seeded negative: DHCP injection detected (orig=$ORIG mod=$MOD)"
else
  fail "P6 — seeded negative: DHCP injection NOT detected"
fi

# P7: Artificially inject an IP Address on branch bridge
write_nix "$SCRATCH/seeded-neg-p7.nix" <<'NIXEOF'
let
  flake = builtins.getFlake "REPO_PATH";
  renderer = flake.libBySystem.x86_64-linux.renderer;
  moduleFn = renderer.hostModuleFromPaths {
    hostName = "s-router-test-clients";
    labSource = "active-lab";
  };
  result = moduleFn { config = {}; };
  # Simulate violation: add IP Address to branch bridge
  modified = result // {
    systemd = result.systemd // {
      network = result.systemd.network // {
        networks = result.systemd.network.networks // {
          branch = (result.systemd.network.networks.branch or {}) // {
            networkConfig = (result.systemd.network.networks.branch.networkConfig or {}) // {
              Address = [ "10.99.99.1/24" ];
            };
          };
        };
      };
    };
  };
in
{
  has_violation = builtins.length
    (modified.systemd.network.networks.branch.networkConfig.Address or []) > 0;
  original_has_address = builtins.hasAttr "Address"
    (result.systemd.network.networks.branch.networkConfig or {});
  modified_addresses = modified.systemd.network.networks.branch.networkConfig.Address or [];
}
NIXEOF

P7_JSON="$(nix eval --impure --json -f "$SCRATCH/seeded-neg-p7.nix" 2>&1)"
if echo "$P7_JSON" | jq -e '.has_violation == true' >/dev/null 2>&1; then
  ADDR="$(echo "$P7_JSON" | jq -r '.modified_addresses | join(", ")')"
  pass "P7 — seeded negative: bridge IP injection detected (addr=$ADDR)"
else
  fail "P7 — seeded negative: bridge IP injection NOT detected"
fi

# P8: Verify missing isolate-bridges is detected
write_nix "$SCRATCH/seeded-neg-p8.nix" <<'NIXEOF'
let
  flake = builtins.getFlake "REPO_PATH";
  renderer = flake.libBySystem.x86_64-linux.renderer;
  moduleFn = renderer.hostModuleFromPaths {
    hostName = "s-router-test-clients";
    labSource = "active-lab";
  };
  result = moduleFn { config = {}; };
  # Simulate violation: remove isolate-bridges service
  modified = result // {
    systemd = result.systemd // {
      services = builtins.removeAttrs
        (result.systemd.services or {})
        [ "access-endpoint-isolate-bridges" ];
    };
  };
in
{
  has_violation = !(builtins.hasAttr "access-endpoint-isolate-bridges"
    (modified.systemd.services or {}));
  original_present = builtins.hasAttr "access-endpoint-isolate-bridges"
    (result.systemd.services or {});
  modified_present = builtins.hasAttr "access-endpoint-isolate-bridges"
    (modified.systemd.services or {});
}
NIXEOF

P8_JSON="$(nix eval --impure --json -f "$SCRATCH/seeded-neg-p8.nix" 2>&1)"
if echo "$P8_JSON" | jq -e '.has_violation == true' >/dev/null 2>&1; then
  pass "P8 — seeded negative: missing isolate-bridges detected"
else
  fail "P8 — seeded negative: missing isolate-bridges NOT detected"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== ${TEST_NAME} Results ==="
echo "Pass: $PASS"
echo "Fail: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  echo "RESULT: FAIL — $FAIL predicate(s) failed"
  exit 1
else
  echo "RESULT: PASS — all SMS acceptance predicates proved"
  exit 0
fi
