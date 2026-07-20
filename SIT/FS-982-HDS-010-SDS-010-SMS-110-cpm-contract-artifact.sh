#!/usr/bin/env bash
# GAMP-ID: FS-982-HDS-010-SDS-010-SMS-110
# GAMP-SCOPE: software-integration-test
# FS-982-SMS-110-RUNTIME: scoped-artifact
# FS-982-SMS-110-ARTIFACT: access-endpoint renderer direct CPM contract artifact
# FS-982-SMS-110-EVIDENCE: tests/FS-310-HDS-010-SDS-010-SMS-110.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL fs982-sms110-access-endpoint-sit: $*" >&2
  exit 1
}

evidence="tests/FS-310-HDS-010-SDS-010-SMS-110.sh"
output="$(NETWORK_REPO_DIRECT_TEST_OK=1 bash "${repo_root}/${evidence}" 2>&1)" || {
  printf '%s\n' "${output}" >&2
  fail "${evidence} failed"
}

grep -Fq "PASS access-endpoint-cpm-entry" <<<"${output}" \
  || fail "${evidence} did not prove direct CPM renderer entry"
grep -Fq "hostModule accepted path-only input without cpm/controlPlane" "${repo_root}/${evidence}" \
  || fail "${evidence} does not assert path-only input rejection"

echo "PASS fs982-sms110-access-endpoint-sit"
