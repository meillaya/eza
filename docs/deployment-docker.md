# Deploying eza with Docker

The published image is `ghcr.io/meillaya/eza`, built for `linux/amd64` and
`linux/arm64`. It contains the **eza-bookmarks** server, the Miso/WASM web
client, curl, sqlite3, monolith (snapshot capture) and SecretSpec. The container runs as non-root **uid/gid 10001**, stores all state
under **/data**, and exposes **/healthz** for health checks.

The image is produced by Nix (`packages.<system>.docker` in the deployment
flake) using `dockerTools.buildLayeredImage`; there is no Dockerfile because
both the server and the WebAssembly client are Nix derivations built from the
same revision.

## Quick start

```bash
docker run -d --name eza --restart unless-stopped \
  -p 8080:8080 -v eza-data:/data \
  ghcr.io/meillaya/eza:latest
```

Open <http://localhost:8080/setup> and create the first account. The named
`eza-data` volume holds the control database, account libraries, snapshots and
backups; keep it across upgrades. On a remote host set
`-e PUBLIC_ORIGIN=https://your-host` and terminate TLS in front of port 8080:
passkeys require a secure origin, and origin checks reject a browser origin
that differs from `PUBLIC_ORIGIN`.

## Docker Compose (recommended for a single host)

```bash
cp deploy/docker-compose.yml docker-compose.yml
# edit PUBLIC_ORIGIN only; the WebAuthn RP ID is derived from its host
docker compose up -d
docker compose logs -f eza
```

The checked-in compose file defaults to
`ghcr.io/meillaya/eza:latest`; pin `EZA_IMAGE` for reproducible deployments.
It uses a named volume `eza-data:/data`. The image pre-creates `/data` owned by
10001:10001, so a fresh named volume is already writable by the container user.
Do not add another replica: SQLite is a single-writer database and the server
serializes all writes.

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
  ghcr.io/meillaya/eza:0.4.0.0
```

Put a TLS terminator in front (Caddy or nginx) on the same host:
WebAuthn passkeys require a **secure origin**, so plain
`http://<host>:8080` will not work except on `http://localhost`.

## Build the image from source

```bash
# In the eza checkout (deployment flake):
# (Use `nix build path:.#docker` if the tree has uncommitted files, a git
# flake only sees tracked files.)
nix build .#docker              # -> ./result is a gzip'd image tarball
docker load < result            # -> Loaded image: eza:0.4.0.0 (some Docker
                                #    versions report localhost/eza:0.4.0.0)
docker image ls | grep eza
EZA_IMAGE=eza:0.4.0.0 docker compose up -d
```

The same binary provides `healthcheck` (for HEALTHCHECK / probes), `backup`,
`verify`, `stats`, `check-dead`, `repair-domains`, `import`, `init` and
`version`.

## Environment variables

| Variable | Image default | Purpose |
|---|---|---|
| `EZA_DATA_DIR` | `/data` | Data root: `control.db`, `users/`, `backups/`. |
| `EZA_CONTROL_DB` | `$EZA_DATA_DIR/control.db` | Account registry (identity, roles, per-account database paths). |
| `EZA_USERS_DIR` | `$EZA_DATA_DIR/users` | Per-account library root: `users/<id>/eza.db` and `users/<id>/snapshots/`. |
| `EZA_MAX_USERS` | `32` | Cap on user databases this process opens at once. |
| `EZA_DB` | `$EZA_DATA_DIR/eza.db` | Pre-0.4 single-user database path. 0.4 never opens or adopts it; it is only used to print the upgrade hint. |
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

Add `--dry-run` to inspect the plan without writing. Only the stamp directory
shape (`control.db`, `manifest.json`, `users/<id>/eza.db`) is accepted; pre-0.4
flat stamps are refused. Accounts whose library is missing from the stamp keep
their current copy. Restoring an
enabled account whose library predates the schema upgrade is safe: the restored
database migrates on open.

Copy a backup off the host:

```bash
docker cp eza:/data/backups/<stamp> /out/
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

The web client is Miso compiled to WebAssembly. The deployment flake builds it
from source with the `ghc-wasm-meta` toolchain input, so the image is
self-contained and there is no release asset to download or hash to pin:

```bash
nix build .#eza-web    # content-addressed bundle at share/eza/static
nix build .#docker    # image with that bundle baked in
```

`packages.<system>.eza-web` compiles `cabal.project.wasm` and runs the same
`scripts/build-web.sh` + `scripts/bundle-web.sh` the development shell uses.
The dependency plan is pinned by `cabal.project.wasm.freeze`; the Hackage
tarballs are fixed-output fetchurls in `nix/wasm-hackage.nix` with their solver
metadata vendored under `nix/wasm-cabal/`, so the Nix build itself is offline
and reproducible.

The output layout is the server's static tree: `share/eza/static/` with
`asset-manifest.json` (build id, logical-to-hashed path map, shell refs, and
the service-worker precache list), the hashed assets (WASM, loader,
`ghc_wasm_jsffi`, CSS with rewritten font URLs, scripts, icons, fonts, the WASI
vendor tree), and the generated `index.html`/`sw.js`/`manifest.webmanifest`.
Hashed files are served `public, max-age=31536000, immutable` with an ETag;
the shell is `no-store`; `/sw.js` is the generated worker served `no-cache`
with the build id as its ETag. The `.gz` sidecars the bundler writes are part
of the tree and the server serves them with `Content-Encoding: gzip` and
`Vary: Accept-Encoding`, which is what keeps the WASM cold load at about
2.1 MB instead of 7.7 MB. The server validates the manifest at startup and
refuses to start without it.

For a local development bundle outside Nix:

```bash
devenv shell -- scripts/build-web.sh
# then either serve it directly...
EZA_STATIC_DIR=$PWD/static ./bin/eza-bookmarks serve
# ...or stage it in an image build by overriding services.eza.staticDir
```

When the wasm dependency set changes, refresh `cabal.project.wasm.freeze`,
`nix/wasm-hackage.nix`, and `nix/wasm-cabal/` together;
`scripts/update-wasm-deps.sh` performs that update from a development shell.

## Upgrades

Back up first, pull the new published image, and recreate the container with
the same volume:

```bash
docker exec eza eza-bookmarks backup
docker compose pull
docker compose up -d            # recreated container keeps the eza-data volume
```

Local build users can rebuild instead:

```bash
git pull && nix build .#docker && docker load < result
EZA_IMAGE=eza:<version> docker compose up -d
```

The SQLite schema/migrations run on server start (`init`/migrations are
idempotent). For the v0.2.0.0 migration, run one explicit dead-link recheck
after upgrading so records previously marked dead by a 403 become live.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Container exits at start | `docker logs eza`: usually a bad `PUBLIC_ORIGIN`/`EZA_RP_ID` or unwritable `/data`. |
| `healthy` never becomes true | `/healthz` 503 → database problem; run `docker compose exec eza eza-bookmarks verify`. |
| Passkeys fail | Origin must be HTTPS and match `PUBLIC_ORIGIN`; `EZA_RP_ID` must be its host. |
| Permission denied in /data | Host bind mount not owned by 10001; fix on the host. |
| Web UI 404 | Image built before the release asset was pinned; rebuild `.#docker`. |
