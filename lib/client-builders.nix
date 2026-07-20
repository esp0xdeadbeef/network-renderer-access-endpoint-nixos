# FS-720-HDS-030-SDS-010-SMS-041 and FS-983-HDS-010-SDS-010-SMS-010:
# endpoint containers consume CPM assignment fields and use eth0 only as the
# NixOS private-network container-local interface.
{ lib, pkgs }:

let
  stripCidr = cidr: builtins.elemAt (lib.splitString "/" cidr) 0;

  basePackages = with pkgs; [
    bind
    curl
    dig
    ethtool
    iproute2
    iputils
    jq
    lsof
    mtr
    netcat-openbsd
    nmap
    nftables
    procps
    ripgrep
    socat
    strace
    tcpdump
    tmux
    traceroute
    tshark
  ];

  evalModules =
    moduleArgs: modules:
    map (module: if builtins.isFunction module then module moduleArgs else module) modules;

  mkBaseEndpoint =
    hostname:
    { lib, ... }:
    {
      networking.hostName = hostname;
      # FS-230-HDS-010-SDS-010-SMS-040: isolated endpoints observe router
      # policy; they must not add a second default-deny or tuple-specific
      # firewall authority after the modeled path has delivered a packet.
      networking.firewall.enable = lib.mkForce false;
      system.stateVersion = "25.11";
      networking.useNetworkd = true;
      systemd.network.enable = true;
      networking.useDHCP = false;
      networking.useHostResolvConf = false;
      services.resolved.enable = true;
      environment.systemPackages = basePackages;
    };

  mkDhcpEndpoint =
    {
      hostname,
      dhcp4 ? true,
      dhcp6 ? false,
    }:
    moduleArgs:
    lib.mkMerge [
      (mkBaseEndpoint hostname moduleArgs)
      {
        systemd.network.networks."10-eth0" = {
          matchConfig.Name = "eth0";
          networkConfig = {
            DHCP =
              if dhcp4 && dhcp6 then
                "yes"
              else if dhcp4 then
                "ipv4"
              else if dhcp6 then
                "ipv6"
              else
                "no";
            IPv6AcceptRA = dhcp6;
            # A protected reservation requires one predictable enrolled IPv6
            # address. Do not derive temporary privacy addresses from the
            # stateful DHCPv6 address that carries that stable identity.
            IPv6PrivacyExtensions = lib.mkIf dhcp6 false;
            Domains = [ "lan." ];
          };
          dhcpV6Config = lib.mkIf dhcp6 {
            # Test-client machine IDs can change when the container is rebuilt.
            # Derive the DHCPv6 DUID from the already-stable interface MAC so an
            # enrolled reservation identity survives that rebuild boundary.
            DUIDType = "link-layer";
            # Start the stateful DHCPv6 exchange deterministically even when a
            # managed RA is delayed or networkd does not use it as its trigger.
            # The router-side RA contract remains independently required.
            WithoutRA = "solicit";
          };
        };
      }
    ];

  mkStaticEndpoint =
    {
      hostname,
      addr4,
      gw4,
      addr6,
      gw6,
      dnsServers ? [
        gw4
        gw6
      ],
      ipv6AcceptRA ? false,
      mdnsClient ? false,
      extraModules ? [ ],
      runtimeAddressAssignments ? [ ],
    }:
    { lib, ... }@moduleArgs:
    let
      runtimeAddressServices = builtins.listToAttrs (
        lib.imap0 (index: assignment: {
          name = "access-endpoint-runtime-ipv6-address-${toString index}";
          value = {
            description = "Materialize protected runtime IPv6 endpoint address";
            wantedBy = [ "multi-user.target" ];
            after = [ "network-online.target" ];
            wants = [ "network-online.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = lib.escapeShellArgs [
                "${pkgs.python3}/bin/python3"
                (toString ./runtime-protected-ipv6-address.py)
                "--source"
                assignment.sourceFile
                "--delegated-prefix-length"
                (toString assignment.delegatedPrefixLength)
                "--tenant-prefix-length"
                (toString assignment.perTenantPrefixLength)
                "--slot"
                (toString assignment.slot)
                "--interface-identifier"
                assignment.interfaceIdentifier
                "--target-prefix-length"
                (toString assignment.prefixLength)
                "--assign-interface"
                assignment.interfaceName
                "--ip-command"
                "${pkgs.iproute2}/bin/ip"
              ];
            };
          };
        }) runtimeAddressAssignments
      );
    in
    lib.mkMerge (
      [
        (mkBaseEndpoint hostname moduleArgs)
        {
          systemd.network.networks."10-eth0" = {
            matchConfig.Name = "eth0";
            networkConfig = {
              Address = [
                addr4
                addr6
              ];
              DNS = dnsServers;
              Domains = [ "lan." ];
              IPv6AcceptRA = ipv6AcceptRA;
              MulticastDNS = "yes";
            };
            routes =
              lib.optional (stripCidr addr4 != gw4) {
                Destination = "0.0.0.0/0";
                Gateway = gw4;
              }
              ++ lib.optional (stripCidr addr6 != gw6) {
                Destination = "::/0";
                Gateway = gw6;
              };
          };

          services.avahi = lib.mkIf mdnsClient {
            enable = true;
            nssmdns4 = true;
            nssmdns6 = true;
          };

          systemd.services = runtimeAddressServices;
        }
      ]
      ++ evalModules moduleArgs extraModules
    );
in
{
  inherit mkDhcpEndpoint mkStaticEndpoint;
}
