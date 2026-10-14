# logseq-db-nix

Self-host [Logseq DB](https://github.com/logseq/logseq) sync + web app on NixOS.

This flake packages Logseq's sync server (the Node.js adapter in
[`deps/db-sync`](https://github.com/logseq/logseq/tree/master/deps/db-sync))
and the DB-version web app, and ships a NixOS module that runs both as
hardened systemd services.

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
  inputs.logseq-db.url = "github:prithvihv/logseq-db-sync-nix";

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

## Flake outputs

| Output | Description |
| --- | --- |
| `nixosModules.default` | `services.logseq-db.syncServer` and `services.logseq-db.webApp`. |
| `packages.<system>.logseq-db-sync` | The sync server. `nix run` starts it. |
| `packages.<system>.logseq-db-app` | The web app as static files, ready to serve as a document root. |
| `overlays.default` | Adds both packages to `pkgs`. |

Both packages are built from the same upstream commit, since the sync protocol
changes on the client and server side together. Supported systems:
`x86_64-linux`, `aarch64-linux`, `aarch64-darwin`.

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
