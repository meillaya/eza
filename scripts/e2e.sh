#!/usr/bin/env bash
# Run the browser checks against disposable multi-user installations.
#
# Every script gets a fresh data root: a control database created by `init` and
# one claimed admin account (EZA_TEST_USER, admin role) whose library is
# seeded with the mini fixture. The first-run scripts in FIRST_RUN_SCRIPTS are
# the exception: they start from an empty control database and claim the first
# account through /setup themselves.
#
# The content-addressed web bundle must have been built first
# (scripts/build-web.sh, which ends by running scripts/bundle-web.sh), and the
# root dev dependencies (@playwright/test) must be installed. CI does both
# before this script runs; locally run
#   bun install --frozen-lockfile && bash scripts/build-web.sh
# Override EZA_BIN or EZA_E2E_SCRIPTS to narrow a local run, and set
# EZA_E2E_SEED=none to skip the fixture import. EZA_E2E_SKIP_STALE_CHECK=1 is a
# local-only escape hatch for running a subset against an existing WASM build
# while another checkout or agent is editing client sources; CI never sets it.
# The bundle's own freshness check (manifest vs static sources) still runs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Fail with an actionable message instead of a module-resolution stack trace.
if ! node -e "import('@playwright/test').then(() => process.exit(0), () => process.exit(1))" >/dev/null 2>&1; then
  echo "e2e dependencies are missing: '@playwright/test' is not installed." >&2
  echo "Run 'bun install --frozen-lockfile' (or 'npm install') at the repo root first." >&2
  exit 1
fi

# The server requires the manifest to start and the suite drives the real
# generated shell and service worker, so a missing bundle is an e2e setup error.
if [[ ! -f static/asset-manifest.json ]]; then
  echo "static/asset-manifest.json is missing; run bash scripts/build-web.sh (or bash scripts/bundle-web.sh --no-build over an existing static/app) first" >&2
  exit 1
fi
if [[ ! -f static/app/app.wasm ]]; then
  echo "static/app/app.wasm is missing; run bash scripts/build-web.sh first" >&2
  exit 1
fi

# manifest_get FIELD [KEY] prints one string from static/asset-manifest.json.
# KEY is a full logical name (it may contain dots), so it is looked up verbatim.
manifest_get() {
  node -e 'const fs = require("fs"); const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); const top = m[process.argv[2]]; const value = process.argv[3] === ":" ? top : top && top[process.argv[3]]; if (typeof value !== "string" || value.length === 0) process.exit(1); process.stdout.write(value);' static/asset-manifest.json "$1" "${2:-:}"
}

BUILD_ID="$(manifest_get build_id)" || {
  echo "static/asset-manifest.json has no build_id; rerun bash scripts/bundle-web.sh --no-build" >&2
  exit 1
}
WASM_URL="$(manifest_get assets app.wasm)" || {
  echo "static/asset-manifest.json does not name app.wasm; rerun bash scripts/bundle-web.sh --no-build" >&2
  exit 1
}
if [[ ! -f "static/${WASM_URL#/assets/}" ]]; then
  echo "the manifest's wasm path is static/${WASM_URL#/assets/}, which does not exist; rerun bash scripts/bundle-web.sh --no-build" >&2
  exit 1
fi
if ! grep -qF "eza-app-shell-${BUILD_ID}" static/sw.js; then
  echo "static/sw.js does not carry build id ${BUILD_ID}; rerun bash scripts/bundle-web.sh --no-build" >&2
  exit 1
fi
if ! grep -qF "$(manifest_get assets eza.css)" static/index.html; then
  echo "static/index.html does not reference the manifest's stylesheet; rerun bash scripts/bundle-web.sh --no-build" >&2
  exit 1
fi

# The bundle is a build output: refuse to test a snapshot older than the client
# sources or the tracked static sources it was supposed to be built from.
if [[ "${EZA_E2E_SKIP_STALE_CHECK:-0}" != "1" ]]; then
  source_roots=(core/src cabal.project.wasm core/eza-core.cabal web/eza-web.cabal)
  for root in web/src web-logic/src; do
    [[ -d "$root" ]] && source_roots+=("$root")
  done
  stale_source="$(find "${source_roots[@]}" -type f -newer static/app/app.wasm -print -quit 2>/dev/null || true)"
  if [[ -n "$stale_source" ]]; then
    echo "static/app/app.wasm is older than $stale_source; run bash scripts/build-web.sh first (or set EZA_E2E_SKIP_STALE_CHECK=1 for a deliberate local subset run)" >&2
    exit 1
  fi
fi
stale_bundle="$(find static/template static/eza.css static/theme.js static/pwa.js static/auth.js \
  static/favicon.svg static/favicon-fallback.svg static/app/index.js static/fonts static/icons \
  static/vendor/browser_wasi_shim -type f -newer static/asset-manifest.json -print -quit 2>/dev/null || true)"
if [[ -n "$stale_bundle" ]]; then
  echo "static/asset-manifest.json is older than $stale_bundle; run bash scripts/bundle-web.sh --no-build first" >&2
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
  bulk-smoke.mjs
  flows-smoke.mjs
  token-smoke.mjs
  token-ui-smoke.mjs
  share-ui-smoke.mjs
  highlight-ui-smoke.mjs
  highlights-shares-smoke.mjs
  prune-undo-smoke.mjs
  rules-ui-smoke.mjs
  deeplink-smoke.mjs
  history-smoke.mjs
  undo-history-smoke.mjs
  extract-edit-smoke.mjs
  dead-link-smoke.mjs
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
  bulk-smoke.mjs
  highlights-shares-smoke.mjs
  addpasskey-smoke.mjs
)

# Scripts that deliberately stay outside the CI suite. Everything else under
# tests/e2e/ must be listed in SCRIPTS, so a new smoke script cannot silently
# rot without a browser run.
EXCLUDED_SCRIPTS=(
  # Needs the public network: it records live pages through the clipper.
  capture-smoke.mjs
  # Superseded by dedup-smoke.mjs (merge) and prune-undo-smoke.mjs (undo);
  # kept as a manual debugging script.
  undo-smoke.mjs
  # Container-only first-run test; the release workflow runs it inside the
  # built image, not against the scratch server harness.
  docker-first-run.mjs
  # Utilities, not assertions.
  capture-screenshots.mjs
  graph-perf.mjs
  load-perf.mjs
  login-visual-check.mjs
  wasm-fetch.mjs
)

in_list() {
  local needle="$1"
  shift
  local candidate
  for candidate in "$@"; do
    [[ "$candidate" == "$needle" ]] && return 0
  done
  return 1
}

# Refuse to run the full suite when a tests/e2e script is neither part of the
# suite nor explicitly excluded above.
if [[ -z "${EZA_E2E_SCRIPTS:-}" ]]; then
  for script_path in tests/e2e/*.mjs; do
    script_name="$(basename "$script_path")"
    if ! in_list "$script_name" "${SCRIPTS[@]}" && ! in_list "$script_name" "${EXCLUDED_SCRIPTS[@]}"; then
      echo "e2e: $script_name is neither in SCRIPTS nor EXCLUDED_SCRIPTS" >&2
      echo "e2e: add it to one of the lists in scripts/e2e.sh" >&2
      exit 1
    fi
  done
fi

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
    # The browser suite stays offline: favicon backfill would otherwise issue
    # external icon requests for the fixture domains.
    "EZA_FAVICON_BACKFILL=0"
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
    if [[ "$name" == "extract-edit-smoke" ]]; then
      sqlite3 "$data/users/1/eza.db" "UPDATE bookmarks SET extracted_text = 'Seeded extraction copy for the editor smoke test.' || char(10) || char(10) || 'A second paragraph keeps the reading window non-trivial.', enrich_state = 'ok', reading_time_minutes = 1 WHERE id = (SELECT MIN(id) FROM bookmarks);" || true
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
