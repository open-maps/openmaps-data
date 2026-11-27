{
  description = "Weekly offline map and routing data for OpenMaps";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            (python3.withPackages (p: [ p.shapely ]))
            curl
            gh
            jq
            osmium-tool
            pmtiles
            spatialite-tools
            unzip
            (callPackage ./valhalla.nix { })
            zstd
          ];
        };
      });
    };
}
