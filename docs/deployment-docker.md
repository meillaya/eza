# Deploying eza with Docker

The image is produced by Nix (`packages.<system>.docker` in the deployment
flake) using `dockerTools.buildLayeredImage`. There is no Dockerfile, because
the web client is a CI-built WASM release asset and the server is a GHC
derivation.

The container runs the **eza-bookmarks** binary as non-root **uid/gid 10001**,
stores all state under **/data**, and exposes **/healthz** for health checks.

## Build and load the image

```bash
# In the eza checkout (deployment flake):
# (Use `nix build path:.#docker` if the tree has uncommitted files, a git
# flake only sees tracked files. `.#docker-local` builds the same image with
# the locally built web bundle instead of the released one.)
nix build .#docker              # -> ./result is a gzip'd image tarball
docker load < result            # -> Loaded image: eza:0.1.0.0 (some Docker
                                #    versions report localhost/eza:0.1.0.0)
docker image ls | grep eza

# Tag/push to your registry:
docker tag eza:0.1.0.0 registry.example.com/eza:0.1.0.0
docker push registry.example.com/eza:0.1.0.0
```

The image contains: `eza-bookmarks`, the web bundle
(`/share/eza/static`, pointed to by `EZA_STATIC_DIR`), `/etc/eza/secretspec.toml`,
curl, sqlite3, monolith (snapshot capture), rclone (offsite backups) and
SecretSpec. `/bin/eza-bookmarks`, `/bin/secretspec`, `/bin/sqlite3`, ...
are symlinks into the Nix store.

The container CMD is `eza-bookmarks serve`; the same binary also provides
`healthcheck` (for HEALTHCHECK / probes), `backup`, `verify`, `stats`,
`check-dead`, `repair-domains`, `import`, `init` and `version`.

## Docker Compose (recommended for a single host)

```bash
cp deploy/docker-compose.yml docker-compose.yml
# edit PUBLIC_ORIGIN / EZA_RP_ID (must be the URL users open, https in prod)
docker compose up -d
docker compose logs -f eza
```

`deploy/docker-compose.yml` uses a named volume `eza-data:/data`. The image
pre-creates `/data` owned by 10001:10001, so a fresh named volume is already
writable by the container user. Do not add another replica: SQLite is a
single-writer database and the server serializes all writes.

## Plain `docker run`

```bash
docker run -d --name eza \
  --restart unless-stopped \
  -p 127.0.0.1:8080:8080 \
  -v eza-data:/data \
  -e PUBLIC_ORIGIN=https://eza.example.com \
  -e EZA_RP_ID=eza.example.com \
  --read-only --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges \
  eza:0.1.0.0
```

Put a TLS terminator in front (Caddy, nginx, Tailscale Serve) on the same host:
WebAuthn passkeys require a **secure origin**, so plain
`http://<host>:8080` will not work except on `http://localhost`.

## Environment variables

| Variable | Image default | Purpose |
|---|---|---|
| `EZA_DATA_DIR` | `/data` | Data root: `eza.db`, `snapshots/`, `backups/`. |
| `EZA_DB` | `$EZA_DATA_DIR/eza.db` | Database file override. |
| `EZA_BIND` | `0.0.0.0:8080` | Listen address. |
| `PUBLIC_ORIGIN` | `http://localhost:8080` | Browser-visible origin; passkeys are bound to it. Set this. |
| `EZA_RP_ID` | host of origin | WebAuthn relying-party ID (host only, no scheme/port). |
| `EZA_RP_NAME` | `eza` | Passkey prompt display name. |
| `EZA_ALLOWED_ORIGINS` | `$PUBLIC_ORIGIN` | Comma-separated extra allowed origins. |
| `EZA_CLIP_ORIGINS` | empty | Comma-separated extension origins for the clipper; extension schemes are accepted automatically. |
| `EZA_DEFUDDLE_CMD` | unset | Optional `node .../sidecar/src/main.mjs` command for Defuddle extraction. |
| `EZA_SESSION_TTL_SECONDS` | `2592000` | Session lifetime. |
| `EZA_SECURE_COOKIES` | derived from origin | Force Secure cookies on/off. |
| `EZA_STATIC_DIR` | `<webAssets>/share/eza/static` | Web bundle location (already set in the image). |
| `EZA_SNAPSHOT_DIR` | `$EZA_DATA_DIR/snapshots` | Snapshot storage. |
| `EZA_BACKUP_DIR` | `$EZA_DATA_DIR/backups` | Default backup directory. |
| `EZA_BACKUP_OFFSITE` | unset | Optional local directory: `eza-bookmarks backup` copies each backup there. |
| `EZA_MONOLITH` | `monolith` | Snapshot tool (on PATH in the image). |
| `EZA_LOG_LEVEL` | `info` | debug/info/warn/error. |
| `EZA_ENRICH_WORKERS` | `2` | In-process background enrichment workers; `0` disables them. |
| `EZA_FETCH_TIMEOUT_MS` | `8000` | Timeout per outbound fetch (server clamps below 1000). |
| `EZA_FAVICON_MAX_BYTES` | `65536` | Maximum favicon download size. |
| `EZA_FAVICON_TTL_DAYS` | `90` | Favicon cache lifetime. |
| `EZA_SHARE_TTL_DAYS` | `7` | Public share-link lifetime. |
| `EZA_ALLOW_PRIVATE_FETCH` | `0` | Set `1` to allow fetching private/RFC1918 URLs (lifts the SSRF guard). |
| `EZA_AI_PROVIDER` | `none` | AI tagging: `none`, `ollama`, `openai`, `openai-compatible`, `anthropic`. |
| `EZA_OLLAMA_BASE_URL` | `http://127.0.0.1:11434` | Ollama endpoint for the `ollama` provider. |
| `EZA_AI_MODEL` | `llama3.2` | Model used for AI tagging. |
| `EZA_AI_AUTO_TAG` | `0` | Automatic AI tagging of newly added bookmarks. |
| `EZA_OPENAI_BASE_URL` | unset | OpenAI-compatible base URL for self-hosted LLM endpoints. |
| `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` | unset | Optional AI-tagging keys; empty disables key-based providers. |

Enrichment workers run inside the server process (each with its own SQLite
connection), so there is no extra container or sidecar: set
`EZA_ENRICH_WORKERS=0` to disable background work. The fetcher refuses
loopback/link-local/private addresses unless `EZA_ALLOW_PRIVATE_FETCH=1` is
set, which is an SSRF surface and only safe for a fully trusted UI. With
`EZA_AI_PROVIDER=none` (the default) the AI endpoints still answer, returning
an empty suggestion list and a notice; `ollama` needs no API key.

## Healthcheck

The image defines a Docker healthcheck that runs the shipped CLI:

    eza-bookmarks healthcheck

It performs `GET /healthz` on `EZA_BIND` and exits 0 only on HTTP 200.
`/healthz` returns `200 {"status":"ok","version":"0.1.0"}` when the database
answers, and `503` otherwise. Compose/UI show `(healthy)` after the 15 s
start period. Use the same command/endpoint for external monitoring.

## Secrets

Two supported paths:

1. **Plain environment variables** (default): pass `ANTHROPIC_API_KEY` /
   `OPENAI_API_KEY` via compose `environment`, `env_file`, or
   `docker secret`-mounted files plus an entrypoint that exports them.
2. **SecretSpec env provider**: override the container command so SecretSpec
   resolves the manifest at `/etc/eza/secretspec.toml` and injects the
   optional keys:

```yaml
services:
  eza:
    command:
      - /bin/secretspec
      - run
      - --file
      - /etc/eza/secretspec.toml
      - --provider
      - env
      - --profile
      - production
      - --
      - /bin/eza-bookmarks
      - serve
    environment:
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
```

Both keys are optional: the server starts normally when they are absent. AI
tagging is off by default (`EZA_AI_PROVIDER=none`), and a key-based provider
with no key reports the missing key instead of failing. Details and CI/desktop
provider setups are in [secrets.md](secrets.md).

## Data, backup and restore

All state is in the volume:

    /data/eza.db          SQLite database (WAL)
    /data/snapshots/      full-page HTML snapshots
    /data/backups/        online backups

Online backup (safe while the server runs; no downtime). It uses the
server's own `backup` command (`VACUUM INTO` + integrity check + 14-day prune):

```bash
docker compose exec eza /bin/eza-bookmarks backup
# prints: backup: /data/backups/eza-20260101-031700.db
docker compose exec eza /bin/eza-bookmarks verify
```

Restore (stop the service first so nothing writes to the database):

```bash
docker compose stop eza
docker compose run --rm --entrypoint sh eza -c 'cp /data/backups/<stamp>.db /data/eza.db && rm -f /data/eza.db-wal /data/eza.db-shm'
docker compose start eza
docker compose exec eza /bin/eza-bookmarks healthcheck
```

Copy a backup off the host:

```bash
docker run --rm -v eza-data:/data -v "$PWD:/out" alpine \
  cp /data/backups/<stamp>.db /out/
```

The image ships `rclone`, so a one-shot offsite copy is
`docker compose exec eza rclone copy /data/backups/<stamp>.db remote:eza-backups`.

## Bind-mount (host directory) instead of a named volume

```bash
sudo mkdir -p /srv/eza/data
sudo chown 10001:10001 /srv/eza/data
docker run ... -v /srv/eza/data:/data ...
```

The container cannot `chown` as non-root, so the host directory must be
writable by uid 10001 (group-write for group 10001 also works).

## Web assets

The client is compiled with the wasm32-wasi GHC toolchain (not in nixpkgs),
built in CI with `scripts/build-web.sh`, and published as a release asset. The
deployment flake pins it as a fixed-output derivation:

```nix
webAssets = {
  url = "https://github.com/meillaya/eza/releases/download/v0.1.0.0/eza-web-0.1.0.0.tar.gz";
  hash = lib.fakeHash; # <- replace with the published asset's SRI hash
};
```

Asset layout: `eza-web-<version>.tar.gz` is a **tarball of the `static/`
tree with entries at the archive root**:

    index.html
    eza.css
    theme.js
    app/index.js
    app/app.wasm
    app/ghc_wasm_jsffi.js
    vendor/...

After the asset exists:

```bash
nix store prefetch-file --json \
  https://github.com/meillaya/eza/releases/download/v0.1.0.0/eza-web-0.1.0.0.tar.gz
# paste "hash" into webAssets.hash, then:
nix build .#eza-web
nix build .#docker              # rebuild the image with the pinned bundle
```

Example CI job (illustrative, because the dev toolchain comes from `devenv.nix`):

```yaml
name: web-assets
on:
  push:
    tags: ["v*"]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v31
      - uses: cachix/cachix-action@v16
        with:
          name: devenv
      - run: nix profile install nixpkgs#devenv
      - run: devenv shell -- scripts/build-web.sh
      - run: tar -czf "eza-web-${GITHUB_REF_NAME#v}.tar.gz" -C static .
      - uses: softprops/action-gh-release@v2
        with:
          files: eza-web-*.tar.gz
```

Use the local bundle while iterating without a release:

```bash
devenv shell -- scripts/build-web.sh
nix build path:.#eza-web-local   # or: git add -f static/app && nix build .#eza-web-local
```

## Upgrades

```bash
git pull && nix build .#docker && docker load < result
docker compose up -d            # recreated container keeps the eza-data volume
```

The SQLite schema/migrations run on server start (`init`/migrations are
idempotent); take a backup first for major upgrades.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Container exits at start | `docker logs eza`: usually a bad `PUBLIC_ORIGIN`/`EZA_RP_ID` or unwritable `/data`. |
| `healthy` never becomes true | `/healthz` 503 → database problem; run `docker compose exec eza eza-bookmarks verify`. |
| Passkeys fail | Origin must be HTTPS and match `PUBLIC_ORIGIN`; `EZA_RP_ID` must be its host. |
| Permission denied in /data | Host bind mount not owned by 10001; fix on the host. |
| Web UI 404 | Image built before the release asset was pinned; rebuild `.#docker`. |
