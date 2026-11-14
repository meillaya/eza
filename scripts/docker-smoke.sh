#!/usr/bin/env bash
# Smoke-test a built eza container image before CI/release publishes it.
#
#   bash scripts/docker-smoke.sh result
#   bash scripts/docker-smoke.sh ghcr.io/meillaya/eza:0.4.0.0
#   EZA_DOCKER_BROWSER=1 bash scripts/docker-smoke.sh result
#
# The argument is either the tarball produced by `nix build .#docker` (the
# `result` symlink is accepted) or an existing image reference. The script uses
# a fresh named volume, waits for /healthz, checks the generated shell, service
# worker, and the content-addressed loader/WASM it names, then checks the
# first-run /setup page; it always removes the container and volume.
# EZA_DOCKER_BROWSER=1 additionally runs tests/e2e/docker-first-run.mjs
# (requires `bun install` and Playwright Chromium on the host).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SOURCE="${1:-}"
if [ -z "$SOURCE" ]; then
  echo "usage: bash scripts/docker-smoke.sh IMAGE_OR_NIX_RESULT" >&2
  exit 2
fi

RUN_BROWSER="${EZA_DOCKER_BROWSER:-0}"
NAME="eza-smoke-$$"
VOLUME="eza-smoke-data-$$"
PORT="$((18080 + RANDOM % 900))"
NETWORK="${EZA_DOCKER_NETWORK:-bridge}"

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [ -e "$SOURCE" ]; then
  if [ ! -f "$SOURCE" ]; then
    echo "docker-smoke: $SOURCE is not a tarball file" >&2
    exit 1
  fi
  echo "docker-smoke: loading image from $SOURCE" >&2
  docker load -i "$SOURCE" >/dev/null
  if tar -tzf "$SOURCE" >/dev/null 2>&1; then
    MANIFEST="$(tar -xzOf "$SOURCE" manifest.json)"
  else
    MANIFEST="$(tar -xOf "$SOURCE" manifest.json)"
  fi
  IMAGE="$(
    printf '%s' "$MANIFEST" |
      python3 -c 'import json,sys; tags=json.load(sys.stdin)[0].get("RepoTags") or []; print(tags[0] if tags else "")'
  )"
  if [ -z "$IMAGE" ]; then
    echo "docker-smoke: the image tarball has no RepoTags" >&2
    exit 1
  fi
else
  IMAGE="$SOURCE"
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "docker-smoke: image $IMAGE is not loaded" >&2
    exit 1
  fi
fi

docker volume create "$VOLUME" >/dev/null
NETWORK_ARGS=(--network "$NETWORK")
if [ "$NETWORK" = "host" ]; then
  # The sandboxed local Docker daemon may not support bridge port mapping;
  # host networking is a convenient fallback for local smoke runs.
  PORT=8080
else
  NETWORK_ARGS+=(-p "127.0.0.1:${PORT}:8080")
fi
echo "docker-smoke: starting $IMAGE on 127.0.0.1:$PORT" >&2

docker run -d \
  --name "$NAME" \
  "${NETWORK_ARGS[@]}" \
  -e "PUBLIC_ORIGIN=http://127.0.0.1:${PORT}" \
  -v "${VOLUME}:/data" \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  "$IMAGE" >/dev/null

ready=0
for _ in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q true; then
    break
  fi
  sleep 0.5
done

if [ "$ready" -ne 1 ]; then
  echo "docker-smoke: container did not become healthy" >&2
  docker logs "$NAME" >&2 || true
  exit 1
fi

check_status() {
  local path="$1" expected="$2" status
  status="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}${path}")"
  if [ "$status" != "$expected" ]; then
    echo "docker-smoke: GET $path returned $status, expected $expected" >&2
    docker logs "$NAME" >&2 || true
    exit 1
  fi
}

# A fresh install redirects / to /setup; after the first account it serves the
# app shell. Accept both here and assert /setup separately.
root_status="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/")"
if [ "$root_status" != "200" ] && [ "$root_status" != "302" ]; then
  echo "docker-smoke: GET / returned $root_status, expected 200 or 302" >&2
  docker logs "$NAME" >&2 || true
  exit 1
fi
# Asset names are content-addressed and generated, so the worker's embedded
# cache list is the HTTP-visible source of truth for the current bundle. This
# also proves the image serves the same bundle the shell/worker were built for.
SW_TEXT="$(curl -fsS "http://127.0.0.1:${PORT}/sw.js")"
WASM_PATH="$(printf '%s' "$SW_TEXT" | grep -o '/assets/app/app\.[0-9a-f][0-9a-f]*\.wasm' | head -n 1)"
LOADER_PATH="$(printf '%s' "$SW_TEXT" | grep -o '/assets/app/index\.[0-9a-f][0-9a-f]*\.js' | head -n 1)"
CSS_PATH="$(printf '%s' "$SW_TEXT" | grep -o '/assets/eza\.[0-9a-f][0-9a-f]*\.css' | head -n 1)"
if [ -z "$WASM_PATH" ] || [ -z "$LOADER_PATH" ] || [ -z "$CSS_PATH" ]; then
  echo "docker-smoke: /sw.js does not name the content-addressed bundle assets" >&2
  exit 1
fi
check_status "/sw.js" 200
check_status "$LOADER_PATH" 200
check_status "$WASM_PATH" 200
check_status "$CSS_PATH" 200
check_status "/setup" 200

if ! curl -fsS "http://127.0.0.1:${PORT}/setup" | grep -q 'password-setup'; then
  echo "docker-smoke: /setup does not contain the password setup form" >&2
  exit 1
fi

if [ "$RUN_BROWSER" = "1" ]; then
  echo "docker-smoke: running first-run browser test" >&2
  EZA_BASE="http://127.0.0.1:${PORT}" node tests/e2e/docker-first-run.mjs
fi

echo "docker-smoke: ok ($IMAGE, ${PORT})" >&2
