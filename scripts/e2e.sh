#!/usr/bin/env bash
# Run the browser checks against disposable servers.
#
# Each script gets a fresh database and its own server, so a flow that claims
# the library or imports a fixture cannot affect the next one. The WASM bundle
# must have been built first (scripts/build-web.sh). Override EZA_BIN or
# EZA_E2E_SCRIPTS to narrow a local run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f static/app/app.wasm ]]; then
  echo "static/app/app.wasm is missing; run bash scripts/build-web.sh first" >&2
  exit 1
fi

BIN="${EZA_BIN:-$(cabal list-bin exe:eza-bookmarks)}"
RUN="$ROOT/.dsh-cache/e2e-run"
rm -rf "$RUN"
mkdir -p "$RUN"

SCRIPTS=(
  auth-smoke.mjs
  api-smoke.mjs
  ui-smoke.mjs
  bulk-ui-smoke.mjs
  flows-smoke.mjs
  token-smoke.mjs
  share-ui-smoke.mjs
  highlight-ui-smoke.mjs
  prune-undo-smoke.mjs
  rules-ui-smoke.mjs
  deeplink-smoke.mjs
  pwa-smoke.mjs
  addpasskey-smoke.mjs
)
if [[ -n "${EZA_E2E_SCRIPTS:-}" ]]; then
  read -r -a SCRIPTS <<<"$EZA_E2E_SCRIPTS"
fi

passed=0
failed=0
declare -a failures=()
index=0

run_one() {
  local script="$1"
  local name="${script%.mjs}"
  local port=$((8210 + index))
  local data="$RUN/$name"
  local log="$RUN/$name.server.log"
  mkdir -p "$data"

  local env_prefix=(
    "EZA_DATA_DIR=$data"
    "EZA_DB=$data/eza.db"
    "EZA_STATIC_DIR=$ROOT/static"
    "EZA_BIND=127.0.0.1:$port"
    "PUBLIC_ORIGIN=http://localhost:$port"
    "EZA_RP_ID=localhost"
    "EZA_ALLOWED_ORIGINS=http://localhost:$port"
    "EZA_SNAPSHOT_DIR=$data/snapshots"
    "EZA_BACKUP_DIR=$data/backups"
    "EZA_TEST_USER=e2e"
    "EZA_TEST_PASSWORD=e2e-password-123"
  )

  env "${env_prefix[@]}" "$BIN" init >/dev/null
  if [[ "${EZA_E2E_SEED:-mini}" == "mini" && "$name" != "auth-smoke" ]]; then
    env "${env_prefix[@]}" "$BIN" import tests/fixtures/mini-bookmarks.html >/dev/null
  fi
  if [[ "$name" == "highlight-ui-smoke" ]]; then
    sqlite3 "$data/eza.db" "UPDATE bookmarks SET extracted_text = 'The first paragraph of the smoke record is long enough to select.' || char(10) || char(10) || 'The second paragraph is also selectable for a highlight.' WHERE id = (SELECT MIN(id) FROM bookmarks);" || true
  fi
  env "${env_prefix[@]}" "$BIN" serve >"$log" 2>&1 &
  local server_pid=$!

  cleanup_one() {
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  }

  local ready=0
  for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
      ready=1
      break
    fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
      break
    fi
    sleep 0.25
  done
  if [[ "$ready" != "1" ]]; then
    echo "FAIL $script: server did not become ready (see $log)"
    cleanup_one
    failed=$((failed + 1))
    failures+=("$script (server)")
    return
  fi

  if EZA_BASE="http://localhost:$port" node "tests/e2e/$script"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    failures+=("$script")
  fi
  cleanup_one
}

for script in "${SCRIPTS[@]}"; do
  echo
  echo "== $script =="
  run_one "$script"
  index=$((index + 1))
done

echo
echo "e2e scripts passed: $passed, failed: $failed"
if ((failed > 0)); then
  printf 'failures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
