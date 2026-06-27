{ system
, pkgs
, lib
, cpm
, network-labs
}:

let
  clientBuilders = import ./client-builders.nix { inherit lib pkgs; };

  cpmSiteData = cpmOutput:
    builtins.concatLists (
      map builtins.attrValues (builtins.attrValues (cpmOutput.control_plane_model.data or { }))
    );

  endpointAssignmentsFromCpm = cpmOutput:
    if cpmOutput ? endpointAssignment then
      cpmOutput.endpointAssignment
    else
      builtins.foldl'
        (acc: site: acc // (site.endpointAssignment or { }))
        { }
        (cpmSiteData cpmOutput);

  endpointBridge = name: assignment:
    let
      bridge = assignment.bridge or null;
      tenant = assignment.tenant or null;
    in
    if builtins.isString bridge && bridge != "" then
      bridge
    else if builtins.isString bridge && bridge == "" && builtins.isString tenant && tenant != "" then
      tenant
    else
      throw "endpointAssignment.${name}.bridge is missing";

  buildEndpointContainer = name: assignment:
    let
      mode =
        if assignment ? mode then
          assignment.mode
        else
          throw "FS-310-HDS-010-SDS-010-SMS-110: endpointAssignment.${name}.mode is missing";
      hostBridge = endpointBridge name assignment;
      hostname = assignment.name or name;
      static = assignment.static or { };
      requireStatic = attr:
        if builtins.hasAttr attr static then
          static.${attr}
        else
          throw (
            if attr == "gateway4" then
              "FS-310-HDS-010-SDS-010-SMS-110: MISSING_CPM_STATIC_ADDRESS_FIELD: static endpoint endpointAssignment.${name} no gateway4; static.gateway4 missing"
            else if attr == "gateway6" then
              "FS-310-HDS-010-SDS-010-SMS-110: MISSING_CPM_STATIC_ADDRESS_FIELD: static endpoint endpointAssignment.${name} no gateway6; static.gateway6 missing"
            else if attr == "address" then
              "FS-310-HDS-010-SDS-010-SMS-110: MISSING_CPM_FIXTURE_FIELD: static endpoint endpointAssignment.${name}.static.address missing"
            else if attr == "prefixLength" then
              "FS-310-HDS-010-SDS-010-SMS-110: MISSING_CPM_FIXTURE_FIELD: static endpoint endpointAssignment.${name}.static.prefixLength missing"
            else
              "FS-310-HDS-010-SDS-010-SMS-110: MISSING_CPM_FIXTURE_FIELD: static endpoint endpointAssignment.${name}.static.${attr} missing"
          );
      staticModule = clientBuilders.mkStaticEndpoint {
        inherit hostname;
        addr4 = "${requireStatic "address"}/${toString (requireStatic "prefixLength")}";
        addr6 = "${requireStatic "address6"}/${toString (requireStatic "prefixLength6")}";
        gw4 = requireStatic "gateway4";
        gw6 = requireStatic "gateway6";
      };
      dhcpModule = clientBuilders.mkDhcpEndpoint {
        inherit hostname;
      };
      mkContainer = module: {
        autoStart = true;
        privateNetwork = true;
        inherit hostBridge;
        config = module;
      };
    in
    if mode == "dhcp" then
      mkContainer dhcpModule
    else if mode == "static" || mode == "static-only" then
      mkContainer staticModule
    else
      throw "FS-310-HDS-010-SDS-010-SMS-110: endpointAssignment.${name} unsupported mode '${mode}'";

  buildContainersFromAssignment = endpointAssignments:
    builtins.mapAttrs buildEndpointContainer endpointAssignments;

  hostModuleFromCpmOutput =
    { cpmOutput
    , mode ? "test"
    ,
    }:

    { config, ... }:

    let
      endpointAssignments = endpointAssignmentsFromCpm cpmOutput;

      clientContainers =
        if cpmOutput ? containers then
          cpmOutput.containers
        else
          buildContainersFromAssignment endpointAssignments;

      clientBridges = lib.unique (
        builtins.map
          (container:
            if container ? hostBridge then container.hostBridge else null
          )
          (builtins.attrValues clientContainers)
      );
      effectiveBridges = builtins.filter (bridge: bridge != null) clientBridges;
      cpmBridgeNetworks = cpmOutput.bridgeNetworks or { };

      cpmBridgeParentNetworks =
        builtins.listToAttrs (
          map
            (bridgeName:
              let
                bridgeNetwork = cpmBridgeNetworks.${bridgeName};
                parent =
                  if builtins.isString (bridgeNetwork.parent or null) && bridgeNetwork.parent != "" then
                    bridgeNetwork.parent
                  else
                    throw "FS-310-HDS-010-SDS-010-SMS-110: bridgeNetworks.${bridgeName}.parent is missing";
              in
              {
                name = "${bridgeName}-parent";
                value = {
                  matchConfig.Name = parent;
                  networkConfig.Bridge = bridgeName;
                };
              })
            (builtins.attrNames cpmBridgeNetworks)
        );

      bridgeNetdevs =
        builtins.listToAttrs (
          map
            (bridge: {
              name = bridge;
              value.netdevConfig = {
                Kind = "bridge";
                Name = bridge;
              };
            })
            effectiveBridges
        );

      bridgeNetworks =
        builtins.listToAttrs (
          map
            (bridge: {
              name = bridge;
              value = {
                matchConfig.Name = bridge;
                networkConfig = {
                  DHCP = "no";
                  IPv6AcceptRA = false;
                };
              };
            })
            effectiveBridges
        );
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

      systemd.network.netdevs = bridgeNetdevs;
      systemd.network.networks = bridgeNetworks // cpmBridgeParentNetworks;

      containers = clientContainers;

      users.users.root.openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAqEmMbztRhj2zE1dXf5Z+Ow7mXXXE6sNAG4/hrIOrmD deadbeef@codex-jail"
      ];

      systemd.services.access-endpoint-renderer-dummy.enable = lib.mkForce false;

      systemd.services.s-router-test-clients-endpoint-ready = {
        description = "Endpoint fixture containers are rendered";
        wantedBy = [ "multi-user.target" ];
        serviceConfig.Type = "oneshot";
        script = "true";
      };

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

  # ----- hostModuleFromPaths: compatibility path builder -----
  hostModuleFromPaths =
    { # FS-310-HDS-010-SDS-010-SMS-110: caller must supply hostName for non-default harness targets.
      hostName ? "s-router-test-clients"
    , # FS-310-HDS-010-SDS-010-SMS-110: caller must supply labSource for non-default lab sources.
      labSource ? "active-lab"
    , intentPath ? null
    , inventoryPath ? null
    , clientsPath ? null
    , routingSopsPath ? null
    , # FS-310-HDS-010-SDS-010-SMS-110: caller must supply mode for non-test materialization.
      mode ? "test"
    , # FS-310-HDS-010-SDS-010-SMS-110: caller must supply siteName for non-default site targets.
      siteName ? "site-a"
    , ...
    }:

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

      fixtureArgs = {
        intentPath = resolvedIntentPath;
        inventoryPath = resolvedInventoryPath;
        sopsPath =
          if routingSopsPath != null then
            routingSopsPath
          else
            "${network-labs}/${labSource}/sops.nix";
        fixture = {
          kind = "emulated-clients";
          inherit hostName siteName;
        };
      };

      unwrapModuleDefault = value:
        if builtins.isAttrs value && value ? content then value.content else value;

      cpmOutput =
        if cpm.clientFixtures ? buildFromPaths then
          cpm.clientFixtures.buildFromPaths fixtureArgs
        else
          unwrapModuleDefault (
            (cpm.clientFixtures.hostModuleFromPaths (fixtureArgs // { inherit lib; }))._module.args.clientFixture
          );
    in
    hostModuleFromCpmOutput { inherit cpmOutput mode; };

  # ----- hostModule: standard renderer interface -----
  hostModule = rendererInput:
    let
      explicitCpm =
        if rendererInput ? controlPlane && rendererInput.controlPlane != null then
          rendererInput.controlPlane
        else if rendererInput ? cpm && rendererInput.cpm != null then
          rendererInput.cpm
        else
          null;
    in
    if explicitCpm != null then
      hostModuleFromCpmOutput {
        cpmOutput = explicitCpm;
        # FS-310-HDS-010-SDS-010-SMS-110: caller must supply mode for non-test materialization.
        mode = rendererInput.mode or "test";
      }
    else
      throw "network-renderer-access-endpoint-nixos.hostModule: 'cpm' or 'controlPlane' is required; use hostModuleFromPaths for path-based rendering";

in
{
  inherit hostModule hostModuleFromPaths;
}
