{ system
, pkgs
, lib
, cpm
, network-labs
}:

{
  hostModuleFromPaths =
    { hostName ? "s-router-test-clients"
    , labSource ? "active-lab"
    , intentPath ? null
    , inventoryPath ? null
    , clientsPath ? null
    , routingSopsPath ? null
    , mode ? "test"
    , siteName ? "nixos"
    , endpointNames ? null
    , endpointAddressing ? "static"
    , selectorFile ? null
    , ...
    }:

    { config, ... }:

    let
      # Resolve actual paths from network-labs
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

      labIntent = import resolvedIntentPath;
      labInventory = import resolvedInventoryPath;
      hasEnterpriseIntent = builtins.attrNames labIntent != [ ];

      # Build host data via CPM client fixtures - this gives us runtime targets
      clientFixtureModule =
        cpm.clientFixtures.hostModuleFromPaths {
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

      # The CPM module provides _module.args.clientFixture and _module.args.renderedHostNetwork
      # We need to extract these at eval time

      # Builders for endpoint containers
      builders = import ./client-builders.nix { inherit lib pkgs; };

      # Generate model-driven client containers (from intent endpoints)
      modelClientModules = lib.optionals hasEnterpriseIntent [
        (import ./model-site-clients.nix {
          inherit builders lib pkgs;
          intent = labIntent;
          inventory = labInventory;
          runtimeTargets = { };
          inherit siteName;
          inherit endpointAddressing;
        })
      ];

      # Merge all container modules
      clientContainers = lib.foldl' lib.recursiveUpdate { } modelClientModules;

      # Helper to create bridge netdevs
      mkClientBridge = name: {
        netdevConfig = {
          Kind = "bridge";
          Name = name;
        };
      };

      # Helper to create bridge network configs
      mkClientBridgeNetwork = name: {
        matchConfig.Name = name;
        linkConfig = {
          ActivationPolicy = "always-up";
          RequiredForOnline = "no";
        };
        networkConfig = {
          ConfigureWithoutCarrier = true;
          DHCP = "no";
          IPv6AcceptRA = false;
        };
      };

      # Collect unique bridge names from client containers
      clientBridges = lib.unique (
        builtins.map
          (container: container.hostBridge or null)
          (builtins.attrValues clientContainers)
      );
      effectiveBridges = builtins.filter (b: b != null) clientBridges;

    in
    {
      imports = [
        clientFixtureModule
      ];

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

      systemd.network.netdevs = lib.mkOverride 90 (
        lib.genAttrs effectiveBridges mkClientBridge
      );
      systemd.network.networks = lib.mkOverride 90 (
        lib.genAttrs effectiveBridges mkClientBridgeNetwork
      );

      containers = clientContainers;

      users.users.root.openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAqEmMbztRhj2zE1dXf5Z+Ow7mXXXE6sNAG4/hrIOrmD deadbeef@codex-jail"
      ];

      # Remove the dummy service, we have real containers now
      systemd.services.access-endpoint-renderer-dummy.enable = lib.mkForce false;

      assertions = [
        {
          assertion = mode == "test" || mode == "production";
          message = "access-endpoint renderer: mode must be either \"test\" or \"production\"";
        }
        {
          assertion = endpointAddressing == "static" || endpointAddressing == "dhcp";
          message = "access-endpoint renderer: endpointAddressing must be either \"static\" or \"dhcp\"";
        }
        {
          assertion = hasEnterpriseIntent;
          message = "access-endpoint renderer: intent.nix must define an 'esp' enterprise scope";
        }
      ];
    };
}
