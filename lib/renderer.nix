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

  # Parse inventory bridge networks for VLAN configuration
  # Each bridge network may have mode=vlan with a vlan ID
  getBridgeVlanConfig = resolvedInventoryPath: hostName:
    let
      inv = import resolvedInventoryPath;
      host = (inv.deployment.hosts or {}).${hostName} or {};
      bridgeNetworks = host.bridgeNetworks or {};
    in
    builtins.mapAttrs
      (bridgeName: cfg:
        if cfg ? mode && cfg.mode == "vlan" && cfg ? vlan then
          { vlanId = cfg.vlan; parent = cfg.parent or "eth0"; }
        else
          null
      )
      bridgeNetworks;

  # Create VLAN netdev for tagged bridge
  mkVlanNetdev = name: vlanCfg: {
    netdevConfig = {
      Kind = "vlan";
      Name = "${vlanCfg.parent}.${toString vlanCfg.vlanId}";
    };
    vlanConfig = {
      Id = vlanCfg.vlanId;
    };
  };

  # Create bridge netdev (plain L2)
  mkClientBridge = name: {
    netdevConfig = {
      Kind = "bridge";
      Name = name;
    };
  };

  # VLAN interface network config — attach to bridge
  mkVlanNetwork = vlanCfg: bridgeName: {
    matchConfig.Name = "${vlanCfg.parent}.${toString vlanCfg.vlanId}";
    linkConfig.ActivationPolicy = "always-up";
    networkConfig = {
      ConfigureWithoutCarrier = true;
      DHCP = "no";
      IPv6AcceptRA = false;
      Bridge = bridgeName;
    };
  };

  # Bridge network config (pure L2 — no IP, no DHCP, no NAT)
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

  # ----- hostModuleFromPaths: the full NixOS module builder -----
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

      resolvedClabInventoryPath = "${network-labs}/${labSource}/inventory-clab.nix";

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

      builders = import ./client-builders.nix { inherit lib pkgs; };

      nixosContainers = buildFixtureContainers {
        inherit hostName labSource builders;
        resolvedInventoryPath = resolvedInventoryPath;
      };

      clabContainers = buildFixtureContainers {
        inherit labSource builders;
        allHosts = true;
        resolvedInventoryPath = resolvedClabInventoryPath;
      };

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

      # VLAN configuration from inventory bridge networks
      bridgeVlanConfig = getBridgeVlanConfig resolvedInventoryPath hostName;
      vlanBridges = lib.filterAttrs (_name: cfg: cfg != null) bridgeVlanConfig;
      vlanBridgeNames = builtins.attrNames vlanBridges;

      # Netdevs: VLAN interfaces + bridges
      vlanNetdevs = lib.mapAttrs' 
        (bridgeName: vlanCfg: {
          name = "${vlanCfg.parent}.${toString vlanCfg.vlanId}";
          value = mkVlanNetdev bridgeName vlanCfg;
        })
        vlanBridges;

      bridgeNetdevs = lib.genAttrs effectiveBridges mkClientBridge;

      # Networks: VLAN network configs (attach VLAN to bridge) + bridge network configs
      vlanNetworks = lib.mapAttrs'
        (bridgeName: vlanCfg: {
          name = "${vlanCfg.parent}.${toString vlanCfg.vlanId}";
          value = mkVlanNetwork vlanCfg bridgeName;
        })
        vlanBridges;

      bridgeNetworks = lib.genAttrs effectiveBridges (name: mkClientBridgeNetwork name);

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

      systemd.network.netdevs = vlanNetdevs // bridgeNetdevs;
      systemd.network.networks = vlanNetworks // bridgeNetworks;

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
      endpointAddressing = rendererInput.endpointAddressing or "static";
    };

in
{
  inherit hostModule hostModuleFromPaths;
}
