#!/usr/bin/env bash
# GAMP-ID: FS-230-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

result="$({
  REPO_ROOT="${repo_root}" nix eval --impure --json --expr '
    let
      flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
      lab = import (flake.inputs.network-labs + "/GAMP/SMT/FS-230-HDS-010-SDS-010-SMS-040/intent-test-clients.nix");
      sopsModule = flake.inputs.network-labs + "/GAMP/SMT/FS-230-HDS-010-SDS-010-SMS-040/sops-routing-s-router-test-clients.nix";
      module = flake.libBySystem.${builtins.currentSystem}.renderer.hostModule {
        cpm = lab;
        hostName = "s-router-test-clients";
        mode = "test";
        sops = sopsModule;
      };
      host = flake.inputs.nixpkgs.lib.nixosSystem {
        system = builtins.currentSystem;
        modules = [
          ({ lib, ... }: {
            options.sops.secrets = lib.mkOption {
              type = lib.types.attrs;
              default = {};
            };
          })
          module
        ];
      };
      conflictingHost = flake.inputs.nixpkgs.lib.nixosSystem {
        system = builtins.currentSystem;
        modules = [
          ({ lib, ... }: {
            options.sops.secrets = lib.mkOption {
              type = lib.types.attrs;
              default = {};
            };
          })
          module
          ({ lib, ... }: {
            containers.fs230-nixos-service.config = {
              networking.firewall.enable = lib.mkForce true;
            };
          })
        ];
      };
      runtimeUnit = "access-endpoint-runtime-ipv6-address-0";
      describe = name:
        let
          container = host.config.containers.${name};
          services = container.config.systemd.services;
          hostUnit = host.config.systemd.services."container@${name}";
        in {
          bindMounts = container.bindMounts;
          firewallEnabled = container.config.networking.firewall.enable;
          hasRuntimeUnit = builtins.hasAttr runtimeUnit services;
          execStart = if builtins.hasAttr runtimeUnit services then services.${runtimeUnit}.serviceConfig.ExecStart else null;
          hostAfter = hostUnit.after;
          hostWants = hostUnit.wants;
        };
    in {
      names = builtins.attrNames host.config.containers;
      endpoints = builtins.listToAttrs (map (name: { inherit name; value = describe name; }) (builtins.attrNames host.config.containers));
      protectedSource = let secret = host.config.sops.secrets."fs230-lab-dmz-ipv6-prefix"; in {
        inherit (secret) key mode path;
        sopsFile = builtins.toString secret.sopsFile;
      };
      conflictingFirewallOverrideAccepted = (builtins.tryEval (
        builtins.deepSeq
          conflictingHost.config.containers.fs230-nixos-service.config.networking.firewall.enable
          true
      )).success;
    }
  '
} 2>"${tmp_dir}/eval.stderr")"

jq -e '
  .names == [
    "fs230-clab-public",
    "fs230-clab-service",
    "fs230-nixos-public",
    "fs230-nixos-service"
  ]
  and ([.endpoints["fs230-nixos-service"], .endpoints["fs230-clab-service"]] | all(
    .bindMounts == {
      "/run/secrets/fs230-lab-dmz-ipv6-prefix": {
        hostPath: "/run/secrets/fs230-lab-dmz-ipv6-prefix",
        isReadOnly: true,
        mountPoint: "/run/secrets/fs230-lab-dmz-ipv6-prefix"
      }
    }
    and .firewallEnabled == false
    and .hasRuntimeUnit == true
    and (.execStart | contains("runtime-protected-ipv6-address.py"))
    and (.execStart | contains("--source /run/secrets/fs230-lab-dmz-ipv6-prefix"))
    and (.execStart | contains("--delegated-prefix-length 48"))
    and (.execStart | contains("--tenant-prefix-length 64"))
    and (.execStart | contains("--slot 35"))
    and (.execStart | contains("--interface-identifier 0000:0000:0000:4242"))
    and (.execStart | contains("--target-prefix-length 128"))
    and (.execStart | contains("--assign-interface eth0"))
    and (.execStart | contains("--ip-command /nix/store/"))
    and (.execStart | contains("--print") | not)
    and (.hostAfter | index("sops-nix.service") != null)
    and (.hostWants | index("sops-nix.service") != null)
  ))
  and ([.endpoints["fs230-nixos-public"], .endpoints["fs230-clab-public"]] | all(
    .bindMounts == {}
    and .firewallEnabled == false
    and .hasRuntimeUnit == false
    and .execStart == null
    and (.hostAfter | index("sops-nix.service") == null)
    and (.hostWants | index("sops-nix.service") == null)
  ))
  and .protectedSource == {
    key: "protected-prefix",
    mode: "0400",
    path: "/run/secrets/fs230-lab-dmz-ipv6-prefix",
    sopsFile: .protectedSource.sopsFile
  }
  and (.protectedSource.sopsFile | endswith("/GAMP/SMT/FS-230-HDS-010-SDS-010-SMS-040/secrets/sops-fs230.json"))
  and .conflictingFirewallOverrideAccepted == false
' <<<"${result}" >/dev/null

printf '%s\n' '2001:db8:230::/48' >"${tmp_dir}/prefix"
derived="$(${repo_root}/lib/runtime-protected-ipv6-address.py \
  --source "${tmp_dir}/prefix" \
  --delegated-prefix-length 48 \
  --tenant-prefix-length 64 \
  --slot 35 \
  --interface-identifier 0000:0000:0000:4242 \
  --target-prefix-length 128 \
  --print)"
test "${derived}" = '2001:db8:230:23::4242/128'

printf '%s\n' '2001:db8:230::/56' >"${tmp_dir}/invalid-prefix"
if ${repo_root}/lib/runtime-protected-ipv6-address.py \
  --source "${tmp_dir}/invalid-prefix" \
  --delegated-prefix-length 48 \
  --tenant-prefix-length 64 \
  --slot 35 \
  --interface-identifier 0000:0000:0000:4242 \
  --target-prefix-length 128 \
  --print >"${tmp_dir}/invalid.stdout" 2>"${tmp_dir}/invalid.stderr"; then
  echo 'FAIL FS-230: mismatched protected prefix length was accepted' >&2
  exit 1
fi
test ! -s "${tmp_dir}/invalid.stdout"
! grep -Fq '2001:db8:230' "${tmp_dir}/invalid.stderr"

if REPO_ROOT="${repo_root}" nix eval --impure --expr '
  let
    flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
    module = flake.libBySystem.${builtins.currentSystem}.renderer.hostModule {
      hostName = "s-router-test-clients";
      mode = "test";
      cpm = {
        endpointAssignment.probe = {
          mode = "static";
          name = "probe";
          bridge = "client";
          static = {
            address = "192.0.2.2";
            prefixLength = 24;
            gateway4 = "192.0.2.1";
            address6 = "2001:db8::2";
            prefixLength6 = 64;
            gateway6 = "2001:db8::1";
          };
          runtimeAddressAssignments = [ {
            family = "ipv6";
            sourceClass = "public";
            sourceFile = "/run/secrets/should-not-be-consumed";
            delegatedPrefixLength = 48;
            perTenantPrefixLength = 64;
            slot = 35;
            interfaceIdentifier = "0000:0000:0000:4242";
            prefixLength = 128;
            interfaceName = "eth0";
          } ];
        };
        bridgeNetworks.client = { };
      };
    };
    evaluated = module { config = { }; };
  in builtins.deepSeq evaluated.containers.probe true
' >"${tmp_dir}/source-class.stdout" 2>"${tmp_dir}/source-class.stderr"; then
  echo 'FAIL FS-230: non-protected runtime address source was accepted' >&2
  exit 1
fi
grep -Fq 'must declare sourceClass=protected' "${tmp_dir}/source-class.stderr"
! grep -Fq '2001:db8:230' "${tmp_dir}/source-class.stderr"

echo 'PASS FS-230-HDS-010-SDS-010-SMS-040 protected runtime service address construction'
