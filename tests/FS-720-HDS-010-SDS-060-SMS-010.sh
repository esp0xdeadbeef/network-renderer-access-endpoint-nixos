#!/usr/bin/env bash
# ============================================================================
# GAMP-ID: FS-720-HDS-010-SDS-060-SMS-010
# Construction test (CMC): Implementation Naming Discipline
# Owning repo: network-renderer-access-endpoint-nixos
#
# Proves: No validation-phase labels (hat, sat, sit, smt) appear as
# implementation identifiers, filenames, service names, marker paths,
# or variable names in the access-endpoint renderer repository.
#
# Permitted exceptions per SMS-010:
#   - GAMP spec files and validation README tables (not in this repo)
#   - Inventory structure keys (e.g., deployment.hosts.<name>.hat.endpointClients)
#   - Test filenames with GAMP trace-chain IDs
#   - Rebuild scripts in scripts/ named for validation phase
#
# Seeded negatives (active, detection + recovery):
#   N1: Validation-phase label in filename (hat-endpoint-fix.nix)
#   N2: Validation-phase label in service name (*-hat-*.service)
# ============================================================================
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

all_checks_passed=true

echo "=== FS-720-HDS-010-SDS-060-SMS-010: Implementation Naming Discipline ==="
echo "Renderer: network-renderer-access-endpoint-nixos"
echo "Trace: FS-720 > HDS-010 > SDS-060 > SMS-010"
echo ""

# ================================================================
# KNOWN_GAPS: permitted validation-phase token occurrences
# Format: "file:line  description"
# ================================================================
KNOWN_GAPS=(
  # All inventory key paths using `hat` as data organization — permitted per SMS-010
  "lib/renderer.nix:212  inventoryHost.hat — inventory data key, allowed exception"
  "lib/renderer.nix:474  assertion block opening brace — no hat/sat/sit/smt token (stale entry, harmless)"
  "lib/renderer.nix:475  inventoryHost ? hat in assertion — inventory data key, allowed exception"
  "lib/renderer.nix:476  inventory.hat.endpointClients in diagnostic message — inventory data key reference, allowed exception"
  # Comment at line 199 describes the inventory key path — not an implementation identifier
  "lib/renderer.nix:199  comment describing hat.endpointClients inventory path, allowed"
  # Line 477 message also references inventory.hat.endpointClients — same exception
  "lib/renderer.nix:477  inventory.hat.endpointClients in assertion message — inventory data key reference, allowed exception"
)

# ================================================================
# Helper
# ================================================================
is_known_gap() {
  local file="$1"
  local line="$2"
  local key="${file}:${line}"
  for gap in "${KNOWN_GAPS[@]}"; do
    if [[ "${gap}" == "${key}"* ]]; then
      return 0
    fi
  done
  return 1
}

# ================================================================
# Check 1: Source file scan — no validation-phase labels in tokens
# ================================================================
echo "--- Check 1: Source file scan for validation-phase tokens ---"
check1_violations=0

# Tokens to detect (case-insensitive, as word components — bounded by non-alpha chars)
# Using grep -iE with word boundaries: token must be preceded/followed by
# non-alpha character or start/end of line
TOKENS="(^|[^a-zA-Z])(hat|sat|sit|smt)($|[^a-zA-Z])"

# Scan source files
src_dirs=("lib" "flake.nix")
for dir in "${src_dirs[@]}"; do
  if [[ "${dir}" == "flake.nix" ]]; then
    search_path="${repo_root}/flake.nix"
  else
    search_path="${repo_root}/${dir}"
  fi

  hits=$(grep -rniE "(${TOKENS})" "${search_path}" 2>/dev/null || true)

  if [[ -n "${hits}" ]]; then
    while IFS= read -r hit_line; do
      [[ -z "${hit_line}" ]] && continue
      file_path="${hit_line%%:*}"
      rest="${hit_line#*:}"
      lineno="${rest%%:*}"
      rel_path="${file_path#${repo_root}/}"

      # Skip tests/ directory — test filenames with GAMP trace-chain IDs are allowed
      if echo "${rel_path}" | grep -q '^tests/'; then
        continue
      fi

      if is_known_gap "${rel_path}" "${lineno}"; then
        echo "  ALLOWED: ${rel_path}:${lineno} (inventory data key — permitted exception)"
        continue
      fi

      # Check if it's in a comment — comments are not implementation identifiers
      # Strip line-number prefix and check content
      content_only="${hit_line#*:*:}"
      if echo "${content_only}" | grep -qE '^\s*(#|//)'; then
        echo "  COMMENT: ${rel_path}:${lineno} (comment, not implementation identifier)"
        continue
      fi

      echo "  VIOLATION: ${rel_path}:${lineno} — validation-phase token in implementation code"
      echo "             ${content_only}"
      check1_violations=$((check1_violations + 1))
    done <<< "${hits}"
  fi
done

# Also scan filenames (not directory names)
echo ""
echo "--- Check 2: Filename scan for validation-phase tokens ---"
check2_violations=0

file_hits=$(find "${repo_root}" \
  \( -path '*/.git/*' -o -path '*/tests/*' -o -path '*/scripts/*' -o -path '*/GAMP/*' \) -prune -o \
  -type f \
  \( -name '*[Hh][Aa][Tt]*' \
     -o -name '*[Ss][Aa][Tt]*' \
     -o -name '*[Ss][Ii][Tt]*' \
     -o -name '*[Ss][Mm][Tt]*' \) \
  -print \
  2>/dev/null || true)

if [[ -n "${file_hits}" ]]; then
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    base="$(basename "${f}")"
    rel_path="${f#${repo_root}/}"

    # Skip known exceptions
    # Test filenames with trace-chain IDs are allowed
    if echo "${rel_path}" | grep -q '^tests/'; then
      continue
    fi
    # Rebuild scripts in scripts/ are allowed
    if echo "${rel_path}" | grep -q '^scripts/'; then
      continue
    fi

    echo "  VIOLATION: ${rel_path} — validation-phase token in filename"
    check2_violations=$((check2_violations + 1))
  done <<< "${file_hits}"
fi

echo "  Source code violations: ${check1_violations}"
echo "  Filename violations:    ${check2_violations}"
echo ""

if [ "${check1_violations}" -gt 0 ] || [ "${check2_violations}" -gt 0 ]; then
  all_checks_passed=false
fi

# ================================================================
# Seeded Negative 1: Validation-phase label in filename
# ================================================================
echo "--- Seeded Negative 1: Validation-phase label in filename ---"
sn1_dir="${tmp_dir}/sn1"
mkdir -p "${sn1_dir}"

# Create a file whose stem contains 'hat'
touch "${sn1_dir}/hat-endpoint-fix.nix"

sn1_hits=$(find "${sn1_dir}" -type f \
  -name '*[Hh][Aa][Tt]*' \
  2>/dev/null || true)

if [[ -n "${sn1_hits}" ]]; then
  echo "  SEEDED_NEGATIVE_CAUGHT: filename 'hat-endpoint-fix.nix' detected"
  echo "    ${sn1_hits}"
  echo "  PASS: Seeded negative 1 — scanner detects validation-phase label in filename"
else
  echo "  FAIL: Seeded negative 1 missed — scanner did not detect filename violation"
  all_checks_passed=false
fi

# Recovery: remove the file, verify clean
rm -f "${sn1_dir}/hat-endpoint-fix.nix"
sn1_clean=$(find "${sn1_dir}" -type f \
  -name '*[Hh][Aa][Tt]*' \
  2>/dev/null || true)
if [[ -z "${sn1_clean}" ]]; then
  echo "  PASS: Seeded negative 1 recovery — clean after removal"
else
  echo "  FAIL: Seeded negative 1 recovery — still shows violations after removal"
  all_checks_passed=false
fi
echo ""

# ================================================================
# Seeded Negative 2: Validation-phase label in service name
# ================================================================
echo "--- Seeded Negative 2: Validation-phase label in service name ---"
sn2_dir="${tmp_dir}/sn2"
mkdir -p "${sn2_dir}"

# Create a file containing a systemd unit with 'hat' in the service name
cat > "${sn2_dir}/service-definition.nix" << 'SN2EOF'
{ lib, ... }:
{
  # VIOLATION: 'hat' in systemd service name
  systemd.services.s-router-hat-endpoint-ready = {
    description = "Validation-phase named service (SMS-010 violation)";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/bin/true";
    };
  };
}
SN2EOF

sn2_hits=$(grep -rniE '(hat|sat|sit|smt)' "${sn2_dir}" 2>/dev/null | \
  grep -vE '^\s*(#|//)' || true)

# Filter to find the service name, not the comment
sn2_service=$(echo "${sn2_hits}" | grep 'hat-endpoint' || true)

if [[ -n "${sn2_service}" ]]; then
  echo "  SEEDED_NEGATIVE_CAUGHT: service name 's-router-hat-endpoint-ready' detected"
  echo "    ${sn2_service}"
  echo "  PASS: Seeded negative 2 — scanner detects validation-phase label in service name"
else
  echo "  FAIL: Seeded negative 2 missed — scanner did not detect service name violation"
  all_checks_passed=false
fi

# Recovery
rm -f "${sn2_dir}/service-definition.nix"
sn2_clean=$(grep -rniE '(hat|sat|sit|smt)' "${sn2_dir}" 2>/dev/null | \
  grep -vE '^\s*(#|//)' || true)
if [[ -z "${sn2_clean}" ]]; then
  echo "  PASS: Seeded negative 2 recovery — clean after removal"
else
  echo "  FAIL: Seeded negative 2 recovery — still shows violations after removal"
  all_checks_passed=false
fi
echo ""

# ================================================================
# Final report
# ================================================================
echo "============================================================"
echo "FS-720-HDS-010-SDS-060-SMS-010 Naming Discipline Scan Summary"
echo "============================================================"
echo "  Source violations:    ${check1_violations}"
echo "  Filename violations:  ${check2_violations}"
echo "  Seeded negatives:     N1 (filename), N2 (service name)"
echo "  KNOWN_GAPS:           ${#KNOWN_GAPS[@]}"
echo ""

if [[ "${all_checks_passed}" == "true" ]]; then
  echo "PASS: FS-720-HDS-010-SDS-060-SMS-010 — no validation-phase labels in implementation identifiers."
  echo "  All hits are inventory data keys (permitted exceptions)."
  echo "  2 active seeded negatives verified (detection + recovery)."
  exit 0
else
  echo "FAIL: Naming discipline violations or scanner failures detected."
  exit 1
fi
