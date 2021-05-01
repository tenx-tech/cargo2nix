{
  nixpkgs ? builtins.fetchTarball {
    url = https://github.com/NixOS/nixpkgs/archive/e34208e10033315fddf6909d3ff68e2d3cf48a23.tar.gz;
    sha256 = "0ngkx5ny7bschmiwc5q9yza8fdwlc3zg47avsywwp8yn96k2cpmg";
  },
  rust-overlay ? builtins.fetchTarball {
    url = https://github.com/oxalica/rust-overlay/archive/a9309152e39974309a95f3350ccb1337734c3fe5.tar.gz;
    sha256 = "04428wpwc5hyaa4cvc1bx52i9m62ipavj0y7qs0h9cq9a7dl1zki";
  },
  system ? builtins.currentSystem,
  overlays ? [ ],
  crossSystem ? null,
  rustChannel ? "1.50.0",
}:
let
  # 1. Setup nixpkgs with rust and cargo2nix overlays.
  pkgs = import nixpkgs {
    inherit system crossSystem;
    overlays =
      let
        rustOverlay = import rust-overlay;
        cargo2nixOverlay = import ./overlay;
      in
        [ cargo2nixOverlay rustOverlay ] ++ overlays;
  };

  # 2. Builds the rust package set, which contains all crates in your cargo workspace's dependency graph.
  # `makePackageSet'` accepts the following arguments:
  # - `packageFun` (required): The generated `Cargo.nix` file, which returns the whole dependency graph.
  # - `workspaceSrc` (optional): Sources for the workspace can be provided or default to the current directory.
  # - `rustChannel` (required): The Rust channel used to build the package set.
  # - `packageOverrides` (optional):
  #     A function taking a package set and returning a list of overrides.
  #     Overrides are introduced to provide native inputs to build the crates generated in `Cargo.nix`.
  #     See `overlay/lib/overrides.nix` on how to create overrides and `overlay/overrides.nix` for a list of predefined overrides.
  #     Most of the time, you can just use `overrides.all`. You can hand-pick overrides later if your build becomes too slow.
  # - `localPatterns` (optional):
  #     A list of regular expressions that specify what should be included in the sources of your workspace's crates.
  #     The expressions are relative to each crate's manifest directory.
  #     This argument is optional and defaults to include the `src` directory and all `toml` files at the root of the manifest directory.
  # - `rootFeatures` (optional):
  #     A list of activated features on your workspace's crates.
  #     Each feature should be of the form `<crate_name>[/<feature>]`.
  #     If `/<feature>` is omitted, the crate is activated with no default features.
  #     The default behavior is to activate all crates with default features.
  # - `fetchCrateAlternativeRegistry` (optional): A fetcher for crates on alternative registries.
  # - `release` (optional): Whether to enable release mode (equivalent to `cargo build --release`), defaults to `true`.
  # - `hostPlatformCpu` (optional):
  #     Equivalent to rust's target-cpu codegen option. If specified "-Ctarget-cpu=<value>" will be added to the set of rust
  #     flags used for compilation of the package set.
  # - `hostPlatformFeatures` (optional):
  #     Equivalent to rust's target-feature codegen option. If specified "-Ctarget-feature=<values>" will be added to the set of rust
  #     flags used for compilation of the package set. The value should be a list of the features to be turned on, without the leading "+",
  #     e.g. `[ "aes" "sse2" "ssse3" "sse4.1" ]`.  They will be prefixed with a "+", and comma delimited before passing through to rust.
  #     Crates that check for CPU features such as the `aes` crate will be evaluated against this argument.
  rustPkgs = pkgs.rustBuilder.makePackageSet' {
    packageFun = import ./Cargo.nix;
    inherit rustChannel;
    packageOverrides = pkgs: pkgs.rustBuilder.overrides.all;
    localPatterns = [ ''^(src|tests|templates)(/.*)?'' ''[^/]*\.(rs|toml)$'' ];
  };
in
  # `rustPkgs` now contains all crates in the dependency graph.
  # To build normal binaries, use `rustPkgs.<registry>.<crate>.<version> { }`.
  # To build test binaries (equivalent to `cargo build --tests`), use
  #   `rustPkgs.<registry>.<crate>.<version>{ compileMode = "test"; }`.
  # To build bench binaries (equivalent to `cargo build --benches`), use
  #   `rustPkgs.<registry>.<crate>.<version>{ compileMode = "bench"; }`.
  # For convenience, you can also refer to the crates in the workspace using
  #   `rustPkgs.workspace.<crate>`.
rec {
  inherit rustPkgs;
  package = rustPkgs.workspace.cargo2nix {};
  # `runTests` runs all tests for a crate inside a Nix derivation.
  # This may be problematic as Nix may restrict filesystem, network access,
  # socket creation, ... which the test binary may need.
  # If you run to those problems, build test binaries (as shown above) and run them
  # manually outside a Nix derivation.
  ci = pkgs.rustBuilder.runTests rustPkgs.workspace.cargo2nix { };
  # `noBuild` is a special crate set used to create a development shell
  # containing all native dependencies provided by the overrides above.
  # `cargo build` with in the shell should just work.
  shell = pkgs.mkShell {
    inputsFrom = pkgs.lib.mapAttrsToList (_: pkg: pkg { }) rustPkgs.noBuild.workspace;
    nativeBuildInputs = with rustPkgs; [ cargo rustc ];
    RUST_SRC_PATH = "${rustPkgs.rust-src}/lib/rustlib/src/rust/library";
  };
  examples =
    let
      cargo2nix = pkgs.lib.sourceByRegex ./. [
        ''^(overlay|src|tests|templates)(/.*)?''
        ''[^/]*\.(nix|rs|toml)$''
      ];
      importExprsInDir = with pkgs.lib; dir:
        mapAttrsToList
          (name: _: import (dir + "/${name}") { inherit cargo2nix; })
          (pkgs.lib.filterAttrs
            (name: kind: kind == "directory")
            (builtins.readDir dir)
          );
    in
      importExprsInDir ./examples;
      
}
