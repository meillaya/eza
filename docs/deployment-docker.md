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
docker load < result            # -> Loaded image: eza:0.2.0.0 (some Docker
                                #    versions report localhost/eza:0.2.0.0)
docker image ls | grep eza

# Tag/push to your registry:
docker tag eza:0.2.0.0 registry.example.com/eza:0.2.0.0
docker push registry.example.com/eza:0.2.0.0
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
# edit PUBLIC_ORIGIN only; the WebAuthn RP ID is derived from its host
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
  eza:0.2.0.0
```

Put a TLS terminator in front (Caddy, nginx, Tailscale Serve) on the same host:
WebAuthn passkeys require a **secure origin**, so plain
`http://<host>:8080` will not work except on `http://localhost`.

## Environment variables

| Variable | Image default | Purpose |
|---|---|---|
| `EZA_DATA_DIR` | `/data` | Data root: `control.db`, `users/`, `backups/`. |
| `EZA_CONTROL_DB` | `$EZA_DATA_DIR/control.db` | Account registry (identity, roles, per-account database paths). |
| `EZA_USERS_DIR` | `$EZA_DATA_DIR/users` | Per-account library root: `users/<id>/eza.db` and `users/<id>/snapshots/`. |
| `EZA_MAX_USERS` | `32` | Cap on user databases this process opens at once. |
| `EZA_DB` | `$EZA_DATA_DIR/eza.db` | Legacy single-user database, read only at startup to register an existing claimed install as user 1. |
| `EZA_BIND` | `0.0.0.0:8080` | Listen address. |
| `PUBLIC_ORIGIN` | `http://localhost:8080` | Browser-visible origin; passkeys are bound to it. Set this. |
| `EZA_RP_ID` | host of `PUBLIC_ORIGIN` | WebAuthn relying-party ID (host only, no scheme/port). The server derives it from `PUBLIC_ORIGIN` when unset; set it only to override, it must be a suffix of the origin host. |
| `EZA_RP_NAME` | `eza` | Passkey prompt display name. |
| `EZA_ALLOWED_ORIGINS` | `$PUBLIC_ORIGIN` | Comma-separated extra allowed origins. |
| `EZA_TRUSTED_PROXIES` | empty | Comma-separated proxy CIDRs. When the socket peer is in this list, the auth rate limiters key on the right-most untrusted `X-Forwarded-For` hop instead of the proxy address. Set it when eza runs behind a reverse proxy so login/recovery limits stay per client. |
| `EZA_CLIP_ORIGINS` | empty | Comma-separated extension origins for the clipper; extension schemes are accepted automatically. |
| `EZA_DEFUDDLE_CMD` | unset | Optional `node .../sidecar/src/main.mjs` command for Defuddle extraction. |
| `EZA_SESSION_TTL_SECONDS` | `2592000` | Session lifetime. |
| `EZA_SECURE_COOKIES` | derived from origin | Force Secure cookies on/off. |
| `EZA_STATIC_DIR` | `<webAssets>/share/eza/static` | Web bundle location (already set in the image). |
| `EZA_SNAPSHOT_DIR` | `$EZA_DATA_DIR/snapshots` | Legacy snapshot root, accepted read-only so snapshots captured before the per-account layout still serve; new captures go to `users/<id>/snapshots/`. |
| `EZA_BACKUP_DIR` | `$EZA_DATA_DIR/backups` | Default backup directory. |
| `EZA_BACKUP_KEEP_DAYS` | `14` | Backup stamp directories older than this are pruned by `backup`. |
| `EZA_SNAPSHOT_MAX_BYTES` | `52428800` | Upper bound on one captured page snapshot file. |
| `EZA_MAX_BODY_BYTES` | `8388608` | Limit for authenticated JSON request bodies; oversize returns 413. |
| `EZA_IMPORT_MAX_BYTES` | `33554432` | Limit for one import upload (Netscape HTML or eza JSON). |
| `EZA_BACKUP_OFFSITE` | unset | Optional local directory: `eza-bookmarks backup` copies each `<stamp>/` tree there. |
| `EZA_MONOLITH` | `monolith` | Snapshot tool (on PATH in the image). |
| `EZA_LOG_LEVEL` | `info` | `debug` logs a development request line, `info` one access line per request, `warn`/`error` disable access logging (error lines still reach stderr). |
| `EZA_ENRICH_WORKERS` | `2` | Process-wide enrichment concurrency; `0` disables the per-account enrichment loop. |
| `EZA_FETCH_TIMEOUT_MS` | `8000` | Timeout per outbound fetch (server clamps below 1000). |
| `EZA_FAVICON_MAX_BYTES` | `262144` | Maximum favicon download size. Complete ICO entries are cropped before storage. |
| `EZA_FAVICON_TTL_DAYS` | `90` | Favicon cache lifetime. |
| `EZA_FAVICON_BACKFILL` | `1` | Background per-domain favicon cache fill (one request per source, not per link); `0` disables it. |
| `EZA_SHARE_TTL_DAYS` | `7` | Public share-link lifetime. |
| `EZA_ALLOW_PRIVATE_FETCH` | `0` | Set `1` to allow fetching private/RFC1918 URLs (lifts the SSRF guard). |
| `EZA_AI_PROVIDER` | `none` | AI tagging: `none`, `ollama`, `openai`, `openai-compatible`, `anthropic`. |
| `EZA_OLLAMA_BASE_URL` | `http://127.0.0.1:11434` | Ollama endpoint for the `ollama` provider. |
| `EZA_AI_MODEL` | empty | AI model; empty selects the provider default (Ollama `llama3.2`, OpenAI `gpt-4o-mini`, Anthropic `claude-haiku-4-5`). |

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

```
/data/
    control.db            accounts, roles, per-account database paths
    users/
        1/eza.db          one account's library
        1/snapshots/      that account's captured pages
        2/eza.db
    backups/
        20260101-031700/
            control.db
            manifest.json accounts captured by this run
            users/1/eza.db
            users/2/eza.db
```

Online backup (safe while the server runs; no downtime). It uses the server's
own `backup` command (`VACUUM INTO` plus integrity check, stamp directories
older than `EZA_BACKUP_KEEP_DAYS` pruned). It backs up the control database and
every account, disabled ones included; `--user` narrows the run to one
account's library (the control database is always included). Page snapshots
under `users/<id>/snapshots/` are not part of a stamp - back up the volume for
those.

```bash
# every account, all in one verified stamp directory
docker compose exec eza /bin/eza-bookmarks backup
# prints: backup: /data/backups/20260101-031700
#         user alice -> /data/backups/20260101-031700/users/1/eza.db

docker compose exec eza /bin/eza-bookmarks backup --user alice
```

List accounts (with role, state, database size, and snapshot count) before or
after a backup:

```bash
docker compose exec eza /bin/eza-bookmarks users list
```

Restore (stop the service first so nothing writes to the databases). The
`restore` command validates the stamp, takes a fresh backup of the current
installation, copies each library to its configured path, and rewrites the
control rows, so a moved data root also works:

```bash
docker compose stop eza
docker compose run --rm eza /bin/eza-bookmarks restore /data/backups/<stamp> --yes
docker compose start eza
```

Add `--dry-run` to inspect the plan without writing. A stamp written by the
first multi-user layout (`users/<id>.db`, no manifest) is accepted; accounts
whose library is missing from the stamp keep their current copy. Restoring an
enabled account whose library predates the schema upgrade is safe: the restored
database migrates on open.

Copy a backup off the host:

```bash
docker cp eza:/data/backups/<stamp> /out/
docker compose exec eza rclone copy /data/backups/<stamp> remote:eza-backups
```


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
deployment flake pins it as a fixed-output derivation; the URL and SRI hash live
in one place, `nix/web-assets.json`:

```json
{
  "url": "https://github.com/meillaya/eza/releases/download/v0.2.0.0/eza-web-0.2.0.0.tar.gz",
  "hash": "sha256-..."
}
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
    # plus the <file>.gz sidecars scripts/build-web.sh writes next to the
    # compressible assets (wasm, css, html shell, loader JavaScript)

The `.gz` sidecars are not optional for a fast cold load: the server serves
them with `Content-Encoding: gzip` and `Vary: Accept-Encoding`, so the WASM
bundle crosses the wire at about 1.5 MB instead of 6.7 MB. Including them in the
tarball is what keeps the compression on; without them the assets are served
uncompressed.

Publish the asset with the release workflow or locally:

```bash
# Local route: build the deterministic tarball, then upload it to a v<version>
# release (the release workflow does the same on a v* tag and updates the pin):
bash scripts/build-web.sh
bash scripts/release-asset.sh            # writes dist/release/eza-web-0.2.0.0.tar.gz
bash scripts/release-asset.sh --check    # prints the SRI hash
# put the printed sha256-... into nix/web-assets.json "hash", then:
nix build .#eza-web
nix build .#docker              # rebuild the image with the pinned bundle
```

`.github/workflows/release.yml` builds and uploads the asset on a `v*` tag and
commits the resolved SRI hash to `nix/web-assets.json`. Until the pin is real,
`.#docker` and the default NixOS web-assets path fail at evaluation with an
actionable message rather than a hash mismatch; `nix/web-assets.json` is the
only file to edit.

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
