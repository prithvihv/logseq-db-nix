{ module }:

{
  name = "logseq-db-sync";

  nodes.machine = {
    imports = [ module ];

    services.logseq-db-sync = {
      enable = true;
      nginx = {
        enable = true;
        hostName = "sync.test";
      };
    };
  };

  testScript = ''
    machine.wait_for_unit("logseq-db-sync.service")
    machine.wait_for_open_port(8787)
    machine.wait_for_unit("nginx.service")

    with subtest("server answers directly"):
        machine.succeed("curl -fsS http://127.0.0.1:8787/health | grep -q '\"ok\":true'")

    with subtest("nginx proxies and auth gates hold"):
        proxy = "curl -sS -H 'Host: sync.test' -o /dev/null -w '%{http_code}' http://127.0.0.1"
        assert machine.succeed(f"{proxy}/health").strip() == "200"
        assert machine.succeed(f"{proxy}/graphs").strip() == "401"
        assert machine.succeed(f"{proxy}/sync/test-graph/pull?since=0").strip() == "401"

    with subtest("state lands in the data dir"):
        machine.succeed("test -f /var/lib/logseq-db-sync/index.sqlite")
        machine.succeed("test -d /var/lib/logseq-db-sync/assets")
        machine.succeed("stat -c %U /var/lib/logseq-db-sync/index.sqlite | grep -qx logseq-db-sync")

    with subtest("base URL defaults to the vhost"):
        machine.succeed("systemctl show -p Environment logseq-db-sync | grep -q DB_SYNC_BASE_URL=http://sync.test")

    with subtest("restarts after being killed"):
        machine.succeed("systemctl kill -s KILL logseq-db-sync")
        machine.wait_until_succeeds("curl -fsS http://127.0.0.1:8787/health")
  '';
}
