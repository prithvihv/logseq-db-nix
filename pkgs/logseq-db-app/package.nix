{
  lib,
  stdenvNoCC,
  nodejs_24,
  pnpm_10,
  fetchPnpmDeps,
  pnpmConfigHook,
  clojure,
  jdk21_headless,
  git,
  cacert,
  logseq-db-sync,
}:

let
  nodejs = nodejs_24;
  pnpm = pnpm_10;
  clojure' = clojure.override { jdk = jdk21_headless; };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "logseq-db-app";
  # The sync protocol changes in lockstep on both sides, so the client is
  # built from the same checkout as the server.
  inherit (logseq-db-sync) version src;

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    inherit pnpm;
    fetcherVersion = 4;
    hash = "sha256-W0VpA+Q2RpN3jEyq8JEhGhZOVEXmnNRABkXqZasjxnc=";
  };

  # Maven artifacts and git deps resolved by `clojure -P -M:cljs`.
  cljDeps = stdenvNoCC.mkDerivation {
    name = "${finalAttrs.pname}-${finalAttrs.version}-clj-deps";
    inherit (finalAttrs) src;

    nativeBuildInputs = [
      clojure'
      git
      cacert
    ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild

      export HOME="$(mktemp -d)"
      export GITLIBS="$out/gitlibs"
      clojure -Sdeps "{:mvn/local-repo \"$out/m2\"}" -P -M:cljs

      runHook postBuild
    '';

    # Same pruning as logseq-db-sync's cljDeps: drop resolver bookkeeping
    # and reduce the bare git repos to the config file tools.gitlibs checks.
    installPhase = ''
      runHook preInstall

      find "$out/m2" -type f \( \
        -name '*.lastUpdated' \
        -o -name resolver-status.properties \
        -o -name _remote.repositories \) \
        -delete

      mapfile -t bareRepos < <(find "$out/gitlibs/_repos" -type f -name config -not -path '*/worktrees/*' -printf '%h\n')
      for repo in "''${bareRepos[@]}"; do
        rm -rf "$repo"
        mkdir -p "$repo"
        touch "$repo/config"
      done
      find "$out/gitlibs/libs" -mindepth 4 -maxdepth 4 -name .git -delete

      runHook postInstall
    '';

    dontFixup = true;

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-2h4nICQ5r8sVx4xLbXK45ik65xh/tXYeQPGvVU5V0ZQ=";
  };

  strictDeps = true;

  nativeBuildInputs = [
    nodejs
    pnpm
    pnpmConfigHook
    clojure'
  ];

  # Read by the shadow-cljs build hook, which otherwise shells out to git
  # and stamps the current time.
  env = {
    LOGSEQ_REVISION = finalAttrs.src.rev;
    LOGSEQ_BUILD_TIME = "1970-01-01T00:00:00Z";
  };

  postConfigure = ''
    export GITLIBS="${finalAttrs.cljDeps}/gitlibs"
    export CLJ_CONFIG="$TMPDIR/clojure"
    mkdir -p "$CLJ_CONFIG"
    echo '{:mvn/local-repo "${finalAttrs.cljDeps}/m2"}' > "$CLJ_CONFIG/deps.edn"
  '';

  buildPhase = ''
    runHook preBuild

    pnpm run release-app

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    cp -r static $out

    runHook postInstall
  '';

  meta = {
    description = "Logseq web app (DB version), as static files to serve";
    homepage = "https://github.com/logseq/logseq";
    license = lib.licenses.agpl3Only;
    platforms = lib.platforms.unix;
  };
})
