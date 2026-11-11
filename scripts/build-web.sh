#!/usr/bin/env bash
# Build the Miso client to static/app and refresh the precompressed sidecars.
# Run through `devenv shell -- bash scripts/build-web.sh` (the wasm32-wasi
# toolchain comes from devenv.nix), or directly inside a devenv shell.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v wasm32-wasi-cabal >/dev/null 2>&1; then
  echo "wasm32-wasi-cabal not found; enter the dev environment with 'devenv shell'" >&2
  exit 1
fi
# gzip writes the <file>.gz sidecars the server serves with Content-Encoding.
# It is a devenv package, so a missing gzip means the wrong shell, not a host
# dependency to silently skip.
if ! command -v gzip >/dev/null 2>&1; then
  echo "gzip not found; enter the dev environment with 'devenv shell'" >&2
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

if command -v wasm-opt >/dev/null 2>&1; then
  wasm-opt -O2 --strip-debug static/app/app.wasm -o static/app/app.wasm
fi

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

# Precompressed sidecars for the text assets. The server serves <file>.gz with
# Content-Encoding: gzip when the client accepts it, so a cold load does not pay
# for the uncompressed bytes.
GZIP_FILES=(
  static/index.html
  static/eza.css
  static/pwa.js
  static/theme.js
  static/auth.js
  static/app/index.js
  static/app/ghc_wasm_jsffi.js
  static/vendor/browser_wasi_shim/index.js
  static/vendor/browser_wasi_shim/wasi.js
  static/vendor/browser_wasi_shim/wasi_defs.js
  static/vendor/browser_wasi_shim/fd.js
  static/vendor/browser_wasi_shim/fs_mem.js
  static/vendor/browser_wasi_shim/fs_opfs.js
  static/vendor/browser_wasi_shim/strace.js
  static/vendor/browser_wasi_shim/debug.js
)
for file in "${GZIP_FILES[@]}"; do
  if [[ -f "$file" ]]; then
    gzip_asset "$file"
  fi
done

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
