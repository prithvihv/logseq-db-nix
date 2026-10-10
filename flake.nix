{
  description = "Logseq DB sync server and web app, packaged for Nix";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        logseq-db-sync = pkgs.callPackage ./pkgs/logseq-db-sync/package.nix { };
        logseq-db-app = pkgs.callPackage ./pkgs/logseq-db-app/package.nix { inherit logseq-db-sync; };
        default = logseq-db-sync;
      });

      checks = forAllSystems (
        pkgs:
        self.packages.${pkgs.stdenv.hostPlatform.system}.logseq-db-sync.tests
        // {
          nixos = pkgs.testers.runNixOSTest {
            imports = [ ./nixos/tests/logseq-db.nix ];
            defaults.imports = [ self.nixosModules.default ];
          };
        }
      );

      overlays.default = final: _prev: {
        logseq-db-sync = final.callPackage ./pkgs/logseq-db-sync/package.nix { };
        logseq-db-app = final.callPackage ./pkgs/logseq-db-app/package.nix { };
      };

      nixosModules = {
        logseq-db =
          { lib, pkgs, ... }:
          let
            packages = self.packages.${pkgs.stdenv.hostPlatform.system};
          in
          {
            imports = [ ./nixos/modules/logseq-db ];
            services.logseq-db = {
              syncServer.package = lib.mkDefault packages.logseq-db-sync;
              webApp.package = lib.mkDefault packages.logseq-db-app;
            };
          };
        default = self.nixosModules.logseq-db;
      };

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
