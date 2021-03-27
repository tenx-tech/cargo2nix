{
  inputs = {
    utils.url = github:numtide/flake-utils;
    nixpkgs-mozilla = { url = github:mozilla/nixpkgs-mozilla; flake = false; };
  };

  outputs = { self, nixpkgs, utils, nixpkgs-mozilla, ... }@inputs:
    let cargo2nixOverlay = import ./overlay;
    in
    {
      overlay = cargo2nixOverlay;
    } // utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            cargo2nixOverlay
            (import "${nixpkgs-mozilla}/rust-overlay.nix")
          ];
        };
        rustChannel = "1.49.0";
        rustChannelSha256 = "KCh2UBGtdlBJ/4UOqZlxUtcyefv7MH1neoVNV4z0nWs=";
        rustPkgs =
          pkgs.rustBuilder.makePackageSet' {
            packageFun = import ./Cargo.nix;
            inherit rustChannel rustChannelSha256;
            packageOverrides = pkgs: pkgs.rustBuilder.overrides.all;
            localPatterns = [ ''^(src|tests|templates)(/.*)?'' ''[^/]*\.(rs|toml)$'' ];
          };
      in
      {
        packages = {
          cargo2nix = rustPkgs.workspace.cargo2nix { };
          ci = pkgs.rustBuilder.runTests rustPkgs.workspace.cargo2nix { };
        };

        defaultPackage = self.packages.${system}.cargo2nix;
        defaultApp = {
          type = "app";
          program = "${self.defaultPackage.${system}}/bin/cargo2nix";
        };
      });
}
