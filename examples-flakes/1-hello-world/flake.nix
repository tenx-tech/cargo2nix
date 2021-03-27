{
  inputs = {
    nixpkgs-mozilla = { url = github:mozilla/nixpkgs-mozilla; flake = false; };
    cargo2nix.url = "path:../../";
    utils.url = github:numtide/flake-utils;
  };

  outputs = { nixpkgs, utils, cargo2nix, nixpkgs-mozilla, ... }: utils.lib.eachDefaultSystem (system:
    let
      rustChannel = "1.49.0";
      rustChannelSha256 = "KCh2UBGtdlBJ/4UOqZlxUtcyefv7MH1neoVNV4z0nWs=";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          (import "${nixpkgs-mozilla}/rust-overlay.nix")
          cargo2nix.overlay
          (
            self: super: {
              rustStable = (
                super.rustChannelOf {
                  channel = rustChannel;
                  sha256 = rustChannelSha256;
                }
              ).rust;
            }
          )
        ];
      };
      rustPkgs = pkgs.rustBuilder.makePackageSet' {
        inherit rustChannel rustChannelSha256;
        packageFun = import ./Cargo.nix;
      };
    in
    {
      defaultPackage = rustPkgs.workspace.hello-world { };

      devShell = pkgs.mkShell {
        buildInputs = with pkgs; [
          rustStable
        ];
      };
    }
  );
}
