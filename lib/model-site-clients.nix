{ builders
, intent
, inventory
, lib
, pkgs
, runtimeTargets ? { }
, siteName
, enterpriseName ? builtins.head (builtins.attrNames intent)
, endpointNames ? null
, endpointAddressing ? "static"
,
}:

let
  enterprise = intent.${enterpriseName};
  site = enterprise.${siteName};

  addrPart = cidr: builtins.elemAt (lib.splitString "/" cidr) 0;
  prefixPart = cidr: builtins.elemAt (lib.splitString "/" cidr) 1;

  hasPrefix = prefix: value: lib.hasPrefix prefix value;
  removePrefix = prefix: value: lib.removePrefix prefix value;

  invNodes = inventory.realization.nodes or { };

  accessNodes = lib.filterAttrs
    (
      _: node:
        (if node ? logicalNode && node.logicalNode ? site then node.logicalNode.site else null) == siteName
        && hasPrefix "${siteName}-router-access-" (if node ? logicalNode && node.logicalNode ? name then node.logicalNode.name else "")
    )
    invNodes;

  tenantPortNames =
    node:
    builtins.filter (name: hasPrefix "tenant-" name) (builtins.attrNames (if node ? ports then node.ports else { }));

  tenantFromPortName = removePrefix "tenant-";

  accessTenants = lib.unique (
    map tenantFromPortName (lib.concatMap tenantPortNames (builtins.attrValues accessNodes))
  );

  sitePrefixes = if site ? ownership && site.ownership ? prefixes then site.ownership.prefixes else [ ];

  tenantPrefixes = builtins.listToAttrs (
    map
      (prefix: {
        name = prefix.name;
        value = prefix;
      })
      (builtins.filter (prefix: (if prefix ? kind then prefix.kind else null) == "tenant") sitePrefixes)
  );

  # Pre-compute tenant prefix lookup to avoid `or` in nested functions
  tenantPrefixLookup =
    tenant:
    if builtins.hasAttr tenant tenantPrefixes then
      tenantPrefixes.${tenant}
    else
      throw "access-endpoint-renderer: no ${siteName} tenant prefix intent for ${tenant}";

  accessNodeEntryForTenant =
    tenant:
    let
      portName = "tenant-${tenant}";
      matches = builtins.filter (entry: builtins.hasAttr portName (if entry.value ? ports then entry.value.ports else { })) (
        lib.attrsToList accessNodes
      );
    in
    if matches == [ ] then
      throw "access-endpoint-renderer: no ${siteName} access node realizes tenant ${tenant}"
    else
      builtins.head matches;

  firstAdvertisement =
    target: group: interfaceName:
    let
      targetAds = if target ? advertisements then target.advertisements else { };
      entries = if builtins.hasAttr group targetAds then targetAds.${group} else [ ];
      matches = builtins.filter
        (
          entry:
            (if entry ? bindInterface then entry.bindInterface else null) == interfaceName
            || (if entry ? interface then entry.interface else null) == interfaceName
            || (if entry ? routerInterface && entry.routerInterface ? logicalInterface then entry.routerInterface.logicalInterface else null) == interfaceName
        )
        entries;
    in
    if matches == [ ] then null else builtins.head matches;

  advertisementGateway =
    advertisement: family:
    if advertisement == null then
      null
    else if advertisement ? routerAddress then
      advertisement.routerAddress
    else if advertisement ? authoritativeRouterAddress then
      advertisement.authoritativeRouterAddress
    else if family == 4 then
      if advertisement ? router then advertisement.router
      else if advertisement ? routerInterface && advertisement.routerInterface ? address4 then advertisement.routerInterface.address4
      else null
    else
      if advertisement ? routerInterface && advertisement.routerInterface ? address6 then advertisement.routerInterface.address6
      else null;

  # Pre-compute tenant runtime data to avoid `or` in nested functions
  allTenantRuntime = builtins.listToAttrs (
    map
      (tenant:
        let
          nodeEntry = accessNodeEntryForTenant tenant;
          node = nodeEntry.value;
          port = node.ports."tenant-${tenant}";
          prefix = tenantPrefixLookup tenant;
          runtimeTargetKey = "esp.${siteName}.${nodeEntry.name}";
          target =
            if builtins.hasAttr runtimeTargetKey runtimeTargets then
              runtimeTargets.${runtimeTargetKey}
            else
              throw "access-endpoint-renderer: no renderer runtime target for ${runtimeTargetKey}";
          dhcp4 = firstAdvertisement target "dhcp4" port.logicalInterface;
          ipv6Ra = firstAdvertisement target "ipv6Ra" port.logicalInterface;
          gw4 = advertisementGateway dhcp4 4;
          gw6 = advertisementGateway ipv6Ra 6;
          hasRuntimeRoutedIPv6 =
            ipv6Ra != null
            && ipv6Ra ? routedPrefixes
            && builtins.isList ipv6Ra.routedPrefixes
            && ipv6Ra.routedPrefixes != [ ];
        in
        {
          name = tenant;
          value = {
            bridge = port.attach.bridge;
            gw4 =
              if gw4 != null then
                gw4
              else
                throw "access-endpoint-renderer: no rendered IPv4 router advertisement for ${nodeEntry.name}.${port.logicalInterface}";
            gw6 =
              if gw6 != null then
                gw6
              else
                throw "access-endpoint-renderer: no rendered IPv6 router advertisement for ${nodeEntry.name}.${port.logicalInterface}";
            prefix4 = prefixPart prefix.ipv4;
            prefix6 = prefixPart prefix.ipv6;
            ipv6AcceptRA = hasRuntimeRoutedIPv6;
          };
        }
      )
      accessTenants
  );

  tenantRuntime =
    tenant:
    if builtins.hasAttr tenant allTenantRuntime then
      allTenantRuntime.${tenant}
    else
      throw "access-endpoint-renderer: no runtime data for tenant ${tenant}";

  siteCommunicationContract = if site ? communicationContract then site.communicationContract else { };
  siteTrafficTypes = if siteCommunicationContract ? trafficTypes then siteCommunicationContract.trafficTypes else [ ];

  trafficTypes = builtins.listToAttrs (
    map
      (trafficType: {
        name = trafficType.name;
        value = trafficType;
      })
      siteTrafficTypes
  );

  siteServices = if siteCommunicationContract ? services then siteCommunicationContract.services else [ ];

  portsForProvider =
    provider:
    let
      providerServices = builtins.filter (service: builtins.elem provider (if service ? providers then service.providers else [ ])) siteServices;
      matches = lib.concatMap
        (
          service:
          let
            trafficType = if builtins.hasAttr service.trafficType trafficTypes then trafficTypes.${service.trafficType} else { match = [ ]; };
          in
            if trafficType ? match then trafficType.match else [ ]
        )
        providerServices;
      portsForProto =
        proto:
        lib.unique (
          lib.concatMap (match: if (if match ? proto then match.proto else null) == proto then (if match ? dports then match.dports else [ ]) else [ ]) matches
        );
    in
    {
      tcp = portsForProto "tcp";
      udp = portsForProto "udp";
    };

  listenerModule =
    provider: ports:
    {
      networking.firewall.allowedTCPPorts = ports.tcp;
      networking.firewall.allowedUDPPorts = ports.udp;
      systemd.services =
        builtins.listToAttrs
          (
            map
              (port: {
                name = "fixture-${provider}-tcp-${toString port}";
                value = {
                  wantedBy = [ "multi-user.target" ];
                  serviceConfig = {
                    ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:${toString port},reuseaddr,fork -";
                    Restart = "always";
                  };
                };
              })
              ports.tcp
          )
        // builtins.listToAttrs (
          map
            (port: {
              name = "fixture-${provider}-udp-${toString port}";
              value = {
                wantedBy = [ "multi-user.target" ];
                serviceConfig = {
                  ExecStart = "${pkgs.socat}/bin/socat -u UDP-LISTEN:${toString port},reuseaddr,fork -";
                  Restart = "always";
                };
              };
            })
            ports.udp
        );
    };

  containerName =
    endpointName:
    if hasPrefix "${siteName}-" endpointName then endpointName else "${siteName}-${endpointName}";

  siteEndpoints = if site ? ownership && site.ownership ? endpoints then site.ownership.endpoints else [ ];

  invEndpoints = if inventory ? endpoints then inventory.endpoints else { };

  endpointContainer =
    endpoint:
    let
      runtime = tenantRuntime endpoint.tenant;
      endpointAddrs = invEndpoints.${endpoint.name};
      addr4 = builtins.head endpointAddrs.ipv4;
      addr6 = builtins.head endpointAddrs.ipv6;
      ports = portsForProvider endpoint.name;
      name = containerName endpoint.name;
    in
    {
      inherit name;
      value = {
        autoStart = true;
        privateNetwork = true;
        hostBridge = runtime.bridge;
        config =
          if endpointAddressing == "dhcp" then
            moduleArgs:
            lib.mkMerge (
              [
                ((builders.mkDhcpEndpoint {
                  hostname = name;
                }) moduleArgs)
              ]
              ++ lib.optional (ports.tcp != [ ] || ports.udp != [ ]) (listenerModule name ports)
            )
          else if endpointAddressing == "static" then
            builders.mkStaticEndpoint {
              hostname = name;
              addr4 = "${addr4}/${runtime.prefix4}";
              gw4 = runtime.gw4;
              addr6 = "${addr6}/${runtime.prefix6}";
              gw6 = runtime.gw6;
              ipv6AcceptRA = runtime.ipv6AcceptRA;
              extraModules = lib.optional (ports.tcp != [ ] || ports.udp != [ ]) (listenerModule name ports);
            }
          else
            throw "access-endpoint-renderer: unsupported endpointAddressing ${endpointAddressing}";
      };
    };

  endpointIsHostContainer =
    endpoint:
    let
      runtime = tenantRuntime endpoint.tenant;
      endpointAddrs =
        if builtins.hasAttr endpoint.name invEndpoints then
          invEndpoints.${endpoint.name}
        else
          null;
    in
    endpoint.kind == "host"
    && builtins.elem endpoint.tenant accessTenants
    && endpointAddrs != null
    && builtins.head endpointAddrs.ipv4 != runtime.gw4
    && builtins.head endpointAddrs.ipv6 != runtime.gw6;

  endpointIsSelected =
    endpoint:
    endpointNames == null || builtins.elem endpoint.name endpointNames;
in
builtins.listToAttrs (
  map endpointContainer (builtins.filter (endpoint: endpointIsSelected endpoint && endpointIsHostContainer endpoint) siteEndpoints)
)
