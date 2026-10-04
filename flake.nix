{
  description = "Logseq DB sync server, packaged for Nix";

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
        default = logseq-db-sync;
      });

      checks = forAllSystems (
        pkgs:
        self.packages.${pkgs.stdenv.hostPlatform.system}.logseq-db-sync.tests
        // {
          nixos = pkgs.testers.runNixOSTest (
            import ./nixos/tests/logseq-db-sync.nix { module = self.nixosModules.default; }
          );
        }
      );

      overlays.default = final: _prev: {
        logseq-db-sync = final.callPackage ./pkgs/logseq-db-sync/package.nix { };
      };

      nixosModules = {
        logseq-db-sync =
          { lib, pkgs, ... }:
          {
            imports = [ ./nixos/modules/logseq-db-sync.nix ];
            services.logseq-db-sync.package =
              lib.mkDefault
                self.packages.${pkgs.stdenv.hostPlatform.system}.logseq-db-sync;
          };
        default = self.nixosModules.logseq-db-sync;
      };

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
