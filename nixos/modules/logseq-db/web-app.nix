{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    mkPackageOption
    types
    ;

  cfg = config.services.logseq-db.webApp;
in
{
  options.services.logseq-db.webApp = {
    enable = mkEnableOption "the Logseq web app, served by static-web-server";

    package = mkPackageOption pkgs "logseq-db-app" { };

    port = mkOption {
      type = types.port;
      default = 3001;
      description = ''
        Port the web app is served on, on all interfaces. Browsers only let
        the app store graphs on HTTPS pages and on `localhost`, so anything
        but local use needs a TLS-terminating reverse proxy in front.

        The app syncs with Logseq's hosted service unless a user enters the
        sync server's URL under Settings > Advanced > Sync Server URL.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open {option}`services.logseq-db.webApp.port` in the firewall.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.logseq-db-app = {
      description = "Logseq web app";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        # The app's file names don't change between versions, so the default
        # max-age headers would mix old scripts with a new index.html after
        # an upgrade. Store files carry no Last-Modified, so browsers refetch.
        ExecStart = lib.escapeShellArgs [
          (lib.getExe pkgs.static-web-server)
          "--port"
          cfg.port
          "--root"
          cfg.package
          "--cache-control-headers"
          "false"
        ];
        Restart = "always";
        RestartSec = 5;

        DynamicUser = true;
        CapabilityBoundingSet = "";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        PrivateUsers = true;
        ProcSubset = "pid";
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
        UMask = "0077";
      };
    };

    networking.firewall.allowedTCPPorts = lib.optional cfg.openFirewall cfg.port;
  };
}
