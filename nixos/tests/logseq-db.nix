{ pkgs, ... }:

let
  # A stand-in for Logseq's Cognito pool: an RSA key published as a JWKS, and
  # tokens signed with it for two users. Only alice is on the allowlist.
  issuer = "https://issuer.test";
  clientId = "test-client";
  alice = "11111111-1111-4111-8111-111111111111";
  mallory = "22222222-2222-4222-8222-222222222222";

  idp =
    pkgs.runCommand "logseq-db-test-idp"
      {
        nativeBuildInputs = [ pkgs.openssl ];
      }
      ''
        mkdir -p "$out"
        openssl genrsa -out key.pem 2048
        openssl genrsa -out rogue.pem 2048

        b64url() { basenc --base64url -w0 | tr -d '='; }

        n=$(openssl rsa -in key.pem -noout -modulus | cut -d= -f2 | basenc --base16 -d | b64url)
        printf '{"keys":[{"kty":"RSA","use":"sig","alg":"RS256","kid":"test","n":"%s","e":"AQAB"}]}' "$n" \
          > "$out/jwks.json"

        # mint <key> <payload-json>
        mint() {
          header=$(printf '{"alg":"RS256","kid":"test"}' | b64url)
          payload=$(printf '%s' "$2" | b64url)
          signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$1" | b64url)
          printf '%s.%s.%s' "$header" "$payload" "$signature"
        }
        # claims <sub> <username> <exp>
        claims() {
          printf '{"iss":"${issuer}","aud":"${clientId}","token_use":"id","sub":"%s","cognito:username":"%s","email":"%s@example.test","exp":%s}' \
            "$1" "$2" "$2" "$3"
        }

        future=4102444800 # 2100-01-01
        mint key.pem "$(claims ${alice} alice $future)" > "$out/alice.jwt"
        mint key.pem "$(claims ${alice} alice 1000000000)" > "$out/alice-expired.jwt"
        mint rogue.pem "$(claims ${alice} alice $future)" > "$out/alice-forged.jwt"
        mint key.pem "$(claims ${mallory} mallory $future)" > "$out/mallory.jwt"
      '';
in
{
  name = "logseq-db";

  nodes = {
    # The defaults: sync server on 8787 and web app on 3001, firewalled.
    server = {
      services.logseq-db = {
        syncServer.enable = true;
        webApp.enable = true;
      };
    };

    # Listening on a privileged port, reachable from other machines.
    direct = {
      services.logseq-db.syncServer = {
        enable = true;
        openFirewall = true;
        settings.DB_SYNC_PORT = 80;
      };
    };

    # Public hosting: Caddy in front, asking the gate about every request.
    # The sync server and the gate both verify tokens against the test IdP,
    # which Caddy serves on port 9000.
    gated = {
      services.logseq-db = {
        syncServer = {
          enable = true;
          settings = {
            DB_SYNC_BASE_URL = "http://gated";
            COGNITO_ISSUER = issuer;
            COGNITO_CLIENT_ID = clientId;
            COGNITO_JWKS_URL = "http://127.0.0.1:9000/jwks.json";
          };
        };
        gate = {
          enable = true;
          allowedUserIds = [ alice ];
          allowedUserIdsFile = "/var/lib/logseq-db-gate/user-ids";
        };
      };

      systemd.tmpfiles.settings.logseq-db-gate."/var/lib/logseq-db-gate/user-ids".f = {
        mode = "0644";
      };

      services.caddy = {
        enable = true;
        virtualHosts.":80".extraConfig = ''
          forward_auth 127.0.0.1:8788 {
            uri /verify
          }
          reverse_proxy 127.0.0.1:8787
        '';
        virtualHosts.":9000".extraConfig = ''
          root * ${idp}
          file_server
        '';
      };
    };
  };

  testScript = ''
    start_all()

    server.wait_for_unit("logseq-db-sync.service")
    server.wait_for_open_port(8787)
    server.wait_for_unit("logseq-db-app.service")
    server.wait_for_open_port(3001)
    direct.wait_for_unit("logseq-db-sync.service")
    direct.wait_for_open_port(80)
    gated.wait_for_unit("logseq-db-sync.service")
    gated.wait_for_open_port(8787)
    gated.wait_for_unit("logseq-db-gate.service")
    gated.wait_for_open_port(8788)
    gated.wait_for_unit("caddy.service")
    gated.wait_for_open_port(80)

    with subtest("the web app is served without cache lifetimes"):
        server.succeed("curl -fsS http://127.0.0.1:3001/ | grep -qF '<div id=\"root\">'")
        headers = server.succeed("curl -fsS -o /dev/null -D - http://127.0.0.1:3001/js/main.js").lower()
        assert "cache-control" not in headers, headers
        assert "last-modified" not in headers, headers

    with subtest("sync endpoints require a token"):
        server.succeed("curl -fsS http://127.0.0.1:8787/health | grep -q '\"ok\":true'")
        status = "curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8787"
        assert server.succeed(f"{status}/graphs") == "401"
        assert server.succeed(f"{status}/sync/some-graph/pull?since=0") == "401"

    with subtest("state lives in the data dir, owned by the service user"):
        server.succeed("test -d /var/lib/logseq-db-sync/assets")
        server.succeed("stat -c %U /var/lib/logseq-db-sync/index.sqlite | grep -qx logseq-db-sync")

    with subtest("a crashed server is restarted"):
        server.succeed("systemctl kill --signal=KILL logseq-db-sync")
        server.wait_until_succeeds("test $(systemctl show -P NRestarts logseq-db-sync) = 1")
        server.wait_for_open_port(8787)

    with subtest("openFirewall exposes a privileged port"):
        server.succeed("curl -fsS http://direct/health")

    with subtest("the server port is firewalled by default"):
        direct.fail("curl -fsS --connect-timeout 3 http://server:8787/health")

    status = "curl -sS -o /dev/null -w '%{http_code}'"
    def token(name):
        return f'"Authorization: Bearer $(cat ${idp}/{name}.jwt)"'

    with subtest("the gate lets the public endpoints through"):
        gated.succeed("curl -fsS http://127.0.0.1/health | grep -q '\"ok\":true'")
        preflight = "-X OPTIONS -H 'Origin: http://app.test' -H 'Access-Control-Request-Method: GET'"
        assert gated.succeed(f"{status} {preflight} http://127.0.0.1/graphs") == "204"

    with subtest("the gate rejects requests without a valid token"):
        assert gated.succeed(f"{status} http://127.0.0.1/graphs") == "401"
        assert gated.succeed(f"{status} -H {token('alice-expired')} http://127.0.0.1/graphs") == "401"
        assert gated.succeed(f"{status} -H {token('alice-forged')} http://127.0.0.1/graphs") == "401"

    with subtest("an allowed user reaches the sync server"):
        gated.succeed(f"curl -fsS -H {token('alice')} http://127.0.0.1/graphs | grep -q '\"graphs\"'")
        # WebSocket clients cannot set headers and pass the token in the query string.
        gated.succeed("curl -fsS \"http://127.0.0.1/graphs?token=$(cat ${idp}/alice.jwt)\" | grep -q '\"graphs\"'")

    with subtest("a user that is not on the allowlist is turned away"):
        assert gated.succeed(f"{status} -H {token('mallory')} http://127.0.0.1/graphs") == "403"
        assert gated.succeed(f"{status} \"http://127.0.0.1/graphs?token=$(cat ${idp}/mallory.jwt)\"") == "403"
        gated.succeed("journalctl -u logseq-db-gate | grep -q 'denied user ${mallory} (username \"mallory\"'")
        # The sync server itself would let them in, so its port must stay closed.
        gated.succeed(f"curl -fsS -H {token('mallory')} http://127.0.0.1:8787/graphs | grep -q '\"graphs\"'")
        direct.fail("curl -fsS --connect-timeout 3 http://gated:8787/health")

    with subtest("the allowlist file is re-read on reload"):
        gated.succeed("echo '${mallory}  # mallory' >> /var/lib/logseq-db-gate/user-ids")
        gated.succeed("systemctl reload logseq-db-gate")
        gated.wait_until_succeeds(f"curl -fsS -H {token('mallory')} http://127.0.0.1/graphs | grep -q '\"graphs\"'")
  '';
}
