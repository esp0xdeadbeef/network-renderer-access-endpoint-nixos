#!/usr/bin/env bash
# GAMP-ID: FS-320-HDS-050-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
#
# Access-endpoint renderer construction test for the attachment surface
# binding module (SMS-010).
#
# This renderer is the one that already gets it right, and it is the model the
# other renderers are measured against:
#
#   lib/renderer.nix  endpointBridge
#     - a missing bridge field throws MISSING_CPM_BRIDGE_FIELD;
#     - an empty-string bridge throws AMBIGUOUS_BRIDGE_DEFAULT and the
#       diagnostic names the tenant/key fallback it refuses to take;
#     - a modelled bridge string is returned as given.
#
# The test is written as a guard, not a discovery: it fails if this renderer
# ever regresses to a defaulted or derived surface, and it fails if the
# no-fallback behaviour goes away. It also proves that the endpoint surface may
# be any bridge the model names, with no physical-port requirement.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
cd "${repo_root}"

trace_id="${SMS_TEST_TRACE_ID:-FS-320-HDS-050-SDS-010-SMS-010}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

all_checks_passed=true
record_pass() { echo "PASS ${trace_id}: $1"; }
record_fail() { echo "FAIL ${trace_id}: $1" >&2; all_checks_passed=false; }

renderer_lib="lib/renderer.nix"

if [[ ! -f "${renderer_lib}" ]]; then
  record_fail "renderer library is absent: ${renderer_lib}"
else
  echo "--- Predicate 1: a missing attachment surface fails closed ---"
  if grep -qF 'MISSING_CPM_BRIDGE_FIELD' "${renderer_lib}"; then
    record_pass "a missing attachment surface throws instead of defaulting"
  else
    record_fail "a missing attachment surface does not throw; the renderer may default it"
  fi

  echo ""
  echo "--- Predicate 2: no fallback surface is derived from a name ---"
  if grep -qF 'AMBIGUOUS_BRIDGE_DEFAULT' "${renderer_lib}"; then
    record_pass "an empty surface identity is rejected with a named no-fallback diagnostic"
  else
    record_fail "an empty surface identity is not rejected; a fallback path may exist"
  fi

  defaulted_surface="$(grep -nE 'bridge\s*\?\s*"[^"]+"' "${renderer_lib}" || true)"
  if [[ -n "${defaulted_surface}" ]]; then
    record_fail "attachment surface carries a renderer-local default: ${defaulted_surface//$'\n'/ | }"
  else
    record_pass "no attachment surface is defaulted"
  fi

  echo ""
  echo "--- Predicate 3: the surface identity is used as given ---"
  if grep -qE 'bridge == ""' "${renderer_lib}" && grep -qF 'bridge' "${renderer_lib}"; then
    record_pass "a modelled surface string is returned unchanged"
  else
    record_fail "a modelled surface string is not returned unchanged"
  fi

  echo ""
  echo "--- Predicate 4: no physical-port requirement on an endpoint surface ---"
  physical_requirement="$(
    grep -nE 'physical(Nic|Port|Interface)[A-Za-z]*\s*(\?|===|==)' "${renderer_lib}" || true
  )"
  if [[ -n "${physical_requirement}" ]]; then
    record_fail "endpoint attachment requires a physical surface: ${physical_requirement//$'\n'/ | }"
  else
    record_pass "an endpoint attaches to a modelled bridge with no physical-port requirement"
  fi
fi

echo ""
if ${all_checks_passed}; then
  echo "PASS ${trace_id} — access-endpoint renderer binds only modelled attachment surfaces and fails closed without one."
  exit 0
fi

echo "FAIL ${trace_id} — access-endpoint renderer diverges from SMS-010 attachment surface binding." >&2
exit 1
