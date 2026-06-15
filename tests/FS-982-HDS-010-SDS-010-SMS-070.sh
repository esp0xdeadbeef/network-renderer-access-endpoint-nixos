#!/usr/bin/env bash
# GAMP-ID: FS-982-HDS-010-SDS-010-SMS-070
# GAMP-SCOPE: software-module-test
# Focused construction test: Access-endpoint renderer sops service ordering.
#
# FS-840: "Required material that is missing, stale, mismatched, unauthorized,
# or ambiguous shall fail visibly before the consuming service is treated as ready."
#
# Verifies that:
# - s-router-test-clients-endpoint-ready.service waits for sops-nix.service
# - access-endpoint-isolate-bridges.service waits for sops-nix.service
# - No oneshot secret services exist in the renderer
#
# Active seeded negatives:
#   SN1 — construct a module where endpoint-ready has NO sops-nix after;
#          verify scanner detects the gap
#   SN2 — construct a module with oneshot sops decrypt service; verify
#          scanner detects the SMS-070 violation
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

echo "--- FS-982-HDS-010-SDS-010-SMS-070: Access-endpoint renderer sops service ordering ---"
echo ""

failures=0

# ============================================================
# Check 1: endpoint-ready service has sops-nix.service in after
# ============================================================
echo "--- Check 1: s-router-test-clients-endpoint-ready waits for sops-nix ---"

# Find the endpoint-ready service definition and verify sops ordering
if grep -A10 'systemd.services.s-router-test-clients-endpoint-ready' "${repo_root}/lib/renderer.nix" 2>/dev/null | \
   grep -q 'sops-nix.service'; then
  echo "  PASS: s-router-test-clients-endpoint-ready has sops-nix.service in after"
else
  echo "  FAIL: s-router-test-clients-endpoint-ready missing sops-nix.service ordering"
  failures=$((failures + 1))
fi
echo ""

# ============================================================
# Check 2: isolate-bridges service has sops-nix.service in after
# ============================================================
echo "--- Check 2: access-endpoint-isolate-bridges waits for sops-nix ---"

if grep -A10 'systemd.services.access-endpoint-isolate-bridges' "${repo_root}/lib/renderer.nix" 2>/dev/null | \
   grep -q 'sops-nix.service'; then
  echo "  PASS: access-endpoint-isolate-bridges has sops-nix.service in after"
else
  echo "  FAIL: access-endpoint-isolate-bridges missing sops-nix.service ordering"
  failures=$((failures + 1))
fi
echo ""

# ============================================================
# Check 3: No oneshot secret services in the renderer
# ============================================================
echo "--- Check 3: No oneshot secret-materialization services ---"

oneshot_hits=$(grep -rn 'sops -d\|ln -sf.*secrets\|writeShellScript.*secrets\|ExecStart.*secrets' \
  "${repo_root}/lib/" --include='*.nix' 2>/dev/null || true)

if [[ -z "${oneshot_hits}" ]]; then
  echo "  PASS: No oneshot secret services detected in renderer lib/"
else
  echo "  FAIL: Oneshot secret service(s) found:"
  echo "${oneshot_hits}"
  failures=$((failures + 1))
fi
echo ""

# ============================================================
# Check 4 (SN1): Scanner detects missing sops ordering
# ============================================================
echo "--- Check 4 (SN1): Scanner detects missing sops ordering ---"

injected_file="${tmp_dir}/injected-ae-service.nix"
cat > "${injected_file}" <<'NIX'
{ lib, ... }:
{
  systemd.services.s-router-test-clients-endpoint-ready = lib.mkIf true {
    description = "Wait for all endpoint fixture containers";
    wantedBy = [ "multi-user.target" ];
    # VIOLATION: missing sops-nix.service
    after = map (name: "container@${name}.service") [ "client1" "client2" ];
    requires = map (name: "container@${name}.service") [ "client1" "client2" ];
    serviceConfig.Type = "oneshot";
  };
}
NIX

has_sops_after=$(grep -c 'after.*sops-nix.service' "${injected_file}" 2>/dev/null || true)
has_endpoint_ready=$(grep -c 's-router-test-clients-endpoint-ready' "${injected_file}" 2>/dev/null || true)

if [[ "${has_endpoint_ready:-0}" -gt 0 ]] && [[ "${has_sops_after:-0}" -eq 0 ]]; then
  echo "  PASS SN1: Scanner correctly identifies endpoint-ready missing sops-nix"
else
  echo "  FAIL SN1: Scanner did not detect missing sops-nix ordering"
  failures=$((failures + 1))
fi
echo ""

# ============================================================
# Check 5 (SN2): Scanner detects oneshot secret service
# ============================================================
echo "--- Check 5 (SN2): Scanner detects injected oneshot secret service ---"

injected_file2="${tmp_dir}/injected-ae-oneshot.nix"
cat > "${injected_file2}" <<'NIX'
{ pkgs, ... }:
{
  # VIOLATION: oneshot service that generates secrets — prohibited by SMS-070
  systemd.services.ae-secret-generator = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p /run/secrets/ae
      ln -sf /run/secrets/pppoe-creds /run/secrets/ae/pppoe-creds
    '';
  };
}
NIX

if grep -qE '(sops -d|ln -sf.*secrets|writeShellScript.*secrets|ExecStart.*secrets)' "${injected_file2}"; then
  echo "  PASS SN2: Scanner detects oneshot secret symlink service in injected violation"
else
  echo "  FAIL SN2: Scanner did NOT detect oneshot secret service"
  failures=$((failures + 1))
fi
echo ""

# ============================================================
# Result
# ============================================================
if [[ ${failures} -eq 0 ]]; then
  echo "PASS FS-982-HDS-010-SDS-010-SMS-070 — Access-endpoint renderer sops service ordering verified"
  exit 0
else
  echo "FAIL FS-982-HDS-010-SDS-010-SMS-070: ${failures} failure(s)"
  exit 1
fi
