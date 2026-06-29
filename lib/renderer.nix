{ system
, pkgs
, lib
, cpm
, network-labs
, self ? null
}:

let
  clientBuilders = import ./client-builders.nix { inherit lib pkgs; };

  sortedAttrNames = attrs: lib.sort builtins.lessThan (builtins.attrNames attrs);

  stringContains = needle: haystack:
    builtins.match ".*${needle}.*" haystack != null;

  secretKeyParts = [ "password" "passphrase" "private" "secret" "token" ];

  keyIsSecret = key:
    let lower = lib.toLower (builtins.toString key);
    in builtins.any (part: stringContains part lower) secretKeyParts;

  safeValue =
    value:
    if builtins.isAttrs value then
      builtins.listToAttrs (
        map
          (key: {
            name = key;
            value = if keyIsSecret key then "<redacted>" else safeValue value.${key};
          })
          (sortedAttrNames value)
      )
    else if builtins.isList value then
      map safeValue value
    else
      value;

  firstAttr =
    values:
    let attrs = builtins.filter builtins.isAttrs values;
    in if attrs == [ ] then { } else builtins.head attrs;

  maxInterfaceNameLength = 15;

  shortenHostBridgeName =
    name:
    if builtins.stringLength name <= maxInterfaceNameLength then
      name
    else
      let
        prefixLength = maxInterfaceNameLength - 7;
        prefix = builtins.substring 0 prefixLength name;
        suffix = builtins.substring 0 6 (builtins.hashString "sha256" name);
      in
      "${prefix}-${suffix}";

  ensureUniqueHostBridgeNames =
    names:
    let
      shortened = map
        (name: {
          original = name;
          rendered = shortenHostBridgeName name;
        })
        names;
      grouped = builtins.foldl'
        (
          acc: entry:
          acc // {
            ${entry.rendered} = (acc.${entry.rendered} or [ ]) ++ [ entry.original ];
          }
        )
        { }
        shortened;
      collisions = lib.filterAttrs (_: originals: builtins.length originals > 1) grouped;
    in
    if collisions != { } then
      throw ''
        network-renderer-access-endpoint-nixos: host bridge name collision after shortening

        ${builtins.toJSON collisions}
      ''
    else
      builtins.listToAttrs (
        map
          (entry: {
            name = entry.original;
            value = entry.rendered;
          })
          shortened
      );

  sourceClassesFromMeta = meta:
    if builtins.isAttrs (meta.sourceClasses or null) then safeValue meta.sourceClasses else { };

  missingSourceClasses = classes:
    let
      required = [ "userIntent" "publicInventory" "protectedInventory" ];
      optional = [ "runtimeFacts" "validationContext" ];
    in
    (builtins.filter (name: !(builtins.hasAttr name classes)) required)
    ++ (map (name: "${name}:not-declared") (builtins.filter (name: !(builtins.hasAttr name classes)) optional));

  upstreamLocks = meta:
    safeValue (
      firstAttr [
        (meta.locks or null)
        (meta.lock or null)
        (meta.lockedToolChain or null)
        (meta.toolChainLocks or null)
        (meta.flakeLocks or null)
      ]
    );

  rendererLockSummary =
    let
      lockPath = ../flake.lock;
    in
    if !(builtins.pathExists lockPath) then
      { available = false; }
    else
      let
        lock = builtins.fromJSON (builtins.readFile lockPath);
        nodes = if builtins.isAttrs (lock.nodes or null) then lock.nodes else { };
        lockKeys = [ "type" "owner" "repo" "rev" "narHash" "lastModified" ];
        nodeSummary = name:
          let
            locked = nodes.${name}.locked or { };
            presentKeys = builtins.filter (key: builtins.hasAttr key locked) lockKeys;
          in
          {
            inherit name;
            value = builtins.listToAttrs (map (key: { name = key; value = locked.${key}; }) presentKeys);
          };
      in
      {
        available = true;
        nodes = builtins.listToAttrs (
          builtins.filter (entry: entry.value != { }) (map nodeSummary (sortedAttrNames nodes))
        );
      };

  rendererRevision =
    if self != null && builtins.isString (self.rev or null) then
      self.rev
    else if self != null && builtins.isString (self.dirtyRev or null) then
      self.dirtyRev
    else
      "unknown";

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
    in
    if !(assignment ? bridge) || bridge == null then
      throw "FS-720-HDS-030-SDS-010-SMS-041: MISSING_CPM_BRIDGE_FIELD: endpoint endpointAssignment.${name} has no bridge field; MISSING_CPM_CONTRACT_FIELD endpointAssignment.${name}.bridge is required"
    else if builtins.isString bridge && bridge != "" then
      bridge
    else if builtins.isString bridge && bridge == "" then
      throw "FS-720-HDS-030-SDS-010-SMS-041: AMBIGUOUS_BRIDGE_DEFAULT: endpoint endpointAssignment.${name}.bridge field is empty string; renderer rejects tenant/key bridge fallback"
    else
      throw "FS-720-HDS-030-SDS-010-SMS-041: MISSING_CPM_BRIDGE_FIELD: endpoint endpointAssignment.${name}.bridge must be a non-empty string";

  buildEndpointContainer = name: assignment:
    let
      mode =
        if assignment ? mode then
          assignment.mode
        else
          throw "FS-310-HDS-010-SDS-010-SMS-110: endpointAssignment.${name}.mode is missing; FS-720-HDS-030-SDS-010-SMS-041: MISSING_CPM_CONTRACT_FIELD MODE_INFERENCE_REJECTED: endpoint endpointAssignment.${name}.mode is missing; renderer refuses inferred assignment mode";
      hostBridge = endpointBridge name assignment;
      hostname = assignment.name or name;
      static = assignment.static or { };
      requireStatic = attr:
        if builtins.hasAttr attr static then
          static.${attr}
        else
          throw (
            if attr == "gateway4" then
              "FS-310-HDS-010-SDS-010-SMS-110: MISSING_CPM_STATIC_ADDRESS_FIELD: static endpoint endpointAssignment.${name} no gateway4; static.gateway4 missing; FS-720-HDS-030-SDS-010-SMS-041: HARDCODED_DEFAULT_REJECTED MISSING_CPM_CONTRACT_FIELD: endpoint endpointAssignment.${name}.static.gateway4 missing; renderer refuses hardcoded gateway default"
            else if attr == "gateway6" then
              "FS-310-HDS-010-SDS-010-SMS-110: MISSING_CPM_STATIC_ADDRESS_FIELD: static endpoint endpointAssignment.${name} no gateway6; static.gateway6 missing; FS-720-HDS-030-SDS-010-SMS-041: HARDCODED_DEFAULT_REJECTED MISSING_CPM_CONTRACT_FIELD: endpoint endpointAssignment.${name}.static.gateway6 missing; renderer refuses hardcoded gateway default"
            else if attr == "address" then
              "FS-310-HDS-010-SDS-010-SMS-110: MISSING_CPM_FIXTURE_FIELD: static endpoint endpointAssignment.${name}.static.address missing; FS-720-HDS-030-SDS-010-SMS-041: HARDCODED_DEFAULT_REJECTED MISSING_CPM_CONTRACT_FIELD: endpoint endpointAssignment.${name}.static.address missing; renderer refuses hardcoded address default"
            else if attr == "prefixLength" then
              "FS-310-HDS-010-SDS-010-SMS-110: MISSING_CPM_FIXTURE_FIELD: static endpoint endpointAssignment.${name}.static.prefixLength missing; FS-720-HDS-030-SDS-010-SMS-041: HARDCODED_DEFAULT_REJECTED MISSING_CPM_CONTRACT_FIELD: endpoint endpointAssignment.${name}.static.prefixLength missing; renderer refuses hardcoded prefix-length default"
            else
              "FS-310-HDS-010-SDS-010-SMS-110: MISSING_CPM_FIXTURE_FIELD: static endpoint endpointAssignment.${name}.static.${attr} missing; FS-720-HDS-030-SDS-010-SMS-041: HARDCODED_DEFAULT_REJECTED MISSING_CPM_CONTRACT_FIELD: endpoint endpointAssignment.${name}.static.${attr} missing; renderer refuses hardcoded static-field default"
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

  buildProvenance =
    { cpmOutput
    , mode
    , endpointAssignments
    ,
    }:
    let
      meta = if builtins.isAttrs (cpmOutput.meta or null) then cpmOutput.meta else { };
      requested = firstAttr [
        (meta.requested or null)
        (meta.request or null)
      ];
      derivedScope = {
        endpointAssignments = sortedAttrNames endpointAssignments;
        bridges = lib.unique (
          builtins.filter (bridge: bridge != null) (
            map (name: endpointBridge name endpointAssignments.${name}) (sortedAttrNames endpointAssignments)
          )
        );
        inherit mode;
      };
      scope = firstAttr [
        (requested.scope or null)
        (meta.requestedScope or null)
        derivedScope
      ];
      target = firstAttr [
        (requested.target or null)
        (meta.requestedTarget or null)
        {
          renderer = "access-endpoint-nixos";
          role = "renderer-output";
          derivedFromRenderer = true;
        }
      ];
      classes = sourceClassesFromMeta meta;
      baseline = meta.controlledBaseline or meta.sourceBaseline or null;
    in
    {
      renderer = {
        name = "network-renderer-access-endpoint-nixos";
        schemaVersion = 1;
        gitRev = rendererRevision;
      };
      input = {
        kind = "control-plane-model";
        controlPlaneModelVersion = cpmOutput.version or null;
      };
      output = {
        kind = "access-endpoint-nixos-module";
        artifact = "etc/network-renderer-access-endpoint/provenance.json";
      };
      sources = {
        sourceClasses = classes;
        missingSourceClasses = missingSourceClasses classes;
      };
      requested = {
        scope = safeValue scope;
        target = safeValue target;
        derivedScope = safeValue derivedScope;
      };
      locks = {
        upstream = upstreamLocks meta;
        renderer = rendererLockSummary;
      };
      redaction = {
        protectedValues = "redacted";
      };
    }
    // lib.optionalAttrs (baseline != null) {
      controlledBaseline = safeValue baseline;
    };

  hostModuleFromCpmOutput =
    { cpmOutput
    , hostName ? "s-router-test-clients"
    , mode ? "test"
    ,
    }:

    { config, ... }:

    let
      endpointAssignments = endpointAssignmentsFromCpm cpmOutput;
      provenance = buildProvenance {
        inherit cpmOutput mode endpointAssignments;
      };
      cpmEnterprises = cpmOutput.control_plane_model.data or { };
      enterpriseData = cpmEnterprises;
      siteData = cpmSiteData cpmOutput;
      fixtureEps = { };
      hasTopEndpointAssignments = (cpmOutput.endpointAssignment or { }) != { };
      hasContainers = cpmOutput ? containers && cpmOutput.containers != { };
      _cpmStructureValid =
        if cpmEnterprises == { } && siteData == [ ] && enterpriseData == { } && !hasTopEndpointAssignments && !hasContainers then
          throw "FS-720-HDS-030-SDS-010-SMS-021: MISSING_CPM_CONTRACT_GAP MISSING_CPM_CONTRACT_FIELD WRONG_LAYER_DIRECT_INVENTORY_IMPORT UNAUTHORIZED_FIXTURE_SOURCE: CPM output lacks endpointAssignment data; renderer refuses raw intent/inventory fixture discovery"
        else
          true;
      _endpointAssignmentPresent =
        if endpointAssignments != { } || hasContainers then
          true
        else if cpmEnterprises != { } || siteData != [ ] || enterpriseData != { } then
          true
        else
          throw "FS-720-HDS-030-SDS-010-SMS-021: MISSING_CPM_CONTRACT_GAP MISSING_CPM_CONTRACT_FIELD UNAUTHORIZED_INVENTORY_FALLBACK UNAUTHORIZED_FIXTURE_SOURCE: endpointAssignment is empty; renderer refuses inventory fallback";
      _unauthorizedInventoryFallback =
        if endpointAssignments == { } && fixtureEps != { } then
          throw "FS-720-HDS-030-SDS-010-SMS-021: WRONG_LAYER_DIRECT_INVENTORY_IMPORT UNAUTHORIZED_INVENTORY_FALLBACK UNAUTHORIZED_FIXTURE_SOURCE: fixture endpoint data must come from CPM endpointAssignment, not raw inventory"
        else
          true;
      hostBridgeNetworks =
        if builtins.isAttrs (cpmOutput.bridgeNetworks or null) then
          cpmOutput.bridgeNetworks
        else if builtins.isAttrs (cpmOutput.deploymentHosts.${hostName}.bridgeNetworks or null) then
          cpmOutput.deploymentHosts.${hostName}.bridgeNetworks
        else if builtins.isAttrs (cpmOutput.control_plane_model.deployment.hosts.${hostName}.bridgeNetworks or null) then
          cpmOutput.control_plane_model.deployment.hosts.${hostName}.bridgeNetworks
        else
          { };
      cpmBridgeNetworks = hostBridgeNetworks;
      endpointAssignmentNames = sortedAttrNames endpointAssignments;
      isManagementAssignment = assignment:
        (assignment.role or null) == "management"
        || (assignment.kind or null) == "management"
        || (assignment.managementEndpoint or false) == true;
      managementAssignmentNames =
        builtins.filter
          (name:
            endpointBridge name endpointAssignments.${name} == "mgmt"
            && isManagementAssignment endpointAssignments.${name})
          endpointAssignmentNames;
      mgmtTenantAssignmentNames =
        builtins.filter
          (name:
            endpointBridge name endpointAssignments.${name} == "mgmt"
            && !(isManagementAssignment endpointAssignments.${name}))
          endpointAssignmentNames;
      _managementBridgeContract =
        if mgmtTenantAssignmentNames != [ ] then
          throw "FS-725-HDS-020-SDS-010-SMS-010: MGMT_BRIDGE_ENDPOINT_TRAFFIC: endpoint tenant assignment(s) ${builtins.concatStringsSep "," mgmtTenantAssignmentNames} attach to mgmt bridge; VLAN 2 is management-only"
        else if builtins.hasAttr "mgmt" cpmBridgeNetworks && endpointAssignments != { } && managementAssignmentNames == [ ] then
          throw "FS-725-HDS-020-SDS-010-SMS-010: EMPTY_MANAGEMENT_ENDPOINT_INVENTORY: mgmt bridge is declared but no CPM endpointAssignment has role=management on mgmt bridge"
        else
          true;

      clientContainersRaw =
        builtins.seq _cpmStructureValid (
          builtins.seq _endpointAssignmentPresent (
            builtins.seq _unauthorizedInventoryFallback (
              builtins.seq _managementBridgeContract (
                if cpmOutput ? containers then
                  cpmOutput.containers
                else
                  buildContainersFromAssignment endpointAssignments
              )
            )
          )
        );

      rawClientBridges = lib.unique (
        builtins.map
          (container:
            if container ? hostBridge then container.hostBridge else null
          )
          (builtins.attrValues clientContainersRaw)
      );

      rawEffectiveBridges =
        lib.unique (
          (builtins.filter (bridge: bridge != null) rawClientBridges)
          ++ (builtins.attrNames cpmBridgeNetworks)
        );

      bridgeNameMap = ensureUniqueHostBridgeNames rawEffectiveBridges;

      renderedBridgeName = bridge:
        if builtins.isString bridge && builtins.hasAttr bridge bridgeNameMap then
          bridgeNameMap.${bridge}
        else
          bridge;

      clientContainers = lib.mapAttrs
        (_name: container:
          if builtins.isAttrs container && builtins.isString (container.hostBridge or null) then
            container // { hostBridge = renderedBridgeName container.hostBridge; }
          else
            container)
        clientContainersRaw;

      clientBridges = lib.unique (
        builtins.map
          (container:
            if container ? hostBridge then container.hostBridge else null
          )
          (builtins.attrValues clientContainers)
      );

      effectiveBridges =
        lib.unique (
          builtins.filter (bridge: bridge != null) clientBridges
          ++ map renderedBridgeName (builtins.attrNames cpmBridgeNetworks)
        );

      vlanBridgeNames =
        builtins.filter
          (bridgeName: (cpmBridgeNetworks.${bridgeName}.mode or null) == "vlan")
          (builtins.attrNames cpmBridgeNetworks);

      requireBridgeNetworkField = bridgeName: field:
        let bridgeNetwork = cpmBridgeNetworks.${bridgeName};
        in
        if builtins.hasAttr field bridgeNetwork && bridgeNetwork.${field} != "" then
          bridgeNetwork.${field}
        else if field == "parent" then
          throw "FS-310-HDS-010-SDS-010-SMS-110 FS-720-HDS-010-SDS-010-SMS-050: bridgeNetworks.${bridgeName}.parent is missing"
        else if field == "vlan" then
          throw "FS-720-HDS-010-SDS-010-SMS-050: bridgeNetworks.${bridgeName}.vlan is missing"
        else
          throw "FS-720-HDS-010-SDS-010-SMS-050: bridgeNetworks.${bridgeName}.${field} is missing";

      cpmBridgeParentNetworks =
        builtins.listToAttrs (
          map
            (bridgeName:
              let
                bridgeNetwork = cpmBridgeNetworks.${bridgeName};
                parent =
                  if (bridgeNetwork.mode or null) == "vlan" then
                    null
                  else if builtins.isString (bridgeNetwork.parent or null) && bridgeNetwork.parent != "" then
                    bridgeNetwork.parent
                  else
                    null;
              in
              {
                name = "${bridgeName}-parent";
                value = {
                  matchConfig.Name = parent;
                  networkConfig.Bridge = renderedBridgeName bridgeName;
                };
              })
            (builtins.filter
              (bridgeName:
                let bridgeNetwork = cpmBridgeNetworks.${bridgeName};
                in (bridgeNetwork.mode or null) != "vlan"
                  && builtins.isString (bridgeNetwork.parent or null)
                  && bridgeNetwork.parent != "")
              (builtins.attrNames cpmBridgeNetworks))
        );

      vlanNetdevs =
        builtins.listToAttrs (
          map
            (bridgeName:
              let
                parent = requireBridgeNetworkField bridgeName "parent";
                vlan = requireBridgeNetworkField bridgeName "vlan";
              in
              {
                name = "40-${parent}.${toString vlan}";
                value = {
                  netdevConfig = {
                    Kind = "vlan";
                    Name = "${parent}.${toString vlan}";
                  };
                  vlanConfig.Id = vlan;
                };
              })
            vlanBridgeNames
        );

      vlanNetworks =
        builtins.listToAttrs (
          map
            (bridgeName:
              let
                parent = requireBridgeNetworkField bridgeName "parent";
                vlan = requireBridgeNetworkField bridgeName "vlan";
              in
              {
                name = "40-${parent}.${toString vlan}";
                value = {
                  matchConfig.Name = "${parent}.${toString vlan}";
                  networkConfig = {
                    Bridge = renderedBridgeName bridgeName;
                    DHCP = "no";
                    IPv6AcceptRA = false;
                  };
                };
              })
            vlanBridgeNames
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
                linkConfig.ActivationPolicy = "always-up";
                matchConfig.Name = bridge;
                networkConfig = {
                  DHCP = "no";
                  ConfigureWithoutCarrier = true;
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

      environment.etc."network-renderer-access-endpoint/provenance.json".text =
        builtins.toJSON provenance;

      systemd.network.netdevs = bridgeNetdevs // vlanNetdevs;
      systemd.network.networks = bridgeNetworks // cpmBridgeParentNetworks // vlanNetworks;

      containers = clientContainers;

      users.users.root.openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAqEmMbztRhj2zE1dXf5Z+Ow7mXXXE6sNAG4/hrIOrmD deadbeef@codex-jail"
      ];

      systemd.services.access-endpoint-renderer-dummy.enable = lib.mkForce false;

      systemd.services.s-router-test-clients-endpoint-ready = {
        description = "Endpoint fixture containers are rendered";
        wantedBy = [ "multi-user.target" ];
        after = [ "sops-nix.service" ];
        wants = [ "sops-nix.service" ];
        serviceConfig.Type = "oneshot";
        script = "true";
      };

      systemd.services.access-endpoint-isolate-bridges = {
        description = "Block endpoint bridge egress to host management VLAN";
        wantedBy = [ "multi-user.target" ];
        after = [ "sops-nix.service" "systemd-networkd.service" "network-online.target" ];
        wants = [ "sops-nix.service" "systemd-networkd.service" "network-online.target" ];
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
    hostModuleFromCpmOutput { inherit cpmOutput hostName mode; };

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
        hostName = rendererInput.hostName or "s-router-test-clients";
        # FS-310-HDS-010-SDS-010-SMS-110: caller must supply mode for non-test materialization.
        mode = rendererInput.mode or "test";
      }
    else
      throw "network-renderer-access-endpoint-nixos.hostModule: 'cpm' or 'controlPlane' is required; use hostModuleFromPaths for path-based rendering";

in
{
  inherit hostModule hostModuleFromPaths;
}
