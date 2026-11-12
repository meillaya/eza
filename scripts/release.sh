#!/usr/bin/env bash
# Build the eza release artifacts. Run with plain bash from the repo root:
#
#   bash scripts/release.sh
#
# Output (dist/release/):
#   eza-web-<version>.tar.gz              the deployment flake's web bundle asset
#                                         (same file .github/workflows/release.yml
#                                         uploads and nix/web-assets.json pins)
#   eza-<version>-<arch>-linux.tar.gz     server binary + static bundle +
#                                         extension + sidecar + licence/notices
#   SHA256SUMS                            checksums for both
#
# Version: derived from flake.nix via scripts/version.sh, which also verifies
# the Cabal packages agree (0.2.0.0). There is no separate release version.
#
# Binary: built through the deployment flake (`nix build .#eza-bookmarks`) when
# Nix is available, so the artifact is the reproducible package rather than an
# ad-hoc dev-shell build. Without Nix (or with --cabal) it falls back to
# `cabal build exe:eza-bookmarks` with a loud warning.
#
# Portability: both build paths produce a binary dynamically linked to the Nix
# store (glibc, gmp, ...) on a normal Nix host. The script inspects the ELF
# interpreter, prints a loud warning and records the closure in the tarball;
# pass --require-portable to make a host-bound binary a hard error. The
# supported portable artifact is the Docker image (`nix build .#docker`); a
# bare tarball can only run on a host with the same Nix store closure.
#
# Options:
#   --cabal              force `cabal build` instead of `nix build`
#   --nix                force `nix build` (fail instead of falling back)
#   --require-portable   fail when the binary's ELF interpreter is in /nix/store
#   --allow-host-bound   accept a host-bound binary silently (no warning block)
#   --no-web             skip the web bundle / release asset (server tarball only)
#   --help               print this help
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_MODE="auto"
REQUIRE_PORTABLE=0
ALLOW_HOST_BOUND=0
BUILD_WEB=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cabal) BUILD_MODE="cabal" ;;
    --nix) BUILD_MODE="nix" ;;
    --require-portable) REQUIRE_PORTABLE=1 ;;
    --allow-host-bound) ALLOW_HOST_BOUND=1 ;;
    --no-web) BUILD_WEB=0 ;;
    -h | --help)
      sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "release.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

VERSION="$(bash scripts/version.sh)"
PLATFORM="${EZA_RELEASE_PLATFORM:-$(uname -m)-linux}"
DIST="$ROOT/dist/release"
OUT="$DIST/eza-${VERSION}"
ASSET_NAME="eza-web-${VERSION}.tar.gz"
TARBALL="$DIST/eza-${VERSION}-${PLATFORM}.tar.gz"

log() { printf 'release: %s\n' "$*" >&2; }
die() {
  printf 'release: error: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$DIST"
WARNINGS=""

# ---------------------------------------------------------------------------
# Web asset (the file the deployment flake pins; see nix/web-assets.json)
# ---------------------------------------------------------------------------
if [ "$BUILD_WEB" -eq 1 ]; then
  log "building the web bundle and dist/$ASSET_NAME"
  bash scripts/release-asset.sh --out "$DIST" || die "scripts/release-asset.sh failed"
  [ -s "$DIST/$ASSET_NAME" ] || die "expected $DIST/$ASSET_NAME"
else
  log "skipping the web asset (--no-web)"
  if [ -f "$DIST/$ASSET_NAME" ]; then
    log "using the existing $DIST/$ASSET_NAME"
  fi
fi

# ---------------------------------------------------------------------------
# Server binary
# ---------------------------------------------------------------------------
BIN=""
BUILD_SOURCE=""
if [ "$BUILD_MODE" != "cabal" ] && command -v nix >/dev/null 2>&1; then
  log "building the reproducible flake package: nix build path:.#eza-bookmarks"
  nix_out="$(mktemp)"
  if nix build --no-link --print-out-paths "path:$ROOT#eza-bookmarks" >"$nix_out" 2>&1; then
    BIN="$(head -n 1 "$nix_out")/bin/eza-bookmarks"
    BUILD_SOURCE="nix build .#eza-bookmarks"
  else
    if [ "$BUILD_MODE" = "nix" ]; then
      cat "$nix_out" >&2
      rm -f "$nix_out"
      die "'nix build .#eza-bookmarks' failed (--nix given; not falling back to cabal)"
    fi
    log "warning: nix build failed; falling back to the development cabal build"
    log "         (a cabal build is not the documented reproducible artifact)"
    rm -f "$nix_out"
  fi
fi
if [ -z "$BIN" ]; then
  command -v cabal >/dev/null 2>&1 || die "neither a working 'nix build' nor cabal is available"
  log "building with cabal (development build; host-bound)"
  cabal build exe:eza-bookmarks || die "cabal build exe:eza-bookmarks failed"
  BIN="$(cabal list-bin exe:eza-bookmarks)" || die "cabal list-bin failed"
  BUILD_SOURCE="cabal build exe:eza-bookmarks"
fi
[ -x "$BIN" ] || die "built binary is not executable: $BIN"
log "binary: $BIN ($BUILD_SOURCE)"

# ---------------------------------------------------------------------------
# Portability check (ELF interpreter in the Nix store = host-bound)
# ---------------------------------------------------------------------------
HOST_BOUND=0
INTERPRETER=""
if command -v readelf >/dev/null 2>&1; then
  INTERPRETER="$(readelf -l "$BIN" 2>/dev/null | sed -n 's/.*interpreter: \(.*\)]/\1/p' | head -n 1)"
elif command -v file >/dev/null 2>&1; then
  INTERPRETER="$(file "$BIN" 2>/dev/null | sed -n 's/.*interpreter \([^,]*\).*/\1/p' | head -n 1)"
fi
case "$INTERPRETER" in
  /nix/store/*) HOST_BOUND=1 ;;
esac

if [ "$HOST_BOUND" -eq 1 ]; then
  WARNINGS="${WARNINGS}The eza-bookmarks binary in this tarball is dynamically linked to
the build host's Nix store (ELF interpreter: ${INTERPRETER}).
It runs only on a host that has the same Nix store closure. The supported
portable artifact is the Docker image: nix build .#docker && docker load < result.
The runtime closure is recorded in share/eza/BUILD-INFO.txt.
"
  if [ "$ALLOW_HOST_BOUND" -eq 0 ]; then
    log "warning: the binary is host-bound to the Nix store (interpreter: $INTERPRETER)"
    log "         a bare tarball cannot run on a non-Nix host; prefer 'nix build .#docker'"
    log "         pass --allow-host-bound to silence this warning"
  fi
  if [ "$REQUIRE_PORTABLE" -eq 1 ]; then
    printf '%s' "$WARNINGS" >&2
    die "--require-portable: the built binary is host-bound; ship the Docker image or build a static/musl binary instead"
  fi
fi
if [ "$BUILD_MODE" = "cabal" ] && [ "$HOST_BOUND" -eq 0 ] && [ -n "$INTERPRETER" ]; then
  log "note: cabal-built binary interpreter: $INTERPRETER"
fi
if [ -z "$INTERPRETER" ]; then
  log "note: could not inspect the ELF interpreter (readelf/file missing); portability unverified"
fi

# ---------------------------------------------------------------------------
# Stage the tarball
# ---------------------------------------------------------------------------
log "staging $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/share/eza"

cp "$BIN" "$OUT/bin/eza-bookmarks"
if [ -d static/app ] && [ -f static/index.html ]; then
  # A release tarball serves the bundle from share/eza/static. The web asset
  # tarball is the flake-pinned copy of the same tree.
  cp -a static "$OUT/share/eza/static"
  if [ -f "$DIST/$ASSET_NAME" ]; then
    cp "$DIST/$ASSET_NAME" "$OUT/share/eza/$ASSET_NAME"
  fi
else
  WARNINGS="${WARNINGS}static/app is missing; the tarball has no web bundle and the UI will 404
until scripts/build-web.sh runs and the release is rebuilt.
"
  log "warning: static/app is missing; archiving the tarball without a web bundle"
fi
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

{
  printf 'eza %s release tarball\n' "$VERSION"
  printf 'binary build: %s\n' "$BUILD_SOURCE"
  printf 'platform: %s\n' "$PLATFORM"
  printf '\n'
  cat <<'EOF'
Run:
  EZA_STATIC_DIR=$PWD/share/eza/static \
  EZA_DATA_DIR=$PWD/data \
  PUBLIC_ORIGIN=https://your-eza-host.example \
  ./bin/eza-bookmarks serve

The web bundle asset for the deployment flake is eza-web-<version>.tar.gz
(included under share/eza/ when the release was built with the web bundle).
Pin its SRI hash in nix/web-assets.json before relying on `nix build .#docker`
or the default NixOS module path.
EOF
} >"$OUT/share/eza/README.txt"

# Keep the artefact honest: a consumer must be able to see how the binary was
# built and why it may not run outside the build host.
{
  printf 'release: eza %s (%s)\n' "$VERSION" "$PLATFORM"
  printf 'built with: %s\n' "$BUILD_SOURCE"
  if [ -n "$INTERPRETER" ]; then
    printf 'ELF interpreter: %s\n' "$INTERPRETER"
  fi
  if [ "$HOST_BOUND" -eq 1 ]; then
    printf 'host-bound: yes (needs the Nix store closure below)\n'
    printf '\n# runtime closure (nix-store --query --requisites):\n'
    if command -v nix-store >/dev/null 2>&1; then
      nix-store --query --requisites "$BIN" 2>/dev/null || true
    fi
  else
    printf 'host-bound: no (or unverified)\n'
  fi
} >"$OUT/share/eza/BUILD-INFO.txt"
if [ -n "$WARNINGS" ]; then
  printf '%s' "$WARNINGS" >"$OUT/share/eza/HOST-BOUND-WARNING.txt"
fi

log "packing $TARBALL"
tar -C "$DIST" -czf "$TARBALL" "eza-${VERSION}"

# ---------------------------------------------------------------------------
# Checksums and summary
# ---------------------------------------------------------------------------
(
  cd "$DIST"
  : >SHA256SUMS
  for file in "$ASSET_NAME" "$(basename "$TARBALL")"; do
    if [ -f "$file" ]; then
      sha256sum "$file" >>SHA256SUMS
    fi
  done
)

printf '\nrelease artifacts in dist/release:\n'
ls -l "$DIST/$ASSET_NAME" "$TARBALL" "$DIST/SHA256SUMS" 2>/dev/null || true
printf '\n'
cat "$DIST/SHA256SUMS" 2>/dev/null || true
printf '\nversion: %s (flake.nix via scripts/version.sh)\n' "$VERSION"
if [ -f "$DIST/$ASSET_NAME" ]; then
  printf 'web asset: %s\n' "$DIST/$ASSET_NAME"
  printf '  next: bash scripts/release-asset.sh --check --require-pinned\n'
  printf '        (after uploading the asset and pinning its SRI hash in nix/web-assets.json;\n'
  printf '         .github/workflows/release.yml does both on a v* tag)\n'
fi
if [ "$HOST_BOUND" -eq 1 ]; then
  printf '\nWARNING: this tarball binary is host-bound to the Nix store; see\n'
  printf '         share/eza/HOST-BOUND-WARNING.txt inside the tarball.\n'
  printf '         The supported portable artifact is the Docker image (nix build .#docker).\n'
fi
