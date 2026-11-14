#!/usr/bin/env bash
# Compile the Miso client to static/app (wasm32 build, post-link, wasm-opt, and
# the WASM size gates), then hand off to scripts/bundle-web.sh, which turns the
# compiled artifacts and the static sources into the content-addressed bundle
# (hashed files, asset-manifest.json, generated shell and service worker).
#
# Run through `devenv shell -- bash scripts/build-web.sh` (the wasm32-wasi
# toolchain comes from devenv.nix), or directly inside a devenv shell.
#
# --skip-bundle stops after the compile + size gates; scripts/bundle-web.sh
# uses that so the two scripts do not recurse.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE=1
for arg in "$@"; do
  case "$arg" in
    --skip-bundle) BUNDLE=0 ;;
    *)
      echo "build-web: unknown argument: $arg" >&2
      echo "usage: bash scripts/build-web.sh [--skip-bundle]" >&2
      exit 2
      ;;
  esac
done

if ! command -v wasm32-wasi-cabal >/dev/null 2>&1; then
  echo "wasm32-wasi-cabal not found; enter the dev environment with 'devenv shell'" >&2
  exit 1
fi
# The size gate below measures app.wasm.gz, so this compile step needs gzip
# even though scripts/bundle-web.sh writes the publishable .gz sidecars for the
# hashed files. It is a devenv package, so a missing gzip means the wrong shell,
# not a host dependency to silently skip.
if ! command -v gzip >/dev/null 2>&1; then
  echo "gzip not found; enter the dev environment with 'devenv shell'" >&2
  exit 1
fi
# wasm-opt is part of the supported devenv toolchain (binaryen). A release
# build without it is ~40% larger than the documented client, which is a
# user-visible cold-load regression; fail instead of silently shipping it.
if ! command -v wasm-opt >/dev/null 2>&1; then
  echo "wasm-opt not found; enter the dev environment with 'devenv shell' (binaryen)" >&2
  exit 1
fi

# The native and WASM builds use separate Cabal dirs: devenv.nix points the
# native one at <checkout>/.devenv/cabal, this script defaults to
# <checkout>/.devenv/cabal-wasm. EZA_WASM_CABAL_DIR overrides it for a cacheable
# location; CI caches both in-checkout dirs (see .github/workflows/ci.yml). The
# default stays under the checkout so local builds do not pollute ~/.cabal.
export CABAL_DIR="${EZA_WASM_CABAL_DIR:-$ROOT/.devenv/cabal-wasm}"
mkdir -p static/app

# The WASM toolchain builds dynamic objects and interface files (the Miso
# compile loads aeson's .dyn_hi), and a developer's existing Cabal config has
# shared: True / optimization: True from its first build. A fresh Cabal dir
# (CI, release runners, a clean checkout) defaults to shared: False, builds
# aeson without .dyn_hi and then fails the Miso compile with "Failed to load
# dynamic interface file". Pin the two settings in the WASM Cabal config so a
# cold store behaves exactly like a warm one; both writes are idempotent.
mkdir -p "$CABAL_DIR"
if ! grep -qE '^shared: *True' "$CABAL_DIR/config" 2>/dev/null; then
  printf '\nshared: True\n' >> "$CABAL_DIR/config"
fi
if ! grep -qE '^optimization: *True' "$CABAL_DIR/config" 2>/dev/null; then
  printf 'optimization: True\n' >> "$CABAL_DIR/config"
fi

wasm32-wasi-cabal build --project-file=cabal.project.wasm eza-web
BIN="$(wasm32-wasi-cabal list-bin --project-file=cabal.project.wasm eza-web)"
echo "wasm binary: $BIN"

GHC_LIBDIR="$(wasm32-wasi-ghc --print-libdir)"
node "$GHC_LIBDIR/post-link.mjs" --input "$BIN" --output static/app/ghc_wasm_jsffi.js
cp "$BIN" static/app/app.wasm

# -Oz is the size-first Binaryen pass: this binary is transferred and compiled
# on every cold client start, and the graph/ledger compute is dominated by JS
# and SQLite rather than this code. --strip-debug removes the DWARF section.
wasm-opt -Oz --strip-debug --strip-producers --strip-dwarf static/app/app.wasm -o static/app/app.wasm

# gzip_asset FILE compresses FILE to FILE.gz atomically.
#
# The old code redirected straight into "$file.gz" and appended `|| true`:
# the shell truncates the sidecar before gzip runs, so a gzip failure (ENOSPC,
# unreadable input, missing gzip) left an empty/partial file that the server
# happily served as `Content-Encoding: gzip`, breaking the client silently.
# Write to a temp file, keep it only if gzip succeeded, and fail the build
# otherwise. `-n` keeps the source mtime/name out of the gzip header so the
# output is reproducible for the release asset.
gzip_asset() {
  local file="$1"
  local tmp="${file}.gz.tmp.$$"
  if ! gzip -9 -n -c "$file" >"$tmp"; then
    rm -f "$tmp"
    echo "build-web: gzip failed for $file" >&2
    exit 1
  fi
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    echo "build-web: gzip produced an empty sidecar for $file" >&2
    exit 1
  fi
  mv -f "$tmp" "$file.gz"
}

gzip_asset static/app/app.wasm

# A cold client downloads this sidecar before it can start. The 1.7 MB target
# is the product goal; the hard ceiling guards against an accidental debug or
# dependency build while the known 2.04 MB regression is tracked separately.
# Override only for a deliberate experiment.
#
# Raw ceiling: raised from 7,700,000 to 7,800,000 in M2-A (2026-11-14) because
# the native client-logic package and the typed client request table pushed the
# optimized binary to 7,746,298. This is a guard against accidental debug or
# dependency builds, not a product limit; M2-B (moving the reducer and effect
# layer out of the Miso shell) is expected to bring it back under the old
# number. Record any further raise in docs/program/README.md.
WASM_GZIP_TARGET_BYTES="${EZA_WASM_GZIP_TARGET_BYTES:-1700000}"
WASM_GZIP_MAX_BYTES="${EZA_WASM_GZIP_MAX_BYTES:-2200000}"
WASM_RAW_MAX_BYTES="${EZA_WASM_RAW_MAX_BYTES:-7800000}"
WASM_RAW_BYTES="$(wc -c < static/app/app.wasm)"
WASM_GZIP_BYTES="$(wc -c < static/app/app.wasm.gz)"
if (( WASM_RAW_BYTES > WASM_RAW_MAX_BYTES )); then
  echo "build-web: app.wasm is ${WASM_RAW_BYTES} bytes, over the ${WASM_RAW_MAX_BYTES}-byte hard ceiling" >&2
  echo "build-web: check that wasm-opt ran and that no debug build was copied into static/app" >&2
  exit 1
fi
if (( WASM_GZIP_BYTES > WASM_GZIP_MAX_BYTES )); then
  echo "build-web: app.wasm.gz is ${WASM_GZIP_BYTES} bytes, over the ${WASM_GZIP_MAX_BYTES}-byte hard ceiling" >&2
  echo "build-web: check that wasm-opt ran and that no debug build was copied into static/app" >&2
  exit 1
fi
if (( WASM_GZIP_BYTES > WASM_GZIP_TARGET_BYTES )); then
  echo "build-web: warning: app.wasm.gz is ${WASM_GZIP_BYTES} bytes, over the ${WASM_GZIP_TARGET_BYTES}-byte target; review WASM growth" >&2
fi
echo "wasm: ${WASM_RAW_BYTES} raw / ${WASM_GZIP_BYTES} gzip (target ${WASM_GZIP_TARGET_BYTES}, max ${WASM_GZIP_MAX_BYTES})"

# The bundler owns the publishable tree: it hashes every asset, writes the gzip
# sidecars, renders the shell and the service worker, and emits
# static/asset-manifest.json. Compiling and bundling stay separate commands so
# `bash scripts/bundle-web.sh --no-build` can rebuild the bundle over an
# existing static/app without recompiling the client.
if [[ "$BUNDLE" == "1" ]]; then
  bash "$ROOT/scripts/bundle-web.sh" --no-build
fi
