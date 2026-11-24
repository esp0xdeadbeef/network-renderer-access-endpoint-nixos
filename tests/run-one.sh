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
#   - a case that prints `SKIP ` is reported as FAIL. Skipping is not a verdict: it
#     is indistinguishable from a green run in a summary, so it hides the fact that
#     nothing was tested.
# The case runs SOURCED, which is how every case found its own directory in the
# per-repository runners before the matrix existed. Sourcing means `$0` is this
# runner, not the case, so a case that located itself with `dirname "$0"`
# resolved the REPO to the caller's working directory: under `run-one.sh` from
# inside the repo that happened to be right, and under CI's shard loop it";
# resolved to the parent of the checkout and `nix run "$ROOT#compile"` failed
# with "path ... does not contain a 'flake.nix'". Nine cases were red for that
# one reason and for no defect in what they assert.
#
# Both halves of the fix are present and neither is a workaround for the other:
#   * each of those cases now locates itself with ${BASH_SOURCE[0]}, which is
#     the case file even when it is sourced, so a case is correct under any
#     runner including `bash tests/x.sh`;
#   * `$0` in the shell below is the case's own path, so the `dirname "$0"`
#     spelling that caused this keeps working -- for a case that has not been
#     converted yet, or one written later by copying an old one. `$0` is the
#     argument to `bash -c`, and it survives the `set --` that installs the
#     trace id because that only replaces the positional parameters.
status=0
timeout "${timeout_seconds}" bash -c '
  _trace="$1"
  _repo="$2"
  if [[ -f "${_repo}/tests/lib/test-common.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_repo}/tests/lib/test-common.sh"
  fi
  set -- "${_trace}"
  source "$0"
' "${test_path}" "$(basename "${test_path}" .sh)" "${repo_root}" >"${log}" 2>&1 || status=$?

# A case that declares SKIP is a case that does not test. It is reported as a
# failure on purpose: a skip that reads as green is how a suite claims coverage it
# does not have. Either make the case run in this environment (check the subject out,
# build the fixture) or delete it -- there is no third option that belongs in CI.
if grep -q '^SKIP ' "${log}"; then
  cat "${log}"
  echo "FAIL $(basename "${test_path}"): the case declared SKIP; a skipped case is not a verdict. Make it run here, or delete it." >&2
  exit 1
fi

cat "${log}"

if ((status != 0)); then
  echo "FAIL $(basename "${test_path}") (exit ${status})" >&2
  exit 1
fi

echo "PASS $(basename "${test_path}")"
