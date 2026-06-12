#!/usr/bin/env bash
# seed.sh — Seed CPM JSON test fixtures for the access-endpoint renderer.
#
# Usage:
#   scripts/seed.sh [--intent INTENT_PATH] [--inventory INVENTORY_PATH] [--name FIXTURE_NAME]
#
#   scripts/seed.sh --all   Seed all known examples from network-labs
#
# Default intent/inventory paths:
#   if --all: iterate network-labs/examples/* for intent.nix + inventory-nixos.nix
#   if --intent + --inventory: seed exactly one fixture
#
# Output:
#   tests/fixtures/<name>/output-control-plane-model.json
#
# Idempotent: if a fixture already exists, skip (unless --force).

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures_dir="${repo_root}/tests/fixtures"

usage() {
  cat >&2 <<'EOF'
usage: scripts/seed.sh [OPTIONS]

Options:
  --intent PATH       Path to intent.nix
  --inventory PATH    Path to inventory-nixos.nix
  --name NAME         Fixture directory name (default: derived from intent basename dir)
  --all               Seed all examples from network-labs
  --force             Overwrite existing fixtures
  -h, --help          Show this help

Examples:
  scripts/seed.sh --intent ./intent.nix --inventory ./inventory-nixos.nix --name single-wan
  scripts/seed.sh --all
  scripts/seed.sh --all --force
EOF
}

resolve_flake_input_path() {
  local input_name="$1"
  local archive_json
  archive_json="$(mktemp)"
  trap 'rm -f "$archive_json"' RETURN

  nix flake archive --json "path:${repo_root}" >"${archive_json}"

  INPUT_NAME="${input_name}" ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      name = builtins.getEnv "INPUT_NAME";
      input = archived.inputs.${name} or null;
      p = if input == null then null else input.path or null;
    in
      if p == null then
        throw "seed.sh: missing flake input path for " + name
      else
        p
  '
}

force=false
all=false
intent_path=""
inventory_path=""
fixture_name=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --intent) intent_path="$2"; shift 2 ;;
    --inventory) inventory_path="$2"; shift 2 ;;
    --name) fixture_name="$2"; shift 2 ;;
    --all) all=true; shift ;;
    --force) force=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "seed.sh: unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

# Resolve CPM path from flake inputs
cpm_path="$(resolve_flake_input_path network-control-plane-model)"
labs_path="$(resolve_flake_input_path network-labs)"

seed_one() {
  local intent="$1"
  local inventory="$2"
  local name="$3"

  local out_dir="${fixtures_dir}/${name}"
  local cpm_json="${out_dir}/output-control-plane-model.json"

  if [[ -f "${cpm_json}" ]] && [[ "${force}" != "true" ]]; then
    echo "seed.sh: fixture '${name}' already exists, skipping (use --force to overwrite)"
    return 0
  fi

  mkdir -p "${out_dir}"

  echo "seed.sh: building CPM for '${name}'..."
  echo "  intent:    ${intent}"
  echo "  inventory: ${inventory}"

  # Run the full pipeline through CPM
  nix run --show-trace "${cpm_path}#compile-and-build-control-plane-model" -- \
    "${intent}" "${inventory}" "${cpm_json}"

  if [[ ! -f "${cpm_json}" ]]; then
    echo "seed.sh: ERROR: CPM did not produce ${cpm_json}" >&2
    return 1
  fi

  echo "seed.sh: fixture '${name}' seeded:"
  echo "  ${cpm_json}"
}

if [[ "${all}" == "true" ]]; then
  examples_root="${labs_path}/examples"
  if [[ ! -d "${examples_root}" ]]; then
    echo "seed.sh: ERROR: examples root not found: ${examples_root}" >&2
    exit 1
  fi

  count=0
  for example_dir in "${examples_root}"/*; do
    [[ -d "${example_dir}" ]] || continue
    name="$(basename "${example_dir}")"
    intent="${example_dir}/intent.nix"
    inventory="${example_dir}/inventory-nixos.nix"

    if [[ ! -f "${intent}" ]]; then
      echo "seed.sh: SKIP ${name}: missing intent.nix"
      continue
    fi
    if [[ ! -f "${inventory}" ]]; then
      echo "seed.sh: SKIP ${name}: missing inventory-nixos.nix"
      continue
    fi

    seed_one "${intent}" "${inventory}" "${name}"
    count=$((count + 1))
  done
  echo "seed.sh: seeded ${count} fixtures"
elif [[ -n "${intent_path}" ]] && [[ -n "${inventory_path}" ]]; then
  if [[ -z "${fixture_name}" ]]; then
    fixture_name="$(basename "$(dirname "${intent_path}")")"
  fi
  seed_one "${intent_path}" "${inventory_path}" "${fixture_name}"
else
  echo "seed.sh: ERROR: must provide --all or both --intent and --inventory" >&2
  usage
  exit 2
fi
