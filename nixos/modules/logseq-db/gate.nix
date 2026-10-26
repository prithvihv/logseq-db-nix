{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    literalExpression
    mkEnableOption
    mkIf
    mkOption
    mkPackageOption
    types
    ;

  cfg = config.services.logseq-db.gate;
  syncSettings = config.services.logseq-db.syncServer.settings;
in
{
  options.services.logseq-db.gate = {
    enable = mkEnableOption "the Logseq DB gate, a forward-auth server that limits the sync server to an allowlist of user ids";

    package = mkPackageOption pkgs "logseq-db-gate" { };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1:8788";
      description = ''
        Address the gate listens on. Only the reverse proxy needs to reach
        it; it is never opened in the firewall. Point the proxy's forward
        auth at it, for Caddy:

        ```
        forward_auth 127.0.0.1:8788 {
          uri /verify
        }
        ```

        Requests the gate answers with 2xx continue to the sync server;
        everything else is relayed to the client as the gate answered it
        (401 without a valid token, 403 for a user that is not allowed).
      '';
    };

    allowedUserIds = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "6a1f0f3e-7c4b-4d1e-9b0a-2f8c1d5e7a9b" ];
      description = ''
        User ids allowed to use the sync server: the `sub` claim of a
        Logseq account's token, a UUID. Usernames and emails are not
        accepted. The gate logs the id, username and email of every user
        it turns away, so sign in once against the server and read them
        from `journalctl -u logseq-db-gate`.
      '';
    };

    allowedUserIdsFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/etc/logseq-db-gate/user-ids";
      description = ''
        File with one allowed user id per line, in addition to
        {option}`services.logseq-db.gate.allowedUserIds`. Blank lines are
        skipped and anything after a `#` is a comment. The file has to be
        readable by the service's dynamic user; `systemctl reload
        logseq-db-gate` re-reads it.
      '';
    };

    issuer = mkOption {
      type = types.str;
      default = syncSettings.COGNITO_ISSUER;
      defaultText = literalExpression "config.services.logseq-db.syncServer.settings.COGNITO_ISSUER";
      description = "Issuer of the JWTs clients authenticate with.";
    };

    clientIds = mkOption {
      type = types.listOf types.str;
      default = [ syncSettings.COGNITO_CLIENT_ID ];
      defaultText = literalExpression "[ config.services.logseq-db.syncServer.settings.COGNITO_CLIENT_ID ]";
      description = "Accepted audiences (app client ids) of client JWTs.";
    };

    jwksUrl = mkOption {
      type = types.str;
      default = syncSettings.COGNITO_JWKS_URL;
      defaultText = literalExpression "config.services.logseq-db.syncServer.settings.COGNITO_JWKS_URL";
      description = "Where signing keys for client JWTs are fetched from. Must be reachable from the server.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.allowedUserIds != [ ] || cfg.allowedUserIdsFile != null;
        message = "services.logseq-db.gate: set allowedUserIds or allowedUserIdsFile, otherwise nobody can use the sync server.";
      }
    ];

    systemd.services.logseq-db-gate = {
      description = "Logseq DB gate";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe cfg.package)
            "-listen"
            cfg.listenAddress
            "-issuer"
            cfg.issuer
            "-jwks-url"
            cfg.jwksUrl
          ]
          ++ lib.concatMap (id: [
            "-client-id"
            id
          ]) cfg.clientIds
          ++ lib.concatMap (id: [
            "-allow-user-id"
            id
          ]) cfg.allowedUserIds
          ++ lib.optionals (cfg.allowedUserIdsFile != null) [
            "-allow-user-ids-file"
            cfg.allowedUserIdsFile
          ]
        );
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
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
  };
}
