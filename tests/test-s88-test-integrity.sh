#!/usr/bin/env bash
# GAMP-SCOPE: meta-guard; protects the S88 conformance tests from being weakened
#
# S88 TEST INTEGRITY -- notify when a protected test is edited, deleted, or
# silently exempted, instead of being made honest.
#
# WHY THIS FILE EXISTS
# --------------------
# Every other `tests/test-s88-*.sh` in this repository asserts that a defect is
# present: they are RED on purpose. A red suite is uncomfortable to work with, so
# the cheapest way to get a green run is to edit the test rather than the defect:
#
#   * relax an assertion, or delete it;
#   * add a skip / an opt-in flag (`[[ -n "${CI:-}" ]] || exit 0`);
#   * widen an error path with `|| true`;
#   * add the offending file to an allowlist;
#   * delete the test and its entry.
#
# All five are forbidden by the owning AGENTS.md ("Fixing rules" 2: "Never make a
# test pass by deleting it, weakening an assertion, adding a skip/opt-in flag, or
# widening an error path with `|| true`. A test that passes because it stopped
# asserting is still a failure."). A rule with no check is a convention, so this
# file is the check.
#
# HOW IT DETECTS IT
# -----------------
# `tests/lib/s88-integrity.manifest` pins the SHA-256 of every protected file and
# declares how many files it protects. This test recomputes them and fails on any
# difference, on any protected file that is missing, and on any
# `tests/test-s88-*.sh` that is present but not pinned -- a test nobody pinned is
# a test nobody is protecting.
#
# Adding or changing a protected test is legitimate. It requires editing the
# manifest in the same commit, which makes the change visible in review instead of
# invisible in a diff of an assertion. That is the whole mechanism: the hash does
# not forbid the change, it refuses to let it be quiet.
#
# THE NOTIFICATION
# ----------------
# Failures are emitted as GitHub Actions annotations in addition to the usual
# FAIL line:
#
#   ::error title=S88 TEST TAMPERED,file=<path>::<what changed>
#
# An annotation attaches to the failing file in the run summary, which is what
# produces the notification on a watched repository. A reviewer reading only the
# checks list still sees "S88 test integrity" fail, with the path.
#
# WHAT THIS CANNOT DO, STATED SO IT IS NOT OVERSOLD
# -------------------------------------------------
# A commit that rewrites BOTH the protected test and the manifest is internally
# consistent and passes. No in-repository check can prevent that; only review of
# the manifest diff can. What this does prevent is the quiet case -- one edited
# assertion, one added skip, one deleted line -- which is how a suite is weakened
# in practice.
#
# Evidence boundary: construction. Static file reads and hashing only.
set -euo pipefail

if [[ -n "${SMS_TEST_REPO_ROOT:-}" ]]; then
  repo_root="${SMS_TEST_REPO_ROOT}"
else
  repo_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "${repo_root}" ]]; then
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
fi

manifest="${repo_root}/tests/lib/s88-integrity.manifest"

problems=0
notify() {
  local path="$1" what="$2"
  problems=$((problems + 1))
  echo "::error title=S88 TEST TAMPERED,file=${path}::${what}"
  echo "TAMPERED ${path}: ${what}" >&2
}

echo "--- S88-INTEGRITY: protected S88 tests are unmodified ---"
echo ""

if [[ ! -f "${manifest}" ]]; then
  notify "tests/lib/s88-integrity.manifest" "the manifest that pins the protected tests is missing"
  echo "FAIL S88-INTEGRITY: no manifest" >&2
  exit 1
fi

expected_count="$(sed -n 's/^# PROTECTED-COUNT:[[:space:]]*\([0-9]\+\).*$/\1/p' "${manifest}" | head -1)"
if [[ -z "${expected_count}" ]]; then
  notify "tests/lib/s88-integrity.manifest" "the manifest declares no PROTECTED-COUNT, so a deletion cannot be detected"
fi

listed=0
while IFS= read -r line; do
  [[ -n "${line}" ]] || continue
  case "${line}" in \#*) continue ;; esac
  listed=$((listed + 1))

  want="${line%%  *}"
  path="${line##*  }"
  [[ -n "${want}" && -n "${path}" ]] || continue

  if [[ ! -f "${repo_root}/${path}" ]]; then
    notify "${path}" "protected file is missing (a deleted test is a weakened test)"
    continue
  fi

  got="$(sha256sum "${repo_root}/${path}" | awk '{print $1}')"
  if [[ "${got}" != "${want}" ]]; then
    notify "${path}" "content changed: pinned ${want}, found ${got}"
  fi
done <"${manifest}"

# A test that exists but is not pinned is unprotected. That is how a second,
# weaker copy of a check appears next to the real one.
while IFS= read -r file; do
  [[ -n "${file}" ]] || continue
  rel="${file#"${repo_root}/"}"
  grep -qE "^[0-9a-f]{64}  ${rel}\$" "${manifest}" || notify "${rel}" "test file is not pinned by the manifest"
done < <(find "${repo_root}/tests" -maxdepth 1 -type f -name 'test-s88-*.sh' | LC_ALL=C sort)

if [[ -n "${expected_count}" ]] && ((listed != expected_count)); then
  notify "tests/lib/s88-integrity.manifest" "declares ${expected_count} protected files but lists ${listed}"
fi

if ((problems > 0)); then
  echo ""
  echo "FAIL S88-INTEGRITY: ${problems} protected file(s) differ from the pinned manifest." >&2
  echo "  If the change is intentional, update tests/lib/s88-integrity.manifest in the" >&2
  echo "  same commit and say why in the message. AGENTS.md 'Fixing rules' 2 forbids" >&2
  echo "  making a test pass by deleting it, weakening an assertion, adding a skip or" >&2
  echo "  opt-in flag, or widening an error path with '|| true'." >&2
  echo "  Fix the defect the test names, not the test." >&2
  exit 1
fi

echo "PASS S88-INTEGRITY: ${listed} protected file(s) match the pinned manifest"
echo "  (a change to a protected test requires editing the manifest in the same commit,"
echo "   which makes the change visible in review -- see the file header for the limit)"
exit 0
