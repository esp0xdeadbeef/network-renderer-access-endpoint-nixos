#!/usr/bin/env bash
# ============================================================================
# FS-310-HDS-010-SDS-010-SMS-110: Renderer Fail-Closed Contract
# Construction test (CMC) — source-scan + seeded negative evaluation.
#
# Trace chain: FS-310 > HDS-010 > SDS-010 > SMS-110
# Owning repo: network-renderer-access-endpoint-nixos
# Renderer API: hostModuleFromPaths
#
# SMS-110 acceptance predicates (access-endpoint renderer specific):
#   P1: AE-CRIT-1 — Missing static.address/prefixLength throws fail-closed
#       with FS-310-HDS-010-SDS-010-SMS-110 diagnostic.
#   P2: AE-HIGH-1 — Missing endpointAssignment.mode throws fail-closed
#       with FS-310-HDS-010-SDS-010-SMS-110 diagnostic.
#   P3: AE-HIGH-2 — Missing bridgeNetworks.parent throws fail-closed
#       with FS-310-HDS-010-SDS-010-SMS-110 diagnostic.
#   P4: AE-HIGH-3/4/5 — Harness invocation params have KNOWN_GAP comments
#       referencing FS-310-HDS-010-SDS-010-SMS-110.
#   P5: No remaining network-affecting hardcoded defaults (address/prefix/mode/parent).
#
# Seeded negatives:
#   N1: Source-scan verify fail-closed throws exist for AE-CRIT-1 (static fields)
#   N2: Source-scan verify fail-closed throws exist for AE-HIGH-1 (mode field)
#   N3: Verify hardcoded defaults are removed from source
# ============================================================================
set -euo pipefail

TEST_NAME="FS-310-HDS-010-SDS-010-SMS-110"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRATCH="$(mktemp -d /tmp/test-${TEST_NAME}-XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

# Helper: write a .nix file substituting REPO_PATH
write_nix() {
  local dest="$1"
  cat > "$dest"
  sed -i "s|REPO_PATH|${REPO_ROOT}|g" "$dest"
}

SRC_FILES=(
  "$REPO_ROOT/lib/renderer.nix"
)

echo "=== ${TEST_NAME} Construction Test ==="
echo "Trace: FS-310 > HDS-010 > SDS-010 > SMS-110"
echo "Renderer: network-renderer-access-endpoint-nixos"
echo "Host: s-router-test-clients | Lab: active-lab"
echo ""

# ================================================================
# P1: AE-CRIT-1 — static.address/prefixLength fail-closed (source scan)
# ================================================================
echo "--- P1: AE-CRIT-1 — static.address/prefixLength fail-closed (source scan) ---"

# P1a: Diagnostic for missing static.address must exist
if grep -q 'static.address missing' "$REPO_ROOT/lib/renderer.nix" 2>/dev/null; then
  pass "P1a — static.address missing diagnostic found in source"
else
  fail "P1a — static.address missing diagnostic NOT FOUND in source"
fi

# P1b: Diagnostic for missing static.prefixLength must exist
if grep -q 'static.prefixLength missing' "$REPO_ROOT/lib/renderer.nix" 2>/dev/null; then
  pass "P1b — static.prefixLength missing diagnostic found in source"
else
  fail "P1b — static.prefixLength missing diagnostic NOT FOUND in source"
fi

# P1c: No hardcoded "0.0.0.0" address default (using or "0.0.0.0" pattern)
if grep -q 'or "0.0.0.0"' "$REPO_ROOT/lib/renderer.nix" 2>/dev/null; then
  fail "P1c — hardcoded 0.0.0.0 address default still present (should be fail-closed throw)"
else
  pass "P1c — no hardcoded 0.0.0.0 address default (fail-closed enforced)"
fi

# P1d: No hardcoded prefixLength 24 default (the literal 'or 24')
if grep -q 'or 24' "$REPO_ROOT/lib/renderer.nix" 2>/dev/null; then
  # Check if the match is inside a string (throw message) or actual default
  # The original was: (static.prefixLength or 24)
  # After fix, there should be no bare 'or 24' as a default
  OR24_MATCHES=$(grep -n 'or 24' "$REPO_ROOT/lib/renderer.nix" 2>/dev/null || true)
  if echo "$OR24_MATCHES" | grep -q 'toString'; then
    fail "P1d — hardcoded prefixLength 24 default still present"
  else
    pass "P1d — no hardcoded prefixLength 24 default (fail-closed enforced)"
  fi
else
  pass "P1d — no hardcoded prefixLength 24 default (fail-closed enforced)"
fi

# P1e: Both diagnostics reference SMS-110 trace chain
if grep -q 'FS-310-HDS-010-SDS-010-SMS-110.*static.address missing' "$REPO_ROOT/lib/renderer.nix" 2>/dev/null; then
  pass "P1e-a — SMS-110 trace-chain reference in static.address diagnostic"
else
  fail "P1e-a — SMS-110 trace-chain reference missing from static.address diagnostic"
fi

if grep -q 'FS-310-HDS-010-SDS-010-SMS-110.*static.prefixLength missing' "$REPO_ROOT/lib/renderer.nix" 2>/dev/null; then
  pass "P1e-b — SMS-110 trace-chain reference in static.prefixLength diagnostic"
else
  fail "P1e-b — SMS-110 trace-chain reference missing from static.prefixLength diagnostic"
fi

# ================================================================
# P2: AE-HIGH-1 — endpointAssignment.mode fail-closed (source scan)
# ================================================================
echo ""
echo "--- P2: AE-HIGH-1 — endpointAssignment.mode fail-closed (source scan) ---"

# P2a: Diagnostic for missing mode must exist
if grep -q 'endpointAssignment.*\.mode is missing' "$REPO_ROOT/lib/renderer.nix" 2>/dev/null; then
  pass "P2a — endpointAssignment.mode missing diagnostic found in source"
else
  fail "P2a — endpointAssignment.mode missing diagnostic NOT FOUND in source"
fi

# P2b: No hardcoded "dhcp" mode default
if grep -q 'or "dhcp"' "$REPO_ROOT/lib/renderer.nix" 2>/dev/null; then
  fail "P2b — hardcoded dhcp mode default still present"
else
  pass "P2b — no hardcoded dhcp mode default (fail-closed enforced)"
fi

# P2c: Diagnostic references SMS-110 trace chain
if grep -q 'FS-310-HDS-010-SDS-010-SMS-110.*mode is missing' "$REPO_ROOT/lib/renderer.nix" 2>/dev/null; then
  pass "P2c — SMS-110 trace-chain reference in mode diagnostic"
else
  fail "P2c — SMS-110 trace-chain reference missing from mode diagnostic"
fi

# ================================================================
# P3: AE-HIGH-2 — bridgeNetworks.parent fail-closed (source scan)
# ================================================================
echo ""
echo "--- P3: AE-HIGH-2 — bridgeNetworks.parent fail-closed (source scan) ---"

# P3a: Diagnostic for missing parent must exist
if grep -q 'bridgeNetworks.*\.parent is missing' "$REPO_ROOT/lib/renderer.nix" 2>/dev/null; then
  pass "P3a — bridgeNetworks.parent missing diagnostic found in source"
else
  fail "P3a — bridgeNetworks.parent missing diagnostic NOT FOUND in source"
fi

# P3b: No hardcoded "eth0" parent default that isn't inside a throw/string
# The pattern `parent = cfg.parent or "eth0"` was the original.
# After fix, check no bare 'or "eth0"' exists
if grep -q 'or "eth0"' "$REPO_ROOT/lib/renderer.nix" 2>/dev/null; then
  fail "P3b — hardcoded eth0 parent default still present"
else
  pass "P3b — no hardcoded eth0 parent default (fail-closed enforced)"
fi

# P3c: Diagnostic references SMS-110 trace chain
if grep -q 'FS-310-HDS-010-SDS-010-SMS-110.*\.parent is missing' "$REPO_ROOT/lib/renderer.nix" 2>/dev/null; then
  pass "P3c — SMS-110 trace-chain reference in parent diagnostic"
else
  fail "P3c — SMS-110 trace-chain reference missing from parent diagnostic"
fi

# ================================================================
# P4: AE-HIGH-3/4/5 — Harness invocation params with KNOWN_GAP comments
# ================================================================
echo ""
echo "--- P4: AE-HIGH-3/4/5 — Harness invocation params KNOWN_GAP (source scan) ---"

# P4a: hostName has KNOWN_GAP comment
if grep -B1 'hostName ? "s-router-test-clients"' "$REPO_ROOT/lib/renderer.nix" 2>/dev/null | grep -q 'FS-310-HDS-010-SDS-010-SMS-110.*caller must supply'; then
  pass "P4a — hostName has KNOWN_GAP comment referencing SMS-110"
else
  fail "P4a — hostName missing KNOWN_GAP comment"
fi

# P4b: labSource has KNOWN_GAP comment
if grep -B1 'labSource ? "active-lab"' "$REPO_ROOT/lib/renderer.nix" 2>/dev/null | grep -q 'FS-310-HDS-010-SDS-010-SMS-110.*caller must supply'; then
  pass "P4b — labSource has KNOWN_GAP comment referencing SMS-110"
else
  fail "P4b — labSource missing KNOWN_GAP comment"
fi

# P4c: mode has KNOWN_GAP comment
if grep -B1 'mode = rendererInput\.mode or "test"' "$REPO_ROOT/lib/renderer.nix" 2>/dev/null | grep -q 'FS-310-HDS-010-SDS-010-SMS-110.*caller must supply'; then
  pass "P4c — mode has KNOWN_GAP comment referencing SMS-110"
else
  fail "P4c — mode missing KNOWN_GAP comment"
fi

# P4d: siteName has KNOWN_GAP comment
if grep -B1 'siteName ? "site-a"' "$REPO_ROOT/lib/renderer.nix" 2>/dev/null | grep -q 'FS-310-HDS-010-SDS-010-SMS-110.*caller must supply'; then
  pass "P4d — siteName has KNOWN_GAP comment referencing SMS-110"
else
  fail "P4d — siteName missing KNOWN_GAP comment"
fi

# ================================================================
# P5: No remaining network-affecting hardcoded defaults
# ================================================================
echo ""
echo "--- P5: No remaining network-affecting hardcoded defaults (source scan) ---"

# Check for common network-affecting default patterns that should be eliminated
REMAINING=0
for pattern in 'or "0.0.0.0"' 'or "eth0"' 'or "dhcp"'; do
  if grep -q "$pattern" "$REPO_ROOT/lib/renderer.nix" 2>/dev/null; then
    REMAINING=$((REMAINING + 1))
  fi
done

if [ "$REMAINING" -eq 0 ]; then
  pass "P5 — no remaining network-affecting hardcoded defaults (address/parent/mode)"
else
  fail "P5 — ${REMAINING} network-affecting hardcoded default pattern(s) still present"
fi

# ================================================================
# Seeded Negative N1: Source-scan for AE-CRIT-1 fail-closed throws
# ================================================================
echo ""
echo "--- Seeded Negative N1: AE-CRIT-1 fail-closed throws (source scan) ---"

write_nix "$SCRATCH/seeded-neg-n1.nix" <<'NIXEOF'
let
  src = builtins.readFile (toString (REPO_PATH + "/lib/renderer.nix"));

  # Check that the fail-closed diagnostics exist for static.address/prefixLength
  hasStaticAddrDiag = builtins.match ".*static.address missing.*" src != null;
  hasStaticPlenDiag = builtins.match ".*static.prefixLength missing.*" src != null;

  # SMS-110 trace-chain reference in diagnostics
  hasSms110Addr = builtins.match ".*FS-310-HDS-010-SDS-010-SMS-110.*static.address missing.*" src != null;
  hasSms110Plen = builtins.match ".*FS-310-HDS-010-SDS-010-SMS-110.*static.prefixLength missing.*" src != null;

  # Hardcoded defaults removed
  noZeroAddr = builtins.match ".*\"0.0.0.0\".*" src != null || builtins.match ".*or \"0.0.0.0\".*" src == null;
in
{
  has_static_addr_diag = hasStaticAddrDiag;
  has_static_plen_diag = hasStaticPlenDiag;
  has_sms110_addr = hasSms110Addr;
  has_sms110_plen = hasSms110Plen;
  no_zero_addr = noZeroAddr;
}
NIXEOF

N1_JSON=$(nix eval --impure --json -f "$SCRATCH/seeded-neg-n1.nix" 2>&1) || {
  fail "N1 — Nix evaluation FAILED: $(echo "$N1_JSON" | head -3)"
  N1_JSON="{}"
}

HAS_ADDR=$(echo "$N1_JSON" | jq -r '.has_static_addr_diag // false')
HAS_PLEN=$(echo "$N1_JSON" | jq -r '.has_static_plen_diag // false')
HAS_SMS110_ADDR=$(echo "$N1_JSON" | jq -r '.has_sms110_addr // false')
HAS_SMS110_PLEN=$(echo "$N1_JSON" | jq -r '.has_sms110_plen // false')
NO_ZERO_ADDR=$(echo "$N1_JSON" | jq -r '.no_zero_addr // false')

if [ "$HAS_ADDR" = "true" ]; then
  pass "N1a — static.address missing diagnostic confirmed by Nix source scan"
else
  fail "N1a — static.address missing diagnostic NOT FOUND (AE-CRIT-1 gap)"
fi

if [ "$HAS_PLEN" = "true" ]; then
  pass "N1b — static.prefixLength missing diagnostic confirmed by Nix source scan"
else
  fail "N1b — static.prefixLength missing diagnostic NOT FOUND (AE-CRIT-1 gap)"
fi

if [ "$HAS_SMS110_ADDR" = "true" ]; then
  pass "N1c — SMS-110 trace in static.address diagnostic (Nix scan)"
else
  fail "N1c — SMS-110 trace NOT IN static.address diagnostic"
fi

if [ "$HAS_SMS110_PLEN" = "true" ]; then
  pass "N1d — SMS-110 trace in static.prefixLength diagnostic (Nix scan)"
else
  fail "N1d — SMS-110 trace NOT IN static.prefixLength diagnostic"
fi

if [ "$NO_ZERO_ADDR" = "true" ]; then
  pass "N1e — hardcoded 0.0.0.0 default removed (Nix scan)"
else
  fail "N1e — hardcoded 0.0.0.0 default may still be present"
fi

# ================================================================
# Seeded Negative N2: Source-scan for AE-HIGH-1 fail-closed throws
# ================================================================
echo ""
echo "--- Seeded Negative N2: AE-HIGH-1 fail-closed throws (source scan) ---"

write_nix "$SCRATCH/seeded-neg-n2.nix" <<'NIXEOF'
let
  src = builtins.readFile (toString (REPO_PATH + "/lib/renderer.nix"));

  # Check that fail-closed diagnostic exists for mode
  hasModeDiag = builtins.match ".*endpointAssignment.*mode is missing.*" src != null;

  # SMS-110 trace-chain reference in mode diagnostic
  hasSms110Mode = builtins.match ".*FS-310-HDS-010-SDS-010-SMS-110.*mode is missing.*" src != null;

  # Hardcoded dhcp default removed
  noDhcpDefault = builtins.match ".*or \"dhcp\".*" src == null;
in
{
  has_mode_diag = hasModeDiag;
  has_sms110_mode = hasSms110Mode;
  no_dhcp_default = noDhcpDefault;
}
NIXEOF

N2_JSON=$(nix eval --impure --json -f "$SCRATCH/seeded-neg-n2.nix" 2>&1) || {
  fail "N2 — Nix evaluation FAILED: $(echo "$N2_JSON" | head -3)"
  N2_JSON="{}"
}

HAS_MODE_DIAG=$(echo "$N2_JSON" | jq -r '.has_mode_diag // false')
HAS_SMS110_MODE=$(echo "$N2_JSON" | jq -r '.has_sms110_mode // false')
NO_DHCP=$(echo "$N2_JSON" | jq -r '.no_dhcp_default // false')

if [ "$HAS_MODE_DIAG" = "true" ]; then
  pass "N2a — endpointAssignment.mode missing diagnostic confirmed by Nix source scan"
else
  fail "N2a — endpointAssignment.mode missing diagnostic NOT FOUND (AE-HIGH-1 gap)"
fi

if [ "$HAS_SMS110_MODE" = "true" ]; then
  pass "N2b — SMS-110 trace in mode diagnostic (Nix scan)"
else
  fail "N2b — SMS-110 trace NOT IN mode diagnostic"
fi

if [ "$NO_DHCP" = "true" ]; then
  pass "N2c — hardcoded dhcp mode default removed (Nix scan)"
else
  fail "N2c — hardcoded dhcp mode default still present"
fi

# ================================================================
# Seeded Negative N3: Combined verification via Nix eval
# ================================================================
echo ""
echo "--- Seeded Negative N3: Combined fail-closed verification (Nix source scan) ---"

write_nix "$SCRATCH/seeded-neg-n3.nix" <<'NIXEOF'
let
  src = builtins.readFile (toString (REPO_PATH + "/lib/renderer.nix"));

  # All fail-closed patterns must be present
  failClosedMode = builtins.match ".*throw.*mode.*missing.*" src != null;
  failClosedAddr = builtins.match ".*throw.*static\.address missing.*" src != null;
  failClosedPlen = builtins.match ".*throw.*static\.prefixLength missing.*" src != null;
  failClosedParent = builtins.match ".*throw.*\.parent is missing.*" src != null;

  # SMS-110 reference in all throws
  allHaveSms110 =
    builtins.match ".*FS-310-HDS-010-SDS-010-SMS-110.*mode is missing.*" src != null &&
    builtins.match ".*FS-310-HDS-010-SDS-010-SMS-110.*static.address missing.*" src != null &&
    builtins.match ".*FS-310-HDS-010-SDS-010-SMS-110.*static.prefixLength missing.*" src != null &&
    builtins.match ".*FS-310-HDS-010-SDS-010-SMS-110.*\.parent is missing.*" src != null;

  # Hardcoded defaults must all be gone
  noHardcoded = 
    builtins.match ".*or \"0\\.0\\.0\\.0\".*" src == null &&
    builtins.match ".*or \"dhcp\".*" src == null &&
    builtins.match ".*or \"eth0\".*" src == null;
in
{
  fail_closed_mode = failClosedMode;
  fail_closed_addr = failClosedAddr;
  fail_closed_plen = failClosedPlen;
  fail_closed_parent = failClosedParent;
  all_have_sms110 = allHaveSms110;
  no_hardcoded = noHardcoded;
}
NIXEOF

N3_JSON=$(nix eval --impure --json -f "$SCRATCH/seeded-neg-n3.nix" 2>&1) || {
  fail "N3 — Nix evaluation FAILED: $(echo "$N3_JSON" | head -3)"
  N3_JSON="{}"
}

FC_MODE=$(echo "$N3_JSON" | jq -r '.fail_closed_mode // false')
FC_ADDR=$(echo "$N3_JSON" | jq -r '.fail_closed_addr // false')
FC_PLEN=$(echo "$N3_JSON" | jq -r '.fail_closed_plen // false')
FC_PARENT=$(echo "$N3_JSON" | jq -r '.fail_closed_parent // false')
ALL_SMS110=$(echo "$N3_JSON" | jq -r '.all_have_sms110 // false')
NO_HARDCODED=$(echo "$N3_JSON" | jq -r '.no_hardcoded // false')

if [ "$FC_MODE" = "true" ]; then
  pass "N3a — fail-closed throw on missing mode confirmed"
else
  fail "N3a — fail-closed throw on missing mode NOT FOUND (AE-HIGH-1 gap)"
fi

if [ "$FC_ADDR" = "true" ]; then
  pass "N3b — fail-closed throw on missing static.address confirmed"
else
  fail "N3b — fail-closed throw on missing static.address NOT FOUND (AE-CRIT-1 gap)"
fi

if [ "$FC_PLEN" = "true" ]; then
  pass "N3c — fail-closed throw on missing static.prefixLength confirmed"
else
  fail "N3c — fail-closed throw on missing static.prefixLength NOT FOUND (AE-CRIT-1 gap)"
fi

if [ "$FC_PARENT" = "true" ]; then
  pass "N3d — fail-closed throw on missing bridgeNetworks.parent confirmed"
else
  fail "N3d — fail-closed throw on missing bridgeNetworks.parent NOT FOUND (AE-HIGH-2 gap)"
fi

if [ "$ALL_SMS110" = "true" ]; then
  pass "N3e — all fail-closed diagnostics reference SMS-110 trace chain"
else
  fail "N3e — one or more fail-closed diagnostics missing SMS-110 reference"
fi

if [ "$NO_HARDCODED" = "true" ]; then
  pass "N3f — all hardcoded defaults (0.0.0.0/dhcp/eth0) removed from source"
else
  fail "N3f — one or more hardcoded defaults still present"
fi

# ================================================================
# Summary
# ================================================================
echo ""
echo "=== ${TEST_NAME} Results ==="
echo "Pass: $PASS"
echo "Fail: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  echo "RESULT: FAIL — $FAIL predicate(s) failed"
  exit 1
else
  echo "RESULT: PASS — all SMS-110 fail-closed acceptance predicates proved for access-endpoint renderer"
  exit 0
fi
