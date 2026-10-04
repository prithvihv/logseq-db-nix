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
  }
  ''
    export DB_SYNC_PORT=18787
    export DB_SYNC_DATA_DIR="$TMPDIR/data"
    base="http://127.0.0.1:$DB_SYNC_PORT"

    logseq-db-sync &
    server=$!
    trap 'kill $server' EXIT

    curl --retry 30 --retry-connrefused --retry-delay 1 -fsS "$base/health" | grep -q '"ok":true'
    test "$(curl -sS -o /dev/null -w '%{http_code}' "$base/graphs")" = 401
    test "$(curl -sS -o /dev/null -w '%{http_code}' "$base/sync/smoke-graph/pull?since=0")" = 401
    test -f "$DB_SYNC_DATA_DIR/index.sqlite"

    touch $out
  ''
