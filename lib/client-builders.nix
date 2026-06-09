{ lib, pkgs }:

let
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
    ,
    }:
    moduleArgs:
    lib.mkMerge [
      (mkBaseEndpoint hostname moduleArgs)
      {
        systemd.network.networks."10-eth0" = {
          matchConfig.Name = "eth0";
          networkConfig = {
            DHCP = "ipv4";
            IPv6AcceptRA = true;
            Domains = [ "lan." ];
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
            routes = [
              {
                Destination = "0.0.0.0/0";
                Gateway = gw4;
              }
              {
                Destination = "::/0";
                Gateway = gw6;
              }
            ];
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
