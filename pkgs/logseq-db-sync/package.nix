{
  lib,
  stdenv,
  stdenvNoCC,
  callPackage,
  fetchFromGitHub,
  nodejs_24,
  pnpm_10,
  fetchPnpmDeps,
  pnpmConfigHook,
  clojure,
  jdk21_headless,
  git,
  cacert,
  python3,
  srcOnly,
  makeBinaryWrapper,
  removeReferencesTo,
  cctools,
}:

let
  nodejs = nodejs_24;
  nodeSources = srcOnly nodejs;
  pnpm = pnpm_10;
  clojure' = clojure.override { jdk = jdk21_headless; };
  pythonEnv = python3.withPackages (ps: [ ps.setuptools ]);
in
stdenv.mkDerivation (finalAttrs: {
  pname = "logseq-db-sync";
  version = "0-unstable-2026-10-01";

  src = fetchFromGitHub {
    owner = "logseq";
    repo = "logseq";
    rev = "22263c36204c86949df6cb4bfa278be0aa215353";
    hash = "sha256-ndyA81tmSS59SC2cKv4uUWc8YxhTdw09ctxrjVFNqZY=";
  };

  # deps.edn pulls in ../common, ../db, ../outliner, ../graph-parser and
  # ../../resources, so the whole checkout is unpacked.
  sourceRoot = "${finalAttrs.src.name}/deps/db-sync";

  # The logseq root has a pnpm-workspace.yaml that deps/db-sync is not a
  # member of; without this pnpm resolves against the root workspace.
  pnpmInstallFlags = [ "--ignore-workspace" ];

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs)
      pname
      version
      src
      sourceRoot
      pnpmInstallFlags
      ;
    inherit pnpm;
    fetcherVersion = 4;
    hash = "sha256-XUbWCj1SOtWw3Og/0eqOG82Xlj8j98oVKT19x7DbhV0=";
  };

  # Maven artifacts and git deps resolved by `clojure -P -M:cljs`.
  cljDeps = stdenvNoCC.mkDerivation {
    name = "${finalAttrs.pname}-${finalAttrs.version}-clj-deps";
    inherit (finalAttrs) src sourceRoot;

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

    # Drop everything that carries timestamps or absolute paths: resolver
    # bookkeeping in the maven repo, and the bare git repos + worktree
    # pointers in gitlibs. tools.gitlibs only needs `_repos/<url>/config` to
    # exist to skip cloning; the checked-out trees under libs/ are what's used.
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
    outputHash = "sha256-P7cL9QAwP/zl8cdgtQy4HuGTWlOj7Nceyyi9KsBhosY=";
  };

  nativeBuildInputs = [
    nodejs
    pnpm
    pnpmConfigHook
    clojure'
    pythonEnv
    makeBinaryWrapper
    removeReferencesTo
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [ cctools.libtool ];

  buildPhase = ''
    runHook preBuild

    pushd node_modules/better-sqlite3
    npm run build-release --offline --nodedir="${nodeSources}"
    # Only the addon is loaded at runtime; the gyp intermediates reference
    # the compiler toolchain and python.
    find build -type f ! -path build/Release/better_sqlite3.node -delete
    find build -type d -empty -delete
    remove-references-to -t "${nodeSources}" build/Release/better_sqlite3.node
    popd

    export GITLIBS="${finalAttrs.cljDeps}/gitlibs"
    clojure -Sdeps '{:mvn/local-repo "${finalAttrs.cljDeps}/m2"}' -M:cljs release db-sync-node

    CI=true pnpm prune --prod --ignore-workspace

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    libdir="$out/lib/logseq-db-sync"
    mkdir -p "$libdir/worker/dist"
    cp package.json "$libdir/"
    cp worker/dist/node-adapter.js* "$libdir/worker/dist/"
    cp -r node_modules "$libdir/"

    makeWrapper "${lib.getExe nodejs}" "$out/bin/logseq-db-sync" \
      --add-flags "--enable-source-maps" \
      --add-flags "$libdir/worker/dist/node-adapter.js" \
      --set-default NODE_ENV production

    runHook postInstall
  '';

  passthru.tests.smoke = callPackage ./smoke-test.nix { logseq-db-sync = finalAttrs.finalPackage; };

  meta = {
    description = "Logseq DB sync server (self-hosted Node.js adapter)";
    homepage = "https://github.com/logseq/logseq/tree/master/deps/db-sync";
    license = lib.licenses.agpl3Only;
    mainProgram = "logseq-db-sync";
    platforms = lib.platforms.unix;
  };
})
