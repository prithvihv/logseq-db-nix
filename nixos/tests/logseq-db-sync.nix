{
  name = "logseq-db-sync";

  nodes = {
    # Behind nginx; the server's own port stays firewalled.
    proxied = {
      services.logseq-db-sync = {
        enable = true;
        nginx = {
          enable = true;
          hostName = "sync.test";
        };
      };
    };

    # Listening on a privileged port without a proxy.
    direct = {
      services.logseq-db-sync = {
        enable = true;
        openFirewall = true;
        settings.DB_SYNC_PORT = 80;
      };
    };
  };

  testScript = ''
    start_all()

    proxied.wait_for_unit("logseq-db-sync.service")
    proxied.wait_for_unit("nginx.service")
    proxied.wait_for_open_port(8787)
    direct.wait_for_unit("logseq-db-sync.service")
    direct.wait_for_open_port(80)

    with subtest("nginx proxies to the server"):
        proxied.succeed("curl -fsS -H 'Host: sync.test' http://127.0.0.1/health | grep -q '\"ok\":true'")

    with subtest("sync endpoints require a token"):
        status = "curl -sS -o /dev/null -w '%{http_code}' -H 'Host: sync.test' http://127.0.0.1"
        assert proxied.succeed(f"{status}/graphs") == "401"
        assert proxied.succeed(f"{status}/sync/some-graph/pull?since=0") == "401"

    with subtest("state lives in the data dir, owned by the service user"):
        proxied.succeed("test -d /var/lib/logseq-db-sync/assets")
        proxied.succeed("stat -c %U /var/lib/logseq-db-sync/index.sqlite | grep -qx logseq-db-sync")

    with subtest("base URL defaults to the nginx vhost"):
        proxied.succeed("systemctl show -P Environment logseq-db-sync | grep -q DB_SYNC_BASE_URL=http://sync.test")

    with subtest("a crashed server is restarted"):
        proxied.succeed("systemctl kill --signal=KILL logseq-db-sync")
        proxied.wait_until_succeeds("test $(systemctl show -P NRestarts logseq-db-sync) = 1")
        proxied.wait_for_open_port(8787)

    with subtest("openFirewall exposes a privileged port"):
        proxied.succeed("curl -fsS http://direct/health")

    with subtest("the server port is firewalled by default"):
        direct.fail("curl -fsS --connect-timeout 3 http://proxied:8787/health")
  '';
}
