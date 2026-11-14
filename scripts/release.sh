#!/usr/bin/env bash
# Build the eza release artifacts. Run with plain bash from the repo root:
#
#   bash scripts/release.sh
#
# Output (dist/release/):
#   eza-<version>-<arch>-linux.tar.gz     server binary + static bundle +
#                                         extension + sidecar + licence/notices
#   SHA256SUMS                            checksum for the tarball
#
# The web bundle is built from source by the deployment flake
# (packages.<system>.eza-web); the release tarball stages that bundle under
# share/eza/static. There is no separate prebuilt web-asset upload or SRI pin.
#
# Version: derived from flake.nix via scripts/version.sh, which also verifies
# the Cabal packages agree (0.4.0.0). There is no separate release version.
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
TARBALL="$DIST/eza-${VERSION}-${PLATFORM}.tar.gz"

log() { printf 'release: %s\n' "$*" >&2; }
die() {
  printf 'release: error: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$DIST"
WARNINGS=""

# ---------------------------------------------------------------------------
# Web bundle (built from source by the deployment flake)
# ---------------------------------------------------------------------------
WEB_STATIC=""
if [ "$BUILD_WEB" -eq 1 ]; then
  if [ "$BUILD_MODE" != "cabal" ] && command -v nix >/dev/null 2>&1; then
    log "building the web bundle: nix build path:.#eza-web"
    web_out="$(mktemp)"
    if nix build --no-link --print-out-paths "path:$ROOT#eza-web" >"$web_out" 2>&1; then
      WEB_STATIC="$(head -n 1 "$web_out")/share/eza/static"
      log "web bundle: $WEB_STATIC"
    else
      cat "$web_out" >&2
      rm -f "$web_out"
      die "'nix build .#eza-web' failed; the release tarball needs a web bundle (the server rejects a static tree without asset-manifest.json)"
    fi
    rm -f "$web_out"
  else
    if [ -f "$ROOT/static/asset-manifest.json" ]; then
      WEB_STATIC="$ROOT/static"
      log "web bundle: local static/ (built by scripts/build-web.sh)"
    else
      die "no web bundle: run 'bash scripts/build-web.sh' first, or build with Nix (nix build .#eza-web)"
    fi
  fi
else
  log "skipping the web bundle (--no-web)"
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
if [ -n "$WEB_STATIC" ]; then
  # A release tarball serves the bundle from share/eza/static. The bundle is
  # the flake-built content-addressed tree (asset-manifest.json + hashed
  # assets + generated shell/service worker).
  cp -a "$WEB_STATIC" "$OUT/share/eza/static"
  [ -f "$OUT/share/eza/static/asset-manifest.json" ] || die "the web bundle has no asset-manifest.json (the server would refuse to start)"
else
  WARNINGS="${WARNINGS}The tarball has no web bundle (--no-web); the UI will 404 until
EZA_STATIC_DIR points at a built bundle.
"
  log "warning: archiving the tarball without a web bundle (--no-web)"
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

The web client is the content-addressed bundle under share/eza/static,
built from source by `nix build .#eza-web` (it is included in this tarball when
the release was built with the web bundle). The Docker image and the NixOS
module consume the same derivation directly.
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
  sha256sum "$(basename "$TARBALL")" >SHA256SUMS
)

printf '\nrelease artifacts in dist/release:\n'
ls -l "$TARBALL" "$DIST/SHA256SUMS" 2>/dev/null || true
printf '\n'
cat "$DIST/SHA256SUMS" 2>/dev/null || true
printf '\nversion: %s (flake.nix via scripts/version.sh)\n' "$VERSION"
if [ "$HOST_BOUND" -eq 1 ]; then
  printf '\nWARNING: this tarball binary is host-bound to the Nix store; see\n'
  printf '         share/eza/HOST-BOUND-WARNING.txt inside the tarball.\n'
  printf '         The supported portable artifact is the Docker image (nix build .#docker).\n'
fi
