{
  cargo,
  rustc,

  lib,
  pkgs,
  buildPackages,
  rustLib,
  stdenv,
}:
{
  release, # Compiling in release mode?
  name,
  version,
  registry,
  src,
  features ? [ ],
  dependencies ? { },
  devDependencies ? { },
  buildDependencies ? { },
  compileMode ? "build",
  profile,
  meta ? { },
  rustcflags ? [ ],
  rustcBuildFlags ? [ ],
  hostPlatformCpu ? null,
  hostPlatformFeatures ? [],
  NIX_DEBUG ? 0,
}:
with builtins; with lib;
let
  inherit (rustLib) realHostTriple decideProfile;

  wrapper = rustpkg: pkgs.writeScriptBin rustpkg ''
    #!${stdenv.shell}
    . ${./utils.sh}
    isBuildScript=
    args=("$@")
    for i in "''${!args[@]}"; do
      if [ "xmetadata=" = "x''${args[$i]::9}" ]; then
        args[$i]=metadata=$NIX_RUST_METADATA
      elif [ "x--crate-name" = "x''${args[$i]}" ] && [ "xbuild_script_" = "x''${args[$i+1]::13}" ]; then
        isBuildScript=1
      fi
    done
    if [ "$isBuildScript" ]; then
      args+=($NIX_RUST_BUILD_LINK_FLAGS)
    else
      args+=($NIX_RUST_LINK_FLAGS)
    fi
    touch invoke.log
    echo "''${args[@]}" >>invoke.log
    exec ${rustc}/bin/${rustpkg} "''${args[@]}"
  '';

  ccForBuild="${buildPackages.stdenv.cc}/bin/${buildPackages.stdenv.cc.targetPrefix}cc";
  cxxForBuild="${buildPackages.stdenv.cc}/bin/${buildPackages.stdenv.cc.targetPrefix}c++";
  targetPrefix = stdenv.cc.targetPrefix;
  cc = stdenv.cc;
  ccForHost="${cc}/bin/${targetPrefix}cc";
  cxxForHost="${cc}/bin/${targetPrefix}c++";
  host-triple = realHostTriple stdenv.hostPlatform;
  depMapToList = deps:
    flatten
      (sort (a: b: elemAt a 0 < elemAt b 0)
        (mapAttrsToList (name: value: [ name "${value}" ]) deps));
  buildCmd =
    let
      hasDefaultFeature = elem "default" features;
      featuresWithoutDefault = if hasDefaultFeature
        then filter (feature: feature != "default") features
        else features;
      buildMode = {
        "test" = "--tests";
        "bench" = "--benches";
      }.${compileMode} or "";
      featuresArg = if featuresWithoutDefault == [ ]
        then ""
        else "--features ${concatStringsSep "," featuresWithoutDefault}";
    in
      ''
        cargo build $CARGO_VERBOSE ${optionalString release "--release"} --target ${host-triple} ${buildMode} \
          ${featuresArg} ${optionalString (!hasDefaultFeature) "--no-default-features"} \
          --message-format=json | tee .cargo-build-output
      '';

  inherit
    (({ right, wrong }: { runtimeDependencies = right; buildtimeDependencies = wrong; })
      (partition (drv: drv.stdenv.hostPlatform == stdenv.hostPlatform)
        (concatLists [
          (attrValues dependencies)
          (optionals (compileMode == "test" || compileMode == "bench") (attrValues devDependencies))
          (attrValues buildDependencies)
        ])))
    runtimeDependencies buildtimeDependencies;

  drvAttrs = {
    inherit src version meta NIX_DEBUG;
    name = "crate-${name}-${version}${optionalString (compileMode != "build") "-${compileMode}"}";
    buildInputs = runtimeDependencies;
    propagatedBuildInputs = concatMap (drv: drv.propagatedBuildInputs) runtimeDependencies;
    nativeBuildInputs = [ cargo ] ++ buildtimeDependencies;

    depsBuildBuild =
      let inherit (buildPackages.buildPackages) stdenv jq remarshal;
      in [ stdenv.cc jq remarshal ];

    # Running the default `strip -S` command on Darwin corrupts the
    # .rlib files in "lib/".
    #
    # See https://github.com/NixOS/nixpkgs/pull/34227
    stripDebugList = if stdenv.isDarwin then [ "bin" ] else null;

    passthru = {
      inherit
        name
        version
        registry
        dependencies
        devDependencies
        buildDependencies
        features;
      shell = pkgs.mkShell (removeAttrs drvAttrs ["src"]);
    };

    dependencies = depMapToList dependencies;
    buildDependencies = depMapToList buildDependencies;
    devDependencies = depMapToList (optionalAttrs (compileMode == "test" || compileMode == "bench") devDependencies);

    extraRustcFlags =
      optionals (hostPlatformCpu != null) ([("-Ctarget-cpu=" + hostPlatformCpu)]) ++
      optionals (hostPlatformFeatures != []) [("-Ctarget-feature=" + (concatMapStringsSep "," (feature: "+" + feature) hostPlatformFeatures))] ++
      rustcflags;

    extraRustcBuildFlags = rustcBuildFlags;

    # HACK: 2019-08-01: wasm32-wasi always uses `wasm-ld`
    configureCargo = ''
      mkdir -p .cargo
      cat > .cargo/config <<'EOF'
      [target."${realHostTriple stdenv.buildPlatform}"]
      linker = "${ccForBuild}"
    '' + optionalString (stdenv.buildPlatform != stdenv.hostPlatform && !(stdenv.hostPlatform.isWasi or false)) ''
      [target."${host-triple}"]
      linker = "${ccForHost}"
    '' + ''
      EOF
    '';

    configurePhase = ''
      runHook preConfigure
      runHook configureCargo
      runHook postConfigure
    '';

    manifestPatch = toJSON {
      features = genAttrs features (_: [ ]);
      profile.${ decideProfile compileMode release } = profile;
    };

    overrideCargoManifest = ''
      echo "[[package]]" > Cargo.lock
      echo name = \"${name}\" >> Cargo.lock
      echo version = \"${version}\" >> Cargo.lock
      registry="${registry}"
      if [ "$registry" != "unknown" ]; then
        echo source = \"registry+''${registry}\" >> Cargo.lock
      fi
      mv Cargo.toml Cargo.original.toml
      # Remarshal was failing on table names of the form:
      # [key."cfg(foo = \"a\", bar = \"b\"))".path]
      # The regex to find or deconstruct these strings must find, in order,
      # these components: open bracket, open quote, open escaped quote, and
      # their closing pairs.  Because each quoted path can contain multiple
      # quote escape pairs, a loop is employed to match the first quote escape,
      # which the sed will replace with a single quote equivalent until all
      # escaped quote pairs are replaced.  The grep regex is identical to the
      # sed regex but does not destructure the match into groups for
      # restructuring in the replacement.
      while grep '\[[^"]*"[^\\"]*\\"[^\\"]*\\"[^"]*[^]]*\]' Cargo.original.toml; do
        sed -i -r 's/\[([^"]*)"([^\\"]*)\\"([^\\"]*)\\"([^"]*)"([^]]*)\]/[\1"\2'"'"'\3'"'"'\4"\5]/g' Cargo.original.toml
      done;
      remarshal -if toml -of json Cargo.original.toml \
        | jq "{ package: .package
              , lib: .lib
              , bin: .bin
              , test: .test
              , example: .example
              , bench: (if \"$registry\" == \"unknown\" then .bench else null end)
              } | with_entries(select( .value != null ))
              + $manifestPatch" \
        | jq "del(.[][] | nulls)" \
        | remarshal -if json -of toml > Cargo.toml
    '';

    setBuildEnv = ''
      MINOR_RUSTC_VERSION="$(${rustc}/bin/rustc --version | cut -d . -f 2)"

      if (( MINOR_RUSTC_VERSION < 41 )); then
        isProcMacro="$(
          remarshal -if toml -of json Cargo.original.toml \
          | jq -r 'if .lib."proc-macro" or .lib."proc_macro" then "1" else "" end' \
        )"
      fi

      crateName="$(
        remarshal -if toml -of json Cargo.original.toml \
        | jq -r 'if .lib."name" then .lib."name" else "${replaceChars ["-"] ["_"] name}" end' \
      )"

      . ${./utils.sh}

      export CARGO_VERBOSE=`cargoVerbosityLevel $NIX_DEBUG`
      export NIX_RUST_METADATA=`extractHash $out`
      export CARGO_HOME=`pwd`/.cargo

      mkdir -p deps build_deps
      linkFlags=(`makeExternCrateFlags $dependencies $devDependencies`)
      buildLinkFlags=(`makeExternCrateFlags $buildDependencies`)
      linkExternCrateToDeps `realpath deps` $dependencies $devDependencies
      linkExternCrateToDeps `realpath build_deps` $buildDependencies

      export NIX_RUST_LINK_FLAGS="''${linkFlags[@]} -L dependency=$(realpath deps) $extraRustcFlags"
      export NIX_RUST_BUILD_LINK_FLAGS="''${buildLinkFlags[@]} -L dependency=$(realpath build_deps) $extraRustcBuildFlags"
      export RUSTC=${wrapper "rustc"}/bin/rustc
      export RUSTDOC=${wrapper "rustdoc"}/bin/rustdoc

      depKeys=(`loadDepKeys $dependencies`)

      if (( NIX_DEBUG >= 1 )); then
        echo $NIX_RUST_LINK_FLAGS
        echo $NIX_RUST_BUILD_LINK_FLAGS
        for key in ''${depKeys[@]}; do
          echo $key
        done
      fi
    '';

    runCargo = ''
      (
        set -euo pipefail
        if (( NIX_DEBUG >= 1 )); then
          set -x
        fi
        env \
          "CC_${stdenv.buildPlatform.config}"="${ccForBuild}" \
          "CXX_${stdenv.buildPlatform.config}"="${cxxForBuild}" \
          "CC_${host-triple}"="${ccForHost}" \
          "CXX_${host-triple}"="${cxxForHost}" \
          "''${depKeys[@]}" \
          ${buildCmd}
      )
    '';

    buildPhase = ''
      runHook overrideCargoManifest
      runHook setBuildEnv
      runHook runCargo
    '';

    outputs = ["out" "bin"];

    installPhase = ''
      mkdir -p $out/lib
      cargo_links="$(remarshal -if toml -of json Cargo.original.toml | jq -r '.package.links | select(. != null)')"
      if (( MINOR_RUSTC_VERSION < 41 )); then
        install_crate ${host-triple} ${if release then "release" else "debug"}
      else
        install_crate2 ${host-triple}
      fi
    '';
  };
in
  stdenv.mkDerivation drvAttrs
