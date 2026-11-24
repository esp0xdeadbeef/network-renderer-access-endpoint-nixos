#!/usr/bin/env bash
# Run exactly ONE test entrypoint, for a CI matrix job.
#
# Why this exists instead of `run-all-tests.sh`: the per-repository runners forked
# into ten variants, each with its own scheduling, output and exit conventions, so
# none of them can be copied between repositories without verification. A matrix
# needs the opposite of a scheduler: one job, one test, one exit code. This file is
# that, and it is small enough that being byte-identical everywhere is credible.
#
# Usage:  run-one.sh tests/FS-100-HDS-010-SDS-010-SMS-010.sh
#         run-one.sh tests/test_trace_ids.py
#
# Environment:
#   TEST_TIMEOUT_SECONDS   per-test timeout (default 1800)
#
# Exit: 0 pass or declared SKIP, 1 fail, 2 misuse.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -ne 1 ]]; then
  echo "usage: run-one.sh <test-path>" >&2
  exit 2
fi

test_path="$1"
[[ "${test_path}" != /* ]] && test_path="${repo_root}/${test_path}"
[[ -f "${test_path}" ]] || { echo "error: no such test: $1" >&2; exit 2; }

timeout_seconds="${TEST_TIMEOUT_SECONDS:-1800}"

case "${test_path}" in
  *.py)
    exec timeout "${timeout_seconds}" python3 "${test_path}"
    ;;
esac

log="$(mktemp)"
trap 'rm -f "${log}"' EXIT

# The conventions the runners already established, kept so a case behaves the same
# under the matrix as it does locally:
#   - `tests/lib/test-common.sh` is sourced when the repository has one;
#   - the trace id (the file name, without .sh) is passed as $1, because the cases
#     read `trace_id="${1:-...}"` and run with $0 = this script otherwise;
#   - a case that cannot run here prints `SKIP ` and exits 0, and is reported as
#     skipped rather than passed.
status=0
timeout "${timeout_seconds}" bash -c '
  _file="$1"
  _trace="$2"
  _repo="$3"
  if [[ -f "${_repo}/tests/lib/test-common.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_repo}/tests/lib/test-common.sh"
  fi
  set -- "${_trace}"
  source "${_file}"
' _ "${test_path}" "$(basename "${test_path}" .sh)" "${repo_root}" >"${log}" 2>&1 || status=$?

if ((status == 0)) && grep -q '^SKIP ' "${log}"; then
  cat "${log}"
  echo "SKIP $(basename "${test_path}")"
  exit 0
fi

cat "${log}"

if ((status != 0)); then
  echo "FAIL $(basename "${test_path}") (exit ${status})" >&2
  exit 1
fi

echo "PASS $(basename "${test_path}")"
