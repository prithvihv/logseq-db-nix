{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    literalExpression
    literalMD
    mkEnableOption
    mkIf
    mkOption
    mkPackageOption
    types
    ;

  cfg = config.services.logseq-db-sync;
  port = cfg.settings.DB_SYNC_PORT;
  dataDir = cfg.settings.DB_SYNC_DATA_DIR;
  privilegedPort = port < 1024;

  vhost = config.services.nginx.virtualHosts.${cfg.nginx.hostName};
  vhostScheme = if vhost.forceSSL || vhost.onlySSL || vhost.addSSL then "https" else "http";
in
{
  options.services.logseq-db-sync = {
    enable = mkEnableOption "the Logseq DB sync server";

    package = mkPackageOption pkgs "logseq-db-sync" { };

    settings = mkOption {
      default = { };
      description = ''
        Environment variables passed to the sync server. See the
        [db-sync README](https://github.com/logseq/logseq/blob/master/deps/db-sync/README.md#environment-variables)
        for the full list; note that the Node.js adapter ignores
        `DB_SYNC_ADMIN_TOKEN`. Secrets such as `SENTRY_DSN` belong in
        {option}`services.logseq-db-sync.environmentFiles` so they stay out of
        the Nix store.
      '';
      type = types.submodule {
        freeformType = types.attrsOf (
          types.nullOr (
            types.oneOf [
              types.str
              types.int
            ]
          )
        );

        options = {
          DB_SYNC_PORT = mkOption {
            type = types.port;
            default = 8787;
            description = ''
              Port the server listens on. The server has no bind address
              setting and always listens on all interfaces; keep
              {option}`services.logseq-db-sync.openFirewall` off when it sits
              behind a reverse proxy.
            '';
          };

          DB_SYNC_DATA_DIR = mkOption {
            type = types.path;
            default = "/var/lib/logseq-db-sync";
            description = "Directory for the SQLite databases and uploaded assets. Created automatically.";
          };

          DB_SYNC_BASE_URL = mkOption {
            type = types.nullOr types.str;
            default = if cfg.nginx.enable then "${vhostScheme}://${cfg.nginx.hostName}" else null;
            defaultText = literalMD ''
              `https://` (or `http://` without TLS) followed by
              {option}`services.logseq-db-sync.nginx.hostName` when
              {option}`services.logseq-db-sync.nginx.enable` is set, otherwise `null`
            '';
            example = "https://sync.example.com";
            description = ''
              Public URL clients reach the server at. Its scheme and host are
              used for every URL the server generates (asset links), so set it
              whenever TLS is terminated by a proxy. When unset, the server
              assumes `http` and the request's `Host` header.
            '';
          };

          COGNITO_ISSUER = mkOption {
            type = types.str;
            default = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_dtagLnju8";
            description = ''
              Issuer of the JWTs clients authenticate with. The default is the
              Logseq account pool the official apps log in against.
            '';
          };

          COGNITO_CLIENT_ID = mkOption {
            type = types.str;
            default = "69cs1lgme7p8kbgld8n5kseii6";
            description = "Expected audience (app client id) of client JWTs.";
          };

          COGNITO_JWKS_URL = mkOption {
            type = types.str;
            default = "${cfg.settings.COGNITO_ISSUER}/.well-known/jwks.json";
            defaultText = literalExpression ''"''${config.services.logseq-db-sync.settings.COGNITO_ISSUER}/.well-known/jwks.json"'';
            description = "Where signing keys for client JWTs are fetched from. Must be reachable from the server.";
          };
        };
      };
    };

    environmentFiles = mkOption {
      type = types.listOf types.path;
      default = [ ];
      example = [ "/run/secrets/logseq-db-sync.env" ];
      description = ''
        Files with additional `KEY=value` environment variables, loaded with
        systemd's `EnvironmentFile=`. Use this for `SENTRY_DSN` and other
        secrets.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open {option}`services.logseq-db-sync.settings.DB_SYNC_PORT` in the firewall.";
    };

    nginx = {
      enable = mkEnableOption "an nginx virtual host that proxies HTTP and WebSocket traffic to the sync server";

      hostName = mkOption {
        type = types.str;
        example = "sync.example.com";
        description = ''
          Name of the nginx virtual host. TLS and anything else about the vhost
          is configured through
          {option}`services.nginx.virtualHosts.<name>`, e.g. `enableACME` and
          `forceSSL`.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    users.users.logseq-db-sync = {
      isSystemUser = true;
      group = "logseq-db-sync";
      home = dataDir;
    };
    users.groups.logseq-db-sync = { };

    systemd.tmpfiles.settings.logseq-db-sync.${dataDir}.d = {
      user = "logseq-db-sync";
      group = "logseq-db-sync";
      mode = "0750";
    };

    systemd.services.logseq-db-sync = {
      description = "Logseq DB sync server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      environment = lib.mapAttrs (_: toString) (lib.filterAttrs (_: v: v != null) cfg.settings);

      serviceConfig = {
        ExecStart = lib.getExe cfg.package;
        EnvironmentFile = cfg.environmentFiles;
        User = "logseq-db-sync";
        Group = "logseq-db-sync";
        WorkingDirectory = dataDir;
        ReadWritePaths = [ dataDir ];

        # A failed startup is only logged and the process exits 0.
        Restart = "always";
        RestartSec = 5;

        AmbientCapabilities = lib.optional privilegedPort "CAP_NET_BIND_SERVICE";
        CapabilityBoundingSet = lib.optional privilegedPort "CAP_NET_BIND_SERVICE";
        LockPersonality = true;
        # MemoryDenyWriteExecute is left off: V8's JIT needs W+X pages.
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        # Capabilities granted inside a private user namespace do not apply
        # to binding ports on the host.
        PrivateUsers = !privilegedPort;
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
        RemoveIPC = true;
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

    networking.firewall.allowedTCPPorts = lib.optional cfg.openFirewall port;

    services.nginx = mkIf cfg.nginx.enable {
      enable = true;
      virtualHosts.${cfg.nginx.hostName}.locations."/" = {
        proxyPass = "http://127.0.0.1:${toString port}";
        proxyWebsockets = true;
        recommendedProxySettings = true;
        extraConfig = ''
          # Graph snapshot uploads can be larger than any fixed cap; the
          # server enforces its own limits (100 MiB per asset).
          client_max_body_size 0;
          proxy_request_buffering off;
          # Clients send no WebSocket keepalives, so idle sync sockets would
          # otherwise be cut after nginx's 60s default.
          proxy_read_timeout 1h;
          proxy_send_timeout 1h;
        '';
      };
    };
  };
}
