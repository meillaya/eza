#!/usr/bin/env bash
# Build the browser clipper into extension/dist.
#
#   bash scripts/build-extension.sh                 # copy build, no Defuddle
#   bash scripts/build-extension.sh --with-defuddle # bundle the Defuddle extractor
#
# Arguments are passed to extension/build.mjs, so --out DIR writes somewhere
# other than extension/dist. The script installs the extension dependencies
# with `npm ci` once when extension/node_modules is missing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/extension"

if ! command -v node >/dev/null 2>&1; then
  echo "node not found; enter the dev environment with 'devenv shell'" >&2
  exit 1
fi
if ! command -v npm >/dev/null 2>&1; then
  echo "npm not found; enter the dev environment with 'devenv shell'" >&2
  exit 1
fi

if [[ ! -d node_modules ]]; then
  echo "installing extension dependencies"
  npm ci
fi

node build.mjs "$@"
