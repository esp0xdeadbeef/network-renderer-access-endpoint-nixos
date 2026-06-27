{ system
, pkgs
, lib
, cpm
, network-labs
}:

let
  # ----- hostModuleFromPaths: the full NixOS module builder -----
  # Consumes CPM output (which includes endpointAssignment from Phase 1)
  # instead of re-parsing raw intent or inventory.
  hostModuleFromPaths =
    { hostName ? "s-router-test-clients"
    , labSource ? "active-lab"
    , intentPath ? null
    , inventoryPath ? null
    , clientsPath ? null
    , routingSopsPath ? null
    , mode ? "test"
    , siteName ? "site-a"
    , ...
    }:

    { config, ... }:

    let
      resolvedIntentPath =
        if intentPath != null then
          intentPath
        else
          "${network-labs}/${labSource}/intent.nix";

      resolvedInventoryPath =
        if inventoryPath != null then
          inventoryPath
        else
          "${network-labs}/${labSource}/inventory-nixos.nix";

      # Build CPM output including Phase 1 endpointAssignment contract.
      # CPM client-fixtures module produces containers, host network config,
      # and endpointAssignment records from the model pipeline.
      cpmOutput =
        cpm.clientFixtures.buildFromPaths {
          intentPath = resolvedIntentPath;
          inventoryPath = resolvedInventoryPath;
          sopsPath =
            if routingSopsPath != null then
              routingSopsPath
            else
              "${network-labs}/${labSource}/sops.nix";
          fixture = {
            kind = "emulated-clients";
            hostName = "s-router-test-clients";
            inherit siteName;
          };
        };

      # CPM-built containers (replaces buildFixtureContainers raw inventory path)
      clientContainers = cpmOutput.containers or { };

      # Extract endpoint assignment records for Phase 2 consumption
      endpointAssignments = cpmOutput.endpointAssignment or { };

      # Bridge names from CPM containers
      clientBridges = lib.unique (
        builtins.map
          (container:
            if container ? hostBridge then container.hostBridge else null
          )
          (builtins.attrValues clientContainers)
      );
      effectiveBridges = builtins.filter (b: b != null) clientBridges;

    in
    {
      system.stateVersion = lib.mkForce "25.11";

      environment.systemPackages = with pkgs; [
        bind
        curl
        iproute2
        iputils
        jq
        ripgrep
        tcpdump
        tmux
        traceroute
        tshark
      ];

      networking.useNetworkd = true;
      systemd.network.enable = true;
      systemd.network.wait-online.enable = false;
      networking.useDHCP = false;
      networking.useHostResolvConf = lib.mkForce false;
      services.resolved.enable = lib.mkForce true;

      containers = clientContainers;

      users.users.root.openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAqEmMbztRhj2zE1dXf5Z+Ow7mXXXE6sNAG4/hrIOrmD deadbeef@codex-jail"
      ];

      systemd.services.access-endpoint-renderer-dummy.enable = lib.mkForce false;

      systemd.services.access-endpoint-isolate-bridges = {
        description = "Block endpoint bridge egress to host management VLAN";
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-networkd.service" "network-online.target" ];
        wants = [ "systemd-networkd.service" "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          # Ensure the filter forward chain exists with netfilter hook
          nft list chain inet filter forward >/dev/null 2>&1 || \
            nft add chain inet filter forward '{ type filter hook forward priority 0; policy accept; }' 2>/dev/null || true

          # Recreate chain if it exists without a hook (from a bad prior run)
          nft list chain inet filter forward 2>/dev/null | grep -q 'type filter hook' || {
            nft delete chain inet filter forward 2>/dev/null || true
            nft add chain inet filter forward '{ type filter hook forward priority 0; policy accept; }' 2>/dev/null || true
          }

          # Block endpoint bridge subnets from reaching vlan2 (real ISP)
          nft add rule inet filter forward oif vlan2 ip saddr 10.20.20.0/24 drop 2>/dev/null || true
          nft add rule inet filter forward oif vlan2 ip saddr 10.20.30.0/24 drop 2>/dev/null || true
          nft add rule inet filter forward oif vlan2 ip saddr 10.20.40.0/24 drop 2>/dev/null || true
          nft add rule inet filter forward oif vlan2 ip saddr 10.20.50.0/24 drop 2>/dev/null || true
          nft add rule inet filter forward oif vlan2 ip saddr 10.20.60.0/24 drop 2>/dev/null || true
          nft add rule inet filter forward oif vlan2 ip saddr 10.20.70.0/24 drop 2>/dev/null || true
          nft add rule inet filter forward oif vlan2 ip saddr 10.20.80.0/24 drop 2>/dev/null || true
          nft add rule inet filter forward oif vlan2 ip saddr 10.50.40.0/24 drop 2>/dev/null || true
        '';
      };

      assertions = [
        {
          assertion = mode == "test" || mode == "production";
          message = "access-endpoint renderer: mode must be either \"test\" or \"production\"";
        }
      ];
    };

  # ----- hostModule: standard renderer interface wrapping hostModuleFromPaths -----
  hostModule = rendererInput:
    let
      hostName = rendererInput.hostName or "s-router-test-clients";
      labSource = rendererInput.labSource or "active-lab";
      resolvedIntentPath =
        if rendererInput ? intent && rendererInput.intent != null then
          rendererInput.intent
        else
          "${network-labs}/${labSource}/intent.nix";
      resolvedInventoryPath =
        if rendererInput ? inventory && rendererInput.inventory != null then
          rendererInput.inventory
        else
          "${network-labs}/${labSource}/inventory-nixos.nix";
    in
    hostModuleFromPaths {
      inherit hostName labSource;
      intentPath = resolvedIntentPath;
      inventoryPath = resolvedInventoryPath;
      clientsPath = rendererInput.clients or null;
      routingSopsPath = rendererInput.sops or null;
      mode = rendererInput.mode or "test";
      siteName = rendererInput.siteName or "site-a";
    };

in
{
  inherit hostModule hostModuleFromPaths;
}
