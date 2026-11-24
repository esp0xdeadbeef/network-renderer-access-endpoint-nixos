#!/usr/bin/env bash
# GAMP-SCOPE: gate; CI history must be green before conformance work continues
#
# S88 CI GATE -- block on the last GitHub Actions run of the watched repository,
# and wait for it inside the test instead of making a caller poll.
#
# WHY THIS IS A GATE AND NOT A FINDING
# ------------------------------------
# The conformance tests in this directory assert real defects, so they are red on
# purpose. That makes "the suite is red" uninformative: it is red whether or not
# the platform builds. A red CI run on the watched repository is a different
# signal -- it means the thing under test does not even assemble -- and no
# conformance finding about it can be trusted until it does.
#
# So this file fails when the last run is not green, and says to fix that first.
#
# WHICH REPOSITORY IS WATCHED
# ---------------------------
#   S88_CI_WATCH_REPO     owner/name. Default: this repository's `origin`.
#   S88_CI_WATCH_BRANCH   default: main.
#
# The acceptance lane that drives the neon and cobalt fixtures sets
# `S88_CI_WATCH_REPO` to the site acceptance harness, because that is where the
# live the run that proves the fabric comes up. It is passed by name at the call
# site rather than written here: a public tree must not carry the name of a
# private repository (`tests/test-no-private-mirror-reference.sh`).
#
# WAITING INSTEAD OF POLLING
# --------------------------
# After a push the run may be queued for a minute and then take ten more. A
# caller that shell-loops on `gh run list` burns a turn per sleep and learns
# nothing. This test sleeps internally:
#
#   S88_CI_WAIT_SECONDS   total budget for the run to reach `completed`
#                         (default 7200)
#   S88_CI_POLL_SECONDS   between checks (default 45)
#   S88_CI_HISTORY_RUNS   how many past runs to measure the budget against
#                         (default 50; 0 disables the measurement)
#
# THE BUDGET IS SIZED FROM MEASURED HISTORY, NOT FROM A GUESS
# -----------------------------------------------------------
# Measured 2026-11-24 over the last 100 runs of each repository (`gh run list`):
#
#   network-labs                  max 4701s (78 min), mean 2036s
#   network-control-plane-model   max 4302s (72 min), mean 1287s
#   network-compiler              max  620s
#   network-forwarding-model      max  499s
#   network-renderer-wireguard    max  434s
#   network-renderer-nixos        max  294s
#   renderer-containerlab         max  185s
#   renderer-nebula               max  167s
#   renderer-openconfig           max   65s
#   renderer-access-endpoint      max   47s
#   the site acceptance harness   max   79s
#
# The long tail is the lab lane, because it rebuilds and boots the fabric. An
# earlier default of 1500s would have expired during a normal `network-labs` run
# (mean 2036s), which is the opposite of what this test is for. 7200s is ~1.5x the
# largest observed run, and this file re-measures the watched repository at run
# time so the number stays honest as the lane grows.
#
# It prints one `waiting:` line per poll so the log shows progress, and it stops
# the moment the run completes. There is no busy loop and no `sleep 1`.
#
# VERDICT
# -------
#   PASS  the last run on the branch is green
#   FAIL  it is not, or `gh` cannot be asked -- a gate that cannot check must not
#         report green. The failing job names are printed so the next step is
#         "fix these", not "investigate".
#   SKIP  deliberately disabled (`S88_CI_GATE=off`), no GitHub origin, or no run
#         history at all. A SKIP is recorded as skipped by the runner, never as a
#         pass, so it cannot be mistaken for evidence.
#
# Evidence boundary: network reads of CI history only. No build, no lab.
set -euo pipefail

if [[ -n "${SMS_TEST_REPO_ROOT:-}" ]]; then
  repo_root="${SMS_TEST_REPO_ROOT}"
else
  repo_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "${repo_root}" ]]; then
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
fi

wait_seconds="${S88_CI_WAIT_SECONDS:-7200}"
poll_seconds="${S88_CI_POLL_SECONDS:-45}"
history_runs="${S88_CI_HISTORY_RUNS:-50}"
branch="${S88_CI_WATCH_BRANCH:-main}"

echo "--- S88-CI-GATE: last CI run of the watched repository ---"
echo ""

if [[ "${S88_CI_GATE:-on}" == "off" ]]; then
  echo "SKIP S88-CI-GATE: S88_CI_GATE=off was set by the caller"
  exit 0
fi

# The watched repository: explicit, else this repository's origin.
watch_repo="${S88_CI_WATCH_REPO:-}"
if [[ -z "${watch_repo}" ]]; then
  origin="$(git -C "${repo_root}" remote get-url origin 2>/dev/null || true)"
  if [[ -z "${origin}" ]]; then
    echo "SKIP S88-CI-GATE: no S88_CI_WATCH_REPO and no origin remote to derive one from"
    exit 0
  fi
  # `git@host:owner/name.git` and `https://host/owner/name.git` both reduce to
  # `owner/name`. Strip the suffix explicitly: a lazy `+?` is not ERE, and the
  # first version of this left `.git` on the name and reported "no run history".
  watch_repo="$(sed -E 's#^.*[:/]([^/]+/[^/]+)$#\1#' <<<"${origin}")"
  watch_repo="${watch_repo%.git}"
fi

echo "  repository: ${watch_repo}"
echo "  branch:     ${branch}"
echo "  wait budget: ${wait_seconds}s (poll ${poll_seconds}s)"

# The budget must exceed what this repository actually takes, or the gate fails on
# its own patience instead of on CI. Measure, print, and say so when it is short.
if (( history_runs > 0 )); then
  history_max="$(gh run list -R "${watch_repo}" -L "${history_runs}" \
    --json createdAt,updatedAt \
    --jq '[.[] | ((.updatedAt|fromdate) - (.createdAt|fromdate))] | max // 0' 2>/dev/null || echo "")"
  if [[ -n "${history_max}" && "${history_max}" != "0" ]] && (( history_max > wait_seconds )); then
    echo "  note:      the longest of the last ${history_runs} runs took ${history_max}s, longer"
    echo "             than the ${wait_seconds}s budget. Raise S88_CI_WAIT_SECONDS or the"
    echo "             gate will report a timeout instead of a verdict."
  elif [[ -n "${history_max}" && "${history_max}" != "0" ]]; then
    echo "  history:   longest of the last ${history_runs} runs: ${history_max}s"
  fi
fi

# The runner caps each test; a wait budget above it is cut short there first.
if [[ -n "${TEST_TIMEOUT_SECONDS:-}" ]] && (( TEST_TIMEOUT_SECONDS <= wait_seconds )); then
  echo "  note:      TEST_TIMEOUT_SECONDS=${TEST_TIMEOUT_SECONDS} is not above the wait"
  echo "             budget; the runner will kill this test before it can judge the run."
  echo "             Run with TEST_TIMEOUT_SECONDS=$(( wait_seconds + 300 ))."
fi
echo ""

if ! command -v gh >/dev/null 2>&1; then
  echo "FAIL S88-CI-GATE: gh is not installed, so the gate cannot read CI history." >&2
  echo "  A gate that cannot check must not report green. Install gh, or set" >&2
  echo "  S88_CI_GATE=off deliberately and say so." >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "FAIL S88-CI-GATE: gh has no credentials inside CI, so the gate cannot read history." >&2
    echo "  The test-suite job must export a token with actions:read, for example:" >&2
    echo "    env: GH_TOKEN: \${{ github.token }}   # and permissions: actions: read" >&2
    exit 1
  fi
  echo "SKIP S88-CI-GATE: gh is not authenticated in this environment"
  echo "  (set S88_CI_GATE=off to silence this deliberately, or run 'gh auth login')"
  exit 0
fi

# Read the newest judgeable run as one TAB-separated record:
#   id, status, conclusion, headSha, displayTitle, url, event
#
# Two runs are excluded, and both exclusions are load-bearing:
#
#   * the run that is executing this test (`GITHUB_RUN_ID`). Without it the gate
#     waits for itself and expires every time -- a deadlock, not a gate.
#   * `cancelled` runs. This workflow cancels in progress on a new push, so the
#     newest run after a push is usually the one the push killed. Judging that
#     would report a cancellation as a CI failure.
#
# @tsv keeps this dependency-free: no jq, no gh --jq expression parsing.
newest_run() {
  local self_id="${GITHUB_RUN_ID:-none}"
  gh run list -R "${watch_repo}" -b "${branch}" -L 10 \
    --json databaseId,status,conclusion,headSha,displayTitle,url,event \
    --jq "[.[]
           | select((.databaseId|tostring) != \"${self_id}\")
           | select(.conclusion != \"cancelled\")]
          | .[0]
          | [.databaseId, .status, (.conclusion // \"\"), .headSha, .displayTitle, .url, .event]
          | @tsv" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Sleep until that run reaches `completed`. One line per poll so the log shows
# progress; nothing else happens while waiting.
# ---------------------------------------------------------------------------
deadline=$(( $(date +%s) + wait_seconds ))
waiting_reported=0
run_record=""

while :; do
  run_record="$(newest_run)"

  if [[ -z "${run_record}" ]]; then
    echo "SKIP S88-CI-GATE: ${watch_repo}/${branch} has no run that this test can judge"
    echo "  (all recent runs are cancelled, or the only run is this one)"
    exit 0
  fi

  IFS=$'\t' read -r run_id status _conclusion _sha _title _url _event <<<"${run_record}"

  if [[ "${status}" == "completed" ]]; then
    break
  fi

  now="$(date +%s)"
  if (( now >= deadline )); then
    echo "FAIL S88-CI-GATE: run ${run_id} was still '${status}' after ${wait_seconds}s." >&2
    echo "  Not judged. Re-run this test once the run completes; do not start new" >&2
    echo "  conformance work on an unverified pipeline." >&2
    exit 1
  fi

  if (( waiting_reported == 0 )); then
    echo "  waiting: run ${run_id} is '${status}'; polling every ${poll_seconds}s up to ${wait_seconds}s"
    waiting_reported=1
  else
    echo "  waiting: still '${status}' ($(( deadline - now ))s left)"
  fi
  sleep "${poll_seconds}"
done

# ---------------------------------------------------------------------------
# Judge it.
# ---------------------------------------------------------------------------
IFS=$'\t' read -r run_id _status conclusion run_sha run_title run_url run_event <<<"${run_record}"

local_sha="$(git -C "${repo_root}" rev-parse HEAD 2>/dev/null || echo unknown)"

echo "  run:        ${run_id} (${run_event}) -> ${conclusion}"
echo "  commit:     ${run_sha}"
echo "  title:      ${run_title}"
echo "  url:        ${run_url}"
if [[ "${run_sha}" != "${local_sha}" ]]; then
  echo "  note:       this run judged ${run_sha:0:12}; the checkout is ${local_sha:0:12}."
  echo "              That is the last judgeable run on ${branch}, which is what this checks."
fi
echo ""

if [[ "${conclusion}" == "success" ]]; then
  echo "PASS S88-CI-GATE: last run ${run_id} on ${watch_repo}/${branch} succeeded"
  exit 0
fi

{
  echo "FAIL S88-CI-GATE: last run ${run_id} on ${watch_repo}/${branch} concluded '${conclusion}'."
  echo "  Fix the CI failure first; conformance findings about a pipeline that does not"
  echo "  build or deploy are not trustworthy, and a red main hides the next real signal."
  echo ""
  echo "  run:   ${run_url}"
  echo "  title: ${run_title}"

  jobs="$(gh run view "${run_id}" -R "${watch_repo}" --json jobs \
    --jq '[.jobs[] | select(.conclusion != "success" and .conclusion != null and .conclusion != "skipped")
           | "    \(.name): \(.conclusion)"] | join("\n")' 2>/dev/null || true)"
  if [[ -n "${jobs}" ]]; then
    echo ""
    echo "  failing jobs:"
    echo "${jobs}"
  else
    echo ""
    echo "  (no per-job detail available; open the run URL above)"
  fi

  echo ""
  echo "  Do not make this pass by setting S88_CI_GATE=off in a commit. The variable"
  echo "  exists for a deliberate, reviewed local run, not for silencing the gate."
} >&2
exit 1
