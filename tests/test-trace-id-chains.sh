#!/usr/bin/env bash
# GAMP-SCOPE: documentation hygiene; trace-chain IDs are full chains
#
# A TRACE-CHAIN ID IS A GREP TARGET, OR IT IS NOTHING.
#
# The rule, from the GAMP methodology note on trace-chain IDs: "Use full
# trace-chain IDs everywhere", and "Shorthand such as `SMS-060`, `FS-310-SMS-060`,
# or `FS-310 SMS-060` is not a trace-chain ID." An item may start at the highest
# layer that owns it -- `FS-040-HDS-010-SDS-010` is a full chain -- but a chain may
# not skip a layer that exists, and it may not be abbreviated.
#
# Three ways this breaks, all of them damaging for the same reason: a reader or a
# gate cannot resolve the ID to a row.
#
#   SHORTHAND   `FS-350-SMS-050` -- two layers missing. Whatever row it meant, no
#               search finds it, and the next reader has to guess.
#   PARTIAL     `FS-350-HDS-010-SMS-050` -- the SDS layer is missing.
#   WRAPPED     a full ID split across two lines ("...FS-880-HDS-010-SDS-" /
#               "010"). Equally unresolvable, and it happens by accident in a
#               comment, which is why it needs a check rather than care.
#
# Why it matters beyond tidiness: the trace chain is the only mechanism that ties a
# test to a specification. An ID that cannot be resolved breaks that tie silently,
# and the suite keeps passing with a citation that points nowhere.
#
# WHAT IT CHECKS
# --------------
#   T1  no chain skips a layer (`FS-<n>-SMS-<n>`, `FS-<n>-HDS-<n>-SMS-<n>`)
#   T2  no bare layer reference (`HDS-<n>`, `SDS-<n>`, `SMS-<n>`) outside a chain
#   T3  no chain broken across a line
#
# Full chains are masked before the bare-reference check, so `SMS-010` inside
# `FS-310-HDS-010-SDS-010-SMS-010` is not a hit. This file is exempt from its own
# scan because it has to contain the patterns it forbids.
#
# STATUS: expected RED. Measured on the current trees, every repository that cites
# the chain carries some: the fix is a mechanical edit plus the discipline to stop
# writing shorthand, and this file is the discipline.
#
# Evidence boundary: construction. Text scan only.
set -euo pipefail

if [[ -n "${SMS_TEST_REPO_ROOT:-}" ]]; then
  repo_root="${SMS_TEST_REPO_ROOT}"
else
  repo_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -z "${repo_root}" ]] && repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

self_path="$(readlink -f "${BASH_SOURCE[0]}")"

echo "--- TRACE-ID-CHAINS: every cited ID is a full chain on one line ---"
echo ""

scan_root="${TRACE_ID_SCAN_ROOT:-${repo_root}}"
mapfile -t files < <(
  find "${scan_root}" -type f \
    \( -name '*.nix' -o -name '*.md' -o -name '*.sh' -o -name '*.ts' -o -name '*.py' -o -name '*.yml' \) \
    -not -path '*/.git/*' 2>/dev/null | LC_ALL=C sort
)

if ((${#files[@]} == 0)); then
  echo "FAIL TRACE-ID-CHAINS: no source or documentation files under ${scan_root}" >&2
  echo "  the scan root is the repository; an empty one means the check did not run" >&2
  exit 1
fi

echo "  files scanned: ${#files[@]}"

report="$(mktemp)"
trap 'rm -f "${report}"' EXIT

scan_files() {
  local root="$1"
  shift
  python3 - "$root" "$@" <<'PY'
import re, sys

root = sys.argv[1]
files = sys.argv[2:]

FULL = re.compile(r'FS-\d+-HDS-\d+-SDS-\d+(-SMS-\d+)?')
PARTIAL = re.compile(r'FS-\d+-HDS-\d+-SMS-\d+')
SHORT = re.compile(r'FS-\d+-SMS-\d+')
BARE = re.compile(r'(?<![A-Za-z0-9-])(HDS|SDS|SMS)-\d+')
# A layer token followed by a separator, at end of line: the ID continues.
WRAP = re.compile(r'(?:FS-\d+-|HDS-\d+-|SDS-\d+-|FS-|HDS-|SDS-)\s*$')

def rel(path):
    return path[len(root) + 1:] if path.startswith(root + "/") else path

for path in files:
    try:
        text = open(path, encoding="utf-8", errors="ignore").read()
    except OSError:
        continue
    for lineno, line in enumerate(text.splitlines(), 1):
        masked = FULL.sub(lambda m: "X" * len(m.group(0)), line)
        for match in PARTIAL.finditer(masked):
            print("PARTIAL\t%s:%d\t%s" % (rel(path), lineno, match.group(0)))
        for match in SHORT.finditer(masked):
            print("SHORTHAND\t%s:%d\t%s" % (rel(path), lineno, match.group(0)))
        for match in BARE.finditer(masked):
            print("BARE\t%s:%d\t%s" % (rel(path), lineno, match.group(0)))
        if WRAP.search(line):
            print("WRAPPED\t%s:%d\t%s" % (rel(path), lineno, line.strip()[:80]))
PY
}

# Exempt this file: it contains the forbidden forms as patterns.
filtered=()
for file in "${files[@]}"; do
  [[ "$(readlink -f "${file}")" == "${self_path}" ]] && continue
  filtered+=("${file}")
done

if ((${#filtered[@]} == 0)); then
  echo "FAIL TRACE-ID-CHAINS: only this test was found; nothing to check" >&2
  exit 1
fi

scan_files "${scan_root}" "${filtered[@]}" >"${report}" || true

issues=0
report_issue() {
  local id="$1" finding="$2" why="$3" read="$4"
  issues=$((issues + 1))
  {
    echo "ISSUE ${id}: ${finding}"
    echo "  why:  ${why}"
    echo "  read: ${read}"
  } >&2
}

read_pointer="the GAMP methodology note on trace-chain IDs: 'Use full trace-chain IDs
         everywhere', and 'Shorthand such as SMS-060, FS-310-SMS-060, or FS-310 SMS-060 is
         not a trace-chain ID.' An item may start at the highest layer that owns it."

summarise() {
  local kind="$1" label="$2" why="$3"
  mapfile -t hits < <(awk -F'\t' -v k="${kind}" '$1 == k { print $2 "\t" $3 }' "${report}")
  ((${#hits[@]} > 0)) || return 1

  declare -A per_file=()
  for hit in "${hits[@]}"; do
    file="${hit%%$'\t'*}"
    per_file["${file}"]=$(( ${per_file["${file}"]:-0} + 1 ))
  done

  report_issue "${kind}" "${#hits[@]} ${label} in ${#per_file[@]} file(s)
$(for f in "${!per_file[@]}"; do printf '      %s (%s)\n' "${f}" "${per_file["${f}"]}"; done | sort | head -12)
$(printf '    first hits:\n'; printf '      %s\n' "${hits[@]:0:8}" | tr '\t' ':')" \
    "${why}" \
    "${read_pointer}"
  return 0
}

summarise "SHORTHAND" "shorthand chain(s) (FS-<n>-SMS-<n>)" \
  "the chain skips the HDS and SDS layers, so it resolves to no row. Whatever row was
     meant, a search for it finds nothing, and the test's citation points at nothing." ||
  echo "PASS T1a: no FS-<n>-SMS-<n> shorthand"

summarise "PARTIAL" "chain(s) that skip the SDS layer (FS-<n>-HDS-<n>-SMS-<n>)" \
  "the SDS layer exists and is the layer that owns the interface contract. A chain that
     omits it names a module test with no design above it." ||
  echo "PASS T1b: no chain skips the SDS layer"

summarise "WRAPPED" "trace-chain ID(s) broken across a line" \
  "a wrapped ID cannot be grepped, and it is how a full ID silently becomes two
     fragments that each look like shorthand." ||
  echo "PASS T3: no trace-chain ID is broken across a line"

summarise "BARE" "bare layer reference(s) (HDS-<n>, SDS-<n>, SMS-<n>)" \
  "a layer token alone is not an ID. It is readable prose only for a reader who
     already knows which chain is meant, and it is unresolvable for everyone else." ||
  echo "PASS T2: no bare layer reference outside a chain"

# ---------------------------------------------------------------------------
# Seeded negatives -- each of the three shapes must be detected, and a full chain
# must not be.
# ---------------------------------------------------------------------------
seeded_root="$(mktemp -d)"
trap 'rm -f "${report}"' EXIT
mkdir -p "${seeded_root}/s88"

cat >"${seeded_root}/s88/seeded.nix" <<'NIX'
# shorthand: the HDS and SDS layers are missing
# owner: FS-350-SMS-050
# partial: the SDS layer is missing
# owner: FS-350-HDS-010-SMS-050
# wrapped: this one continues on the next line, FS-880-HDS-010-SDS-
# 010-SMS-050
# fine: a full chain
# owner: FS-350-HDS-010-SDS-010-SMS-050
# fine: a bare FS row is a full chain at its layer
# owner: FS-040
NIX

mapfile -t seeded_files < <(find "${seeded_root}" -name '*.nix' | LC_ALL=C sort)
seeded_report="$(scan_files "${seeded_root}" "${seeded_files[@]}")"

seeded_ok=1
for kind in SHORTHAND PARTIAL WRAPPED; do
  grep -q "^${kind}"$'\t' <<<"${seeded_report}" || seeded_ok=0
done
# T2 must NOT fire on the full chain, and the bare FS row must not be read as a
# bare layer reference.
if grep -q "^BARE"$'\t' <<<"${seeded_report}"; then
  seeded_ok=0
fi
# exactly one SHORTHAND, one PARTIAL, one WRAPPED
sh_count="$(grep -c "^SHORTHAND"$'\t' <<<"${seeded_report}" || true)"
pt_count="$(grep -c "^PARTIAL"$'\t' <<<"${seeded_report}" || true)"
wr_count="$(grep -c "^WRAPPED"$'\t' <<<"${seeded_report}" || true)"
if [[ "${sh_count}" != "1" ]] || [[ "${pt_count}" != "1" ]] || [[ "${wr_count}" != "1" ]]; then
  seeded_ok=0
fi

if ((seeded_ok == 0)); then
  issues=$((issues + 1))
  {
    echo "ISSUE SEED: the scanner did not classify the seeded file as expected"
    echo "  expected exactly one SHORTHAND, one PARTIAL, one WRAPPED, and no BARE."
    echo "  got: SHORTHAND=${sh_count} PARTIAL=${pt_count} WRAPPED=${wr_count}"
    echo "       $(grep -c '^BARE' <<<"${seeded_report}" || echo 0) BARE"
    echo "  every PASS above is therefore not evidence"
  } >&2
else
  echo "PASS SEED: detected shorthand, partial and wrapped; left full chains alone"
fi

echo ""
if ((issues > 0)); then
  echo "FAIL TRACE-ID-CHAINS: ${issues} issue(s)." >&2
  echo "  Rewrite each citation as its full chain, on one line." >&2
  echo "  If the row genuinely starts at FS, cite FS-<n>-HDS-<n>-SDS-<n>." >&2
  exit 1
fi

echo "PASS TRACE-ID-CHAINS: every cited ID is a full chain on one line"
exit 0
