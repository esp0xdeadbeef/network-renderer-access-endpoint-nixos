{ system
, pkgs
, lib
, cpm
, network-labs
}:

let
  # Build endpoint containers from inventory fixture data
  buildFixtureContainers =
    { hostName ? null
    , allHosts ? false
    , labSource
    , resolvedInventoryPath
    , builders
    }:
    let
      labInventory = import resolvedInventoryPath;
      labDeployment = labInventory.deployment or { };
      labHosts = labDeployment.hosts or { };
      # Collect endpoint clients from either the specified host or ALL hosts
      endpointClients =
        if allHosts then
          lib.foldl' (acc: host: acc // (host.hat.endpointClients or {})) {} (builtins.attrValues labHosts)
        else if hostName != null then
          (labHosts.${hostName} or {}).hat.endpointClients or {}
        else
          {};

      endpointBuildData = builtins.mapAttrs
        (name: endpoint:
          let
            tenant =
              if builtins.hasAttr "tenant" endpoint then
                endpoint.tenant
              else
                throw "access-endpoint-renderer: endpoint ${name} has no tenant";
            assignment =
              if builtins.hasAttr "assignment" endpoint then
                endpoint.assignment
              else
                "dhcp";
            bridge =
              if builtins.hasAttr "bridge" endpoint then
                endpoint.bridge
              else
                tenant;
            staticIpv4 =
              if builtins.hasAttr "ipv4" endpoint then
                endpoint.ipv4
              else
                [ ];
            staticIpv6 =
              if builtins.hasAttr "ipv6" endpoint then
                endpoint.ipv6
              else
                [ ];
            rawGateway4 =
              if builtins.hasAttr "gateway4" endpoint then
                endpoint.gateway4
              else
                null;
            rawGateway6 =
              if builtins.hasAttr "gateway6" endpoint then
                endpoint.gateway6
              else
                null;
            containerConfig =
              if assignment == "dhcp" then
                builders.mkDhcpEndpoint {
                  hostname = name;
                }
              else if assignment == "static-ipv4-or-ipv6-client" || assignment == "static" then
                let
                  gw4 =
                    if rawGateway4 != null then
                      rawGateway4
                    else
                      throw "access-endpoint-renderer: static endpoint ${name} has no gateway4";
                  gw6 =
                    if rawGateway6 != null then
                      rawGateway6
                    else
                      throw "access-endpoint-renderer: static endpoint ${name} has no gateway6";
                  addr4 =
                    if staticIpv4 != [ ] then
                      builtins.head staticIpv4
                    else
                      throw "access-endpoint-renderer: static endpoint ${name} has no ipv4 address";
                  addr6 =
                    if staticIpv6 != [ ] then
                      builtins.head staticIpv6
                    else
                      throw "access-endpoint-renderer: static endpoint ${name} has no ipv6 address";
                in
                builders.mkStaticEndpoint {
                  hostname = name;
                  inherit addr4 gw4 addr6 gw6;
                }
              else
                throw "access-endpoint-renderer: endpoint ${name} has unsupported assignment ${assignment}";
          in
          {
            autoStart = true;
            privateNetwork = true;
            hostBridge = bridge;
            config = containerConfig;
          }
        )
        endpointClients;
    in
    endpointBuildData;

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

in
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
    , endpointAddressing ? "static"
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

      # Also resolve CLAB inventory for dual-host endpoints
      resolvedClabInventoryPath = "${network-labs}/${labSource}/inventory-clab.nix";

      labIntent = import resolvedIntentPath;
      hasEnterpriseIntent = builtins.attrNames labIntent != [ ];

      # Build CPM client fixture module
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

      # Builders
      builders = import ./client-builders.nix { inherit lib pkgs; };

      # Build NixOS fixture containers
      nixosContainers = buildFixtureContainers {
        inherit hostName labSource builders;
        resolvedInventoryPath = resolvedInventoryPath;
      };

      # Build CLAB fixture containers (from ALL hosts in CLAB inventory)
      clabContainers = buildFixtureContainers {
        inherit labSource builders;
        allHosts = true;
        resolvedInventoryPath = resolvedClabInventoryPath;
      };

      # Merge both host's containers
      clientContainers =
        lib.recursiveUpdate nixosContainers clabContainers;

      # Collect unique bridge names from client containers
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

      systemd.network.netdevs = lib.genAttrs effectiveBridges mkClientBridge;
      systemd.network.networks = lib.genAttrs effectiveBridges mkClientBridgeNetwork;

      containers = clientContainers;

      users.users.root.openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAqEmMbztRhj2zE1dXf5Z+Ow7mXXXE6sNAG4/hrIOrmD deadbeef@codex-jail"
      ];

      systemd.services.access-endpoint-renderer-dummy.enable = lib.mkForce false;

      assertions = [
        {
          assertion = mode == "test" || mode == "production";
          message = "access-endpoint renderer: mode must be either \"test\" or \"production\"";
        }
      ];
    };
}
