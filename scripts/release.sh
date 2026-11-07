#!/usr/bin/env bash
# Build a self-contained eza release tarball:
#   dist/eza-<version>-x86_64-linux.tar.gz
# with bin/eza-bookmarks, share/eza/static, and the SecretSpec manifest.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${EZA_RELEASE_VERSION:-0.1.0}"
OUT="dist/release/eza-${VERSION}"
mkdir -p "dist/release"

cabal build exe:eza-bookmarks
BIN="$(cabal list-bin exe:eza-bookmarks)"

bash scripts/build-web.sh

rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/share/eza/static/app" "$OUT/share/eza/static/vendor"

cp "$BIN" "$OUT/bin/eza-bookmarks"
cp static/index.html static/eza.css static/theme.js static/auth.js static/favicon.svg "$OUT/share/eza/static/" 2>/dev/null || true
cp static/favicon-fallback.svg "$OUT/share/eza/static/" 2>/dev/null || true
cp -r static/app/. "$OUT/share/eza/static/app/"
cp -r static/vendor/. "$OUT/share/eza/static/vendor/"
cp secretspec.toml "$OUT/share/eza/secretspec.toml"

cat > "$OUT/share/eza/README.txt" <<'EOF'
Run:
  EZA_STATIC_DIR=$PWD/share/eza/static \
  EZA_DATA_DIR=$PWD/data \
  PUBLIC_ORIGIN=https://your-eza-host.example \
  ./bin/eza-bookmarks serve
EOF

TARBALL="dist/release/eza-${VERSION}-x86_64-linux.tar.gz"
tar -C dist/release -czf "$TARBALL" "eza-${VERSION}"
echo "release: $TARBALL"
sha256sum "$TARBALL"
