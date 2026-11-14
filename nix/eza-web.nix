{
  lib,
  pkgs,
  ghc-wasm-meta,
  system,
  version,
  src,
}:
# The WebAssembly client, built inside Nix.
#
# The wasm32-wasi GHC toolchain comes from the ghc-wasm-meta flake input. The
# Hackage releases the wasm dependency plan needs are fixed-output fetchurls
# listed in ./wasm-hackage.nix, and their solver metadata (the latest published
# Hackage revision of each .cabal file) is vendored under ./wasm-cabal/. The
# build assembles a small local Hackage repository from those two inputs, so
# the derivation itself never touches the network. The plan is pinned by
# cabal.project.wasm.freeze; the tarball list, the vendored .cabal files, and
# the freeze file change together when the wasm dependency set changes.
#
# The dependency store is built by its own derivation keyed only on the wasm
# build plan (project file, package .cabal files, freeze file, toolchain), so a
# client source change only relinks the shell and re-runs the bundler.
#
# The bundle itself is produced by the same scripts the developer path uses
# (scripts/build-web.sh, which compiles, runs the size gates, and calls
# scripts/bundle-web.sh to write the content-addressed manifest/shell/service
# worker), so there is exactly one bundling implementation.
let
  wasmTools = ghc-wasm-meta.packages.${system}.default;
  hackage = import ./wasm-hackage.nix;
  buildTools = [
    wasmTools
    pkgs.bash
    pkgs.cacert
    pkgs.coreutils
    pkgs.findutils
    pkgs.gnused
    pkgs.gzip
    pkgs.python3
  ];

  # A package tarball is immutable; pin each one by SRI hash.
  hackageTarball =
    package:
    pkgs.fetchurl {
      name = "${package.name}-${package.version}.tar.gz";
      url = "https://hackage.haskell.org/package/${package.name}-${package.version}/${package.name}-${package.version}.tar.gz";
      inherit (package) hash;
    };

  # The local Hackage repository: the vendored package metadata becomes an
  # old-format index, and the fixed-output tarballs become the package payload.
  # cabal resolves the frozen plan from this file:// URL with no network.
  hackageRepo = pkgs.runCommand "eza-hackage-repo-${version}" {
    nativeBuildInputs = [ pkgs.python3 ];
  } ''
    mkdir -p $out/package
    cat > $TMPDIR/cabal-manifest.txt <<EOF
    ${lib.concatMapStringsSep "\n" (package: "${package.name} ${package.version}") hackage.packages}
    EOF
    python3 ${./build-wasm-index.py} "$TMPDIR/cabal-manifest.txt" ${./wasm-cabal} "$out/00-index.tar.gz"
    ${lib.concatMapStringsSep "\n" (
      package:
      "python3 ${./patch-wasm-cabal.py} '${package.name}' '${package.version}' "
      + "${hackageTarball package} ${./wasm-cabal}/${package.name}-${package.version}.cabal "
      + "\"$out/package/${package.name}-${package.version}.tar.gz\""
    ) hackage.packages}
  '';

  # The offline CABAL_DIR setup both wasm derivations use: a writable HOME and
  # CABAL_DIR, the file:// Hackage repository, and the shared/optimization
  # settings scripts/build-web.sh would otherwise append (so the built output
  # matches a developer build).
  cabalConfig = ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    export CABAL_DIR="$TMPDIR/cabal"
    mkdir -p "$CABAL_DIR"
    cat > "$CABAL_DIR/config" <<EOF
    repository hackage.haskell.org
      url: file://${hackageRepo}
      secure: False
    remote-repo-cache: $CABAL_DIR/packages
    jobs: \$ncpus
    shared: True
    optimization: True
    EOF
    SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
    export SSL_CERT_FILE
    cabal update
  '';

  # Dependency store keyed on the plan only. Local package sources are not
  # needed: cabal reads their .cabal files to solve the plan and builds only
  # the Hackage dependencies here.
  wasmDeps = pkgs.runCommand "eza-wasm-deps-${version}" {
    nativeBuildInputs = buildTools;
  } ''
    set -euo pipefail
    ${cabalConfig}
    mkdir -p "$TMPDIR/project"
    cd "$TMPDIR/project"
    cp ${src}/cabal.project.wasm ${src}/cabal.project.wasm.freeze .
    for package in core web-logic web; do
      mkdir -p "$package"
      cp ${src}/$package/*.cabal "$package/"
    done
    wasm32-wasi-cabal build --project-file=cabal.project.wasm --only-dependencies all
    mkdir -p $out
    cp -a "$CABAL_DIR/store" "$out/store"
  '';
in
pkgs.runCommand "eza-web-${version}" {
  nativeBuildInputs = buildTools;
  meta = {
    description = "eza web client bundle (content-addressed static tree built from source)";
    homepage = "https://github.com/meillaya/eza";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
  };
} ''
  set -euo pipefail
  ${cabalConfig}

  mkdir -p source
  cp -a ${src}/. source/
  chmod -R u+w source
  cd source

  # Reuse the prebuilt dependency store: only the local packages compile here,
  # so a client source change is a short relink plus the bundler.
  ln -s ${wasmDeps}/store "$CABAL_DIR/store"

  # scripts/build-web.sh defaults CABAL_DIR to a checkout-local directory; the
  # override points it at the pre-populated offline store above. The compile,
  # the WASM size gates, and the bundler are the developer path unchanged.
  export EZA_WASM_CABAL_DIR="$CABAL_DIR"
  # Do not override the size gates: the same scripts/build-web.sh ceiling must
  # reject a regression in the reproducible release build too.
  bash scripts/build-web.sh

  mkdir -p "$out/share/eza/static"
  cp -a static/. "$out/share/eza/static/"

  # The server refuses to start without this manifest, so a bundle missing it
  # (or missing the hashed wasm it names) must fail the build, not the deploy.
  manifest="$out/share/eza/static/asset-manifest.json"
  test -f "$manifest"
  grep -q '"schema_version": 1' "$manifest"
  grep -q '"build_id":' "$manifest"
  grep -q '"app.wasm"' "$manifest"
  grep -q '"precache": \[' "$manifest"
  test -f "$out/share/eza/static/index.html"
  test -f "$out/share/eza/static/sw.js"
  grep -q "eza-app-shell-" "$out/share/eza/static/sw.js"
  ls "$out/share/eza/static/app/app."*.wasm >/dev/null
''
