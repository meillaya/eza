# eza

A self-hosted, search-first knowledge base for your browser bookmarks — a
"third brain" that stays fast with 10,000+ links.

- **Backend:** Haskell (GHC 9.10), Warp/WAI, SQLite + FTS5.
- **Frontend:** Miso compiled to WebAssembly (GHC 9.14), served by the same binary.
- **Auth:** WebAuthn passkeys + one-time recovery codes (no passwords).
- **Dev environment:** `devenv.nix` only.
- **Deploy:** NixOS (primary), Docker, Kubernetes, behind Tailscale Serve or Caddy.

> Status: working end-to-end. The Haskell server + SQLite/FTS5 search,
> Netscape import/export, WebAuthn passkeys (setup/login/recovery/add-passkey),
> the v1 JSON API, and the Miso/WASM client (library, detail, inbox, graph,
> dedup, tags, AI tagging, maintenance, account) are implemented and smoke-tested.
> NixOS/Docker/Kubernetes deployment artifacts and SecretSpec integration are in
> `nix/`, `deploy/`, and `docs/`. The old Python implementation lives under
> `legacy/` for reference.

## Quick start (development)

Requires [devenv](https://devenv.sh) / Nix.

```bash
devenv shell            # GHC 9.10 + wasm32-wasi GHC 9.14 + everything else
dev                     # run the server on http://localhost:8080
web                     # build the Miso WASM bundle into static/app/
build                   # native build + web bundle
test                    # Haskell unit/integration suite
```

The first run opens `/setup`: register a passkey and save the ten recovery
codes. There is no password. Additional passkeys can be registered from
`/account/add-passkey`; recovery is at `/recover`.

To serve the app locally with the prebuilt WASM bundle:

```bash
devenv shell -- bash -c 'bash scripts/build-web.sh && cabal run eza-bookmarks -- serve'
```

and open <http://localhost:8080> (WebAuthn requires `localhost`, not
`127.0.0.1`).

The import/export path is available from the CLI:

```bash
eza-bookmarks init
eza-bookmarks import netscape bookmarks_14_08_2026.html --report dist/import.json
eza-bookmarks stats
eza-bookmarks verify
eza-bookmarks export > bookmarks.html
```

The reference export (`bookmarks_14_08_2026.html`) imports as:

| Metric | Count |
|---|---|
| unique http(s) bookmarks | **8,988** |
| tags | **75** |
| bookmark-tag links | **21,316** |
| duplicate anchors collapsed | 465 |
| non-http anchors skipped | 4 |
| untagged bookmarks | 87 |
| folders skipped as noise | 56 |

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `EZA_DATA_DIR` | `./data` | data root (DB, snapshots, backups) |
| `EZA_DB` | `$EZA_DATA_DIR/eza.db` | SQLite database path |
| `EZA_BIND` | `127.0.0.1:8080` | Warp listen address |
| `PUBLIC_ORIGIN` | `http://localhost:8080` | WebAuthn origin and secure-cookie decision |
| `EZA_RP_ID` | host of `PUBLIC_ORIGIN` | WebAuthn relying-party ID |
| `EZA_RP_NAME` | `eza` | WebAuthn display name |
| `EZA_STATIC_DIR` | `./static` in dev / package share in prod | web assets |
| `EZA_ALLOWED_ORIGINS` | `PUBLIC_ORIGIN` | Origin header allowlist |
| `EZA_SESSION_TTL_SECONDS` | 30 days | session lifetime |
| `EZA_SNAPSHOT_DIR`, `EZA_MONOLITH` | `$EZA_DATA_DIR/snapshots`, `monolith` | single-file snapshots |
| `EZA_BACKUP_DIR`, `EZA_BACKUP_OFFSITE` | `$EZA_DATA_DIR/backups`, unset | backups |
| `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` | unset | optional AI tagging |
| `EZA_AI_PROVIDER` | `anthropic` | `anthropic` / `openai` / `openai-compatible` |
| `EZA_OPENAI_BASE_URL` | OpenAI | base URL for compatible providers |
| `EZA_LOG_LEVEL` | `info` | logging |

Secrets are declared in `secretspec.toml` (SecretSpec). Development resolves
them through `devenv`; production uses the systemd-credential provider. See
`docs/secrets.md` (deployment docs).

## Architecture

```
core/    shared pure types, JSON, search-query parser, wikilinks
server/  Warp server, SQLite+FTS5, WebAuthn, importer/exporter, CLI
web/     Miso WASM client
static/  design system, auth.js, vendored WASI shim, built app/
nix/     NixOS module, package, Docker image
deploy/  compose + Kubernetes manifests
docs/    API, UI, import, deployment, performance
```

SQLite is WAL-mode with FTS5 `porter unicode61` over title, description, URL,
note body, and extracted text. Search supports `tag:`, `is:unread`, `is:dead`,
`link:`, and `-term` operators. The schema is append-only migrated and the app
refuses to open the old Python database (use a fresh DB + HTML import).

Auth is deny-by-default: every route is declared in one place, unsafe methods
require a CSRF header, and an unauthenticated API call returns 401.

## Tests

```bash
test                                    # Haskell unit + SQLite integration
EZA_IMPORT_FIXTURE=$PWD/bookmarks_14_08_2026.html test   # full-file acceptance
bash scripts/build-web.sh               # WASM bundle
bun tests/e2e/auth-smoke.mjs            # passkey setup/login (needs a server)
bun tests/e2e/api-smoke.mjs             # authenticated API contract smoke
```

## Deploy

- `docs/deployment-nixos.md` — NixOS module, hardened systemd, Caddy/Tailscale,
  backup timer, SecretSpec systemd credentials.
- `docs/deployment-docker.md` — non-root image, `/data` volume, compose.
- `docs/deployment-k8s.md` — single-writer SQLite deployment.
- `docs/tailscale.md` — HTTPS origin and RP ID notes.

The deployed binary is `eza-bookmarks` (server + CLI).

## License

MIT.
