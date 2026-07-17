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
    { ... }:
    {
      networking.hostName = hostname;
      system.stateVersion = "25.11";
      networking.useNetworkd = true;
      systemd.network.enable = true;
      networking.useDHCP = false;
      networking.useHostResolvConf = false;
      services.resolved.enable = true;
      environment.systemPackages = basePackages;
    };

  mkDhcpEndpoint =
    { hostname
    , dhcp4 ? true
    , dhcp6 ? false
    ,
    }:
    moduleArgs:
    lib.mkMerge [
      (mkBaseEndpoint hostname moduleArgs)
      {
        systemd.network.networks."10-eth0" = {
          matchConfig.Name = "eth0";
          networkConfig = {
            DHCP =
              if dhcp4 && dhcp6 then "yes"
              else if dhcp4 then "ipv4"
              else if dhcp6 then "ipv6"
              else "no";
            IPv6AcceptRA = dhcp6;
            Domains = [ "lan." ];
          };
          dhcpV6Config = lib.mkIf dhcp6 {
            # Test-client machine IDs can change when the container is rebuilt.
            # Derive the DHCPv6 DUID from the already-stable interface MAC so an
            # enrolled reservation identity survives that rebuild boundary.
            DUIDType = "link-layer";
          };
        };
      }
    ];

  mkStaticEndpoint =
    { hostname
    , addr4
    , gw4
    , addr6
    , gw6
    , dnsServers ? [
        gw4
        gw6
      ]
    , ipv6AcceptRA ? false
    , mdnsClient ? false
    , extraModules ? [ ]
    ,
    }:
    { lib, ... }@moduleArgs:
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
        }
      ]
      ++ evalModules moduleArgs extraModules
    );
in
{
  inherit mkDhcpEndpoint mkStaticEndpoint;
}
