#!/usr/bin/env bash
# GAMP-SCOPE: repository hygiene; no private-repository names in public trees
#
# A private repository's name must not appear in any public repository, in code,
# tests, generated rows, or spec files. The name is assembled at runtime so this
# guard never contains the literal it forbids.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
workspace_root="${NETWORK_WORKSPACE_ROOT:-$(cd "${repo_root}/.." && pwd)}"

# Every private repository name, assembled at runtime so this guard never
# contains the literal it forbids. `network-codex-agent` was the first; the site
# acceptance harness is private too and was missing, which is how a public GAMP
# document came to cite it by name (measured 2026-11-21).
private_name() {
  local head="$1" tail="$2"
  printf '%s-%s' "${head}" "${tail}"
}

private_names=(
  "$(private_name network codex-agent)"
  "$(private_name network site-esp)"
)
private_name_primary="${private_names[0]}"

self_path="$(readlink -f "${BASH_SOURCE[0]}")"

fail() {
  echo "FAIL no-private-mirror-reference: $*" >&2
  exit 1
}

# Public checkouts: this repository plus every sibling that is not the private
# mirror itself.
mapfile -t repositories < <(
  printf '%s\n' "${repo_root}"
  for candidate in "${workspace_root}"/network-*/; do
    candidate="${candidate%/}"
    [[ -d "${candidate}/.git" ]] || continue
    skip=0
    for private in "${private_names[@]}"; do
      [[ "$(basename "${candidate}")" == "${private}" ]] && skip=1
    done
    ((skip == 1)) && continue
    printf '%s\n' "${candidate}"
  done | LC_ALL=C sort -u
)

violations=0
for repository in "${repositories[@]}"; do
  mapfile -t hits < <(
    for private in "${private_names[@]}"; do
      rg -n --hidden --no-messages --glob '!**/.git/**' --glob '!*.lock' \
        --fixed-strings "${private}" "${repository}" \
        | grep -v -F "${self_path}:" \
        | grep -v -F "/tests/test-no-private-mirror-reference.sh:" || true
    done
  )
  if ((${#hits[@]} > 0)); then
    for hit in "${hits[@]}"; do
      location="${hit%%:*}"
      echo "PRIVATE_REFERENCE: ${location#"${workspace_root}/"} (line $(echo "${hit}" | cut -d: -f2))" >&2
    done
    violations=$((violations + ${#hits[@]}))
  fi

  # A public tree must not carry a GitHub token or a workflow secret that
  # fetches a private repository.
  mapfile -t token_hits < <(
    rg -n --hidden --no-messages --glob '!**/.git/**' \
      'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|ghs_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}' \
      "${repository}" || true
  )
  if ((${#token_hits[@]} > 0)); then
    for hit in "${token_hits[@]}"; do
      location="${hit%%:*}"
      echo "TOKEN_LITERAL: ${location#"${workspace_root}/"} (line $(echo "${hit}" | cut -d: -f2))" >&2
    done
    violations=$((violations + ${#token_hits[@]}))
  fi
done

((violations == 0)) || fail "${violations} private-name or token reference(s) in public trees"

echo "PASS no-private-mirror-reference: no private repository name or token in ${#repositories[@]} public tree(s)"
