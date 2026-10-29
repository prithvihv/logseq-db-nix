{
  lib,
  buildGoModule,
}:

buildGoModule {
  pname = "logseq-db-gate";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.fileFilter (file: file.hasExt "go" || file.name == "go.mod") ./.;
  };

  # Standard library only.
  vendorHash = null;

  ldflags = [
    "-s"
    "-w"
  ];

  # The tests stand up an httptest JWKS server on the loopback interface.
  __darwinAllowLocalNetworking = true;

  meta = {
    description = "Forward-auth gate that limits a Logseq DB sync server to an allowlist of user ids";
    mainProgram = "logseq-db-gate";
    platforms = lib.platforms.unix;
  };
}
