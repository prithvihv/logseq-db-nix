# logseq-db-nix

Self-host [Logseq DB](https://github.com/logseq/logseq) sync + web app on NixOS.

This flake packages Logseq's sync server (the Node.js adapter in
[`deps/db-sync`](https://github.com/logseq/logseq/tree/master/deps/db-sync))
and the DB-version web app, and ships a NixOS module that runs both as
hardened systemd services. For hosting on the public internet it adds a small
forward-auth server that limits the sync server to an allowlist of user ids.

Nothing in nixpkgs covers this yet. The PR that adds the DB version of Logseq,
[NixOS/nixpkgs#516682](https://github.com/NixOS/nixpkgs/pull/516682), has been
open since May 2026 and is still in review, and it only packages the desktop
app. (An older PR for a web-app module,
[NixOS/nixpkgs#273532](https://github.com/NixOS/nixpkgs/pull/273532), has been
open since 2023.) This flake fills the gap until something lands upstream.

## NixOS

Add the flake as an input and import the module:

```nix
{
  inputs.logseq-db.url = "github:prithvihv/logseq-db-nix";

  outputs = { nixpkgs, logseq-db, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        logseq-db.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

The module picks up the packages from this flake; no overlay is needed.

Then enable the services. This runs the sync server on port 8787 and the web
app on port 3001:

```nix
{
  services.logseq-db = {
    syncServer = {
      enable = true;
      openFirewall = true;
    };
    webApp = {
      enable = true;
      openFirewall = true;
    };
  };
}
```

### Pointing a client at your server

1. Open Logseq DB (desktop, web, or mobile) and create or sign in to your
   official Logseq account.
2. Go to **Settings > Advanced > Sync Server URL** and enter
   `http://<host>:8787`.
3. Download a graph, or enable sync for an existing one.

### Hosting it publicly

The sync server accepts any valid Logseq account. Put on the internet as-is,
anyone with a (free) Logseq account could store their graphs on your server.

`services.logseq-db.gate` runs `logseq-db-gate`, a forward-auth server for
your reverse proxy. It is part of this flake, not of Logseq; the sync server
itself has no allowlist. The proxy asks the gate about every request before passing
it on; the gate verifies the Logseq token the client sent and only lets
requests through whose user id is on the allowlist. It answers 401 when there
is no valid token and 403 when the user is not allowed, and the proxy relays
that to the client. Unauthenticated `/health` checks and CORS preflights pass.

```nix
{
  services.logseq-db = {
    syncServer = {
      enable = true;
      settings.DB_SYNC_BASE_URL = "https://sync.example.com";
    };
    gate = {
      enable = true;
      allowedUserIds = [ "6a1f0f3e-7c4b-4d1e-9b0a-2f8c1d5e7a9b" ];
    };
  };

  services.caddy = {
    enable = true;
    virtualHosts."sync.example.com".extraConfig = ''
      forward_auth 127.0.0.1:8788 {
        uri /verify
      }
      reverse_proxy 127.0.0.1:8787
    '';
  };
  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
```

Caddy handles TLS, WebSocket upgrades and large bodies without further
configuration. Any proxy with a forward-auth step works the same way: the gate
reads the original method and URI from `X-Forwarded-Method` and
`X-Forwarded-Uri` (Caddy, Traefik) or `X-Original-Method` and `X-Original-URI`
(nginx `auth_request`), and the token from the `Authorization` header or the
`token` query parameter, which is how WebSocket clients send it.

Leave `syncServer.openFirewall` off: whatever reaches port 8787 directly
bypasses the gate.

User ids are the `sub` claim of the Logseq account's token, a UUID; usernames
and emails are not accepted. To find one, point a client at the server and
sign in. The gate turns the user away and logs who it was:

```console
$ journalctl -u logseq-db-gate
GET /graphs: denied user 6a1f0f3e-7c4b-4d1e-9b0a-2f8c1d5e7a9b (username "alice", email "alice@example.com"): not on the allowlist
```

To manage the list outside your Nix configuration, point
`allowedUserIdsFile` at a file with one id per line (`#` starts a comment) and
`systemctl reload logseq-db-gate` after editing it.

The gate is a dependency-free Go program; `nix run .#logseq-db-gate -- -help`
lists its flags if you want to run it without the module.

### Options

`services.logseq-db.syncServer`

| Option | Default | Description |
| --- | --- | --- |
| `enable` | `false` | Run the sync server. |
| `package` | `pkgs.logseq-db-sync` | Package to run. |
| `settings` | `{ }` | Environment variables for the server. Freeform; the ones below are typed. |
| `settings.DB_SYNC_PORT` | `8787` | Listening port. The server always binds all interfaces. |
| `settings.DB_SYNC_DATA_DIR` | `/var/lib/logseq-db-sync` | SQLite databases and uploaded assets. Created automatically. |
| `settings.DB_SYNC_BASE_URL` | `null` | Public URL clients reach the server at, used for generated asset links. Defaults to `http` and the request's `Host` header. |
| `settings.COGNITO_ISSUER` | Logseq's pool | Issuer of client JWTs. |
| `settings.COGNITO_CLIENT_ID` | Logseq's app client | Expected audience of client JWTs. |
| `settings.COGNITO_JWKS_URL` | `${COGNITO_ISSUER}/.well-known/jwks.json` | Where signing keys are fetched from. |
| `environmentFiles` | `[ ]` | Extra `KEY=value` files loaded with `EnvironmentFile=`. Put secrets like `SENTRY_DSN` here so they stay out of the Nix store. |
| `openFirewall` | `false` | Open `DB_SYNC_PORT`. |

The full list of environment variables is in the
[upstream README](https://github.com/logseq/logseq/blob/master/deps/db-sync/README.md#environment-variables).
`DB_SYNC_ADMIN_TOKEN` is ignored by the Node.js adapter.

`services.logseq-db.webApp`

| Option | Default | Description |
| --- | --- | --- |
| `enable` | `false` | Serve the web app with `static-web-server`. |
| `package` | `pkgs.logseq-db-app` | Static files to serve. |
| `port` | `3001` | Listening port, on all interfaces. |
| `openFirewall` | `false` | Open `port`. |

The web app is served without cache lifetimes. Its file names do not change
between versions, so default `max-age` headers would mix old scripts with a
new `index.html` after an upgrade.

`services.logseq-db.gate`

| Option | Default | Description |
| --- | --- | --- |
| `enable` | `false` | Run the gate. |
| `package` | `pkgs.logseq-db-gate` | Package to run. |
| `listenAddress` | `127.0.0.1:8788` | Where the reverse proxy reaches the gate. Never opened in the firewall. |
| `allowedUserIds` | `[ ]` | User ids (token `sub` claims) allowed to use the sync server. |
| `allowedUserIdsFile` | `null` | File with one allowed user id per line, re-read on `systemctl reload`. |
| `issuer` | `syncServer.settings.COGNITO_ISSUER` | Issuer of client JWTs. |
| `clientIds` | `[ syncServer.settings.COGNITO_CLIENT_ID ]` | Accepted audiences of client JWTs. |
| `jwksUrl` | `syncServer.settings.COGNITO_JWKS_URL` | Where signing keys are fetched from. |

One of `allowedUserIds` and `allowedUserIdsFile` must be set. The gate fetches
the signing keys on first use, caches them for six hours, and refetches (at
most once a minute) when a token names a key it does not have, so key
rotation at Logseq's end is picked up automatically.

## Flake outputs

| Output | Description |
| --- | --- |
| `nixosModules.default` | `services.logseq-db.syncServer`, `services.logseq-db.webApp` and `services.logseq-db.gate`. |
| `packages.<system>.logseq-db-sync` | The sync server. `nix run` starts it. |
| `packages.<system>.logseq-db-app` | The web app as static files, ready to serve as a document root. |
| `packages.<system>.logseq-db-gate` | The forward-auth gate. |
| `overlays.default` | Adds all three packages to `pkgs`. |

The sync server and web app are built from the same upstream commit, since the
sync protocol changes on the client and server side together. Supported
systems: `x86_64-linux`, `aarch64-linux`, `aarch64-darwin`.

## Build notes

- `better-sqlite3` is compiled against Node 24.18.1 headers on purpose. Newer
  24.x headers produce an addon that aborts when a statement is garbage
  collected ([nodejs/node#65446](https://github.com/nodejs/node/issues/65446));
  an addon built against 24.18.1 runs on any 24.x runtime.
- Clojure/Maven dependencies are fetched in a fixed-output derivation and
  pruned of timestamps and absolute paths so the hash is reproducible. Letting
  the Clojure CLI clone its git dependencies and then stripping the bare repos
  down to what it still accepts is the same trick
  [NixOS/nixpkgs#516682](https://github.com/NixOS/nixpkgs/pull/516682) uses.
- The upstream test suite is not run during the build because it can abort in
  the same `better-sqlite3` finalizer
  ([WiseLibs/better-sqlite3#1515](https://github.com/WiseLibs/better-sqlite3/issues/1515)).
  The smoke test and the NixOS test exercise the built server instead.

## Related

- [NixOS/nixpkgs#516682](https://github.com/NixOS/nixpkgs/pull/516682):
  `logseq_2` in nixpkgs, the DB desktop app. Open since May 2026.
- [logseq/logseq#12459](https://github.com/logseq/logseq/pull/12459): the
  upstream change that added the custom sync server URL setting.

## License

Logseq, and therefore the packaged server and web app, is licensed under
AGPL-3.0. See the [upstream license](https://github.com/logseq/logseq/blob/master/LICENSE.md).
