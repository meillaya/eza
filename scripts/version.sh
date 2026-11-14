#!/usr/bin/env bash
# Print the single eza version shared by the deployment flake and the Cabal
# packages, and fail when they disagree.
#
#   bash scripts/version.sh          # print 0.4.0.0 (checks cabal files)
#   bash scripts/version.sh --check  # same, but only validates
#
# The deployment flake is the source of truth: `version = "x"` in flake.nix
# names the release asset, the container tag and the NixOS module defaults.
# The Cabal package versions and the deployment copies must match it, otherwise
# a release tarball and the flake disagree about what was built. The extension
# and sidecar carry their own three-part versions (0.1.0) and are deliberately
# not compared here. Deployment copies that a later milestone removes are
# skipped when the file is absent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    -h | --help)
      sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "version.sh: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

flake_version="$(
  sed -n 's/^[[:space:]]*version = "\([^"]*\)";[[:space:]]*$/\1/p' "$ROOT/flake.nix" | head -n 1
)"
if [ -z "$flake_version" ]; then
  echo "version.sh: could not find 'version = \"x\";' in flake.nix" >&2
  exit 1
fi

status=0
for cabal_file in core/eza-core.cabal server/eza-server.cabal web/eza-web.cabal web-logic/eza-web-logic.cabal; do
  [ -f "$ROOT/$cabal_file" ] || continue
  cabal_version="$(sed -n 's/^version:[[:space:]]*\([^[:space:]]*\)[[:space:]]*$/\1/p' "$ROOT/$cabal_file" | head -n 1)"
  if [ "$cabal_version" != "$flake_version" ]; then
    echo "version.sh: version drift: $cabal_file has '$cabal_version' but flake.nix has '$flake_version'" >&2
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  exit 1
fi
if [ "$CHECK_ONLY" -eq 0 ]; then
  printf '%s\n' "$flake_version"
fi
