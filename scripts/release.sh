#!/usr/bin/env bash
# Build a self-contained eza release tarball:
#   dist/eza-<version>-x86_64-linux.tar.gz
# with bin/eza-bookmarks, share/eza/static, the SecretSpec manifest, and the
# licence/notice files the Apache-2.0 binary distribution must carry.
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
mkdir -p "$OUT/bin" "$OUT/share/eza"

cp "$BIN" "$OUT/bin/eza-bookmarks"
cp -a static "$OUT/share/eza/static"
cp secretspec.toml "$OUT/share/eza/secretspec.toml"
cp LICENSE "$OUT/share/eza/LICENSE"
cp THIRD-PARTY-NOTICES.md "$OUT/share/eza/THIRD-PARTY-NOTICES.md"

if [ -d extension ]; then
  mkdir -p "$OUT/share/eza/extension"
  tar --exclude=node_modules --exclude=dist -C extension -cf - . | tar -C "$OUT/share/eza/extension" -xf -
fi
if [ -d sidecar ]; then
  mkdir -p "$OUT/share/eza/sidecar"
  tar --exclude=node_modules -C sidecar -cf - . | tar -C "$OUT/share/eza/sidecar" -xf -
fi

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
