# cargo2nix

[![Build Status][build-badge]][build-url]

[build-badge]: https://circleci.com/gh/cargo2nix/cargo2nix.svg?style=shield
[build-url]: https://circleci.com/gh/cargo2nix/cargo2nix

[Nixify](https://nixos.org/nix) your Rust projects today with `cargo2nix`,
bringing you reproducible builds and better caching.

This repository hosts two components:

- A [Nixpkgs](https://github.com/NixOS/nixpkgs) overlay, located at the `/overlay`
  directory, providing utilities to build and test your Cargo workspace.
  
- A utility written in Rust to generate version pins of crate dependencies.
  
Together, these components will take an existing `Cargo.lock` and delegate the
process of fetching and compiling your dependencies (generated by Cargo) using
the deterministic Nix package manager.

## Install

This project assumes that the [Nix package manager](https://nixos.org/nix) is
already installed on your machine. Run the command below to install `cargo2nix`:

```bash
nix-env -iA package -f https://github.com/cargo2nix/cargo2nix/tarball/master
```

## How to use this for your Rust projects

### As a build system

The basic process of converting an existing Cargo project to `cargo2nix` boils
down to the following steps:

1. Generate a `Cargo.nix` file by running `cargo2nix -f` at the root of your
   Cargo workspace.
2. Create a `default.nix` file which imports Nixpkgs with the [cargo2nix] and
   [nixpkgs-mozilla] overlays and builds your project using the `Cargo.nix` file
   from earlier.
3. Run `nix-build` to compile and/or test your project.

[nixpkgs-mozilla]: https://github.com/mozilla/nixpkgs-mozilla#rust-overlay
[cargo2nix]: ./overlay

Check out our series of [example projects](./examples) which showcase how to use
`cargo2nix` in detail.

### Declarative debug & development shell

You can load a `nix-shell` for any crate derivation in the dependency tree. The
advantage of this shell is that in this environment users can develop their
crates and be sure that their crates builds in the same way that `cargo2nix`
overlay will build them.

To do this, first run `nix-shell -A 'rustPkgs.<registry>.<crate>."x.y.z"'
default.nix`.  For instance, the following command being invoked in this
repository root drops you into such a development shell.

```bash
# When a crate is not associated with any registry, such as when building locally,
# the registry is "unknown" as shown below:
nix-shell -A 'rustPkgs.unknown.cargo2nix."0.9.0"' default.nix

# This crate is a dependency that we may be debugging. Use the --pure switch if
# impurities from your current environment may be polluting the nix build:
nix-shell --pure -A 'rustPkgs."registry+https://github.com/rust-lang/crates.io-index".openssl."0.10.30"' default.nix

# If you are working on a dependency and need the source (or a fresh copy) you
# can unpack the $src variable. Through nix stdenv, tar is available in pure 
# shells
mkdir debug
cp $src debug
cd debug
tar -xzfv $(basename $src)
cd <unpacked source>
```

You will need to override your `Cargo.toml` and `Cargo.lock` in this shell, so
make sure that you have them backed up if your are directly using your clone of
your project instead of unpacking fresh sources like above.

Now you just need to run the `$configurePhase` and `$buildPhase` steps in order.
You can find additional phases that may exist in overrides by running `env |
grep Phase`

```bash
echo $configurePhase 
# runHook preConfigure runHook configureCargo runHook postConfigure

runHook preConfigure
runHook configureCargo
runHook postConfigure

echo $buildPhase
# runHook overrideCargoManifest runHook setBuildEnv runHook runCargo

runHook overrideCargoManifest  # This overrides your .cargo folder, e.g. for setting cross-compilers
runHook setBuildEnv  # This sets up linker flags for the `rustc` invocations
runHook runCargo
```

If `runCargo` succeeds, you will have a completed output ready for the (usually)
less interesting `$installPhase`. If there's a problem, inspecting the `env` or
reading the generated `Cargo.lock` etc should yield clues.  If you've unpacked a
fresh source and are using the `--pure switch`, everything is identical to how
the overlay builds the crate, cutting out guess work.

## Common issues

1. When building `sys` crates, native dependencies that `build.rs` scripts may
   themselves attempt to provide could be missing. See the
   `overlay/overrides.nix` for patterns of common solutions for fixing up
   specific deps.
   
   To provide your own override, pass a modified `packageOverrides` to
   `pkgs.rustBuilder.makePackageSet'`:
   
   ```nix
     rustPkgs = pkgs.rustBuilder.makePackageSet' {
       # ... required arguments not shown
     
       # Use the existing all list of overrides and append your override
       packageOverrides = pkgs: pkgs.rustBuilder.overrides.all ++ [
       
         # parentheses disambiguate each makeOverride call as a single list element
         (pkgs.rustBuilder.rustLib.makeOverride {
             name = "fantasy-zlib-sys";
             overrideAttrs = drv: {
               propagatedNativeBuildInputs = drv.propagatedNativeBuildInputs or [ ] ++ [
                 pkgs.zlib.dev
               ];
             };
         })
         
       ];
     };
   ```
   
1. When re-vendoring nixpkgs-mozilla or cargo2nix, pay attention to the revs of
   nixpkgs, the nixpkgs-mozilla overlay, and the cargo2nix overlay. Certain
   non-release versions of nixpkgs-mozilla have shipped with a `rustc` that
   doesn't include zlib in its runtime dependencies.
   
1. Many `crates.io` public crates may not build using the current Rust compiler,
   unless a lint cap is put on these crates. For instance, `cargo2nix` caps all
   lints to `warn` by default.

1. `Error: Cannot convert data to TOML (Invalid type <class 'NoneType'>)`
   
   This issue will be taken care of when #149 gets fixed.

   Another toml issue is that Nix 2.1.3 ships with a broken `builtins.fromTOML`
   function which is unable to parse lines of TOML that look like this:

   ```toml
   [target.'cfg(target_os = "linux")'.dependencies.rscam]
   ```

   If Nix fails to parse your project's `Cargo.toml` manifest with an error
   similar to the one below, please upgrade to a newer version of Nix. Versions
   2.3.1 and newer are not affected by this bug. If upgrading is not an option,
   removing the inner whitespace from the problematic keys should work around
   this issue.

   ```text
   error: while parsing a TOML string at /nix/store/.../overlay/mkcrate.nix:31:14: Bare key 'cfg(target_os = "linux")' cannot contain whitespace at line 45
   ```

1. Git dependencies and crates from alternative Cargo registries rely on
   `builtins.fetchGit` to support fetching from private Git repositories. This
   means that such dependencies cannot be evaluated with `restrict-eval`
   applied.

   Also, if your Git dependency is tied to a Git branch, e.g. `master`, and you
   would like to force it to update on upstream changes, you should append
   `--option tarball-ttl 0` to your `nix-build` command.

## Design

This Nixpkgs overlay builds your Rust crates and binaries by first pulling the
dependencies apart, building them individually as separate Nix derivations and
linking them together. This is achieved by passing custom linker flags to the
`cargo` invocations and the underlying `rustc` and `rustdoc` invocations.

In addition, this overlay takes cross-compilation into account and build the
crates onto the correct host platform configurations with the correct
platform-dependent feature flags specified in the Cargo manifests and build-time
dependencies.

## Credits

The design for the Nix overlay is inspired by the excellent work done by James
Kay, which is described [here][blog-1] and [here][blog-2]. His source is
available [here][mkRustCrate]. This work would have been impossible without
these fantastic write-ups. Special thanks to James Kay!

[blog-1]: https://www.hadean.com/blog/managing-rust-dependencies-with-nix-part-i
[blog-2]: https://www.hadean.com/blog/managing-rust-dependencies-with-nix-part-ii
[mkRustCrate]: https://github.com/Twey/mkRustCrate

## License

`cargo2nix` is free and open source software distributed under the terms of the
[MIT License](./LICENSE).
