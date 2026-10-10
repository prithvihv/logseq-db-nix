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
  };

  testScript = ''
    start_all()

    server.wait_for_unit("logseq-db-sync.service")
    server.wait_for_open_port(8787)
    server.wait_for_unit("logseq-db-app.service")
    server.wait_for_open_port(3001)
    direct.wait_for_unit("logseq-db-sync.service")
    direct.wait_for_open_port(80)

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
  '';
}
