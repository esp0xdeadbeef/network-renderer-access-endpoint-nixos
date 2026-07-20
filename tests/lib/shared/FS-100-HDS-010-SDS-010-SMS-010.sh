#!/usr/bin/env bash
# GAMP-ID: FS-100-HDS-010-SDS-010-SMS-010
# GAMP-ID: FS-100-HDS-010-SDS-010-SMS-040
# GAMP-ID: FS-100-HDS-010-SDS-010-SMS-050
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

provenance_json="${tmp_dir}/provenance.json"

REPO_ROOT="${repo_root}" nix eval \
  --extra-experimental-features 'nix-command flakes' \
  --impure --json --expr '
    let
      flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
      renderer = flake.libBySystem.${builtins.currentSystem}.renderer;
      cpmOutput = {
        version = 1;
        meta = {
          sourceClasses = {
            userIntent = {
              path = "examples/fs100/intent.nix";
              narHash = "sha256-intent";
            };
            publicInventory = {
              path = "examples/fs100/inventory-nixos.nix";
              narHash = "sha256-public-inventory";
            };
            protectedInventory = {
              ref = "sops://examples/fs100/protected.yaml";
              secretValue = "PLAINTEXT-PROTECTED-VALUE";
            };
            runtimeFacts = {
              ref = "runtime://provider/public-addresses";
            };
            validationContext = {
              profile = "renderer-construction";
            };
          };
          requested = {
            scope = {
              site = "access-endpoint";
              host = "s-router-test-clients";
            };
            target = {
              renderer = "access-endpoint-nixos";
              role = "renderer-output";
            };
          };
          locks = {
            network-control-plane-model = {
              rev = "1111222233334444555566667777888899990000";
              narHash = "sha256-cpm";
            };
          };
          controlledBaseline = "fs100-renderer-output-provenance";
        };
        endpointAssignment = {
          endpoint-a = {
            name = "endpoint-a";
            bridge = "br-client";
            mode = "static";
            static = {
              address = "10.20.20.10";
              prefixLength = 24;
              gateway4 = "10.20.20.1";
              address6 = "fd42:dead:beef:20::10";
              prefixLength6 = 64;
              gateway6 = "fd42:dead:beef:20::1";
            };
          };
        };
      };
      module = renderer.hostModule {
        cpm = cpmOutput;
        mode = "test";
      };
      renderedModule = module { config = {}; };
    in
      builtins.fromJSON renderedModule.environment.etc."network-renderer-access-endpoint/provenance.json".text
  ' >"${provenance_json}"

if grep -Fq "PLAINTEXT-PROTECTED-VALUE" "${provenance_json}"; then
  echo "FAIL fs100-access-endpoint-renderer-output-provenance: protected plaintext leaked" >&2
  exit 1
fi

jq -e '
  .renderer.name == "network-renderer-access-endpoint-nixos" and
  .renderer.schemaVersion == 1 and
  (.renderer.gitRev | type == "string") and
  .input.kind == "control-plane-model" and
  .input.controlPlaneModelVersion == 1 and
  .output.kind == "access-endpoint-nixos-module" and
  .output.artifact == "etc/network-renderer-access-endpoint/provenance.json" and
  .sources.sourceClasses.userIntent.path == "examples/fs100/intent.nix" and
  .sources.sourceClasses.publicInventory.path == "examples/fs100/inventory-nixos.nix" and
  .sources.sourceClasses.protectedInventory.secretValue == "<redacted>" and
  .sources.sourceClasses.runtimeFacts.ref == "runtime://provider/public-addresses" and
  .sources.sourceClasses.validationContext.profile == "renderer-construction" and
  (.sources.missingSourceClasses | length) == 0 and
  .requested.scope.site == "access-endpoint" and
  .requested.scope.host == "s-router-test-clients" and
  .requested.target.renderer == "access-endpoint-nixos" and
  .requested.target.role == "renderer-output" and
  (.requested.derivedScope.endpointAssignments | index("endpoint-a") != null) and
  (.requested.derivedScope.bridges | index("br-client") != null) and
  .locks.upstream["network-control-plane-model"].rev == "1111222233334444555566667777888899990000" and
  .locks.renderer.available == true and
  .controlledBaseline == "fs100-renderer-output-provenance" and
  .redaction.protectedValues == "redacted"
' "${provenance_json}" >/dev/null

echo "PASS fs100-access-endpoint-renderer-output-provenance"
