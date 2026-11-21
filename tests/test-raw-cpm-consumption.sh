#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-040-SDS-010-SMS-100
# GAMP-SCOPE: software-module-test
#
# RR_RAW_CPM_INPUT: a renderer must not take network semantics from the plain
# control-plane model. Its semantic input is the validated canonical
# realization bundle, and the canonical content is what it may read.
#
# WHY THIS IS A SOURCE SCAN AND NOT A NIX EVAL
# --------------------------------------------
# The defect is not a bad value, it is a bad dependency: `controlPlaneEnvelope`
# IS the producer's CPM, handed through the bundle unchanged, and
# `bundle.network.data` carries the producer's data as-is (measured 2026-11-21:
# no `canonicalInterfaces`, no canonical routes -- the bundle adds validation,
# identity, provenance and coverage AROUND the CPM, it does not canonicalize
# it). So "consume the validated bundle" and "consume the CPM" are currently the
# same operation, and only a dependency scan can tell them apart.
#
# The sibling case `test-...-cpm-only-consumption.sh` lists this as an open gap:
#
#   GAPS (RR_* predicates not yet construction-provable in this test):
#     RR_RAW_CPM_INPUT — old direct-CPM API still accessible; gate not yet enforced
#
# This is that gate.
#
# THIS TEST CURRENTLY FAILS. That is the point: every renderer in the fleet still
# reaches the plain CPM somewhere, so the platform's claim that network-semantics
# enter through one validated canonical bundle holds only for validation, not for
# content. Do not make this pass by adding the hits to the allowlist below --
# each entry there is a documented, deliberate exception, and there are none yet.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"

fail() {
  echo "FAIL RR_RAW_CPM_INPUT: $*" >&2
  exit 1
}

# Implementation source only. `tests/` is excluded on purpose: a test may build
# a CPM as INPUT to prove the renderer rejects it (network-renderer-openconfig
# does exactly that with OC_RAW_CPM).
scan_roots=()
for candidate in s88 lib host-module.nix flake.nix; do
  [[ -e "${repo_root}/${candidate}" ]] && scan_roots+=("${repo_root}/${candidate}")
done
((${#scan_roots[@]} > 0)) || fail "no implementation source found (looked for s88/, lib/, host-module.nix, flake.nix)"

# Patterns that mean "read the plain control-plane model".
#
#   controlPlaneEnvelope        the producer's CPM as validateInput returns it
#   control_plane_model         the same thing by its own name
#
# `controlPlaneEnvelope.controlPlaneEnvelope` does not exist; the first name is
# the renderer-side handle and the second is the field inside the CPM.
pattern='controlPlaneEnvelope|control_plane_model'

# Deliberate exceptions, as "path:token". Each needs a reason. Empty today.
allowlist=()

hits="$(grep -rnE "${pattern}" "${scan_roots[@]}" --include='*.nix' 2>/dev/null || true)"
[[ -n "${hits}" ]] || {
  echo "PASS RR_RAW_CPM_INPUT: no renderer source reads the plain control-plane model"
  exit 0
}

unexempt=""
while IFS= read -r line; do
  [[ -n "${line}" ]] || continue
  # `grep -rn` gives "path:line:content"; compare on path plus the token found.
  file="${line%%:*}"
  rel="${file#"${repo_root}"/}"
  token="control_plane_model"
  grep -q "controlPlaneEnvelope" <<<"${line}" && token="controlPlaneEnvelope"
  exempt=0
  for entry in "${allowlist[@]}"; do
    [[ "${entry}" == "${rel}:${token}" ]] && exempt=1
  done
  ((exempt == 1)) || unexempt+="${rel}:${token}"$'\n'
done <<<"${hits}"

[[ -n "${unexempt}" ]] || {
  echo "PASS RR_RAW_CPM_INPUT: every plain-CPM read is an allowlisted exception"
  exit 0
}

{
  echo "FAIL RR_RAW_CPM_INPUT: this renderer takes network semantics from the plain control-plane model."
  echo
  echo "  hits:"
  while IFS= read -r entry; do
    [[ -n "${entry}" ]] && echo "    ${entry}"
  done <<<"${unexempt}"
  echo
  echo "  \`controlPlaneEnvelope\` is the producer's CPM, returned by"
  echo "  canonical.validateInput unchanged. \`control_plane_model\` is the same value"
  echo "  under its own name. Reading either is not consuming the canonical bundle:"
  echo "  it is consuming the CPM with a validation wrapper around it."
  echo
  echo "  This is why the fleet behaves inconsistently. A renderer that requires"
  echo "  canonical content fails loudly (network-renderer-openconfig: no"
  echo "  \`canonicalInterfaces\` -> no output), while a renderer that reads the plain"
  echo "  CPM keeps passing and cannot see that the canonical field is missing or"
  echo "  false."
  echo
  echo "  Fix: network-realization-model must emit canonical network semantics, and"
  echo "  this renderer must read those. Not here -- the renderer must not infer or"
  echo "  reconstruct them."
} >&2
exit 1
