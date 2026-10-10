{
  runCommand,
  curl,
  logseq-db-sync,
}:

runCommand "logseq-db-sync-smoke-test"
  {
    nativeBuildInputs = [
      curl
      logseq-db-sync
    ];
    __darwinAllowLocalNetworking = true;
  }
  ''
    # Port 0 lets the kernel pick a free port, so unsandboxed builds cannot
    # collide with (or be answered by) anything already listening.
    export DB_SYNC_PORT=0
    export DB_SYNC_DATA_DIR="$TMPDIR/data"

    logseq-db-sync > >(tee server.log) 2>&1 &
    server=$!
    trap 'kill $server' EXIT

    for _ in $(seq 30); do
      port=$(sed -n 's/^Logseq sync listening on port //p' server.log)
      [ -n "$port" ] && break
      sleep 1
    done
    base="http://127.0.0.1:''${port:?server did not report a listening port}"

    curl -fsS "$base/health" | grep -q '"ok":true'
    test "$(curl -sS -o /dev/null -w '%{http_code}' "$base/graphs")" = 401
    test "$(curl -sS -o /dev/null -w '%{http_code}' "$base/sync/smoke-graph/pull?since=0")" = 401
    test -f "$DB_SYNC_DATA_DIR/index.sqlite"

    touch $out
  ''
