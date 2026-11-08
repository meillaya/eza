#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v wasm32-wasi-cabal >/dev/null 2>&1; then
  echo "wasm32-wasi-cabal not found; enter the dev environment with 'devenv shell'" >&2
  exit 1
fi

export CABAL_DIR="$ROOT/.devenv/cabal-wasm"
mkdir -p static/app

wasm32-wasi-cabal build --project-file=cabal.project.wasm eza-web
BIN="$(wasm32-wasi-cabal list-bin --project-file=cabal.project.wasm eza-web)"
echo "wasm binary: $BIN"

GHC_LIBDIR="$(wasm32-wasi-ghc --print-libdir)"
node "$GHC_LIBDIR/post-link.mjs" --input "$BIN" --output static/app/ghc_wasm_jsffi.js
cp "$BIN" static/app/app.wasm

if command -v wasm-opt >/dev/null 2>&1; then
  wasm-opt -O2 --strip-debug static/app/app.wasm -o static/app/app.wasm
fi

gzip -9 -c static/app/app.wasm > static/app/app.wasm.gz || true

# The server serves /sw.js with this id in its version, so a rebuild invalidates
# the service worker and open tabs refresh themselves on the next load.
BUILD_ID="$(
  {
    sha256sum \
      static/app/app.wasm \
      static/app/ghc_wasm_jsffi.js \
      static/app/index.js \
      static/eza.css \
      static/index.html \
      static/pwa.js \
      static/sw.js \
      static/theme.js \
      static/auth.js \
      static/manifest.webmanifest 2>/dev/null || true
  } | sha256sum | cut -c1-16
)"
printf '%s\n' "$BUILD_ID" > static/app/build-id
echo "web assets written to static/app (build $BUILD_ID)"
