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
echo "web assets written to static/app"
