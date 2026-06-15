#!/usr/bin/env bash
# run-all-tests.sh — Auto-discover and run all access-endpoint renderer tests.
#
# Usage:
#   ./run-all-tests.sh
#
# Environment:
#   TEST_JOBS              Number of parallel jobs (default: nproc)
#   TEST_TIMEOUT_SECONDS    Per-test timeout (default: 1800)
#   NETWORK_REPO_DIRECT_TEST_OK  Set to 1 to skip the guard warning
#
# Auto-discovers test-*.sh in tests/ and runs them asynchronously.
# Reports PASS/FAIL summary at the end.
# No hardcoded test list.

set -euo pipefail
exec > >(tee "/tmp/network-renderer-access-endpoint-nixos-tests.out")

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Guard: warn if NETWORK_REPO_DIRECT_TEST_OK is not set
if [[ "${NETWORK_REPO_SWEEP:-0}" != "1" && "${NETWORK_REPO_DIRECT_TEST_OK:-0}" != "1" ]]; then
  echo "WARN: direct repo tests are partial; set NETWORK_REPO_DIRECT_TEST_OK=1 for intentional focused runs." >&2
fi

default_jobs="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
jobs="${TEST_JOBS:-${default_jobs}}"
test_timeout_seconds="${TEST_TIMEOUT_SECONDS:-${NETWORK_REPO_TEST_TIMEOUT_SECONDS:-1800}}"

if ! [[ "${jobs}" =~ ^[0-9]+$ ]] || [[ "${jobs}" -lt 1 ]]; then
  echo "error: TEST_JOBS must be a positive integer, got '${jobs}'" >&2
  exit 2
fi
if ! [[ "${test_timeout_seconds}" =~ ^[0-9]+$ ]] || [[ "${test_timeout_seconds}" -lt 1 ]]; then
  echo "error: TEST_TIMEOUT_SECONDS must be a positive integer, got '${test_timeout_seconds}'" >&2
  exit 2
fi

# Auto-discover test files
mapfile -d '' tests < <(
  find "${repo_root}/tests" -maxdepth 1 -type f -name 'FS-*-HDS-*-SDS-*-SMS-*.sh' -print0 | sort -z
)

if [[ "${#tests[@]}" -eq 0 ]]; then
  echo "error: no FS-*-HDS-*-SDS-*-SMS-*.sh files found in ${repo_root}/tests" >&2
  exit 2
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

declare -A pid_to_name=()
declare -A pid_to_log=()
declare -A pid_to_start=()
running=0
failures=0
passed=0

wait_for_one() {
  local finished_pid
  local status=0
  wait -n -p finished_pid || status=$?

  local name="${pid_to_name[${finished_pid}]}"
  local log_file="${pid_to_log[${finished_pid}]}"
  local start="${pid_to_start[${finished_pid}]}"
  local elapsed=$((SECONDS - start))
  unset "pid_to_name[${finished_pid}]"
  unset "pid_to_log[${finished_pid}]"
  unset "pid_to_start[${finished_pid}]"
  running=$((running - 1))

  if (( status == 0 )); then
    printf 'PASS %s (%ss)\n' "${name}" "${elapsed}"
    passed=$((passed + 1))
  else
    printf 'FAIL %s (exit %s, %ss)\n' "${name}" "${status}" "${elapsed}" >&2
    awk -v prefix="[${name}] " '{ print prefix $0 }' "${log_file}" >&2
    failures=$((failures + 1))
  fi
}

printf 'running %s tests with TEST_JOBS=%s\n' "${#tests[@]}" "${jobs}"

for test_path in "${tests[@]}"; do
  test_name="$(basename "${test_path}")"
  log_file="${tmp_dir}/${test_name}.log"
  printf 'START %s\n' "${test_name}"

  timeout "${test_timeout_seconds}" bash "${test_path}" >"${log_file}" 2>&1 &
  pid=$!
  pid_to_name["${pid}"]="${test_name}"
  pid_to_log["${pid}"]="${log_file}"
  pid_to_start["${pid}"]="${SECONDS}"
  running=$((running + 1))

  while (( running >= jobs )); do
    wait_for_one
  done
done

while (( running > 0 )); do
  wait_for_one
done

echo ""
echo "========================================"
printf 'Results: %s passed, %s failed, %s total\n' "${passed}" "${failures}" "${#tests[@]}"
printf 'PASS: %s, FAIL: %s, TOTAL: %s\n' "${passed}" "${failures}" "${#tests[@]}" >&2

if (( failures > 0 )); then
  printf 'FAIL network-renderer-access-endpoint-nixos: %s test(s) failed\n' "${failures}" >&2
  exit 1
fi

printf 'PASS network-renderer-access-endpoint-nixos: all %s tests passed\n' "${#tests[@]}"
