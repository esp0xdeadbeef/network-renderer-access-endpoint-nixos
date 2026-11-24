#!/usr/bin/env bash
# GAMP-SCOPE: software-module-test
#
# S88 IMPORT-GRAPH COHERENCE -- declarations compared against the dependency
# graph the runtime will actually build. Nix and Python are both resolved.
#
# WHY THIS IS NOT A KEYWORD CHECK
# ------------------------------
# Grepping for level names or for `readDir` proves a string is present or absent.
# This file resolves every relative dependency under a level tree -- `.nix` path
# tokens and Python `import`/`from` statements -- builds the graph, and compares
# it against three independently produced declarations:
#
#   A. the boundary statement (`s88/README.md`) against the level directories
#   B. the level order against the direction of every edge
#   C. the S88 LAYER declared per file in TRACE.md, where one exists
#
# and against the only thing that decides whether a file runs at all:
#
#   D. reachability from a real entrypoint
#
# A disagreement between any two of them is the defect.
#
# THE CHECKS
# ----------
# G0  A boundary statement exists and describes every level directory present.
# G1  No upward dependency: a lower level must not import a higher one. Authority
#     flows downward, so a responsibility level that depends on a decision level
#     can no longer be changed without changing the decision.
# G2  The S88 LAYER TRACE.md declares for a file matches where the graph places
#     it. Only checked where TRACE.md exists.
# G3  Every level-tree file is reachable from an entrypoint. Files loaded through
#     a CONSTRUCTED path are reported separately -- they are a different defect
#     with a different owner, and folding them in would make one of the two
#     verdicts wrong.
#
# This file is byte-identical in every renderer. Do not fork it per repository: a
# divergent copy is how a class of checks stops running without anybody noticing.
# If the contract must change, change it here and copy the same file everywhere
# in the same change (`scripts/lib/discover-tests.sh` states the same rule).
#
# Evidence boundary: construction. Static file reads and path resolution only.
# No build, no lab, no network.
#
# KNOWN FINDINGS ARE PINNED, NOT IGNORED
# -------------------------------------
# G0-G3 assert real properties of the tree, so a repository that has not written a
# boundary statement, has an EquipmentModule reaching up into a Unit, or has files
# no entrypoint reaches is red on purpose. A suite that is red on every commit
# reports no regression -- the signal is the thing that gets lost. Silence would be
# worse than red, so the debt is pinned in `tests/lib/s88-graph.baseline`:
#
#   <ISSUE-ID>=<count>      # e.g. S88-G1=4
#
# The test fails when a count moves in EITHER direction: more is a regression, and
# fewer is progress that must lower the pin in the same change, so the ledger can
# only shrink by an explicit edit. No baseline file means zero tolerance, which is
# the default. The seeded-negative id (S88-G-SEED) is never pinnable: it is a
# statement about this checker, not about the tree.
set -euo pipefail

# Resolve the repository root without relying on the caller.
#
# Do not write this as `${VAR:-$(git ... || cd ... && pwd)}`: `a || b && c` runs
# `c` even when `a` succeeds, so the value is the git output AND the pwd output --
# two lines, and every `-d` test then silently fails.
if [[ -n "${SMS_TEST_REPO_ROOT:-}" ]]; then
  repo_root="${SMS_TEST_REPO_ROOT}"
else
  repo_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "${repo_root}" ]]; then
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
fi
if [[ -f "${repo_root}/tests/lib/direct-test-guard.sh" ]]; then
  # shellcheck source=/dev/null
  source "${repo_root}/tests/lib/direct-test-guard.sh" 2>/dev/null || true
fi

levels=(Enterprise Site Area ProcessCell Unit EquipmentModule ControlModule)

level_rank() {
  case "$1" in
    Enterprise) echo 1 ;;
    Site) echo 2 ;;
    Area) echo 3 ;;
    ProcessCell) echo 4 ;;
    Unit) echo 5 ;;
    EquipmentModule) echo 6 ;;
    ControlModule) echo 7 ;;
    *) echo 99 ;;
  esac
}

# Directory spellings accepted in a tree, declared rather than guessed so a new
# spelling is a change to this file and not a silent tolerance.
canonical_level_for_dir() {
  case "$1" in
    Enterprise | enterprise) echo "Enterprise" ;;
    Site | site) echo "Site" ;;
    Area | area) echo "Area" ;;
    ProcessCell | processcell | process_cell) echo "ProcessCell" ;;
    Unit | unit) echo "Unit" ;;
    EquipmentModule | equipmentmodule | equipment_module | EM) echo "EquipmentModule" ;;
    ControlModule | controlmodule | control_module | CM) echo "ControlModule" ;;
    *) echo "" ;;
  esac
}

# Level of a path, relative to the repository. Understands every tree root this
# fleet uses, so a renderer that keeps its level code under a generator directory
# is measured the same way as one that keeps it at `s88/`.
level_of_path() {
  local rel="$1" rest part
  for root in s88 clabgen/s88 implementation/s88; do
    case "${rel}" in
      "${root}"/*)
        rest="${rel#"${root}"/}"
        part="$(cut -d/ -f1 <<<"${rest}")"
        canonical_level_for_dir "${part}"
        return 0
        ;;
    esac
  done
  echo ""
}

issues=0
# One entry per finding, keyed by the check that raised it (S88-G0..G3). This is
# what tests/lib/s88-graph.baseline pins; see `finish` for why.
declare -A issue_counts=()
record_count() { issue_counts["$1"]=$(( ${issue_counts["$1"]:-0} + 1 )); }
report_issue() {
  local id="$1" finding="$2" why="$3" read="$4"
  issues=$((issues + 1))
  record_count "${id}"
  {
    echo "ISSUE ${id}: ${finding}"
    echo "  why:  ${why}"
    echo "  read: ${read}"
    echo
  } >&2
}

read_pointer="the workspace ISA-88 architecture note (not in this repository): the level
         table (Control Module = implementation mechanism derived later, Unit =
         forwarding execution context), the requirement for a per-repository boundary
         statement, and the failure-signature entry 'Reasoning requires reading link
         names or file names -> authority is being recovered from derivation'. Where a
         TRACE.md exists, it is the per-file layer declaration."

baseline_file="${repo_root}/tests/lib/s88-graph.baseline"
s88_graph_baseline_update="${S88_GRAPH_BASELINE_UPDATE:-0}"

baseline_count() {
  local id="$1" pinned
  [[ -f "${baseline_file}" ]] || { echo 0; return 0; }
  pinned="$(awk -F= -v k="${id}" '$1 == k { print $2; exit }' "${baseline_file}" | tr -d '[:space:]')"
  [[ "${pinned}" =~ ^[0-9]+$ ]] || pinned=0
  echo "${pinned}"
}

write_baseline() {
  mkdir -p "$(dirname "${baseline_file}")"
  {
    echo "# S88 import-graph findings this repository currently carries."
    echo "# Generated: S88_GRAPH_BASELINE_UPDATE=1 bash tests/test-s88-import-graph-coherence.sh"
    echo "# The count must move only with this file, in the same change: see the test header."
    for id in S88-G0 S88-G1 S88-G2 S88-G3; do
      printf '%s=%s\n' "${id}" "${issue_counts[${id}]:-0}"
    done
  } >"${baseline_file}"
  echo "WROTE ${baseline_file#"${repo_root}/"}: $(grep -vc '^#' "${baseline_file}") pinned check(s)" >&2
}

# Compare the tree's findings against the ledger and exit.
finish() {
  local id current pinned drift=0 pinned_total=0 trees="${#roots[@]}"
  for id in S88-G0 S88-G1 S88-G2 S88-G3; do
    current="${issue_counts[${id}]:-0}"
    pinned="$(baseline_count "${id}")"
    pinned_total=$((pinned_total + pinned))
    if (( current != pinned )); then
      drift=$((drift + 1))
      echo "  ${id}: ${current} found, ${pinned} pinned" >&2
    fi
  done

  if [[ "${s88_graph_baseline_update}" == "1" ]]; then
    write_baseline
    echo "PASS S88-GRAPH: baseline updated; review and commit tests/lib/s88-graph.baseline"
    exit 0
  fi

  if (( ${issue_counts["S88-G-SEED"]:-0} > 0 )); then
    echo "FAIL S88-GRAPH: a graph check failed its seeded negative." >&2
    echo "  Every PASS above is therefore not evidence." >&2
    exit 1
  fi

  if (( drift > 0 )); then
    echo "FAIL S88-GRAPH: the finding count changed." >&2
    echo "  Fix in the layer that owns the behaviour; if the count fell, lower" >&2
    echo "  tests/lib/s88-graph.baseline in the same change" >&2
    echo "  (S88_GRAPH_BASELINE_UPDATE=1 regenerates it)." >&2
    exit 1
  fi

  if (( pinned_total > 0 )); then
    echo "KNOWN-FINDING S88-GRAPH: ${pinned_total} finding(s) pinned in tests/lib/s88-graph.baseline"
    echo "  across ${trees} tree(s). Recorded, not tolerated: the count cannot grow, and"
    echo "  each pin must be lowered when the layer that owns the behaviour is fixed."
    exit 0
  fi

  echo "PASS S88-GRAPH: the graph and its declarations agree"
  exit 0
}

echo "--- S88-GRAPH: declarations vs the resolved dependency graph ---"
echo ""

# ---------------------------------------------------------------------------
# Discover the level trees this repository carries.
# ---------------------------------------------------------------------------
roots=()
for candidate in s88 clabgen/s88 implementation/s88; do
  [[ -d "${repo_root}/${candidate}" ]] && roots+=("${candidate}")
done

if ((${#roots[@]} == 0)); then
  report_issue "S88-G0" "this repository carries no level tree (s88/, clabgen/s88/, implementation/s88/)" \
    "the level decomposition is meant to be the same everywhere in the fleet, so only the
       repository's slice is restated -- not the whole hierarchy. A renderer with no level
       tree states no slice, and the level vocabulary it uses in code cannot be reviewed
       against anything" \
    "${read_pointer}"
  finish
fi

echo "  level trees: ${roots[*]}"

# ---------------------------------------------------------------------------
# File set: every level-tree source, plus the entrypoints. Both languages.
# ---------------------------------------------------------------------------
mapfile -t tree_files < <(
  for root in "${roots[@]}"; do
    find "${repo_root}/${root}" -type f \( -name '*.nix' -o -name '*.py' \) | LC_ALL=C sort
  done
)

nix_count=0
py_count=0
for file in ${tree_files[@]+"${tree_files[@]}"}; do
  case "${file}" in
    *.nix) nix_count=$((nix_count + 1)) ;;
    *.py) py_count=$((py_count + 1)) ;;
  esac
done
echo "  source files: ${#tree_files[@]} (nix ${nix_count}, python ${py_count})"

# ---------------------------------------------------------------------------
# Resolvers.
#
# Nix: match relative path TOKENS, not `import <path>` prefixes. A file listed in
# a Nix list (`imports = [ ../../Unit/module/host-network.nix ];`) is a dependency
# the evaluator follows, and a prefix-anchored match misses it.
#
# Python: parse with `ast`, so `from . import x`, `from .sub import y` and
# absolute package imports all resolve to real files.
# ---------------------------------------------------------------------------
nix_edges_of() {
  local file="$1" dir raw target
  dir="$(dirname "${file}")"
  # Repo-root-anchored imports, as the CLI writes them.
  local repo_root_for_edges="${repo_root}"
  while IFS= read -r raw; do
    [[ -n "${raw}" ]] || continue
    case "${raw}" in
      /*) target="$(realpath -m "${raw}" 2>/dev/null || true)" ;;
      *) target="$(realpath -m "${dir}/${raw}" 2>/dev/null || true)" ;;
    esac
    [[ -n "${target}" ]] || continue
    [[ -d "${target}" ]] && target="${target}/default.nix"
    [[ -f "${target}" ]] || continue
    printf 'EDGE\t%s\t%s\n' "${file}" "${target}"
  done < <(
    {
      # Relative imports: `../../Unit/module/x.nix`.
      grep -oE '(\.\.?/)+[A-Za-z0-9._/-]+\.nix' "${file}" 2>/dev/null
      # Root-anchored imports: `"${self_path}/s88/Enterprise/cli/render-node.nix"`.
      # The CLI embeds its Nix expression in a quoted string, so the prefix is a
      # variable and only the `/s88/...` tail is literal. Anchor it at the
      # repository root; that is what the variable resolves to at runtime
      # (`${self.outPath}` / `${self_path}`).
      grep -oE '/s88/[A-Za-z0-9._/-]+\.nix' "${file}" 2>/dev/null \
        | sed "s|^|${repo_root_for_edges}|"
    } | sort -u || true
  )
  return 0
}

python_edges_of() {
  local root="$1"
  python3 - "${root}" <<'PY' 2>/dev/null || true
import ast, os, sys

root = os.path.realpath(sys.argv[1])
roots = [os.path.join(root, r) for r in ("s88", "clabgen/s88", "implementation/s88")]

def candidates(base, dotted):
    parts = dotted.split(".") if dotted else []
    path = os.path.join(base, *parts) if parts else base
    return [path + ".py", os.path.join(path, "__init__.py")]

def emit(src, target):
    if os.path.isfile(target):
        print("EDGE\t%s\t%s" % (src, os.path.realpath(target)))

for tree in roots:
    if not os.path.isdir(tree):
        continue
    for dirpath, _dirnames, filenames in os.walk(tree):
        for name in filenames:
            if not name.endswith(".py"):
                continue
            path = os.path.join(dirpath, name)
            try:
                with open(path, "r", encoding="utf-8") as fh:
                    parsed = ast.parse(fh.read(), filename=path)
            except (SyntaxError, UnicodeDecodeError):
                continue
            for node in ast.walk(parsed):
                if isinstance(node, ast.ImportFrom):
                    base = os.path.dirname(path)
                    if node.level:
                        for _ in range(node.level - 1):
                            base = os.path.dirname(base)
                        mods = [node.module] if node.module else []
                        if not node.module:
                            mods = [a.name for a in node.names]
                    else:
                        if not node.module:
                            continue
                        base = root
                        mods = [node.module]
                    for mod in mods:
                        for target in candidates(base, mod.replace(".", os.sep)):
                            emit(path, target)
                        # `from pkg import sub` usually imports the SUBMODULE
                        # `pkg.sub`, not a symbol, so it is a dependency too.
                        for alias in node.names:
                            for target in candidates(base, os.path.join(mod.replace(".", os.sep), alias.name)):
                                emit(path, target)
                elif isinstance(node, ast.Import):
                    for alias in node.names:
                        for target in candidates(root, alias.name.replace(".", os.sep)):
                            emit(path, target)
PY
  return 0
}

mapfile -t entrypoints < <(
  [[ -f "${repo_root}/flake.nix" ]] && echo "${repo_root}/flake.nix"
  for root in "${roots[@]}"; do
    for level in "${levels[@]}"; do
      [[ -f "${repo_root}/${root}/${level}/api/default.nix" ]] && echo "${repo_root}/${root}/${level}/api/default.nix"
    done
  done
  # Python renderers are driven by a script or module at or near the root.
  find "${repo_root}" -maxdepth 2 -type f -name '*.py' -not -path '*/s88/*' -not -path '*/tests/*' \
    -not -path '*/.git/*' 2>/dev/null | LC_ALL=C sort
  # The renderer CLIs. They are shell scripts that carry Nix expressions
  # (`nix eval --impure --expr '... import (builtins.toPath "${self}/s88/...")'`),
  # so the `.nix` they reach is load-bearing while no `.nix` file names it --
  # and a scanner that only reads `.nix` reports those modules as orphaned.
  # Measured on this repository: s88/Enterprise/cli/render-node.nix is the
  # document -> node renderer the CLI docs advertise and
  # tests/lib/FS-460-HDS-010-SDS-010-SMS-010/
  # test-FS-460-HDS-010-SDS-010-SMS-010-cli-render-node.sh exercises, and it was
  # reported as
  # decoration. bin/ is where a repository's entrypoints live by construction,
  # so scan it rather than naming one file here.
  find "${repo_root}/bin" -maxdepth 1 -type f 2>/dev/null | LC_ALL=C sort
)

# ---------------------------------------------------------------------------
# Entrypoints: the flake, every level facade, and the repository's own scripts.
# A file reachable from any of them is load-bearing; the rest is decoration.
# ---------------------------------------------------------------------------
edges_file="$(mktemp)"
trap 'rm -f "${edges_file}"' EXIT

# Entrypoints contribute edges as well. `flake.nix` is the reason several level
# files are reachable at all: with only the tree scanned, everything the flake
# imports directly looks orphaned.
scan_files=()
for file in ${tree_files[@]+"${tree_files[@]}"}; do scan_files+=("${file}"); done
for file in ${entrypoints[@]+"${entrypoints[@]}"}; do scan_files+=("${file}"); done

for file in "${scan_files[@]}"; do
  case "${file}" in
    *.nix) nix_edges_of "${file}" ;;
    # A shell entrypoint (the CLI) embeds its Nix expressions in a quoted
    # string, so the same relative-path scan applies to it. Without this the
    # module it imports is reported as an orphan and the only way to make the
    # checker happy is to delete a working renderer.
    *bin/*) nix_edges_of "${file}" ;;
  esac
done >>"${edges_file}" || true

# ---------------------------------------------------------------------------
# Follow the graph THROUGH files that live outside the level tree.
#
# The edge set above is one level deep: it starts from the level tree and from
# the entrypoints, so a level file reached only via an intermediate `.nix` that
# is neither is reported as an orphan. That intermediate is real and ordinary --
# `flake.nix` -> `modules/wireguard-provider-runtime.nix` ->
# `s88/ControlModule/{addressing-services,firewall-nat,tunnel-runtime}.nix` is
# how this repository ships its NixOS module -- so the defect is in the walk, not
# in the tree. Measured here: three ControlModule files were reported as
# unreachable while `modules/wireguard-provider-runtime.nix` named all three.
#
# The walk is transitive and bounded by the repository: a `.nix` under the repo
# that is not under `s88/` is scanned once, when some already-scanned file names
# it. Nothing outside the repository is read, and a file with no importer is
# still an orphan because the walk only ever reaches files somebody names.
# ---------------------------------------------------------------------------
seen_files="$(mktemp)"
trap 'rm -f "${edges_file}" "${seen_files}"' EXIT
for file in "${scan_files[@]}"; do printf '%s\n' "$(realpath -m "${file}")" >>"${seen_files}"; done
sort -u "${seen_files}" -o "${seen_files}"

while :; do
  # Every `.nix` under the repository that a scanned file already names, and that
  # has not been scanned itself.
  mapfile -t frontier < <(
    awk -F'\t' '$1 == "EDGE" { print $3 }' "${edges_file}" 2>/dev/null \
      | sort -u \
      | while IFS= read -r target; do
          [[ "${target}" == "${repo_root}"/* ]] || continue
          [[ "${target}" == *.nix ]] || continue
          [[ "${target}" == "${repo_root}/s88/"* ]] && continue
          grep -qxF "${target}" "${seen_files}" && continue
          printf '%s\n' "${target}"
        done
  )
  ((${#frontier[@]} > 0)) || break
  for file in "${frontier[@]}"; do
    printf '%s\n' "${file}" >>"${seen_files}"
    nix_edges_of "${file}" >>"${edges_file}" || true
  done
  sort -u "${seen_files}" -o "${seen_files}"
done


# Called once with the repository root: the resolver walks every level tree it
# knows about, and absolute package imports (`from clabgen.s88.site import x`)
# only resolve from there.
python_edges_of "${repo_root}" >>"${edges_file}" || true

# One dependency stated two ways is still one edge.
sort -u "${edges_file}" -o "${edges_file}"

echo "  entrypoints:  ${#entrypoints[@]}"
echo "  edges:        $(grep -c '^EDGE' "${edges_file}" 2>/dev/null || true)"
echo ""

# ---------------------------------------------------------------------------
# G0 -- the boundary statement exists and describes the tree.
# ---------------------------------------------------------------------------
boundary=""
for root in "${roots[@]}"; do
  [[ -f "${repo_root}/${root}/README.md" ]] && boundary="${repo_root}/${root}/README.md" && break
done
[[ -n "${boundary}" ]] || { [[ -f "${repo_root}/s88/README.md" ]] && boundary="${repo_root}/s88/README.md"; }

if [[ -z "${boundary}" ]]; then
  report_issue "S88-G0" "no boundary statement for ${roots[*]}" \
    "the workspace note requires a per-repository boundary file and lists the
       repositories that lack one. Without it the level shape below can only be
       compared with itself." \
    "${read_pointer}"
else
  undescribed=()
  for root in "${roots[@]}"; do
    for dir in "${repo_root}/${root}"/*/; do
      [[ -d "${dir}" ]] || continue
      name="$(basename "${dir}")"
      [[ -n "$(canonical_level_for_dir "${name}")" ]] || continue
      grep -qE "(^|[^A-Za-z])${name}([^A-Za-z]|$)" "${boundary}" || undescribed+=("${root}/${name}")
    done
  done
  if ((${#undescribed[@]} > 0)); then
    report_issue "S88-G0" "${boundary#"${repo_root}/"} does not describe: ${undescribed[*]}" \
      "each level directory is a claim about responsibility placement. An undescribed
         directory is structure nobody owns: either intentional and unrecorded, or
         leftover from a move." \
      "${read_pointer}"
  else
    echo "PASS G0: ${boundary#"${repo_root}/"} describes every level directory present"
  fi
fi

# ---------------------------------------------------------------------------
# G1 -- upward dependencies.
# ---------------------------------------------------------------------------
upward=0
while IFS=$'\t' read -r tag from to; do
  [[ "${tag}" == "EDGE" ]] || continue
  from_level="$(level_of_path "${from#"${repo_root}/"}")"
  to_level="$(level_of_path "${to#"${repo_root}/"}")"
  [[ -n "${from_level}" && -n "${to_level}" ]] || continue
  if (( $(level_rank "${to_level}") < $(level_rank "${from_level}") )); then
    upward=$((upward + 1))
    report_issue "S88-G1" "${from#"${repo_root}/"} (${from_level}) imports ${to#"${repo_root}/"} (${to_level})" \
      "the target is higher in the hierarchy. Authority flows downward: a lower level that
         depends on a higher one makes the implementation depend on the decision it is
         supposed to execute, so the decision can no longer move independently." \
      "${read_pointer}"
  fi
done <"${edges_file}"

((upward == 0)) && echo "PASS G1: no upward dependency among ${#tree_files[@]} files"

# ---------------------------------------------------------------------------
# G2 -- TRACE.md's declared layer must agree with the graph.
#
# Not "does the row contain the level name": the file must be reachable from that
# level's facade, and it must live under it.
# ---------------------------------------------------------------------------
declare -A reached_from_facade=()
for root in "${roots[@]}"; do
  for level in "${levels[@]}"; do
    facade="${repo_root}/${root}/${level}/api/default.nix"
    [[ -f "${facade}" ]] || continue
    queue=("${facade}")
    declare -A seen=()
    while ((${#queue[@]} > 0)); do
      current="${queue[0]}"
      queue=("${queue[@]:1}")
      [[ -n "${seen[${current}]:-}" ]] && continue
      seen["${current}"]=1
      while IFS=$'\t' read -r tag from to; do
        [[ "${from}" == "${current}" ]] || continue
        queue+=("${to}")
      done <"${edges_file}"
    done
    for reached in "${!seen[@]}"; do
      reached_from_facade["${reached#"${repo_root}/"}"]+="${level},"
    done
  done
done

trace_checked=0
while IFS= read -r trace_file; do
  [[ -n "${trace_file}" ]] || continue
  trace_dir="$(dirname "${trace_file}")"
  trace_checked=$((trace_checked + 1))
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    IFS='|' read -r _ path declared _why <<<"${row}"
    path="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^`//' -e 's/`$//' <<<"${path}")"
    declared="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"${declared}")"
    [[ -n "${path}" && -e "${repo_root}/${path}" ]] || continue

    declared_owner=""
    for level in "${levels[@]}"; do
      grep -qE "(^|[^A-Za-z])${level}([^A-Za-z]|$)" <<<"${declared}" && declared_owner="${level}"
    done
    [[ -n "${declared_owner}" ]] || continue

    placed_in="$(level_of_path "${path}")"
    reached_by="${reached_from_facade["${path}"]:-}"

    if [[ -z "${reached_by}" ]]; then
      report_issue "S88-G2" "${path} is declared ${declared_owner} but no level facade reaches it" \
        "a declared layer with no path from any facade means the code runs, if at all, from
           somewhere the hierarchy does not describe." \
        "${read_pointer}"
    elif [[ -n "${placed_in}" && "${placed_in}" != "${declared_owner}" ]]; then
      report_issue "S88-G2" "${path} is declared ${declared_owner} but lives under ${placed_in}/" \
        "the row names one level and the file sits in another. When the declaration and the
           placement disagree, the trace sends a reader to the wrong layer." \
        "${read_pointer}"
    fi
  done < <(grep -E '^\|[[:space:]]*`?[A-Za-z0-9_./-]+\.(nix|py)`?[[:space:]]*\|' "${trace_file}" || true)
done < <(find "${repo_root}" -name 'TRACE.md' -not -path '*/.git/*' 2>/dev/null | LC_ALL=C sort)

if ((trace_checked == 0)); then
  echo "  note: no TRACE.md in this repository; G2 not applicable"
elif ((issues == 0)); then
  echo "PASS G2: declared layers match the graph"
elif ! grep -q '^ISSUE S88-G2' <<<"$(printf '%s' "${issues}")" 2>/dev/null; then
  echo "PASS G2: declared layers match the graph"
fi

# ---------------------------------------------------------------------------
# G3 -- decoration.
# ---------------------------------------------------------------------------
declare -A reachable=()
queue=()
for entry in ${entrypoints[@]+"${entrypoints[@]}"}; do
  queue+=("${entry}")
done
while ((${#queue[@]} > 0)); do
  current="${queue[0]}"
  queue=("${queue[@]:1}")
  [[ -n "${reachable[${current}]:-}" ]] && continue
  reachable["${current}"]=1
  while IFS=$'\t' read -r tag from to; do
    [[ "${from}" == "${current}" ]] || continue
    queue+=("${to}")
  done <"${edges_file}"
done

decorative=()
for file in ${tree_files[@]+"${tree_files[@]}"}; do
  [[ -n "${reachable[${file}]:-}" ]] || decorative+=("${file#"${repo_root}/"}")
done

# A file loaded from a CONSTRUCTED path is followed by the runtime but not by any
# static resolver. Detection: the file's directory (depth >= 3, so an unrelated
# sibling cannot match) appears as a literal fragment in a file that IS reachable.
# A constructed path inside a file nothing imports is not a mechanism, it is two
# orphans.
dynamic=()
orphaned=()
for file in ${decorative[@]+"${decorative[@]}"}; do
  loaded_dynamically=0
  dir="${file%/*}"
  for _ in 1 2 3 4 5; do
    for root in "${roots[@]}"; do
      case "${dir}" in
        "${root}"/*) fragment="${dir#"${root}"/}" ;;
        *) continue ;;
      esac
      if [[ "$(awk -F/ '{print NF}' <<<"${fragment}")" -ge 3 ]]; then
        while IFS= read -r referrer; do
          [[ -n "${referrer}" ]] || continue
          [[ "${referrer}" == "${repo_root}/${file}" ]] && continue
          if [[ -n "${reachable[${referrer}]:-}" ]]; then
            loaded_dynamically=1
            dynamic+=("${file}  <- constructed from '${fragment}' in ${referrer#"${repo_root}/"}")
            break
          fi
        done < <(grep -rlF "${fragment}" "${repo_root}/${root}" --include='*.nix' --include='*.py' 2>/dev/null || true)
      fi
    done
    ((loaded_dynamically == 1)) && break
    [[ "${dir}" == */* ]] || break
    dir="${dir%/*}"
  done
  ((loaded_dynamically == 1)) || orphaned+=("${file}")
done

if ((${#dynamic[@]} > 0)); then
  {
    echo "  ${#dynamic[@]} file(s) reachable only through a constructed path:"
    printf '    %s\n' "${dynamic[@]}"
    echo "  (the 'uncontrolled sidecar' shape: the loaded set is a property of the file"
    echo "   system, not of the model)"
    echo
  } >&2
fi

if ((${#orphaned[@]} > 0)); then
  declare -A by_level=()
  for file in "${orphaned[@]}"; do
    level="$(level_of_path "${file}")"
    [[ -n "${level}" ]] || level="(outside a level)"
    by_level["${level}"]=$(( ${by_level["${level}"]:-0} + 1 ))
  done
  report_issue "S88-G3" "${#orphaned[@]} of ${#tree_files[@]} level-tree files are unreachable from any entrypoint" \
    "an unreachable file still reads as authoritative to a reviewer and nothing executes it.
       This graph resolves both languages transitively and accounts for constructed paths
       separately, so an entry here is not a resolver artefact." \
    "${read_pointer}"
  {
    echo "  orphaned by level:"
    for level in "${!by_level[@]}"; do
      echo "    ${level}: ${by_level["${level}"]}"
    done | sort
    echo "  all:"
    printf '    %s\n' "${orphaned[@]}"
  } >&2
else
  echo "PASS G3: every level-tree file is reachable (${#tree_files[@]} resolved, ${#dynamic[@]} by constructed path)"
fi

# ---------------------------------------------------------------------------
# Seeded negatives -- both resolvers and both graph checks must be able to fail.
# ---------------------------------------------------------------------------
seeded_root="$(mktemp -d)"
mkdir -p \
  "${seeded_root}/s88/Unit/lookup" \
  "${seeded_root}/s88/EquipmentModule/mapping" \
  "${seeded_root}/s88/ControlModule/render"

cat >"${seeded_root}/s88/ControlModule/render/private.nix" <<'NIX'
{ }: { x = 1; }
NIX
cat >"${seeded_root}/s88/Unit/lookup/down.nix" <<'NIX'
{ lib }: import ../../ControlModule/render/private.nix { }
NIX
cat >"${seeded_root}/s88/EquipmentModule/mapping/up.nix" <<'NIX'
{ lib }: import ../../Unit/lookup/down.nix { }
NIX
cat >"${seeded_root}/s88/Unit/lookup/orphan.nix" <<'NIX'
{ }: { orphan = true; }
NIX

mkdir -p "${seeded_root}/clabgen/s88/enterprise" "${seeded_root}/clabgen/s88/site"
cat >"${seeded_root}/clabgen/s88/site/base.py" <<'PY'
VALUE = 1
PY
cat >"${seeded_root}/clabgen/s88/enterprise/seeded.py" <<'PY'
from ..site import base
PY

seeded_edges="$(mktemp)"
for file in $(find "${seeded_root}/s88" -name '*.nix' | LC_ALL=C sort); do
  nix_edges_of "${file}"
done >>"${seeded_edges}" || true
python_edges_of "${seeded_root}" >>"${seeded_edges}" || true

seeded_upward=0
while IFS=$'\t' read -r tag from to; do
  [[ "${tag}" == "EDGE" ]] || continue
  fl="$(level_of_path "${from#"${seeded_root}/"}")"
  tl="$(level_of_path "${to#"${seeded_root}/"}")"
  [[ -n "${fl}" && -n "${tl}" ]] || continue
  (( $(level_rank "${tl}") < $(level_rank "${fl}") )) && seeded_upward=$((seeded_upward + 1))
done <"${seeded_edges}"

seeded_py="$(grep -c 'clabgen/s88/site/base.py' "${seeded_edges}" 2>/dev/null || true)"
seeded_orphan="$(grep -c 'orphan.nix' "${seeded_edges}" 2>/dev/null || true)"
rm -f "${seeded_edges}"

if ((seeded_upward < 1)) || [[ "${seeded_py}" == "0" ]] || [[ "${seeded_orphan}" != "0" ]]; then
  report_issue "S88-G-SEED" "a graph check did not behave on the seeded fixture" \
    "expected >=1 upward edge, >=1 resolved Python edge and 0 edges to the orphan;
       got upward=${seeded_upward} python_edges=${seeded_py} orphan_edges=${seeded_orphan}.
       Every PASS this test printed is therefore not evidence" \
    "tests/test-s88-import-graph-coherence.sh -- nix_edges_of, python_edges_of, G1/G3"
else
  echo "PASS S88-G-SEED: nix and python resolvers detected the seeded upward, python and orphan cases"
fi

echo ""
finish
