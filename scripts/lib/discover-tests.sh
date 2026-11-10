#!/usr/bin/env bash
# GAMP-SCOPE: runner-only test discovery; not SMT acceptance evidence.
#
# Canonical test-entrypoint discovery for every `network-*` repository.
#
# This file is byte-identical in every repository that ships it. Do not fork it
# per repository: a divergent copy is how a whole class of tests stops running
# in CI without anybody noticing. If the contract below must change, change it
# here and copy the same file to the other repositories in the same change.
#
# Contract
# --------
# `discover_tests <repo-root>` prints one test entrypoint per line, relative to
# `<repo-root>/tests`, sorted with LC_ALL=C, and exits 0. It prints nothing else
# on stdout. It never inspects git state, never runs a build, and never lists a
# hardcoded test name.
#
# An entrypoint is a regular file or a symlink directly under `tests/` whose
# name matches one of:
#
#   test-*.sh                     focused or infrastructure test
#   test_*.py                     Python test module
#   FS-<n>-HDS-<n>-SDS-<n>-SMS-<n>.sh|.py
#                                 canonical construction SMS entrypoint
#   FS-<n>-HDS-<n>-SDS-<n>-SMS-<n>-<slug>.sh|.py
#                                 trace-bound SMS entrypoint with a qualifier
#                                 suffix (for example `-ratm`); still a test,
#                                 because it carries the full trace chain
#   FS-<n>-HDS-<n>-SDS-<n>-SIT-<slug>.sh|.py
#                                 trace-bound SIT entrypoint
# Excluded by construction, so that adding one of these never changes the suite:
#
#   * `test.sh`                                    repository test dispatcher
#   * anything under `tests/lib/`, `tests/fixtures/`, `tests/cases/`, or any
#     other subdirectory; those are helpers and case fixtures invoked by an
#     entrypoint, not entrypoints themselves
#   * non-`.sh`/`.py` files such as `.nix` fixtures and `.md` documents
#   * live probes, which need a running lab or a reachable host and therefore
#     cannot execute on a CI runner. A live probe is recognised from its own
#     `# GAMP-SCOPE:` header declaring `live`, not from its file name, so the
#     exclusion is a declared property of the test and not a naming accident.
#     Live probes stay reachable through their owning HAT/SIT lane.
#
# Usage
# -----
#   source scripts/lib/discover-tests.sh
#   mapfile -t names < <(discover_tests "${repo_root}")
#
# To run an entrypoint, dispatch on its extension: `bash` for `.sh`, `python3`
# for `.py`. `discover_test_runner <path>` does that dispatch for callers.

discover_tests() {
  local repo_root="${1:-}"
  if [[ -z "${repo_root}" ]]; then
    printf 'discover_tests: repository root argument required\n' >&2
    return 64
  fi

  local test_dir="${repo_root}/tests"
  [[ -d "${test_dir}" ]] || return 0

  local name
  while IFS= read -r name; do
    if grep -qE '^#[[:space:]]*GAMP-SCOPE:.*\blive\b' "${test_dir}/${name}" 2>/dev/null; then
      continue
    fi
    printf '%s\n' "${name}"
  done < <(
    find "${test_dir}" -maxdepth 1 \( -type f -o -type l \) \
      \( \
        -name 'test-*.sh' \
        -o -name 'test_*.py' \
        -o -regextype posix-extended -regex '.*/FS-[0-9]+-HDS-[0-9]+-SDS-[0-9]+-(SMS|SIT)-[0-9a-z][a-z0-9-]*(-[a-z0-9-]+)?\.(sh|py)' \
      \) \
      ! -name 'test.sh' \
      -printf '%f\n' \
      | LC_ALL=C sort
  )
}

discover_test_runner() {
  local test_path="${1:?}"
  case "${test_path}" in
    *.py) printf 'python3\n' ;;
    *)    printf 'bash\n' ;;
  esac
}
