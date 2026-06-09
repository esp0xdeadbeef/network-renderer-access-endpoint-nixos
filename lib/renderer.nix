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
    , siteName ? "site-a"
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

      # Builders for endpoint containers
      builders = import ./client-builders.nix { inherit lib pkgs; };

      # --- Path 1: Inventory fixture endpoint clients (HAT test clients) ---
      hatEndpointClients =
        (((labInventory.deployment or { }).hosts or { }).${hostName} or { }).hat.endpointClients or { };

      mkHatEndpointContainer =
        name: endpoint:
        let
          tenant = endpoint.tenant or (throw "access-endpoint-renderer HAT endpoint ${name} has no tenant");
          assignment = endpoint.assignment or "dhcp";
          bridge = endpoint.bridge or tenant;
          staticIpv4 = endpoint.ipv4 or [ ];
          staticIpv6 = endpoint.ipv6 or [ ];
          gateway4 = endpoint.gateway4 or null;
          gateway6 = endpoint.gateway6 or null;
        in
        if assignment == "dhcp" then
          {
            autoStart = true;
            privateNetwork = true;
            hostBridge = bridge;
            config = builders.mkDhcpEndpoint {
              hostname = name;
            };
          }
        else if assignment == "static-ipv4-or-ipv6-client" || assignment == "static" then
          {
            autoStart = true;
            privateNetwork = true;
            hostBridge = bridge;
            config = builders.mkStaticEndpoint {
              hostname = name;
              addr4 =
                if staticIpv4 == [ ] then
                  throw "access-endpoint-renderer HAT static endpoint ${name} has no ipv4 address"
                else
                  builtins.head staticIpv4;
              gw4 =
                gateway4 or (throw "access-endpoint-renderer HAT static endpoint ${name} has no gateway4");
              addr6 =
                if staticIpv6 == [ ] then
                  throw "access-endpoint-renderer HAT static endpoint ${name} has no ipv6 address"
                else
                  builtins.head staticIpv6;
              gw6 =
                gateway6 or (throw "access-endpoint-renderer HAT static endpoint ${name} has no gateway6");
            };
          }
        else
          throw "access-endpoint-renderer HAT endpoint ${name} has unsupported assignment ${assignment}";

      hatEndpointModules =
        lib.optional (hatEndpointClients != { }) (
          builtins.mapAttrs mkHatEndpointContainer hatEndpointClients
        );

      # --- Path 2: Model-driven client containers (from intent endpoints) ---
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
      clientContainers = lib.foldl' lib.recursiveUpdate { } (
        modelClientModules ++ hatEndpointModules
      );

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
          message = "access-endpoint renderer: intent.nix must define an enterprise scope";
        }
      ];
    };
}
