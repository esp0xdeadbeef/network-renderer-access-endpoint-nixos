{ system
, pkgs
, lib
}:

{
  hostModuleFromPaths =
    { hostName
    , labSource ? null
    , intentPath
    , inventoryPath
    , clientsPath ? null
    , routingSopsPath ? null
    , mode ? "test"
    , siteName ? null
    , endpointNames ? null
    , endpointAddressing ? "static"
    , selectorFile ? null
    , ...
    }:

    { config, ... }:

    let
      hasRoutingSops = routingSopsPath != null;
    in
    {
      imports = lib.optional hasRoutingSops routingSopsPath;

      _module.args.accessEndpointRenderer = {
        renderer = "network-renderer-access-endpoint-nixos";
        inherit
          system
          hostName
          labSource
          intentPath
          inventoryPath
          clientsPath
          routingSopsPath
          mode
          siteName
          endpointNames
          endpointAddressing
          selectorFile
          ;
      };

      assertions = [
        {
          assertion = mode == "test" || mode == "production";
          message = "access-endpoint renderer: mode must be either \"test\" or \"production\"";
        }
        {
          assertion = endpointAddressing == "static" || endpointAddressing == "dhcp";
          message = "access-endpoint renderer: endpointAddressing must be either \"static\" or \"dhcp\"";
        }
      ];

      networking.hostName = lib.mkDefault hostName;

      environment.etc."access-endpoint-renderer/input.json".text =
        builtins.toJSON {
          renderer = "network-renderer-access-endpoint-nixos";
          inherit
            system
            hostName
            labSource
            intentPath
            inventoryPath
            clientsPath
            routingSopsPath
            mode
            siteName
            endpointNames
            endpointAddressing
            selectorFile
            ;
        };

      systemd.services.access-endpoint-renderer-dummy = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/true";
        };
      };
    };
}
