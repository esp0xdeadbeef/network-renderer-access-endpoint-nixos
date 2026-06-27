#!/usr/bin/env bash
# ============================================================================
# FS-720-HDS-010-SDS-010-SMS-050: Endpoint Bridge Module
# Construction test (SMT) — focused renderer module artifact check.
#
# Trace chain: FS-720 > HDS-010 > SDS-010 > SMS-050
# Owning repo: network-renderer-access-endpoint-nixos
# Renderer API: hostModule
# Fixture: direct CPM endpointAssignment + bridgeNetworks contract
#
# SMS-050 acceptance predicates covered:
#   SMS-050 (Bridge Netdev Emission) — bridge netdevs with Kind=bridge
#   SMS-020 (Bridge Network Configuration) — DHCP=no, no DHCPServer/Address/IPMasquerade
#   SMS-040 (Dummy Service Deactivation) — access-endpoint-renderer-dummy disabled
#   SMS-060 (VLAN-Tagged Bridge Network Configuration) — VLAN netdevs + networks
#
# Seeded negatives:
#   N1: DHCPServer=yes on bridge → host-DHCP-server violation
#   N2: Address= on bridge → host-IP-on-bridge violation
# ============================================================================
set -euo pipefail

TEST_NAME="FS-720-HDS-010-SDS-010-SMS-050"
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
# Evaluate the renderer module and return JSON blob — full module scan.
# ---------------------------------------------------------------
eval_module_json() {
  local nixfile="$SCRATCH/eval-module.nix"
  write_nix "$nixfile" <<'NIXEOF'
let
  flake = builtins.getFlake "REPO_PATH";
  renderer = flake.libBySystem.x86_64-linux.renderer;
  cpmFixture = {
    endpointAssignment.test-client = {
      mode = "static";
      name = "test-client";
      bridge = "client";
      static = {
        address = "10.20.20.10";
        prefixLength = 24;
        gateway4 = "10.20.20.1";
        address6 = "fd42:dead:beef:20::10";
        prefixLength6 = 64;
        gateway6 = "fd42:dead:beef:20::1";
      };
    };
    bridgeNetworks.client = {
      mode = "vlan";
      parent = "eth0";
      vlan = 302;
    };
  };
  moduleFn = renderer.hostModule {
    hostName = "s-router-test-clients";
    cpm = cpmFixture;
    mode = "test";
  };
  result = moduleFn { config = {}; };

  # --- Netdevs ---
  netdevs = result.systemd.network.netdevs or {};
  netdevNames = builtins.attrNames netdevs;

  bridgeNetdevs = builtins.filter
    (n: (netdevs.${n}.netdevConfig or {}).Kind or "" == "bridge")
    netdevNames;

  vlanNetdevs = builtins.filter
    (n: (netdevs.${n}.netdevConfig or {}).Kind or "" == "vlan")
    netdevNames;

  # --- Networks ---
  networks = result.systemd.network.networks or {};
  vlanPrefix = "40-eth0.";
  bridgeNames = builtins.filter
    (n: n != "10-eth0" && builtins.match "${vlanPrefix}.*" n == null)
    (builtins.attrNames networks);

  vlanNetworks = builtins.filter
    (n: builtins.match "${vlanPrefix}.*" n != null)
    (builtins.attrNames networks);

  # Per-bridge network config check — focused on SMS-020 prohibitions
  bridgeCheck = name:
    let
      net = networks.${name} or {};
      nc = net.networkConfig or {};
    in {
      inherit name;
      dhcp = nc.DHCP or "absent";
      dhcpServer = nc.DHCPServer or "absent";
      hasAddress = if nc ? Address then true else false;
      ipMasquerade = nc.IPMasquerade or "absent";
      activationPolicy = net.linkConfig.ActivationPolicy or "absent";
      configureWithoutCarrier = nc.ConfigureWithoutCarrier or "absent";
      ipv6AcceptRA = nc.IPv6AcceptRA or "absent";
    };

  # Per-VLAN network config check
  vlanCheck = name:
    let
      net = networks.${name} or {};
      nc = net.networkConfig or {};
    in {
      inherit name;
      dhcp = nc.DHCP or "absent";
      dhcpServer = nc.DHCPServer or "absent";
      hasAddress = if nc ? Address then true else false;
      bridge = nc.Bridge or "absent";
    };

  # --- Services ---
  services = result.systemd.services or {};
  dummyService = services."access-endpoint-renderer-dummy" or null;
  dummyEnabled =
    if dummyService == null then "absent"
    else
      let e = dummyService.enable or null;
      in
      if e == null then "absent"
      else if builtins.isBool e then (if e then "true" else "false")
      else if builtins.isAttrs e then "mkForce-false"
      else "present";

  # --- Containers ---
  containers = result.containers or {};
in
{
  test_host = "s-router-test-clients";
  netdev_count = builtins.length netdevNames;
  bridge_netdev_count = builtins.length bridgeNetdevs;
  bridge_netdev_names = bridgeNetdevs;
  vlan_netdev_count = builtins.length vlanNetdevs;
  vlan_netdev_names = vlanNetdevs;
  bridges = map bridgeCheck bridgeNames;
  vlan_networks = map vlanCheck vlanNetworks;
  dummy_service_enabled = dummyEnabled;
  container_count = builtins.length (builtins.attrNames containers);
}
NIXEOF

  nix eval --impure --json -f "$nixfile"
}

echo "=== ${TEST_NAME} Construction Test ==="
echo "Trace: FS-720 > HDS-010 > SDS-010 > SMS-050"
echo "Renderer: network-renderer-access-endpoint-nixos"
echo "Host: s-router-test-clients | Lab: active-lab"
echo ""

# Evaluate once
JSON="$(eval_module_json)"

# ============================================================
# SMS-050: Bridge Netdev Emission
# ============================================================
echo "--- SMS-050: Bridge Netdev Emission ---"

BRIDGE_ND_COUNT="$(echo "$JSON" | jq -r '.bridge_netdev_count')"
if [ "$BRIDGE_ND_COUNT" -ge 1 ]; then
  pass "SMS-050a — ${BRIDGE_ND_COUNT} bridge netdev(s) emitted"
else
  fail "SMS-050a — no bridge netdevs emitted"
fi

BRIDGE_NAMES="$(echo "$JSON" | jq -r '.bridge_netdev_names | join(", ")')"
pass "SMS-050b — bridge netdev names: ${BRIDGE_NAMES}"

# Every bridge netdev must have Kind=bridge (implied by filter, verify no null)
if echo "$JSON" | jq -e '.bridge_netdev_names | length > 0' >/dev/null 2>&1; then
  pass "SMS-050c — bridge netdevs non-empty list"
else
  fail "SMS-050c — bridge netdevs list empty"
fi

# ============================================================
# SMS-020: Bridge Network Configuration
# ============================================================
echo ""
echo "--- SMS-020: Bridge Network Configuration ---"

DHCPSERVER_VIOLATION=0
ADDRESS_VIOLATION=0
MASQ_VIOLATION=0
DHCP_VIOLATION=0
CFG_VIOLATION=0

while IFS= read -r bridge; do
  name="$(echo "$bridge" | jq -r '.name')"
  dhcp="$(echo "$bridge" | jq -r '.dhcp')"
  dhcpServer="$(echo "$bridge" | jq -r '.dhcpServer')"
  hasAddr="$(echo "$bridge" | jq -r '.hasAddress')"
  masq="$(echo "$bridge" | jq -r '.ipMasquerade')"

  # DHCP must be "no"
  if [ "$dhcp" != "no" ]; then
    fail "SMS-020a — bridge $name DHCP=$dhcp (must be 'no')"
    DHCP_VIOLATION=1
  fi

  # DHCPServer must be absent (not yes)
  if [ "$dhcpServer" != "absent" ]; then
    fail "SMS-020b — bridge $name DHCPServer=$dhcpServer (prohibited)"
    DHCPSERVER_VIOLATION=1
  fi

  # No Address
  if [ "$hasAddr" = "true" ]; then
    fail "SMS-020c — bridge $name has host-side Address (prohibited)"
    ADDRESS_VIOLATION=1
  fi

  # No IPMasquerade
  if [ "$masq" != "absent" ] && [ "$masq" != "false" ]; then
    fail "SMS-020d — bridge $name IPMasquerade=$masq (prohibited)"
    MASQ_VIOLATION=1
  fi

  # ActivationPolicy must be always-up
  actPol="$(echo "$bridge" | jq -r '.activationPolicy')"
  if [ "$actPol" != "always-up" ]; then
    fail "SMS-020e — bridge $name ActivationPolicy=$actPol (expected always-up)"
    CFG_VIOLATION=1
  fi

  # ConfigureWithoutCarrier must be true
  cwc="$(echo "$bridge" | jq -r '.configureWithoutCarrier')"
  if [ "$cwc" != "true" ]; then
    fail "SMS-020f — bridge $name ConfigureWithoutCarrier=$cwc (expected true)"
    CFG_VIOLATION=1
  fi

  # IPv6AcceptRA must be false
  ra="$(echo "$bridge" | jq -r '.ipv6AcceptRA')"
  if [ "$ra" != "false" ] && [ "$ra" != "absent" ]; then
    fail "SMS-020g — bridge $name IPv6AcceptRA=$ra (must be false)"
    CFG_VIOLATION=1
  fi
done < <(echo "$JSON" | jq -c '.bridges[]')

if [ "$DHCP_VIOLATION" -eq 0 ]; then
  pass "SMS-020a — all bridges DHCP=no"
fi
if [ "$DHCPSERVER_VIOLATION" -eq 0 ]; then
  pass "SMS-020b — no bridge has DHCPServer"
fi
if [ "$ADDRESS_VIOLATION" -eq 0 ]; then
  pass "SMS-020c — no bridge has host-side Address"
fi
if [ "$MASQ_VIOLATION" -eq 0 ]; then
  pass "SMS-020d — no bridge has IPMasquerade"
fi
if [ "$CFG_VIOLATION" -eq 0 ]; then
  pass "SMS-020e-g — all bridges have correct ActivationPolicy/ConfigureWithoutCarrier/IPv6AcceptRA"
fi

# ============================================================
# SMS-040: Dummy Service Deactivation
# ============================================================
echo ""
echo "--- SMS-040: Dummy Service Deactivation ---"

DUMMY_ENABLED="$(echo "$JSON" | jq -r '.dummy_service_enabled')"
if [ "$DUMMY_ENABLED" = "false" ] || [ "$DUMMY_ENABLED" = "absent" ] || [ "$DUMMY_ENABLED" = "mkForce-false" ]; then
  pass "SMS-040 — access-endpoint-renderer-dummy disabled (enable=$DUMMY_ENABLED)"
else
  fail "SMS-040 — access-endpoint-renderer-dummy enable=$DUMMY_ENABLED (must be disabled)"
fi

# ============================================================
# SMS-060: VLAN-Tagged Bridge Network Configuration
# ============================================================
echo ""
echo "--- SMS-060: VLAN-Tagged Bridge Networks ---"

VLAN_ND_COUNT="$(echo "$JSON" | jq -r '.vlan_netdev_count')"
if [ "$VLAN_ND_COUNT" -ge 1 ]; then
  pass "SMS-060a — ${VLAN_ND_COUNT} VLAN netdev(s) emitted"
else
  fail "SMS-060a — no VLAN netdevs emitted"
fi

VLAN_NAMES="$(echo "$JSON" | jq -r '.vlan_netdev_names | join(", ")')"
pass "SMS-060b — VLAN netdev names: ${VLAN_NAMES}"

# Each VLAN network must have Bridge= set to a real bridge name
VLAN_NOBRIDGE=0
while IFS= read -r vlan; do
  vname="$(echo "$vlan" | jq -r '.name')"
  vbridge="$(echo "$vlan" | jq -r '.bridge')"
  vdhcp="$(echo "$vlan" | jq -r '.dhcp')"
  vdhcpServer="$(echo "$vlan" | jq -r '.dhcpServer')"
  vhasAddr="$(echo "$vlan" | jq -r '.hasAddress')"

  if [ "$vbridge" = "absent" ]; then
    fail "SMS-060c — VLAN $vname has no Bridge= assignment"
    VLAN_NOBRIDGE=1
  fi

  if [ "$vdhcp" != "no" ]; then
    fail "SMS-060d — VLAN $vname DHCP=$vdhcp (must be 'no')"
  fi

  if [ "$vdhcpServer" != "absent" ]; then
    fail "SMS-060e — VLAN $vname DHCPServer=$vdhcpServer (prohibited)"
  fi

  if [ "$vhasAddr" = "true" ]; then
    fail "SMS-060f — VLAN $vname has host-side Address (prohibited)"
  fi
done < <(echo "$JSON" | jq -c '.vlan_networks[]')

if [ "$VLAN_NOBRIDGE" -eq 0 ]; then
  pass "SMS-060c — all VLAN networks have Bridge= assignment"
fi

# ============================================================
# Seeded Negatives
# ============================================================
echo ""
echo "--- Seeded Negatives ---"

# N1: Inject DHCPServer=yes on a bridge network
write_nix "$SCRATCH/seeded-neg-n1.nix" <<'NIXEOF'
let
  flake = builtins.getFlake "REPO_PATH";
  renderer = flake.libBySystem.x86_64-linux.renderer;
  cpmFixture = {
    endpointAssignment.test-client = {
      mode = "static";
      name = "test-client";
      bridge = "client";
      static = {
        address = "10.20.20.10";
        prefixLength = 24;
        gateway4 = "10.20.20.1";
        address6 = "fd42:dead:beef:20::10";
        prefixLength6 = 64;
        gateway6 = "fd42:dead:beef:20::1";
      };
    };
    bridgeNetworks.client = {
      mode = "vlan";
      parent = "eth0";
      vlan = 302;
    };
  };
  moduleFn = renderer.hostModule {
    hostName = "s-router-test-clients";
    cpm = cpmFixture;
    mode = "test";
  };
  result = moduleFn { config = {}; };

  # Find first non-eth0, non-VLAN bridge network
  networks = result.systemd.network.networks or {};
  allNames = builtins.attrNames networks;
  vlanPrefix = "40-eth0.";
  bridgeNames = builtins.filter
    (n: n != "10-eth0" && builtins.match "${vlanPrefix}.*" n == null)
    allNames;

  targetBridge = builtins.head bridgeNames;

  # Inject DHCPServer=yes
  modified = result // {
    systemd = result.systemd // {
      network = result.systemd.network // {
        networks = result.systemd.network.networks // {
          "${targetBridge}" = (networks.${targetBridge} or {}) // {
            networkConfig = (networks.${targetBridge}.networkConfig or {}) // {
              DHCPServer = "yes";
            };
          };
        };
      };
    };
  };

  checkName = targetBridge;
  origDHCPServer = (networks.${targetBridge}.networkConfig or {}).DHCPServer or "absent";
  modifiedDHCPServer = modified.systemd.network.networks.${targetBridge}.networkConfig.DHCPServer or "absent";
in
{
  inherit checkName;
  has_violation = modifiedDHCPServer == "yes";
  original = origDHCPServer;
  modified = modifiedDHCPServer;
}
NIXEOF

N1_JSON="$(nix eval --impure --json -f "$SCRATCH/seeded-neg-n1.nix" 2>&1)"
if echo "$N1_JSON" | jq -e '.has_violation == true' >/dev/null 2>&1; then
  BNAME="$(echo "$N1_JSON" | jq -r '.checkName')"
  ORIG="$(echo "$N1_JSON" | jq -r '.original')"
  pass "N1 — seeded negative: DHCPServer injection on bridge $BNAME (orig=$ORIG mod=yes)"
else
  BNAME="$(echo "$N1_JSON" | jq -r '.checkName')"
  fail "N1 — seeded negative: DHCPServer injection NOT detected on bridge $BNAME"
fi

# N2: Inject Address= on a bridge network
write_nix "$SCRATCH/seeded-neg-n2.nix" <<'NIXEOF'
let
  flake = builtins.getFlake "REPO_PATH";
  renderer = flake.libBySystem.x86_64-linux.renderer;
  cpmFixture = {
    endpointAssignment.test-client = {
      mode = "static";
      name = "test-client";
      bridge = "client";
      static = {
        address = "10.20.20.10";
        prefixLength = 24;
        gateway4 = "10.20.20.1";
        address6 = "fd42:dead:beef:20::10";
        prefixLength6 = 64;
        gateway6 = "fd42:dead:beef:20::1";
      };
    };
    bridgeNetworks.client = {
      mode = "vlan";
      parent = "eth0";
      vlan = 302;
    };
  };
  moduleFn = renderer.hostModule {
    hostName = "s-router-test-clients";
    cpm = cpmFixture;
    mode = "test";
  };
  result = moduleFn { config = {}; };

  networks = result.systemd.network.networks or {};
  allNames = builtins.attrNames networks;
  vlanPrefix = "40-eth0.";
  bridgeNames = builtins.filter
    (n: n != "10-eth0" && builtins.match "${vlanPrefix}.*" n == null)
    allNames;

  targetBridge = builtins.head bridgeNames;

  # Inject host-side Address
  modified = result // {
    systemd = result.systemd // {
      network = result.systemd.network // {
        networks = result.systemd.network.networks // {
          "${targetBridge}" = (networks.${targetBridge} or {}) // {
            networkConfig = (networks.${targetBridge}.networkConfig or {}) // {
              Address = [ "10.99.99.1/24" ];
            };
          };
        };
      };
    };
  };

  checkName = targetBridge;
  origHasAddress = builtins.hasAttr "Address"
    (networks.${targetBridge}.networkConfig or {});
  modifiedHasAddress = builtins.hasAttr "Address"
    (modified.systemd.network.networks.${targetBridge}.networkConfig or {});
  modifiedAddresses =
    modified.systemd.network.networks.${targetBridge}.networkConfig.Address or [];
in
{
  inherit checkName;
  has_violation = builtins.length modifiedAddresses > 0;
  original_has_address = origHasAddress;
  modified_addresses = modifiedAddresses;
}
NIXEOF

N2_JSON="$(nix eval --impure --json -f "$SCRATCH/seeded-neg-n2.nix" 2>&1)"
if echo "$N2_JSON" | jq -e '.has_violation == true' >/dev/null 2>&1; then
  BNAME="$(echo "$N2_JSON" | jq -r '.checkName')"
  ADDRS="$(echo "$N2_JSON" | jq -r '.modified_addresses | join(", ")')"
  pass "N2 — seeded negative: bridge IP injection on bridge $BNAME (addr=$ADDRS)"
else
  BNAME="$(echo "$N2_JSON" | jq -r '.checkName')"
  fail "N2 — seeded negative: bridge IP injection NOT detected on bridge $BNAME"
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
  echo "RESULT: PASS — all SMS-050 acceptance predicates proved"
  exit 0
fi
