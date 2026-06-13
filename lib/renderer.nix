{ system
, pkgs
, lib
, cpm
, network-labs
}:

let
  # ----- Build endpoint containers from CPM endpointAssignment contract -----
  # Phase 2: Replaces buildFixtureContainers which read raw inventory.
  # Consumes CPM Phase 1 endpointAssignment records per-endpoint.
  buildContainersFromAssignment =
    { endpointAssignment ? { }
    , builders
    }:
    builtins.mapAttrs
      (key: record:
        let
          mode = if record ? mode then record.mode else
            throw "access-endpoint-renderer: FS-310-HDS-010-SDS-010-SMS-110 — required CPM field endpointAssignment.${key}.mode is missing";
          tenant = record.tenant or key;
          bridge =
            let
              rawBridge = record.bridge or null;
            in
            if builtins.isString rawBridge && rawBridge != "" then
              rawBridge
            else
              tenant;
          static = record.static or { };
          dhcp = record.dhcp or { };
          name = key;
          isStatic = builtins.elem mode [ "static" "static-only" ];
          isDhcp = builtins.substring 0 4 mode == "dhcp" || mode == "reservation-dhcp" || mode == "reservation-dhcpv6";

          containerConfig =
            if isStatic then
              let
                # GAMP: FS-310-HDS-010-SDS-010-SMS-110 — fail-closed: no hardcoded address/prefix defaults
                staticAddr = if static ? address then static.address else
                  throw "access-endpoint-renderer: FS-310-HDS-010-SDS-010-SMS-110 — required CPM field static.address missing for endpoint ${key}";
                staticPlen = if static ? prefixLength then static.prefixLength else
                  throw "access-endpoint-renderer: FS-310-HDS-010-SDS-010-SMS-110 — required CPM field static.prefixLength missing for endpoint ${key}";
                addr4 = "${staticAddr}/${toString staticPlen}";
                gw4 = static.gateway4 or null;
                addr6 =
                  if static ? address6 && static ? prefixLength6 then
                    "${static.address6}/${toString static.prefixLength6}"
                  else
                    null;
                gw6 = static.gateway6 or null;
              in
              if gw4 == null then
                throw "access-endpoint-renderer: static endpoint ${key} has no gateway4"
              else
                builders.mkStaticEndpoint {
                  hostname = name;
                  inherit addr4 gw4;
                  inherit addr6 gw6;
                }
            else if isDhcp then
              builders.mkDhcpEndpoint {
                hostname = name;
              }
            else
              throw "access-endpoint-renderer: endpoint ${key} has unsupported mode ${mode}";
        in
        {
          autoStart = true;
          privateNetwork = true;
          hostBridge = bridge;
          config = containerConfig;
        }
      )
      endpointAssignment;

  # Parse inventory bridge networks for VLAN configuration.
  # Bridge/VLAN infrastructure is host-level network topology configuration,
  # not endpoint assignment — it stays until a CPM host-network contract exists.
  getBridgeVlanConfig = resolvedInventoryPath: hostName:
    let
      inv = import resolvedInventoryPath;
      host = (inv.deployment.hosts or {}).${hostName} or {};
      bridgeNetworks = host.bridgeNetworks or {};
    in
    builtins.mapAttrs
      (bridgeName: cfg:
        if cfg ? mode && cfg.mode == "vlan" && cfg ? vlan then
          { vlanId = cfg.vlan; parent = if cfg ? parent then cfg.parent else
            throw "access-endpoint-renderer: FS-310-HDS-010-SDS-010-SMS-110 — required field bridgeNetworks.${bridgeName}.parent is missing for VLAN bridge"; }
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

      # Build full CPM output including Phase 1 endpointAssignment contract.
      # This replaces raw inventory reads for endpoint assignment.
      cpmOutput =
        cpm.compileAndBuildFromPaths {
          inputPath = resolvedIntentPath;
          inventoryPath = resolvedInventoryPath;
        };

      # Navigate CPM output: control_plane_model.data.<enterprise>.<site>.endpointAssignment
      cpmData = cpmOutput.control_plane_model or cpmOutput;
      cpmEnterprises = cpmData.data or { };
      enterpriseName = builtins.head (builtins.attrNames cpmEnterprises);
      enterpriseData = cpmEnterprises.${enterpriseName} or { };
      siteData = enterpriseData.${siteName} or { };

      # Extract endpointAssignment from CPM output
      endpointAssignments = siteData.endpointAssignment or { };

      builders = import ./client-builders.nix { inherit lib pkgs; };

      # Build containers from CPM contract instead of raw inventory
      nixosContainers = buildContainersFromAssignment {
        endpointAssignment = endpointAssignments;
        inherit builders;
      };

      # ----- Build fixture endpoint containers from inventory endpoint clients -----
      # Reads inventory deployment.hosts.<hostName>.hat.endpointClients for nixos-owned
      # fixture endpoints (separate from CPM model endpoints).  These are ephemeral
      # test fixtures that do not belong in the CPM model.
      labInventory = import resolvedInventoryPath;
      inventoryHost = (labInventory.deployment.hosts or { }).${hostName} or { };

      # All endpoint clients regardless of owning substrate — each substrate's
      # endpoints are rendered as NixOS containers on this host for fixture testing.
      fixtureEndpointClients =
        (inventoryHost.hat or { }).endpointClients or {};

      fixtureEndpointNames = builtins.attrNames fixtureEndpointClients;

      # Build one container per fixture endpoint client from inventory data
      buildFixtureContainer = name: ep:
        let
          assignment = ep.assignment or "dhcp";
          tenant = ep.tenant or name;
          bridge = ep.bridge or tenant;
          staticIpv4 = ep.ipv4 or [ ];
          staticIpv6 = ep.ipv6 or [ ];
        in
        if assignment == "dhcp" then
          {
            autoStart = true;
            privateNetwork = true;
            hostBridge = bridge;
            config = builders.mkDhcpEndpoint { hostname = name; };
          }
        else if assignment == "static-ipv4-or-ipv6-client" || assignment == "static" then
          let
            addr4 =
              if staticIpv4 != [ ] then
                let raw = builtins.head staticIpv4;
                in if lib.hasInfix "/" raw then raw
                   else throw "access-endpoint-renderer: static fixture ${name} ipv4 missing prefix: ${raw}"
              else throw "access-endpoint-renderer: static fixture ${name} has no ipv4";
            gw4 = ep.gateway4
              or (throw "access-endpoint-renderer: static fixture ${name} has no gateway4");
            addr6 =
              if staticIpv6 != [ ] then
                let raw = builtins.head staticIpv6;
                in if lib.hasInfix "/" raw then raw
                   else throw "access-endpoint-renderer: static fixture ${name} ipv6 missing prefix: ${raw}"
              else throw "access-endpoint-renderer: static fixture ${name} has no ipv6";
            gw6 = ep.gateway6
              or (throw "access-endpoint-renderer: static fixture ${name} has no gateway6");
          in
          {
            autoStart = true;
            privateNetwork = true;
            hostBridge = bridge;
            config = builders.mkStaticEndpoint {
              hostname = name;
              inherit addr4 gw4 addr6 gw6;
            };
          }
        else
          throw "access-endpoint-renderer: fixture ${name} unsupported assignment ${assignment}";

      fixtureContainers = builtins.mapAttrs buildFixtureContainer fixtureEndpointClients;

      # Merge fixture containers into client containers
      clientContainers = nixosContainers // fixtureContainers;

      # Static-IP and route check shell fragments for the readiness script
      fixtureStaticChecks = lib.concatMapStringsSep "\n"
        (name:
          let
            ep = fixtureEndpointClients.${name};
            assignment = ep.assignment or "dhcp";
            staticIpv4 = ep.ipv4 or [ ];
            staticIpv6 = ep.ipv6 or [ ];
            ipv4Check =
              if staticIpv4 != [ ] then
                let addrOnly = builtins.head (lib.splitString "/" (builtins.head staticIpv4));
                in ''
                  timeout 5 nixos-container run ${lib.escapeShellArg name} -- \
                    ip -br addr show dev eth0 | grep -F ${lib.escapeShellArg addrOnly} >/dev/null
                ''
              else "";
            ipv6Check =
              if staticIpv6 != [ ] then
                let addrOnly = builtins.head (lib.splitString "/" (builtins.head staticIpv6));
                in ''
                  timeout 5 nixos-container run ${lib.escapeShellArg name} -- \
                    ip -br addr show dev eth0 | grep -F ${lib.escapeShellArg addrOnly} >/dev/null
                ''
              else "";
            routeCheck =
              if ep ? gateway4 then ''
                timeout 5 nixos-container run ${lib.escapeShellArg name} -- \
                  ip route | grep -F ${lib.escapeShellArg "default via ${ep.gateway4}"} >/dev/null
              '' else "";
          in
          lib.optionalString (assignment == "static-ipv4-or-ipv6-client" || assignment == "static") ''
            ${ipv4Check}
            ${ipv6Check}
            ${routeCheck}
          ''
        )
        fixtureEndpointNames;

      # DHCP check shell fragments
      fixtureDhcpChecks = lib.concatMapStringsSep "\n"
        (name:
          let ep = fixtureEndpointClients.${name};
              assignment = ep.assignment or "dhcp";
          in
          lib.optionalString (assignment == "dhcp") ''
            timeout 5 nixos-container run ${lib.escapeShellArg name} -- \
              ip -4 -o addr show scope global dev eth0 | grep -F " inet " >/dev/null
            timeout 5 nixos-container run ${lib.escapeShellArg name} -- \
              ip -4 route show default | grep -F "default " >/dev/null
          ''
        )
        fixtureEndpointNames;

      # Endpoint readiness oneshot script — waits for all fixture containers to be
      # up and configured, then writes the marker that the rebuild loop checks.
      endpointReadyScript = pkgs.writeShellScript "s-router-test-clients-endpoint-ready" ''
        set -euo pipefail
        marker=/run/s-router-test-clients-endpoints-ready
        check_endpoints() {
          for client in ${lib.concatMapStringsSep " " lib.escapeShellArg fixtureEndpointNames}; do
            timeout 5 nixos-container status "$client" | grep -F "up" >/dev/null
          done
          ${fixtureStaticChecks}
          ${fixtureDhcpChecks}
        }
        for _ in $(seq 1 120); do
          if check_endpoints; then
            printf 'ready\n' > "$marker"
            exit 0
          fi
          sleep 2
        done
        check_endpoints
        printf 'ready\n' > "$marker"
      '';

      # Collect unique bridge names from CPM-built containers
      clientBridges = lib.unique (
        builtins.map
          (container:
            if container ? hostBridge then container.hostBridge else null
          )
          (builtins.attrValues clientContainers)
      );
      # Effective bridges = container bridges + VLAN bridge names
      # (VLAN bridges like mgmt are host infrastructure, not endpoint assignment)
      effectiveBridges = builtins.filter (b: b != null) (
        clientBridges ++ (builtins.attrNames vlanBridges)
      );

      # VLAN configuration from inventory bridge networks
      bridgeVlanConfig = getBridgeVlanConfig resolvedInventoryPath hostName;
      vlanBridges = lib.filterAttrs (_name: cfg: cfg != null) bridgeVlanConfig;

      # Netdevs: VLAN interfaces + bridges
      vlanNetdevs = lib.mapAttrs'
        (bridgeName: vlanCfg: {
          name = "40-${vlanCfg.parent}.${toString vlanCfg.vlanId}";
          value = mkVlanNetdev bridgeName vlanCfg;
        })
        vlanBridges;

      bridgeNetdevs = lib.genAttrs effectiveBridges mkClientBridge;

      # Networks: VLAN network configs + bridge network configs
      vlanNetworks = lib.mapAttrs'
        (bridgeName: vlanCfg: {
          name = "40-${vlanCfg.parent}.${toString vlanCfg.vlanId}";
          value = mkVlanNetwork vlanCfg bridgeName;
        })
        vlanBridges;

      bridgeNetworks = lib.genAttrs effectiveBridges (name: mkClientBridgeNetwork name);

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

      systemd.network.netdevs = vlanNetdevs // bridgeNetdevs;
      systemd.network.networks = vlanNetworks // bridgeNetworks // {
        "10-eth0".networkConfig.VLAN = map
          (vlanCfg: "${vlanCfg.parent}.${toString vlanCfg.vlanId}")
          (builtins.attrValues vlanBridges);
      };

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

      systemd.services.s-router-test-clients-endpoint-ready = lib.mkIf (fixtureEndpointClients != { }) {
        description = "Wait for all endpoint fixture containers to be up and configured";
        wantedBy = [ "multi-user.target" ];
        after = map (name: "container@${name}.service") fixtureEndpointNames;
        requires = map (name: "container@${name}.service") fixtureEndpointNames;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = endpointReadyScript;
        };
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
      # GAMP: FS-310-HDS-010-SDS-010-SMS-110 — renderer invocation parameter, caller must supply
      hostName = rendererInput.hostName or "s-router-test-clients";
      # GAMP: FS-310-HDS-010-SDS-010-SMS-110 — renderer invocation parameter, caller must supply
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
      # GAMP: FS-310-HDS-010-SDS-010-SMS-110 — renderer invocation parameter, caller must supply
      mode = rendererInput.mode or "test";
      # GAMP: FS-310-HDS-010-SDS-010-SMS-110 — renderer invocation parameter, caller must supply
      siteName = rendererInput.siteName or "site-a";
    };

in
{
  inherit hostModule hostModuleFromPaths;
}
