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

  runtimeAddressAssignmentsFor = name: assignment:
    let
      raw = assignment.runtimeAddressAssignments or [ ];
      pow2 = exponent: builtins.foldl' (value: _: value * 2) 1 (lib.replicate exponent null);
      invalid = index: detail:
        throw "FS-230-HDS-010-SDS-010-SMS-040: endpointAssignment.${name}.runtimeAddressAssignments[${toString index}] ${detail}";
      normalize = index: runtime:
        if !builtins.isAttrs runtime then
          invalid index "must be an attribute set"
        else if (runtime.family or null) != "ipv6" then
          invalid index "must declare family=ipv6"
        else if (runtime.sourceClass or null) != "protected" then
          invalid index "must declare sourceClass=protected"
        else if !builtins.isString (runtime.sourceFile or null)
          || !(lib.hasPrefix "/run/secrets/" runtime.sourceFile)
          || runtime.sourceFile == "/run/secrets/" then
          invalid index "must reference a non-empty /run/secrets/... sourceFile"
        else if !builtins.isInt (runtime.delegatedPrefixLength or null)
          || runtime.delegatedPrefixLength < 0
          || runtime.delegatedPrefixLength > 64 then
          invalid index "has an invalid delegatedPrefixLength"
        else if !builtins.isInt (runtime.perTenantPrefixLength or null)
          || runtime.perTenantPrefixLength < runtime.delegatedPrefixLength
          || runtime.perTenantPrefixLength > 64 then
          invalid index "has an invalid perTenantPrefixLength"
        else if !builtins.isInt (runtime.slot or null)
          || runtime.slot < 0
          || runtime.slot >= pow2 (runtime.perTenantPrefixLength - runtime.delegatedPrefixLength) then
          invalid index "has a slot outside the delegated prefix"
        else if !builtins.isString (runtime.interfaceIdentifier or null)
          || runtime.interfaceIdentifier == "" then
          invalid index "must declare a non-empty interfaceIdentifier"
        else if (runtime.prefixLength or null) != 128 then
          invalid index "must declare prefixLength=128"
        else if !builtins.isString (runtime.interfaceName or null)
          || runtime.interfaceName == "" then
          invalid index "must declare a non-empty interfaceName"
        else
          {
            inherit (runtime)
              delegatedPrefixLength
              family
              interfaceIdentifier
              interfaceName
              perTenantPrefixLength
              prefixLength
              slot
              sourceClass
              sourceFile
              ;
          };
    in
    if !builtins.isList raw then
      throw "FS-230-HDS-010-SDS-010-SMS-040: endpointAssignment.${name}.runtimeAddressAssignments must be a list"
    else
      lib.imap0 normalize raw;

  buildEndpointContainer = name: assignment:
    let
      mode =
        if assignment ? mode then
          assignment.mode
        else
          throw "FS-310-HDS-030-SDS-010-SMS-110: endpointAssignment.${name}.mode is missing; FS-720-HDS-030-SDS-010-SMS-041: MISSING_CPM_CONTRACT_FIELD MODE_INFERENCE_REJECTED: endpoint endpointAssignment.${name}.mode is missing; renderer refuses inferred assignment mode";
      hostBridge = endpointBridge name assignment;
      hostname = assignment.name or name;
      static = assignment.static or { };
      dhcp = assignment.dhcp or { };
      hasExplicitDhcpContract = assignment ? dhcp;
      dhcp4 = (dhcp ? servedPrefix4) || !hasExplicitDhcpContract;
      dhcp6 = dhcp ? servedPrefix6;
      runtimeAddressAssignments = runtimeAddressAssignmentsFor name assignment;
      requireStatic = attr:
        if builtins.hasAttr attr static then
          static.${attr}
        else
          throw (
            if attr == "gateway4" then
              "FS-310-HDS-030-SDS-010-SMS-110: MISSING_CPM_STATIC_ADDRESS_FIELD: static endpoint endpointAssignment.${name} no gateway4; static.gateway4 missing; FS-720-HDS-030-SDS-010-SMS-041: HARDCODED_DEFAULT_REJECTED MISSING_CPM_CONTRACT_FIELD: endpoint endpointAssignment.${name}.static.gateway4 missing; renderer refuses hardcoded gateway default"
            else if attr == "gateway6" then
              "FS-310-HDS-030-SDS-010-SMS-110: MISSING_CPM_STATIC_ADDRESS_FIELD: static endpoint endpointAssignment.${name} no gateway6; static.gateway6 missing; FS-720-HDS-030-SDS-010-SMS-041: HARDCODED_DEFAULT_REJECTED MISSING_CPM_CONTRACT_FIELD: endpoint endpointAssignment.${name}.static.gateway6 missing; renderer refuses hardcoded gateway default"
            else if attr == "address" then
              "FS-310-HDS-030-SDS-010-SMS-110: MISSING_CPM_FIXTURE_FIELD: static endpoint endpointAssignment.${name}.static.address missing; FS-720-HDS-030-SDS-010-SMS-041: HARDCODED_DEFAULT_REJECTED MISSING_CPM_CONTRACT_FIELD: endpoint endpointAssignment.${name}.static.address missing; renderer refuses hardcoded address default"
            else if attr == "prefixLength" then
              "FS-310-HDS-030-SDS-010-SMS-110: MISSING_CPM_FIXTURE_FIELD: static endpoint endpointAssignment.${name}.static.prefixLength missing; FS-720-HDS-030-SDS-010-SMS-041: HARDCODED_DEFAULT_REJECTED MISSING_CPM_CONTRACT_FIELD: endpoint endpointAssignment.${name}.static.prefixLength missing; renderer refuses hardcoded prefix-length default"
            else
              "FS-310-HDS-030-SDS-010-SMS-110: MISSING_CPM_FIXTURE_FIELD: static endpoint endpointAssignment.${name}.static.${attr} missing; FS-720-HDS-030-SDS-010-SMS-041: HARDCODED_DEFAULT_REJECTED MISSING_CPM_CONTRACT_FIELD: endpoint endpointAssignment.${name}.static.${attr} missing; renderer refuses hardcoded static-field default"
          );
      staticModule = clientBuilders.mkStaticEndpoint {
        inherit hostname;
        inherit runtimeAddressAssignments;
        addr4 = "${requireStatic "address"}/${toString (requireStatic "prefixLength")}";
        addr6 = "${requireStatic "address6"}/${toString (requireStatic "prefixLength6")}";
        gw4 = requireStatic "gateway4";
        gw6 = requireStatic "gateway6";
        dnsServers = static.dnsServers or [
          (requireStatic "gateway4")
          (requireStatic "gateway6")
        ];
      };
      dhcpModule = clientBuilders.mkDhcpEndpoint {
        inherit hostname dhcp4 dhcp6;
      };
      runtimeSourceMounts = builtins.listToAttrs (
        map
          (runtime: {
            name = runtime.sourceFile;
            value = {
              hostPath = runtime.sourceFile;
              isReadOnly = true;
            };
          })
          runtimeAddressAssignments
      );
      mkContainer = module:
        builtins.deepSeq runtimeAddressAssignments {
          autoStart = true;
          privateNetwork = true;
          inherit hostBridge;
          config = module;
          bindMounts = runtimeSourceMounts;
        };
    in
    if mode == "dhcp" && runtimeAddressAssignments != [ ] then
      throw "FS-230-HDS-010-SDS-010-SMS-040: endpointAssignment.${name}.runtimeAddressAssignments require an explicit static endpoint assignment"
    else if mode == "dhcp" then
      mkContainer dhcpModule
    else if mode == "static" || mode == "static-only" then
      mkContainer staticModule
    else
      throw "FS-310-HDS-030-SDS-010-SMS-110: endpointAssignment.${name} unsupported mode '${mode}'";

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
    , sopsModule ? null
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
      hostUplinks =
        if builtins.isAttrs (cpmOutput.uplinks or null) then
          cpmOutput.uplinks
        else if builtins.isAttrs (cpmOutput.deploymentHosts.${hostName}.uplinks or null) then
          cpmOutput.deploymentHosts.${hostName}.uplinks
        else if builtins.isAttrs (cpmOutput.control_plane_model.deployment.hosts.${hostName}.uplinks or null) then
          cpmOutput.control_plane_model.deployment.hosts.${hostName}.uplinks
        else
          { };
      cpmBridgeNetworks = hostBridgeNetworks;
      hostUplinkNames = sortedAttrNames hostUplinks;
      hostUplinkBridgeNames =
        builtins.filter
          (bridge: builtins.isString bridge && bridge != "")
          (map (uplinkName: hostUplinks.${uplinkName}.bridge or null) hostUplinkNames);
      endpointAssignmentNames = sortedAttrNames endpointAssignments;
      runtimeAddressAssignmentNames =
        builtins.filter
          (name: runtimeAddressAssignmentsFor name endpointAssignments.${name} != [ ])
          endpointAssignmentNames;
      runtimeContainerDependencies = builtins.listToAttrs (
        map
          (name: {
            name = "container@${name}";
            value = {
              after = [ "sops-nix.service" ];
              wants = [ "sops-nix.service" ];
            };
          })
          runtimeAddressAssignmentNames
      );
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

      _hostParticipationGuard =
        let
          hostServiceFields = [ "dhcpServer" "DHCPServer" "dns" "DNS" "nat" "NAT" "gateway" "Gateway" "firewall" "Firewall" "IPMasquerade" ];
          checkBridge = _name: bridgeData:
            let
              fields = if builtins.isAttrs bridgeData then builtins.attrNames bridgeData else [ ];
              violations = builtins.filter (f: builtins.elem f hostServiceFields) fields;
              active = builtins.filter
                (f:
                  let v = bridgeData.${f};
                  in v == true || v == "yes" || v == "enabled" || (builtins.isAttrs v && (v.enabled or false) == true))
                violations;
            in
            if active != [ ] then
              throw "FS-983-HDS-010-SDS-010-SMS-010: HOST_PARTICIPATION_VIOLATION: bridge ${_name} declares host-side service(s) ${builtins.concatStringsSep "," active}; s-router-test-clients host must not provision DHCP server, DNS, NAT, gateway, or endpoint firewall per FS-725"
            else
              true;
        in
        if builtins.isAttrs cpmBridgeNetworks then
          builtins.deepSeq (builtins.mapAttrs checkBridge cpmBridgeNetworks) true
        else
          true;

      clientContainersRaw =
        builtins.seq _cpmStructureValid (
          builtins.seq _endpointAssignmentPresent (
            builtins.seq _unauthorizedInventoryFallback (
              builtins.seq _managementBridgeContract (
                builtins.seq _hostParticipationGuard (
                if cpmOutput ? containers then
                  cpmOutput.containers
                else
                  buildContainersFromAssignment endpointAssignments
                )
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
          ++ hostUplinkBridgeNames
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
          ++ map renderedBridgeName hostUplinkBridgeNames
        );

      vlanBridgeNames =
        builtins.filter
          (bridgeName: (cpmBridgeNetworks.${bridgeName}.mode or null) == "vlan")
          (builtins.attrNames cpmBridgeNetworks);

      vlanUplinkNames =
        builtins.filter
          (uplinkName: (hostUplinks.${uplinkName}.mode or null) == "vlan")
          hostUplinkNames;

      requireBridgeNetworkField = bridgeName: field:
        let bridgeNetwork = cpmBridgeNetworks.${bridgeName};
        in
        if builtins.hasAttr field bridgeNetwork && bridgeNetwork.${field} != "" then
          bridgeNetwork.${field}
        else if field == "parent" then
          throw "FS-310-HDS-030-SDS-010-SMS-110 FS-720-HDS-010-SDS-010-SMS-050: bridgeNetworks.${bridgeName}.parent is missing"
        else if field == "vlan" then
          throw "FS-720-HDS-010-SDS-010-SMS-050: bridgeNetworks.${bridgeName}.vlan is missing"
        else
          throw "FS-720-HDS-010-SDS-010-SMS-050: bridgeNetworks.${bridgeName}.${field} is missing";

      requireUplinkField = uplinkName: field:
        let uplink = hostUplinks.${uplinkName};
        in
        if builtins.hasAttr field uplink && uplink.${field} != "" then
          uplink.${field}
        else if field == "parent" then
          throw "FS-725-HDS-020-SDS-010-SMS-010: uplinks.${uplinkName}.parent is missing"
        else if field == "vlan" then
          throw "FS-725-HDS-020-SDS-010-SMS-010: uplinks.${uplinkName}.vlan is missing"
        else if field == "bridge" then
          throw "FS-725-HDS-020-SDS-010-SMS-010: uplinks.${uplinkName}.bridge is missing"
        else
          throw "FS-725-HDS-020-SDS-010-SMS-010: uplinks.${uplinkName}.${field} is missing";

      parentIfNames =
        lib.unique (
          (builtins.filter builtins.isString (map
            (bridgeName:
              let bridgeNetwork = cpmBridgeNetworks.${bridgeName};
              in if builtins.isString (bridgeNetwork.parent or null) && bridgeNetwork.parent != "" then bridgeNetwork.parent else null)
            (builtins.attrNames cpmBridgeNetworks)))
          ++ (builtins.filter builtins.isString (map
            (uplinkName:
              let uplink = hostUplinks.${uplinkName};
              in if builtins.isString (uplink.parent or null) && uplink.parent != "" then uplink.parent else null)
            hostUplinkNames))
        );

      bridgeNetworkVlanIfNameFor = bridgeName:
        "${requireBridgeNetworkField bridgeName "parent"}.${toString (requireBridgeNetworkField bridgeName "vlan")}";

      uplinkVlanIfNameFor = uplinkName:
        "${requireUplinkField uplinkName "parent"}.${toString (requireUplinkField uplinkName "vlan")}";

      directBridgeNamesForParent = parentIf:
        (map renderedBridgeName (builtins.filter
          (bridgeName:
            let bridgeNetwork = cpmBridgeNetworks.${bridgeName};
            in (bridgeNetwork.mode or null) != "vlan"
              && (bridgeNetwork.parent or null) == parentIf)
          (builtins.attrNames cpmBridgeNetworks)))
        ++ (map
          (uplinkName: renderedBridgeName (requireUplinkField uplinkName "bridge"))
          (builtins.filter
            (uplinkName:
              let uplink = hostUplinks.${uplinkName};
              in (uplink.mode or null) != "vlan"
                && (uplink.parent or null) == parentIf)
            hostUplinkNames));

      vlanChildrenForParent = parentIf:
        (map bridgeNetworkVlanIfNameFor (builtins.filter
          (bridgeName:
            let bridgeNetwork = cpmBridgeNetworks.${bridgeName};
            in (bridgeNetwork.mode or null) == "vlan"
              && (bridgeNetwork.parent or null) == parentIf)
          (builtins.attrNames cpmBridgeNetworks)))
        ++ (map uplinkVlanIfNameFor (builtins.filter
          (uplinkName:
            let uplink = hostUplinks.${uplinkName};
            in (uplink.mode or null) == "vlan"
              && (uplink.parent or null) == parentIf)
          hostUplinkNames));

      parentNetworks =
        builtins.listToAttrs (
          map
            (parentIf:
              let
                vlanChildrenRaw = vlanChildrenForParent parentIf;
                _vlanNoCollision =
                  if builtins.length vlanChildrenRaw == builtins.length (lib.unique vlanChildrenRaw) then
                    true
                  else
                    throw "FS-040-HDS-010-SDS-010-SMS-020: VLAN identity collision on parent ${parentIf} at host ${hostName}: ${builtins.concatStringsSep "," vlanChildrenRaw}";
                vlanChildren = lib.unique vlanChildrenRaw;
                directBridgeNames = lib.unique (directBridgeNamesForParent parentIf);
                _singleDirectBridge =
                  if builtins.length directBridgeNames <= 1 then
                    true
                  else
                    throw "FS-040-HDS-010-SDS-010-SMS-020: multiple non-vlan host attachments on parent ${parentIf} at host ${hostName}: ${builtins.concatStringsSep "," directBridgeNames}";
              in
              builtins.seq _vlanNoCollision (builtins.seq _singleDirectBridge {
                name = "20-${parentIf}";
                value = {
                  linkConfig = {
                    ActivationPolicy = "always-up";
                    RequiredForOnline = "no";
                  };
                  matchConfig.Name = parentIf;
                  networkConfig = {
                    ConfigureWithoutCarrier = true;
                    DHCP = "no";
                    IPv6AcceptRA = false;
                    LinkLocalAddressing = "no";
                  }
                  // lib.optionalAttrs (vlanChildren != [ ]) { VLAN = vlanChildren; }
                  // lib.optionalAttrs (builtins.length directBridgeNames == 1) {
                    Bridge = builtins.head directBridgeNames;
                  };
                };
              }))
            parentIfNames
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

      uplinkVlanNetdevs =
        builtins.listToAttrs (
          map
            (uplinkName:
              let
                parent = requireUplinkField uplinkName "parent";
                vlan = requireUplinkField uplinkName "vlan";
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
            vlanUplinkNames
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

      uplinkVlanNetworks =
        builtins.listToAttrs (
          map
            (uplinkName:
              let
                parent = requireUplinkField uplinkName "parent";
                vlan = requireUplinkField uplinkName "vlan";
                bridge = renderedBridgeName (requireUplinkField uplinkName "bridge");
              in
              {
                name = "40-${parent}.${toString vlan}";
                value = {
                  matchConfig.Name = "${parent}.${toString vlan}";
                  networkConfig = {
                    Bridge = bridge;
                    DHCP = "no";
                    IPv6AcceptRA = false;
                    LinkLocalAddressing = "no";
                  };
                };
              })
            vlanUplinkNames
        );

      hostUplinkNameForRenderedBridge = renderedBridge:
        let
          matches =
            builtins.filter
              (uplinkName:
                builtins.isString (hostUplinks.${uplinkName}.bridge or null)
                && renderedBridgeName hostUplinks.${uplinkName}.bridge == renderedBridge)
              hostUplinkNames;
        in
        if matches == [ ] then null else builtins.head matches;

      uplinkIpv4Dhcp = uplink:
        uplink ? ipv4
        && builtins.isAttrs uplink.ipv4
        && ((uplink.ipv4.dhcp or false) || (uplink.ipv4.method or null) == "dhcp");

      uplinkIpv6Dhcp = uplink:
        uplink ? ipv6
        && builtins.isAttrs uplink.ipv6
        && ((uplink.ipv6.dhcp or false) || (uplink.ipv6.method or null) == "dhcp" || (uplink.ipv6.method or null) == "dhcp6");

      uplinkIpv6AcceptRA = uplink:
        uplink ? ipv6
        && builtins.isAttrs uplink.ipv6
        && ((uplink.ipv6.acceptRA or false) || (uplink.ipv6.method or null) == "slaac");

      isManagementUplink = uplinkName: uplink:
        uplinkName == "management"
        || (uplink.management or false) == true
        || (uplink.role or null) == "management";

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
            (bridge:
              let
                uplinkName = hostUplinkNameForRenderedBridge bridge;
                uplink = if uplinkName == null then { } else hostUplinks.${uplinkName};
                managementUplink = uplinkName != null && isManagementUplink uplinkName uplink;
                hostIpv4Dhcp = managementUplink && uplinkIpv4Dhcp uplink;
                hostIpv6Dhcp = managementUplink && uplinkIpv6Dhcp uplink;
                hostIpv6RA = managementUplink && uplinkIpv6AcceptRA uplink;
                dhcpMode =
                  if hostIpv4Dhcp && hostIpv6Dhcp then "yes"
                  else if hostIpv4Dhcp then "ipv4"
                  else if hostIpv6Dhcp then "ipv6"
                  else "no";
              in
              {
                name = bridge;
                value = {
                  linkConfig.ActivationPolicy = "always-up";
                  matchConfig.Name = bridge;
                  networkConfig = {
                    DHCP = dhcpMode;
                    ConfigureWithoutCarrier = true;
                    IPv6AcceptRA = hostIpv6RA;
                    LinkLocalAddressing = if hostIpv6Dhcp || hostIpv6RA then "ipv6" else "no";
                  };
                };
              })
            effectiveBridges
        );
    in
    {
      # Secret delivery is a consumer-selected realization module. The
      # renderer composes that explicit module into the host without reading,
      # decrypting, copying, or inferring protected values.
      imports = lib.optional (sopsModule != null) sopsModule;

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

      systemd.network.netdevs = bridgeNetdevs // vlanNetdevs // uplinkVlanNetdevs;
      systemd.network.networks = bridgeNetworks // parentNetworks // vlanNetworks // uplinkVlanNetworks;

      containers = clientContainers;

      users.users.root.openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAqEmMbztRhj2zE1dXf5Z+Ow7mXXXE6sNAG4/hrIOrmD deadbeef@codex-jail"
      ];

      systemd.services = runtimeContainerDependencies // {
        access-endpoint-renderer-dummy.enable = lib.mkForce false;

        s-router-test-clients-endpoint-ready = {
          description = "Endpoint fixture containers are rendered";
          wantedBy = [ "multi-user.target" ];
          after = [ "sops-nix.service" ];
          wants = [ "sops-nix.service" ];
          serviceConfig.Type = "oneshot";
          script = "true";
        };

        access-endpoint-isolate-bridges = {
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
    { # FS-310-HDS-030-SDS-010-SMS-110: caller must supply hostName for non-default harness targets.
      hostName ? "s-router-test-clients"
    , # FS-310-HDS-030-SDS-010-SMS-110: caller must supply labSource for non-default lab sources.
      labSource ? "active-lab"
    , intentPath ? null
    , inventoryPath ? null
    , clientsPath ? null
    , routingSopsPath ? null
    , # FS-310-HDS-030-SDS-010-SMS-110: caller must supply mode for non-test materialization.
      mode ? "test"
    , # FS-310-HDS-030-SDS-010-SMS-110: caller must supply siteName for non-default site targets.
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
    hostModuleFromCpmOutput {
      inherit cpmOutput hostName mode;
      sopsModule =
        if routingSopsPath == null then
          null
        else if builtins.isString routingSopsPath then
          builtins.toPath routingSopsPath
        else
          routingSopsPath;
    };

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
        # FS-310-HDS-030-SDS-010-SMS-110: caller must supply mode for non-test materialization.
        mode = rendererInput.mode or "test";
        sopsModule =
          let
            selected = rendererInput.sops or null;
          in
          if selected == null then
            null
          else if builtins.isString selected then
            builtins.toPath selected
          else
            selected;
      }
    else
      throw "network-renderer-access-endpoint-nixos.hostModule: 'cpm' or 'controlPlane' is required; use hostModuleFromPaths for path-based rendering";

in
{
  inherit hostModule hostModuleFromPaths;
}
