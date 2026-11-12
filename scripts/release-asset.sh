#!/usr/bin/env bash
# Build the eza web-asset release tarball:
#
#   dist/release/eza-web-<version>.tar.gz
#
# The archive holds the `static/` tree with entries at the archive root (the
# same layout `pkgs.fetchurl` + `tar -xzf` expects in flake.nix) and is
# deterministic: sorted names, normalised ownership/modes, a fixed mtime from
# $SOURCE_DATE_EPOCH (default: the HEAD commit time) and `gzip -n`.
#
# It is the single place that produces the asset the deployment flake pins and
# the release workflow uploads; the matching SRI hash lives in
# nix/web-assets.json (one line to replace after the first release).
#
# Usage:
#   bash scripts/release-asset.sh                 # build web bundle, write asset
#   bash scripts/release-asset.sh --no-build      # use the existing static/ tree
#   bash scripts/release-asset.sh --out DIR       # different output directory
#   bash scripts/release-asset.sh --check         # validate nix/web-assets.json
#   bash scripts/release-asset.sh --check --require-pinned
#                                                 # ...and fail while the hash is
#                                                 # still the lib.fakeHash placeholder
#   bash scripts/release-asset.sh --print-hash    # build, print only the SRI hash
#
# The script needs only bash, tar, gzip and python3 (all in devenv). The SRI
# hash is printed at the end; copy it into nix/web-assets.json to pin the
# asset, or let .github/workflows/release.yml commit it after uploading.
# build-web needs the wasm32-wasi toolchain from `devenv shell`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT_DIR="$ROOT/dist/release"
BUILD=1
CHECK=0
REQUIRE_PINNED=0
PRINT_HASH_ONLY=0

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-build) BUILD=0 ;;
    --out)
      [ "$#" -ge 2 ] || {
        echo "release-asset.sh: --out needs a directory" >&2
        exit 2
      }
      OUT_DIR="$2"
      shift
      ;;
    --check) CHECK=1 ;;
    --require-pinned) REQUIRE_PINNED=1 ;;
    --print-hash) PRINT_HASH_ONLY=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "release-asset.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

VERSION="$(bash scripts/version.sh)"
ASSET_NAME="eza-web-${VERSION}.tar.gz"
PIN_FILE="$ROOT/nix/web-assets.json"
EXPECTED_URL="https://github.com/meillaya/eza/releases/download/v${VERSION}/${ASSET_NAME}"

json_field() {
  # json_field FILE FIELD — print one string field of a flat JSON object.
  python3 - "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
field = value.get(sys.argv[2])
if not isinstance(field, str) or not field:
    sys.exit(f"release-asset.sh: {sys.argv[1]} has no string field {sys.argv[2]!r}")
print(field)
PY
}

is_sri_sha256() {
  python3 - "$1" <<'PY'
import base64
import sys

value = sys.argv[1]
if not value.startswith("sha256-"):
    sys.exit(1)
try:
    raw = base64.b64decode(value[len("sha256-"):], validate=True)
except Exception:
    sys.exit(1)
sys.exit(0 if len(raw) == 32 else 1)
PY
}

is_placeholder_hash() {
  # lib.fakeHash is sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=;
  # treat an all-zero body as unpinned too.
  python3 - "$1" <<'PY'
import base64
import sys

value = sys.argv[1]
if not value.startswith("sha256-"):
    sys.exit("release-asset.sh: not an SRI sha256 hash")
body = value[len("sha256-"):]
try:
    raw = base64.b64decode(body, validate=True)
except Exception:
    sys.exit("release-asset.sh: SRI hash body is not valid base64")
if len(raw) != 32:
    sys.exit("release-asset.sh: SRI hash body must decode to 32 bytes")
sys.exit(0 if raw == b"\x00" * 32 else 1)
PY
}

sri_hash() {
  if command -v nix >/dev/null 2>&1; then
    nix hash file --sri --type sha256 "$1"
    return
  fi
  if command -v openssl >/dev/null 2>&1 && command -v base64 >/dev/null 2>&1; then
    printf 'sha256-%s\n' "$(openssl dgst -sha256 -binary "$1" | base64 | tr -d '\n')"
    return
  fi
  echo "release-asset.sh: neither nix nor openssl is available to compute the SRI hash" >&2
  return 1
}

check_pin() {
  if [ ! -f "$PIN_FILE" ]; then
    echo "release-asset.sh: missing $PIN_FILE (the pinned web-asset URL and SRI hash)" >&2
    return 1
  fi
  pinned_url="$(json_field "$PIN_FILE" url)" || return 1
  pinned_hash="$(json_field "$PIN_FILE" hash)" || return 1
  if ! is_sri_sha256 "$pinned_hash"; then
    echo "release-asset.sh: nix/web-assets.json hash is not an SRI sha256: $pinned_hash" >&2
    return 1
  fi
  if [ "$pinned_url" != "$EXPECTED_URL" ]; then
    echo "release-asset.sh: nix/web-assets.json url is stale" >&2
    echo "  expected: $EXPECTED_URL" >&2
    echo "  pinned:   $pinned_url" >&2
    echo "  Update nix/web-assets.json when the version or repository changes." >&2
    return 1
  fi
  if is_placeholder_hash "$pinned_hash"; then
    echo "release-asset.sh: nix/web-assets.json still pins the placeholder hash (lib.fakeHash)." >&2
    if [ "$REQUIRE_PINNED" -eq 1 ]; then
      echo "  Build/upload ${ASSET_NAME}, then set:" >&2
      echo "    \"hash\": \"<nix hash file --sri --type sha256 ${ASSET_NAME}>\""
      return 1
    fi
    echo "  Default Docker/NixOS builds fail until it is replaced (this is only a check)." >&2
  fi
  echo "release-asset.sh: pin ok: $pinned_url" >&2
  echo "release-asset.sh: pinned hash: $pinned_hash" >&2
  if [ -f "$OUT_DIR/$ASSET_NAME" ]; then
    built_hash="$(sri_hash "$OUT_DIR/$ASSET_NAME")"
    echo "release-asset.sh: built hash:  $built_hash" >&2
    if [ "$built_hash" != "$pinned_hash" ] && ! is_placeholder_hash "$pinned_hash"; then
      if [ "$REQUIRE_PINNED" -eq 1 ]; then
        echo "release-asset.sh: built asset does not match the pinned SRI hash" >&2
        return 1
      fi
      echo "release-asset.sh: warning: built asset differs from the pinned hash (re-upload and repin)" >&2
    fi
    echo "$built_hash"
  fi
  return 0
}

if [ "$CHECK" -eq 1 ]; then
  check_pin >/dev/null
  # check_pin echoes the built hash to stdout when the asset exists; the
  # human-readable status goes to stderr.
  exit 0
fi

if [ "$BUILD" -eq 1 ]; then
  echo "release-asset.sh: building the web bundle (scripts/build-web.sh)" >&2
  bash scripts/build-web.sh
fi

# ---- validate the bundle before packing it into a release asset ------------
[ -f static/index.html ] || {
  echo "release-asset.sh: static/index.html is missing; run bash scripts/build-web.sh" >&2
  exit 1
}
[ -f static/app/app.wasm ] || {
  echo "release-asset.sh: static/app/app.wasm is missing; run bash scripts/build-web.sh" >&2
  exit 1
}

# A stale bundle is worse than no asset: the flake would pin a client that does
# not match the sources in the tag. --no-build skips the rebuild, not the check.
if [ "$BUILD" -eq 0 ]; then
  stale="$(
    find core/src web/src cabal.project.wasm core/eza-core.cabal web/eza-web.cabal \
      -type f -newer static/app/app.wasm -print -quit 2>/dev/null || true
  )"
  if [ -n "$stale" ]; then
    echo "release-asset.sh: static/app/app.wasm is older than $stale" >&2
    echo "  Re-run without --no-build (or run bash scripts/build-web.sh) first." >&2
    exit 1
  fi
fi

# Every precompressed sidecar is served by the server as Content-Encoding: gzip,
# so a corrupt/empty one breaks the client. build-web.sh keeps them fresh; this
# check is the release gate for that invariant.
required_sidecars=(
  static/app/app.wasm.gz
  static/app/index.js.gz
  static/app/ghc_wasm_jsffi.js.gz
  static/index.html.gz
  static/eza.css.gz
  static/pwa.js.gz
)
for file in "${required_sidecars[@]}"; do
  if [ ! -s "$file" ]; then
    echo "release-asset.sh: $file is missing or empty" >&2
    exit 1
  fi
done
while IFS= read -r -d '' gz; do
  if ! gzip -t "$gz" 2>/dev/null; then
    echo "release-asset.sh: $gz is not valid gzip" >&2
    exit 1
  fi
  source_file="${gz%.gz}"
  if [ -f "$source_file" ] && [ "$source_file" -nt "$gz" ]; then
    echo "release-asset.sh: $gz is older than $source_file; rebuild the bundle" >&2
    exit 1
  fi
done < <(find static -name '*.gz' -type f -print0)

# ---- deterministic tarball -------------------------------------------------
epoch="${SOURCE_DATE_EPOCH:-}"
if ! [[ "$epoch" =~ ^[0-9]+$ ]]; then
  epoch="$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || true)"
fi
if ! [[ "$epoch" =~ ^[0-9]+$ ]]; then
  epoch=0
fi

mkdir -p "$OUT_DIR"
ASSET="$OUT_DIR/$ASSET_NAME"
tmp="$ASSET.tmp.$$"
trap 'rm -f "$tmp"' EXIT
# --mode normalises permission bits so a checkout's umask cannot leak into the
# release asset; gzip -n keeps the timestamp out of the gzip header.
tar \
  --sort=name \
  --mtime="@${epoch}" \
  --owner=0 --group=0 --numeric-owner \
  --mode='u+rwX,go+rX,go-w' \
  --format=gnu \
  -C static -cf - . | gzip -9 -n > "$tmp"
mv -f "$tmp" "$ASSET"
trap - EXIT

HASH="$(sri_hash "$ASSET")"
SIZE="$(wc -c < "$ASSET" | tr -d ' ')"
if [ "$PRINT_HASH_ONLY" -eq 1 ]; then
  printf '%s\n' "$HASH"
  exit 0
fi

cat <<EOF
release asset: $ASSET
size:          $SIZE bytes
version:       $VERSION (from flake.nix via scripts/version.sh)
sri256:        $HASH
pinned url:    $EXPECTED_URL

Next steps:
  1. Upload $(basename "$ASSET") to the GitHub release tagged v$VERSION
     (.github/workflows/release.yml does this on a v* tag push).
  2. Pin the asset in nix/web-assets.json:
       "url":  "$EXPECTED_URL"
       "hash": "$HASH"
     then run: bash scripts/release-asset.sh --check --require-pinned
  3. Rebuild the deployment outputs: nix build .#eza-web .#docker
EOF
