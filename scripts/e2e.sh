#!/usr/bin/env bash
# Run the browser checks against disposable multi-user installations.
#
# Every script gets a fresh data root: a control database created by `init` and
# one claimed admin account (EZA_TEST_USER, admin role) whose library is
# seeded with the mini fixture. The first-run scripts in FIRST_RUN_SCRIPTS are
# the exception: they start from an empty control database and claim the first
# account through /setup themselves.
#
# The WASM bundle must have been built first (scripts/build-web.sh). Override
# EZA_BIN or EZA_E2E_SCRIPTS to narrow a local run, and set EZA_E2E_SEED=none
# to skip the fixture import.
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

TEST_USER="${EZA_TEST_USER:-e2e}"
TEST_PASSWORD="${EZA_TEST_PASSWORD:-e2e-password-123}"
SEED="${EZA_E2E_SEED:-mini}"

SCRIPTS=(
  auth-smoke.mjs
  multiuser-smoke.mjs
  api-smoke.mjs
  ui-smoke.mjs
  keyboard-smoke.mjs
  navigation-smoke.mjs
  logout-smoke.mjs
  dedup-smoke.mjs
  bulk-ui-smoke.mjs
  flows-smoke.mjs
  token-smoke.mjs
  share-ui-smoke.mjs
  highlight-ui-smoke.mjs
  prune-undo-smoke.mjs
  rules-ui-smoke.mjs
  deeplink-smoke.mjs
  accessions-smoke.mjs
  graph-smoke.mjs
  graph-views-smoke.mjs
  pwa-smoke.mjs
  addpasskey-smoke.mjs
)

# Scripts that claim the first account themselves. They run against an empty
# control database with no fixture import.
FIRST_RUN_SCRIPTS=(
  auth-smoke.mjs
  flows-smoke.mjs
  token-smoke.mjs
  addpasskey-smoke.mjs
)

if [[ -n "${EZA_E2E_SCRIPTS:-}" ]]; then
  read -r -a SCRIPTS <<<"$EZA_E2E_SCRIPTS"
fi

passed=0
failed=0
declare -a failures=()
index=0

is_first_run() {
  local candidate
  for candidate in "${FIRST_RUN_SCRIPTS[@]}"; do
    if [[ "$candidate" == "$1" ]]; then
      return 0
    fi
  done
  return 1
}

run_one() {
  local script="$1"
  local name="${script%.mjs}"
  local port=$((8210 + index))
  local data="$RUN/$name"
  local log="$RUN/$name.server.log"
  mkdir -p "$data/users"

  local first_run=0
  if is_first_run "$script"; then
    first_run=1
  fi

  local env_prefix=(
    "EZA_DATA_DIR=$data"
    "EZA_DB=$data/eza.db"
    "EZA_CONTROL_DB=$data/control.db"
    "EZA_USERS_DIR=$data/users"
    "EZA_STATIC_DIR=$ROOT/static"
    "EZA_BIND=127.0.0.1:$port"
    "PUBLIC_ORIGIN=http://localhost:$port"
    "EZA_RP_ID=localhost"
    "EZA_ALLOWED_ORIGINS=http://localhost:$port"
    "EZA_SNAPSHOT_DIR=$data/snapshots"
    "EZA_BACKUP_DIR=$data/backups"
  )

  env "${env_prefix[@]}" "$BIN" init >/dev/null
  if [[ "$first_run" == "0" ]]; then
    printf '%s\n' "$TEST_PASSWORD" |
      env "${env_prefix[@]}" "$BIN" users add --username "$TEST_USER" --role admin --password-stdin >/dev/null
    if [[ "$SEED" == "mini" ]]; then
      env "${env_prefix[@]}" "$BIN" import tests/fixtures/mini-bookmarks.html --user "$TEST_USER" >/dev/null
    fi
    if [[ "$name" == "highlight-ui-smoke" ]]; then
      sqlite3 "$data/users/1/eza.db" "UPDATE bookmarks SET extracted_text = 'The first paragraph of the smoke record is long enough to select.' || char(10) || char(10) || 'The second paragraph is also selectable for a highlight.' WHERE id = (SELECT MIN(id) FROM bookmarks);" || true
    fi
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

  if EZA_BASE="http://localhost:$port" \
    EZA_TEST_USER="$TEST_USER" \
    EZA_TEST_PASSWORD="$TEST_PASSWORD" \
    EZA_DEDUP_DB="$data/users/1/eza.db" \
    node "tests/e2e/$script"; then
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
