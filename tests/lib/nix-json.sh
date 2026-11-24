#!/usr/bin/env bash
# GAMP-SCOPE: runner-only helper; not SMT acceptance evidence.
#
# `nix eval` output capture, with stderr kept OUT of the value.
#
# WHY THIS FILE EXISTS
# --------------------
# Every construction case in this repository evaluates the renderer with
# `nix eval --impure --json -f <fixture>.nix` and then reads fields out of the
# result with `jq`. The obvious spelling
#
#     B2_JSON=$(nix eval --impure --json -f "${SCRATCH}/b2-positive.nix" 2>&1)
#
# is wrong, and wrong in the worst way: when the result is a cold flake input,
# Nix writes progress to stderr --
#
#     copying path '/nix/store/…-source' from 'https://cache.nixos.org'…
#
# -- and `2>&1` folds that line into the captured value. `jq` then reads
# `copying path…` instead of `{…}` and reports
#
#     jq: parse error: Invalid numeric literal at line 1, column 8
#
# which the case faithfully reports as a renderer defect. Measured on a CI
# runner (cold store): four cases here failed that way on a commit whose
# behaviour was identical to a green local run, because a developer machine has
# the store path already. That is an environment fact being reported as a
# product fact, which is the same defect class as asserting connectivity no
# layer derived.
#
# THE RULE
# --------
# Stderr is diagnostics, never the document. A case that needs the error text
# (a `throw` seeded negative) captures stdout and stderr in two files and reads
# the message out of the second one; see `nix_eval_stderr_matches` below.

# Resolve the repository root for a case that lives in `tests/lib/<dir>/`.
# The cases are also sourced by `tests/run-one.sh`, so `$0` is not reliable.
nix_json_repo_root() {
  local case_path="$1"
  (cd "$(dirname "${case_path}")/../../.." && pwd)
}

# nix_json <fixture.nix>
#
# Prints the JSON document on stdout. Nix's stderr is written to
# `<scratch>/<fixture>.stderr` and echoed to the case's stderr only when the
# evaluation fails, so a crash stays diagnosable and a warning stays harmless.
nix_json() {
  local expr="$1"
  local stash="${SCRATCH:-${TMPDIR:-/var/tmp}}"
  local err="${stash}/$(basename "${expr}" .nix).stderr"
  if nix eval --impure --json -f "${expr}" 2>"${err}"; then
    return 0
  fi
  echo "  nix eval stderr ($(basename "${expr}")):" >&2
  sed 's/^/    /' "${err}" >&2
  return 1
}

# nix_plain <fixture.nix>
#
# The same contract for an evaluation whose value is not JSON (a count, a
# string). Kept separate so a caller cannot accidentally ask for JSON and get a
# bare value.
nix_plain() {
  local expr="$1"
  local stash="${SCRATCH:-${TMPDIR:-/var/tmp}}"
  local err="${stash}/$(basename "${expr}" .nix).stderr"
  if nix eval --impure -f "${expr}" 2>"${err}"; then
    return 0
  fi
  echo "  nix eval stderr ($(basename "${expr}")):" >&2
  sed 's/^/    /' "${err}" >&2
  return 1
}

# nix_eval_stderr_once <fixture.nix> <needle>
#
# For a seeded negative that must `throw`: runs the evaluation, keeps stdout and
# stderr apart, and succeeds only if the evaluation FAILED and its stderr
# contains <needle>. Both streams land in `<scratch>/<fixture>.{out,stderr}` so a
# caller can print them; the message being on stderr is the point, because a
# `throw` is not a document.
nix_eval_stderr_once() {
  local expr="$1"
  local needle="$2"
  local stash="${SCRATCH:-${TMPDIR:-/var/tmp}}"
  local stem="${stash}/$(basename "${expr}" .nix)"
  local status=0
  nix eval --impure -f "${expr}" >"${stem}.out" 2>"${stem}.stderr" || status=$?
  if ((status == 0)); then
    return 1
  fi
  grep -q "${needle}" "${stem}.stderr"
}
