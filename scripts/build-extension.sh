#!/usr/bin/env bash
# Build the browser clipper packages into extension/dist.
#
#   bash scripts/build-extension.sh                  # plain Chrome + Firefox build
#   bash scripts/build-extension.sh --target chrome  # one target
#   bash scripts/build-extension.sh --out DIR        # write somewhere else
#   bash scripts/build-extension.sh --with-defuddle  # bundle the optional extractor
#
# The plain build needs Node only: there are no runtime dependencies, the
# build copies plain files, and it writes a deterministic ZIP. npm ci runs only
# when the optional Defuddle bundle is requested and the dependencies are
# missing. Arguments are passed to extension/build.mjs; --out is resolved from
# the current working directory, so from the repository root
# `bash scripts/build-extension.sh --out extension/dist` writes the same place
# as the default.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v node >/dev/null 2>&1; then
  echo "node not found; enter the dev environment with 'devenv shell'" >&2
  exit 1
fi

needs_defuddle=0
for arg in "$@"; do
  case "$arg" in
    --with-defuddle) needs_defuddle=1 ;;
  esac
done

if [[ "$needs_defuddle" == 1 ]]; then
  if ! command -v npm >/dev/null 2>&1; then
    echo "npm not found; the optional Defuddle bundle needs the extension dependencies" >&2
    exit 1
  fi
  if [[ ! -d "$ROOT/extension/node_modules" ]]; then
    echo "installing extension dependencies for the optional Defuddle bundle"
    (cd "$ROOT/extension" && npm ci)
  fi
fi

node "$ROOT/extension/build.mjs" "$@"
