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

  accessNodes = lib.filterAttrs
    (
      _: node:
        (node.logicalNode.site or null) == siteName
        && hasPrefix "${siteName}-router-access-" (node.logicalNode.name or "")
    )
    inventory.realization.nodes;

  tenantPortNames =
    node:
    builtins.filter (name: hasPrefix "tenant-" name) (builtins.attrNames (node.ports or { }));

  tenantFromPortName = removePrefix "tenant-";

  accessTenants = lib.unique (
    map tenantFromPortName (lib.concatMap tenantPortNames (builtins.attrValues accessNodes))
  );

  tenantPrefixes = builtins.listToAttrs (
    map
      (prefix: {
        name = prefix.name;
        value = prefix;
      })
      (builtins.filter (prefix: (prefix.kind or null) == "tenant") (site.ownership.prefixes or [ ]))
  );

  tenantPrefixFor =
    tenant:
      tenantPrefixes.${tenant}
        or (throw "access-endpoint-renderer: no ${siteName} tenant prefix intent for ${tenant}");

  accessNodeEntryForTenant =
    tenant:
    let
      portName = "tenant-${tenant}";
      matches = builtins.filter (entry: builtins.hasAttr portName (entry.value.ports or { })) (
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
      entries = (target.advertisements or { }).${group} or [ ];
      matches = builtins.filter
        (
          entry:
          (entry.bindInterface or null) == interfaceName
          || (entry.interface or null) == interfaceName
          || (entry.routerInterface.logicalInterface or null) == interfaceName
        )
        entries;
    in
    if matches == [ ] then null else builtins.head matches;

  advertisementGateway =
    advertisement: family:
    if advertisement == null then
      null
    else
      advertisement.routerAddress or advertisement.authoritativeRouterAddress or (
        if family == 4 then
          advertisement.router or advertisement.routerInterface.address4 or null
        else
          advertisement.routerInterface.address6 or null
      );

  tenantRuntime =
    tenant:
    let
      nodeEntry = accessNodeEntryForTenant tenant;
      node = nodeEntry.value;
      port = node.ports."tenant-${tenant}";
      prefix = tenantPrefixFor tenant;
      runtimeTargetKey = "esp.${siteName}.${nodeEntry.name}";
      target =
        runtimeTargets.${runtimeTargetKey}
          or (throw "access-endpoint-renderer: no renderer runtime target for ${runtimeTargetKey}");
      dhcp4 = firstAdvertisement target "dhcp4" port.logicalInterface;
      ipv6Ra = firstAdvertisement target "ipv6Ra" port.logicalInterface;
      gw4 = advertisementGateway dhcp4 4;
      gw6 = advertisementGateway ipv6Ra 6;
      hasRuntimeRoutedIPv6 =
        ipv6Ra != null
        && builtins.isList (ipv6Ra.routedPrefixes or null)
        && ipv6Ra.routedPrefixes != [ ];
    in
    {
      bridge = port.attach.bridge;
      gw4 =
        if gw4 == null then
          throw "access-endpoint-renderer: no rendered IPv4 router advertisement for ${nodeEntry.name}.${port.logicalInterface}"
        else
          gw4;
      gw6 =
        if gw6 == null then
          throw "access-endpoint-renderer: no rendered IPv6 router advertisement for ${nodeEntry.name}.${port.logicalInterface}"
        else
          gw6;
      prefix4 = prefixPart prefix.ipv4;
      prefix6 = prefixPart prefix.ipv6;
      ipv6AcceptRA = hasRuntimeRoutedIPv6;
    };

  trafficTypes = builtins.listToAttrs (
    map
      (trafficType: {
        name = trafficType.name;
        value = trafficType;
      })
      (site.communicationContract.trafficTypes or [ ])
  );

  portsForProvider =
    provider:
    let
      providerServices = builtins.filter (service: builtins.elem provider (service.providers or [ ])) (
        site.communicationContract.services or [ ]
      );
      matches = lib.concatMap
        (
          service:
          let
            trafficType = trafficTypes.${service.trafficType} or { match = [ ]; };
          in
            trafficType.match or [ ]
        )
        providerServices;
      portsForProto =
        proto:
        lib.unique (
          lib.concatMap (match: if (match.proto or null) == proto then match.dports or [ ] else [ ]) matches
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

  endpointContainer =
    endpoint:
    let
      runtime = tenantRuntime endpoint.tenant;
      endpointAddrs = inventory.endpoints.${endpoint.name};
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
      endpointAddrs = inventory.endpoints.${endpoint.name} or null;
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
  map endpointContainer (builtins.filter (endpoint: endpointIsSelected endpoint && endpointIsHostContainer endpoint) site.ownership.endpoints)
)
