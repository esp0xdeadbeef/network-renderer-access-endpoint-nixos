#!/usr/bin/env bash
# GAMP-SCOPE: runner-only test scheduling; not SMT acceptance evidence.
#
# The one local test runner for every `network-*` repository.
#
# This file is byte-identical everywhere it ships. Do not fork it: thirteen
# divergent copies of the local runner existed (nine `tests/test.sh`, eight
# `run-all-tests.sh`, two `tests/run.sh`), and "the suite" therefore meant a
# different thing depending on the repository -- some copies ran every test and
# exited 0 no matter what, one discarded each test's output with `>/dev/null`, and
# exactly one could stop at the first failure. A runner is a gate; a gate that
# answers differently per repository is not a gate.
#
# Usage
# -----
#   NETWORK_REPO_DIRECT_TEST_OK=1 bash tests/test.sh     # the whole sweep
#   NETWORK_REPO_DIRECT_TEST_OK=1 ./run-all-tests.sh     # same run (shim)
#
# Environment
#   TEST_JOBS             Max concurrent tests (default: nproc)
#   TEST_TIMEOUT_SECONDS  Per-test timeout in seconds (default: 1800)
#   TEST_FAIL_FAST        1: stop at the first failure; 0: run everything
#                         (default: 1 locally, 0 when CI is set)
#
# WHY FAIL-FAST IS THE LOCAL DEFAULT AND NOT THE CI ONE
# -----------------------------------------------------
# Iterating on a bug means running the suite dozens of times, and the sweep is
# minutes (CPM: 288 entrypoints, labs: 486). When the first test has already
# failed, the rest are results about defects nobody will touch until that one is
# fixed. So a human-driven run stops, cancels what is in flight, and says how much
# it did not run.
#
# CI asks the opposite question -- "is this commit good" -- and its value is the
# complete list of what is broken: one red per defect, not one run per defect. So
# fail-fast defaults OFF when `CI` is set, an explicit TEST_FAIL_FAST wins over
# both, and the effective setting is printed at startup so a run's behaviour is
# never a guess.
#
# CI does not call this script. `.github/workflows/tests-matrix.yml` runs one
# entrypoint per job through `tests/run-one.sh`, so one failing test cannot hide
# another. This entry point is for the local loop.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_name="$(basename "${repo_root}")"
test_dir="${repo_root}/tests"

# --- configuration ---
default_jobs="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
jobs="${TEST_JOBS:-${default_jobs}}"
test_timeout_seconds="${TEST_TIMEOUT_SECONDS:-1800}"

if ! [[ "${jobs}" =~ ^[0-9]+$ ]] || [[ "${jobs}" -lt 1 ]]; then
  echo "error: TEST_JOBS must be a positive integer, got '${jobs}'" >&2
  exit 2
fi
if ! [[ "${test_timeout_seconds}" =~ ^[0-9]+$ ]] || [[ "${test_timeout_seconds}" -lt 1 ]]; then
  echo "error: TEST_TIMEOUT_SECONDS must be a positive integer, got '${test_timeout_seconds}'" >&2
  exit 2
fi

if [[ -n "${TEST_FAIL_FAST:-}" ]]; then
  fail_fast="${TEST_FAIL_FAST}"
  fail_fast_origin="TEST_FAIL_FAST"
elif [[ -n "${CI:-}" ]]; then
  fail_fast="0"
  fail_fast_origin="CI detected"
else
  fail_fast="1"
  fail_fast_origin="local default"
fi
case "${fail_fast}" in
  0|1) ;;
  *) echo "error: TEST_FAIL_FAST must be 0 or 1, got '${fail_fast}'" >&2; exit 2 ;;
esac

if [[ "${NETWORK_REPO_SWEEP:-0}" != "1" && "${NETWORK_REPO_DIRECT_TEST_OK:-0}" != "1" ]]; then
  echo "WARN: direct repo tests are partial; set NETWORK_REPO_DIRECT_TEST_OK=1 for intentional focused runs." >&2
fi

# --- discovery ---
# The shared contract, when the repository has adopted it.
if [[ -f "${repo_root}/scripts/lib/discover-tests.sh" ]]; then
  # shellcheck source=/dev/null
  source "${repo_root}/scripts/lib/discover-tests.sh"
  mapfile -t test_names < <(discover_tests "${repo_root}")
else
  # The same naming rule, inline, so a repository that has not adopted the
  # contract still runs its tests instead of discovering none and exiting 0 --
  # a runner that reports success over zero tests is worse than no runner.
  mapfile -t test_names < <(
    find "${test_dir}" -maxdepth 1 \( -type f -o -type l \) \
      \( \
        -name 'test-*.sh' \
        -o -name 'test_*.py' \
        -o -regextype posix-extended -regex '.*/FS-[0-9]+-HDS-[0-9]+-SDS-[0-9]+-(SMS|SIT)-[0-9a-z][a-z0-9-]*(-[a-z0-9-]+)?\.(sh|py)' \
      \) \
      ! -name 'test.sh' \
      -printf '%f\n' 2>/dev/null | LC_ALL=C sort
  )
fi

test_files=()
for test_name in "${test_names[@]}"; do
  test_files+=("${test_dir}/${test_name}")
done

if [[ ${#test_files[@]} -eq 0 ]]; then
  echo "error: no test entrypoints discovered in ${test_dir}" >&2
  exit 2
fi

# --- run ---
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

declare -A pid_to_name=()
declare -A pid_to_log=()
declare -A pid_to_start=()
declare -A cancelled_pids=()
declare -a started_pids=()
running=0
failures=0
passed=0
skipped=0
cancelled=0

# `setsid` gives each test its own process group, so a fail-fast stop can cancel
# the whole tree. Without it a TERM reaches the wrapper subshell and nothing else:
# measured, the sweep then waited 30s for a `sleep 30` it had already decided not
# to wait for.
setsid_bin="$(command -v setsid || true)"

record_result() {
  local pid="${1:?}" status="${2:-0}"
  local name="${pid_to_name[${pid}]:-}"
  local log_file="${pid_to_log[${pid}]:-}"
  local start="${pid_to_start[${pid}]:-${SECONDS}}"
  local elapsed=$((SECONDS - start))
  [[ -n "${name}" ]] || return 0
  unset "pid_to_name[${pid}]"
  unset "pid_to_log[${pid}]"
  unset "pid_to_start[${pid}]"
  running=$((running - 1))

  if (( status == 0 )) && grep -q '^SKIP ' "${log_file}" 2>/dev/null; then
    # A case that cannot run here (no adjacent checkout, no lab path) says SKIP and
    # exits 0. That is not a pass: it is counted separately, so a run can never
    # claim coverage it did not have. The CI matrix treats the same line as a
    # failure, because a skipped test on a runner that has the checkout is a
    # missing test rather than an environment limit.
    printf 'SKIP %s (%ss)\n' "${name}" "${elapsed}"
    grep '^SKIP ' "${log_file}" >&2 || true
    skipped=$((skipped + 1))
  elif (( status == 0 )); then
    printf 'PASS %s (%ss)\n' "${name}" "${elapsed}"
    passed=$((passed + 1))
  else
    printf 'FAIL %s (exit %s, %ss)\n' "${name}" "${status}" "${elapsed}" >&2
    awk -v prefix="[${name}] " '{ print prefix $0 }' "${log_file}" >&2
    failures=$((failures + 1))
  fi
}

wait_for_one() {
  local finished_pid=""
  local status=0
  wait -n -p finished_pid || status=$?
  [[ -n "${finished_pid}" ]] || { running=0; return 1; }
  record_result "${finished_pid}" "${status}"
}

cancel_in_flight() {
  local pid
  (( running > 0 )) || return 0
  printf 'STOP fail-fast: cancelling %s test(s) still in flight\n' "${running}" >&2
  for pid in "${started_pids[@]}"; do
    [[ -n "${pid_to_name[${pid}]:-}" ]] || continue
    cancelled_pids[${pid}]=1
    cancelled=$((cancelled + 1))
    kill -TERM -- "-${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
  done
}

printf '%s: running %s tests with TEST_JOBS=%s, fail-fast=%s (%s)\n' \
  "${repo_name}" "${#test_files[@]}" "${jobs}" "${fail_fast}" "${fail_fast_origin}"

for test_file in "${test_files[@]}"; do
  if (( fail_fast == 1 && failures > 0 )); then
    printf 'STOP fail-fast: not starting the remaining tests after %s failure(s)\n' "${failures}" >&2
    cancel_in_flight
    break
  fi

  name="${test_file#${repo_root}/}"
  log_file="${tmp_dir}/${name//\//__}.log"
  printf 'START %s\n' "${name}"

  ${setsid_bin:+"${setsid_bin}"} timeout "${test_timeout_seconds}" bash -c '
    _common="$1"
    _test="$2"
    _trace="$(basename "${_test}" .sh)"
    [[ -f "${_common}" ]] && source "${_common}"
    case "${_test}" in
      *.py) set --; exec python3 "$_test" ;;
      # Pass the trace id as $1. These cases take `trace_id="${1:-${invoked_name}}"`
      # where `invoked_name` is `basename "$0"`, and while `source`d `$0` is THIS
      # runner, so the fallback read "test" and 81 of 110 cases exited 2 with
      # `usage: <trace-id>` -- reported as failures that passed when run directly.
      *)    set -- "${_trace}"; source "$_test" ;;
    esac
  ' _ "${repo_root}/tests/lib/test-common.sh" "${test_file}" >"${log_file}" 2>&1 &

  started_pids+=("$!")
  pid_to_name[$!]="${name}"
  pid_to_log[$!]="${log_file}"
  pid_to_start[$!]="${SECONDS}"
  running=$((running + 1))

  if (( running >= jobs )); then
    wait_for_one
  fi
done

# A failure that lands while every remaining test is ALREADY running stops nothing
# unless the in-flight ones are cancelled here; otherwise the sweep waits out the
# slowest of them, which is the case fail-fast exists for.
if (( fail_fast == 1 && failures > 0 )); then
  cancel_in_flight
fi

# Reap whatever is still in flight. A cancelled job's own result is meaningless, so
# it is neither a pass nor an extra failure -- but everything else must still be
# COUNTED: an earlier version discarded every in-flight result, so a run whose
# last-started test failed printed "TOTAL: 0" and exited 0.
while (( running > 0 )); do
  finished_pid=""
  status=0
  wait -n -p finished_pid || status=$?
  [[ -n "${finished_pid}" ]] || { running=0; break; }
  if [[ -n "${cancelled_pids[${finished_pid}]:-}" ]]; then
    unset "pid_to_name[${finished_pid}]"
    unset "pid_to_log[${finished_pid}]"
    unset "pid_to_start[${finished_pid}]"
    running=$((running - 1))
  else
    record_result "${finished_pid}" "${status}"
  fi
done

# --- report ---
total=$((passed + skipped + failures))
printf '\n%s passed, %s skipped, %s failed, %s cancelled of %s discovered\n' \
  "${passed}" "${skipped}" "${failures}" "${cancelled}" "${#test_files[@]}"
printf 'PASS: %s, SKIP: %s, FAIL: %s, CANCELLED: %s, TOTAL: %s\n' \
  "${passed}" "${skipped}" "${failures}" "${cancelled}" "${total}" >&2

if (( fail_fast == 1 && failures > 0 )); then
  not_run=$(( ${#test_files[@]} - passed - skipped - failures - cancelled ))
  if (( not_run > 0 )); then
    printf 'NOT RUN %s test(s): fail-fast stopped the sweep after the first failure\n' "${not_run}" >&2
  fi
  if (( cancelled > 0 )); then
    printf 'CANCELLED %s test(s) still in flight when fail-fast stopped the sweep\n' "${cancelled}" >&2
  fi
fi

if (( failures > 0 )); then
  printf 'FAIL %s: %s test(s) failed\n' "${repo_name}" "${failures}" >&2
  exit 1
fi

if (( skipped > 0 )); then
  printf 'PASS %s: %s passed, %s skipped (not run)\n' "${repo_name}" "${passed}" "${skipped}"
else
  printf 'PASS %s: all %s tests passed\n' "${repo_name}" "${total}"
fi
