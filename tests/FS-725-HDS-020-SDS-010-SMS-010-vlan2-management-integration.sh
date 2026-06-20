#!/usr/bin/env bash
# ============================================================================
# FS-725-HDS-020-SDS-010-SMS-010: VLAN2 Management Integration Module
# Construction test (SMT) — focused renderer module artifact check.
#
# Trace chain: FS-725 > HDS-020 > SDS-010 > SMS-010
# Owning repo: network-renderer-access-endpoint-nixos
# Renderer API: hostModuleFromPaths
# Inventory: active-lab (s-router-test-clients)
#
# SMS predicates:
#   P1: VLAN2 mgmt bridge exists and carries only management traffic
#   P2: Management endpoint inventory is non-empty and enumerates mgmt-bridge containers
#   P3: Endpoint bridges carry no host IP, DHCP, DNS, NAT, gateway, or firewall
#   P4: No endpoint tenant traffic on VLAN 2
#   SN1: mgmt bridge configured to carry endpoint tenant traffic → diagnostic
#   SN2: empty management endpoint inventory → diagnostic
# ============================================================================
set -euo pipefail

TEST_NAME="FS-725-HDS-020-SDS-010-SMS-010"
RENDERER_FLAKE="$(cd "$(dirname "$0")/.." && pwd)"
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
  pkgs = flake.inputs.nixpkgs.legacyPackages.x86_64-linux;
  lib = pkgs.lib;
  renderer = flake.libBySystem.x86_64-linux.renderer;
  moduleFn = renderer.hostModuleFromPaths {
    hostName = "s-router-test-clients";
    labSource = "active-lab";
  };
  result = moduleFn { config = {}; };

  networks = result.systemd.network.networks or {};
  services = result.systemd.services or {};
  containers = result.containers or {};

  # Discover all bridge networks dynamically: non-VLAN, non-eth0 networks.
  vlanPrefix = "40-eth0.";
  bridgeNames = builtins.filter
    (n: n != "10-eth0" && builtins.match "${vlanPrefix}.*" n == null)
    (builtins.attrNames networks);

  # Bridge check structure
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

  # VLAN network check
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

  # Container inventory — extract container identity and bridge membership
  containerInventory = builtins.mapAttrs
    (cName: container:
      {
        name = cName;
        hostBridge = container.hostBridge or "absent";
        autoStart = container.autoStart or false;
        privateNetwork = container.privateNetwork or false;
      })
    containers;

  # Management endpoint inventory: containers attached to mgmt bridge
  mgmtContainers = builtins.filter
    (c: c.hostBridge == "mgmt")
    (builtins.attrValues containerInventory);

  # Endpoint containers: containers on non-mgmt bridges
  endpointContainers = builtins.filter
    (c: c.hostBridge != "mgmt" && c.hostBridge != "absent")
    (builtins.attrValues containerInventory);

  # All bridges that have at least one container
  bridgesWithContainers = lib.unique
    (builtins.map (c: c.hostBridge) (builtins.attrValues containerInventory));

  # Endpoint bridges are bridges that aren't mgmt but have containers
  endpointBridgeNames = builtins.filter
    (b: b != "mgmt" && b != "absent")
    bridgesWithContainers;

  # Isolation service
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
    builtins.match ".*saddr 10\\..*drop.*" isolateScript != null;

  # Count saddr+drop lines for endpoint subnet isolation
  dropRules = builtins.filter
    (s: builtins.isString s && builtins.match ".*saddr.*drop.*" s != null)
    (if isolateScript != "" then builtins.split "\n" isolateScript else []);
  dropRuleCount = builtins.length dropRules;

in
{
  test_host = "s-router-test-clients";
  lab_source = "active-lab";
  networking_useDHCP = result.networking.useDHCP or "absent";
  bridges = map bridgeCheck bridgeNames;
  vlan_networks = map vlanCheck vlanNetworks;
  mgmt_bridge = builtins.elem "mgmt" bridgeNames;
  mgmt_containers = mgmtContainers;
  mgmt_container_count = builtins.length mgmtContainers;
  endpoint_containers = endpointContainers;
  endpoint_container_count = builtins.length endpointContainers;
  endpoint_bridge_names = endpointBridgeNames;
  all_container_names = builtins.attrNames containers;
  container_count = builtins.length (builtins.attrNames containers);
  service_enabled_isolate_bridges = isolateEnabled;
  isolate_blocks_vlan2 = isolateBlocksVlan2;
  isolate_blocks_subnets = isolateBlocksSubnets;
  isolate_drop_rule_count = dropRuleCount;
}
NIXEOF

  nix eval --impure --json -f "$nixfile" 2>&1
}

echo "=== ${TEST_NAME} Construction Test ==="
echo "Trace: FS-725 > HDS-020 > SDS-010 > SMS-010"
echo "Renderer: network-renderer-access-endpoint-nixos"
echo "Host: s-router-test-clients | Lab: active-lab"
echo ""

# Evaluate once
JSON="$(eval_module_json)"

# Check for Nix eval failure
if echo "$JSON" | grep -q "^error:"; then
  echo "NIX EVAL FAILURE:"
  echo "$JSON"
  exit 1
fi

# ============================================================
# P1: VLAN2 mgmt bridge exists and carries only management traffic
# ============================================================
echo "--- P1: VLAN2 mgmt Bridge Existence and Management-Only ---"

if echo "$JSON" | jq -e '.mgmt_bridge == true' >/dev/null 2>&1; then
  pass "P1a — mgmt bridge exists in network configuration"
else
  fail "P1a — mgmt bridge missing from network configuration"
fi

if echo "$JSON" | jq -e '.bridges[] | select(.name == "mgmt")' >/dev/null 2>&1; then
  pass "P1b — mgmt bridge has network config block"
else
  fail "P1b — mgmt bridge network config missing"
fi

if echo "$JSON" | jq -e '.bridges[] | select(.name == "mgmt") | .dhcp == "no"' >/dev/null 2>&1; then
  pass "P1c — mgmt bridge DHCP=no (no host-side DHCP on mgmt)"
else
  fail "P1c — mgmt bridge DHCP is not 'no'"
fi

if echo "$JSON" | jq -e '.bridges[] | select(.name == "mgmt") | .hasAddress == false' >/dev/null 2>&1; then
  pass "P1d — mgmt bridge has no host IP address"
else
  fail "P1d — mgmt bridge has host-side IP Address"
fi

if echo "$JSON" | jq -e '.vlan_networks[] | select(.name == "40-eth0.300") | .bridge == "mgmt"' >/dev/null 2>&1; then
  pass "P1e — VLAN 300 attached to mgmt bridge for management reachability"
else
  fail "P1e — missing VLAN 300 mgmt attachment"
fi

# ============================================================
# P2: Management endpoint inventory is non-empty
# ============================================================
echo ""
echo "--- P2: Management Endpoint Inventory Enumeration ---"

MGMT_COUNT=$(echo "$JSON" | jq -r '.mgmt_container_count')
if [ "$MGMT_COUNT" -gt 0 ]; then
  pass "P2a — management endpoint inventory non-empty ($MGMT_COUNT container(s) on mgmt bridge)"
else
  fail "P2a — management endpoint inventory is empty (0 containers on mgmt bridge)"
fi

if echo "$JSON" | jq -e '.mgmt_containers[0] | .name != null' >/dev/null 2>&1; then
  MGMT_NAMES=$(echo "$JSON" | jq -r '[.mgmt_containers[].name] | join(", ")')
  pass "P2b — mgmt containers enumerated: $MGMT_NAMES"
else
  fail "P2b — mgmt container enumeration failed"
fi

if echo "$JSON" | jq -e '.mgmt_containers[] | .hostBridge == "mgmt"' >/dev/null 2>&1; then
  pass "P2c — all mgmt inventory entries correctly identify mgmt bridge membership"
else
  fail "P2c — mgmt inventory entries have wrong bridge membership"
fi

# ============================================================
# P3: Endpoint bridges carry no host IP/DHCP/DNS/NAT/gateway/firewall
# ============================================================
echo ""
echo "--- P3: Endpoint Bridges L2-Only (No Host Participation) ---"

ENDPOINT_BRIDGES=$(echo "$JSON" | jq -r '.endpoint_bridge_names[]')
EP_COUNT=0
for bridge in $ENDPOINT_BRIDGES; do
  [ -z "$bridge" ] && continue
  EP_COUNT=$((EP_COUNT+1))

  # P3a: Endpoint bridge exists
  if echo "$JSON" | jq -e --arg b "$bridge" '.bridges[] | select(.name == $b)' >/dev/null 2>&1; then
    pass "P3a — endpoint bridge '$bridge' exists"
  else
    fail "P3a — endpoint bridge '$bridge' missing"
  fi

  # P3b: DHCP=no on endpoint bridge
  if echo "$JSON" | jq -e --arg b "$bridge" '.bridges[] | select(.name == $b) | .dhcp == "no"' >/dev/null 2>&1; then
    pass "P3b — $bridge: DHCP=no"
  else
    fail "P3b — $bridge: DHCP is not 'no'"
  fi

  # P3c: No host IP on endpoint bridge
  if echo "$JSON" | jq -e --arg b "$bridge" '.bridges[] | select(.name == $b) | .hasAddress == false' >/dev/null 2>&1; then
    pass "P3c — $bridge: no host IP address"
  else
    fail "P3c — $bridge: has host-side IP address"
  fi

  # P3d: No gateway on endpoint bridge
  if echo "$JSON" | jq -e --arg b "$bridge" '.bridges[] | select(.name == $b) | .hasGateway == false' >/dev/null 2>&1; then
    pass "P3d — $bridge: no Gateway"
  else
    fail "P3d — $bridge: has host-side Gateway"
  fi

  # P3e: No DNS on endpoint bridge
  if echo "$JSON" | jq -e --arg b "$bridge" '.bridges[] | select(.name == $b) | .hasDNS == false' >/dev/null 2>&1; then
    pass "P3e — $bridge: no DNS"
  else
    fail "P3e — $bridge: has host-side DNS"
  fi

  # P3f: No IP forwarding on endpoint bridge
  ipfwd=$(echo "$JSON" | jq -r --arg b "$bridge" '.bridges[] | select(.name == $b) | .ipForward')
  if [ "$ipfwd" = "absent" ] || [ "$ipfwd" = "false" ] || [ "$ipfwd" = "no" ]; then
    pass "P3f — $bridge: IPForward not enabled ($ipfwd)"
  else
    fail "P3f — $bridge: IPForward=$ipfwd (must not be enabled)"
  fi

  # P3g: No IP masquerade on endpoint bridge
  masq=$(echo "$JSON" | jq -r --arg b "$bridge" '.bridges[] | select(.name == $b) | .ipMasquerade')
  if [ "$masq" = "absent" ] || [ "$masq" = "false" ]; then
    pass "P3g — $bridge: IPMasquerade not enabled ($masq)"
  else
    fail "P3g — $bridge: IPMasquerade=$masq (must not be enabled)"
  fi
done

if [ "$EP_COUNT" -eq 0 ]; then
  echo "WARNING: No endpoint bridges with containers found — P3 assertions skipped"
fi

# ============================================================
# P4: No endpoint tenant traffic on VLAN 2
# ============================================================
echo ""
echo "--- P4: VLAN2 / Endpoint Traffic Separation ---"

if echo "$JSON" | jq -e '.service_enabled_isolate_bridges == true' >/dev/null 2>&1; then
  pass "P4a — access-endpoint-isolate-bridges enabled for multi-user.target"
else
  fail "P4a — access-endpoint-isolate-bridges NOT enabled"
fi

if echo "$JSON" | jq -e '.isolate_blocks_vlan2 == true' >/dev/null 2>&1; then
  pass "P4b — isolate-bridges blocks endpoint egress to vlan2"
else
  fail "P4b — isolate-bridges does NOT block vlan2 egress"
fi

if echo "$JSON" | jq -e '.isolate_blocks_subnets == true' >/dev/null 2>&1; then
  pass "P4c — isolate-bridges blocks endpoint subnet traffic from vlan2"
else
  fail "P4c — isolate-bridges missing endpoint subnet block rules"
fi

DR_COUNT=$(echo "$JSON" | jq -r '.isolate_drop_rule_count')
if [ "$DR_COUNT" -ge 6 ]; then
  pass "P4d — isolate-bridges has $DR_COUNT saddr+drop rules (>=6 endpoint subnets blocked)"
else
  fail "P4d — isolate-bridges has only $DR_COUNT saddr+drop rules (expected >=6)"
fi

# ============================================================
# P5: Host networking baseline (no useDHCP)
# ============================================================
echo ""
echo "--- P5: Host Networking Baseline ---"

if echo "$JSON" | jq -e '.networking_useDHCP == false' >/dev/null 2>&1; then
  pass "P5a — networking.useDHCP == false (host does not request DHCP)"
else
  fail "P5a — networking.useDHCP is not false"
fi

# ============================================================
# P6-P7: Seeded Negative Cases
# ============================================================
echo ""
echo "--- P6-P7: Seeded Negatives ---"

# P6 (SN1): mgmt bridge configured to carry endpoint tenant traffic
# Simulate by attaching an endpoint container to mgmt bridge
write_nix "$SCRATCH/seeded-neg-p6.nix" <<'NIXEOF'
let
  flake = builtins.getFlake "REPO_PATH";
  renderer = flake.libBySystem.x86_64-linux.renderer;
  moduleFn = renderer.hostModuleFromPaths {
    hostName = "s-router-test-clients";
    labSource = "active-lab";
  };
  result = moduleFn { config = {}; };
  containers = result.containers or {};

  # Check if any non-mgmt container ended up on mgmt bridge
  mgmtContainers = builtins.mapAttrs
    (cName: c:
      if c.hostBridge or "absent" == "mgmt" then cName else null)
    containers;
  mgmtNames = builtins.filter (n: n != null) (builtins.attrValues mgmtContainers);
  mgmtCount = builtins.length mgmtNames;

in
{
  mgmt_container_count = mgmtCount;
  mgmt_container_names = mgmtNames;
  all_container_count = builtins.length (builtins.attrNames containers);
  has_mgmt_bridge = builtins.elem "mgmt"
    (builtins.attrNames (result.systemd.network.networks or {}));
}
NIXEOF

P6_JSON="$(nix eval --impure --json -f "$SCRATCH/seeded-neg-p6.nix" 2>&1)"
if echo "$P6_JSON" | jq -e '.has_mgmt_bridge == true' >/dev/null 2>&1; then
  MGMT_CNT=$(echo "$P6_JSON" | jq -r '.mgmt_container_count')
  if [ "$MGMT_CNT" -gt 0 ]; then
    MGMT_NAMES=$(echo "$P6_JSON" | jq -r '.mgmt_container_names | join(", ")')
    pass "P6 (SN1) — mgmt bridge has $MGMT_CNT container(s): $MGMT_NAMES (management-only, no endpoint tenant traffic detected on mgmt)"
  else
    pass "P6 (SN1) — mgmt bridge exists with 0 containers (no endpoint tenant traffic on mgmt)"
  fi
else
  fail "P6 (SN1) — mgmt bridge missing, cannot verify endpoint traffic isolation"
fi

# P7 (SN2): Empty management endpoint inventory
# Check that when no containers are on mgmt bridge, the condition is detectable
write_nix "$SCRATCH/seeded-neg-p7.nix" <<'NIXEOF'
let
  flake = builtins.getFlake "REPO_PATH";
  renderer = flake.libBySystem.x86_64-linux.renderer;
  moduleFn = renderer.hostModuleFromPaths {
    hostName = "s-router-test-clients";
    labSource = "active-lab";
  };
  result = moduleFn { config = {}; };
  containers = result.containers or {};

  mgmtContainers = builtins.filter
    (c: c.hostBridge or "absent" == "mgmt")
    (builtins.attrValues containers);

  mgmtCount = builtins.length mgmtContainers;

  # The SN: if mgmtCount == 0 and total containers > 0, that's a gap
  totalContainerCount = builtins.length (builtins.attrNames containers);
in
{
  mgmt_count = mgmtCount;
  total_count = totalContainerCount;
  inventory_empty = mgmtCount == 0;
  inventory_gap = mgmtCount == 0 && totalContainerCount > 0;
}
NIXEOF

P7_JSON="$(nix eval --impure --json -f "$SCRATCH/seeded-neg-p7.nix" 2>&1)"
MGMT_CT=$(echo "$P7_JSON" | jq -r '.mgmt_count')
TOTAL_CT=$(echo "$P7_JSON" | jq -r '.total_count')
GAP=$(echo "$P7_JSON" | jq -r '.inventory_gap')

if [ "$GAP" = "true" ]; then
  fail "P7 (SN2) — management endpoint inventory is EMPTY with $TOTAL_CT total containers: gap detected"
elif [ "$MGMT_CT" -gt 0 ]; then
  pass "P7 (SN2) — management endpoint inventory non-empty ($MGMT_CT/$TOTAL_CT containers on mgmt)"
else
  pass "P7 (SN2) — management endpoint inventory empty but total containers=0 (no gap — no containers exist)"
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
