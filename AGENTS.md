# Project knowledge base

eza stores bookmarks in SQLite and serves searchable libraries from one
Haskell process. Each account has a private SQLite library database; a control
database maps accounts to databases. The client is Miso compiled to
WebAssembly. An instance is sized for one person or a small household, with
around ten thousand links per account.

## Stack

- Server: GHC 9.10, Warp/WAI, `sqlite-simple` and `direct-sqlite` with FTS5,
  `webauthn` 0.12, aeson, tagsoup, `http-client`, optparse-applicative.
- Client: Miso 1.14 shell compiled to WebAssembly (GHC WASM 9.14), with the
  pure client state, routes, request algebra and reducers in the
  native-tested `eza-web-logic` package. Shared DTOs from `eza-core`.
- Development: `devenv.nix` only. Do not add flake devShells or a
  `nix develop` path.
- Deployment: deployment-only `flake.nix`, `nix/module.nix`,
  `dockerTools`, and the manifests under `deploy/`.

## Layout

```
core/    pure types, JSON codecs, search parser, wikilinks, URL helpers
server/  Warp server, SQLite, WebAuthn, importer, CLI, tests
web/     Miso client shell (views, FFI, subscriptions)
web-logic/ pure client model, routes, request algebra and reducers (native)
static/  CSS, auth pages, WASI loader, built WASM
spec/    bounded TLA+ models and JSON Schemas for the extension contract
nix/     NixOS module, package, Docker image, web bundle
deploy/  Docker Compose stack
extension/ Chromium MV3 clipper source and checks
sidecar/ optional JSON-lines extraction sidecar
scripts/ devenv command implementations, build and release helpers
docs/    API, architecture, deployment, import, performance, figures
tests/   fixtures and Playwright smoke tests
```

`core` builds for native and WASM. It must not import server code or IO
dependencies. `server` and `web` never import each other.

## Commands

```bash
devenv shell -- dev          # server on :8000
devenv shell -- web          # build WASM bundle
devenv shell -- build        # native and WASM
devenv shell -- test         # cabal test all
devenv shell -- lint         # fourmolu and hlint
devenv shell -- docs         # documentation drift checks
devenv shell -- e2e          # Playwright
devenv shell -- spec         # TLA+ model check and schema checks
devenv shell -- bench        # query benchmark
```

There is no Makefile. The devenv scripts are the command surface.
`scripts/build-web.sh` must work through `bash scripts/build-web.sh`.

## Database rules

- `data/control.db` uses the schema in `Eza.Control`: accounts, roles,
  WebAuthn handles, and the database path. `data/users/<id>/eza.db` uses the
  schema in `Eza.Db`. 0.4 opens only those two shapes; a pre-0.4 flat
  `EZA_DB` database is never opened or adopted (the server prints an upgrade
  hint), and the old Python layout is refused with a migration hint.
- A user database path comes only from the control row, never from a request.
- Migrations are append-only for both databases and checksummed by the shared
  `Eza.Migrate` engine (`schema_meta`): each migration's version, name and SQL
  are hashed, a mismatch refuses to open the database, and an older binary
  refuses a newer schema. Never edit or rename a migration that has shipped;
  rollback means restoring the per-migration backup (user DBs) or the
  pre-upgrade stamp (control DB). `eza-bookmarks verify` checks control and
  account schemas as well as the FTS index.
- A library's writer, read-only pool, layout cache and workers are owned by
  `Eza.Library`; open and close through it. Worker connections are bracketed
  and must close when the worker is cancelled. Never open a second long-lived
  library connection ad hoc, and never start workers outside the supervisor.
- Use `withImmediateTransaction` for writes. Do not perform network or
  subprocess work inside a write transaction.
- Request handlers never perform network or subprocess egress. Validate and
  enqueue a `jobs` row in the write transaction (202 + job id), and let the
  per-library egress worker claim it (`claimJobKind`, cancel flag, bounded
  retries, restart requeues running jobs). One active job per (kind, target)
  is a partial unique index; `GET /api/v1/jobs/{id}` is scoped to the caller's
  library. Snapshot file reads stay a normal GET; only capture is a job.
- The FTS triggers compare only the six indexed columns (title, description,
  url, note_body, extracted_text, domain), so updates to other columns do not
  rewrite the index.
- `added_at` records when eza first saw a row. `created_at` records the
  original save date from the export. Prune uses `added_at`.
- Destructive actions record a journal change with the before-image of every
  affected row inside the same transaction: full bookmark rows, bookmark/tag
  links (tag names), highlights, wikilinks, clipped captures and manual
  dead-link overrides; tag merge/rename/detach also capture the tag rows.
  `Eza.Journal` prunes the journal to the newest 100 changes. The UI asks for
  confirmation before merge or prune.
- Undo restores the newest usable change only: update-by-id when the URL is
  unchanged, insert when id and URL are free, refuse a URL conflict as a
  refused row (never overwrite) and rebuild the FTS index after a bookmark
  restore. Keep `recursive_triggers` on; `eza-bookmarks verify` checks the FTS
  integrity, not just row counts.
- Schema history: v7-v15 added the old undo side tables (dropped in v17),
  captures/clip templates, views, the event log/webhooks, the FTS domain
  column, webhook delivery kinds and dead-link overrides. **v16** adds
  `schema_meta` with per-migration checksums; **v17** replaces the undo side
  tables with `journal`/`journal_rows` (the legacy undo history is not
  migrated). The control database is at schema v2 (`schema_meta`). Do not
  edit a shipped migration; checksums refuse it.
- Favicons are cached per source domain in the `favicons` table, never per
  bookmark: one icon row serves every link on that domain and a single
  `UPDATE bookmarks ... WHERE domain = ?` fills the list rows. The per-account
  background backfill loop (`EZA_FAVICON_BACKFILL`, default on) must stay
  cache-first and fetch at most one missing domain at a time: conventional
  icon paths first, then at most one homepage parse when those miss. Never add
  a per-link icon request path. Only complete raster bodies are stored
  (complete ICO entries are cropped; truncated, incomplete, SVG, and
  placeholder bodies are rejected); startup validation repairs rows written
  before that rule, and successful icons refresh after `EZA_FAVICON_TTL_DAYS`.
- Capture snapshots live under `users/<id>/snapshots`. Backups are a stamp
  directory holding `control.db`, `manifest.json`, and
  `users/<id>/eza.db` (disabled accounts included; page snapshots are not in
  the stamp), pruned on `EZA_BACKUP_KEEP_DAYS`. Restore with
  `eza-bookmarks restore STAMP --yes` while the server is stopped: it
  validates the stamp, backs up the current installation, and rewrites the
  control paths. Only that stamp directory shape is accepted; pre-0.4 flat
  stamps are refused. Never copy a live database with `cp`, and never present a
  restore recipe that places `users/<id>.db` where the control row expects
  `users/<id>/eza.db`.

## Import rules

- Claim an account before importing. 0.4 never falls back to the pre-0.4 flat
  `EZA_DB` file: an import with no account fails, so back the old file up and
  import its HTML export instead.
- Imports are de-duplicated by the canonical URL key and idempotent. Newly
  inserted rows enqueue background enrichment jobs in the same transaction;
  matched rows keep their existing enrichment state.
- `eza-bookmarks import --json FILE` and the account import panel accept the
  versioned eza JSON export. The JSON export carries bookmarks, highlights
  (prefix/suffix included), captures, saved searches, rules, views, and clip
  templates; webhook secrets are deliberately excluded.

## Auth rules

- `Eza.Routes` is the single route truth: method, path template, authorization
  class and capability for every surface. `Eza.Server` parses each request once
  with `Routes.matchRoute` and dispatches to the `Eza.Api.*` handler families;
  `Eza.Authz` derives from the same table. Add a route by adding a `Route`
  constructor and its classification and handler, never by adding a bare route
  literal to a server case. Unknown `/api` paths are JSON 404; a known path with
  an unsupported method is JSON 405 with `Allow`. Exempt only the health
  endpoint, the login/setup/recovery ceremonies, and static assets.
- The control database owns identity: one username, one role, one database
  path, and one WebAuthn handle per account. Each user database owns that
  account's Argon2id hash in `app_state` and its sessions, tokens, shares,
  views, and webhooks. `Eza.Password` produces the PHC-style hash; never
  store or log the plaintext, and compare tags in constant time.
- Session, share, and API tokens carry the account id in their prefix
  (`u<id>_...`, `eza_pat_u<id>_...`). Resolve the account first, then hash the
  full token in that account's database. Every token must carry its account
  prefix; unprefixed pre-0.4 tokens are rejected.
- Authentication is a read. Validate sessions/tokens on the read-only pool;
  record `last_seen_at`/`last_used_at` only as a throttled activity touch
  (≤ once per minute) when stale. Never write on the authentication path for a
  fresh request; a normal GET must not need the writer.
- Admin accounts manage accounts, never each other's library content. At
  least one enabled admin must remain; an admin cannot disable or delete
  itself. The admin password reset is a break-glass takeover path: it may hand
  the account to the caller, so document it as such rather than claiming the
  admin cannot reach content. `DELETE /api/v1/admin/users/{id}` removes the
  account, and the library only when `delete_db` is true.
- Unsafe methods require `X-CSRF-Token` matching the hashed `eza_csrf`
  cookie. Sessions store `sha256(raw cookie token)` and expire after
  `EZA_SESSION_TTL_SECONDS`.
- Public auth POSTs check `Origin` and reject `Sec-Fetch-Site: cross-site`.
  A request body above `EZA_AUTH_BODY_LIMIT_BYTES` returns 413.
- Login failures are counted in `app_state`: after `EZA_LOGIN_MAX_ATTEMPTS`
  the account locks for `EZA_LOGIN_LOCKOUT_SECONDS` and the endpoint returns
  429 with `Retry-After`.
- Recovery redemption names a username and is verified against that
  account. Recovery sessions may call only `POST /api/setup/password`,
  `POST /api/auth/logout`, and read the account. Recovery clears the password
  and passkeys; the following setup writes a new password and rotates every
  recovery code out.
- Passkeys are optional second factors, not the primary login. The retired
  pre-0.4 `/api/auth/options|verify` sign-in routes are removed (JSON 404); a
  password login with `require_passkey` on returns `requires_2fa` and a
  short-lived `pending_2fa` session. `POST /api/auth/passkey/options|verify`
  complete the second factor. Pending sessions may not call `/api/v1` routes.
  The `POST /api/v1/account/2fa` endpoint requires the current password, and
  enabling it requires at least one passkey. Recovery clears the flag.
- Do not log credentials, challenges, recovery codes, or cookies. The
  password CLI paths read from a terminal or stdin with echo off and never
  take a password in argv.
- `EZA_LOG_LEVEL` controls WAI access logging (`debug`/`info` on, `warn`/
  `error` off); error lines still go to stderr. `EZA_MAX_BODY_BYTES` and
  `EZA_IMPORT_MAX_BYTES` bound authenticated request bodies with a JSON 413.
  Snapshot capture checks the bookmark URL against the public-address policy
  (honouring `EZA_ALLOW_PRIVATE_FETCH`) and caps the file at
  `EZA_SNAPSHOT_MAX_BYTES`; monolith's own subresource fetches remain outside
  the guard, so do not claim snapshot capture is fully sandboxed. AI tagging
  has no automatic switch: `EZA_AI_MODEL` defaults per provider and
  suggestions are requested explicitly.
- `PUBLIC_ORIGIN` and `EZA_RP_ID` define the WebAuthn scope. Changing the
  origin invalidates existing passkeys and requires recovery.
  `EZA_ALLOWED_ORIGINS` adds origins for the HTTP checks; it never replaces
  the public origin. `EZA_CLIP_ORIGINS` is the separate allowlist for the
  browser clipper; `chrome-extension://`, `moz-extension://`, and
  `safari-web-extension://` origins are accepted for bearer capture routes.
- Capture tokens are limited. A `capture` token may only `GET
  /api/v1/whoami`, `GET /api/v1/clip-templates`, `POST /api/v1/clip`,
  `POST /api/v1/clip/preview`, and `POST /api/v1/quick-save`; template writes
  require a browser session. The clipper sends `Authorization: Bearer` and
  `Idempotency-Key`, never a cookie, and never places the token in a URL or
  log. The clip API supports CORS preflight before the auth guard.

## Extension rules

- Extensions v1 are declarative: views and webhooks are data, never code.
  `spec/schema` and "Eza.View"/"Eza.Webhook" define the shapes; the server
  validates before storing and the client renders only known kinds. No
  plugin loader, sandboxed script host, or third-party extraction code.
- A view or webhook belongs to exactly one account database. Unknown schema
  versions and kinds are rejected; limits are enforced server-side.
- Events are recorded in the same transaction as the write. Merge/merge-all
  emit the keeper `bookmark.updated` and absorbed `bookmark.deleted` rows;
  bulk tag/read changes emit per-row `bookmark.updated`. Delivery is
  at-least-once with HMAC signing, retries, and disable on terminal failure.
  Webhook management is session-only, never bearer-token.
- The formal specs in `spec/` are bounded design checks, not refinement
  proofs. Do not claim a proof of the implementation; update the specs,
  schemas, examples, and bad fixtures together when a contract changes.

## Conventions

- Format with fourmolu and run hlint. Keep `-Wall` clean.
- Prefer total functions. Do not add partial functions such as `head`.
- SQL uses named parameters. The key includes the leading colon.
- DTOs live in core modules (`Eza.Types`, `Eza.Account`, `Eza.Ai`,
  `Eza.Consolidation`, `Eza.Rule`, `Eza.Share`, `Eza.View`, `Eza.Webhook`,
  `Eza.User`, `Eza.Boot`, `Eza.GraphLayout`) and serve both server and client.
  Every JSON body that crosses the boundary is one of those types; the client
  decodes strictly and reports a parse failure instead of defaulting a field.
  The boot payload carries `wire_version` and the client refuses to paint on a
  mismatch.
- `web` is the Miso shell: views, subscriptions, browser FFI and effect
  interpretation. Pure client state, routes, request paths and reducers live
  in `web-logic`, which builds natively and must not import Miso or JSFFI.
  Add reducer/route tests there; Playwright covers only the wiring.
- Assets live under `EZA_STATIC_DIR` and are served at `/assets/*`.
  `scripts/build-web.sh` compiles the client and then calls
  `scripts/bundle-web.sh`, which content-hashes every web asset and writes the
  single `asset-manifest.json` (assets, shell refs, precache list, build id).
  The manifest is the only asset list: the server shell, the auth pages and
  `/sw.js` all read it; never hand-maintain a second list. Hashed files are
  `public, max-age=31536000, immutable`; the shell is `no-store`; `/sw.js` is
  the generated file served `no-cache` with the build id as its ETag. After a
  web change, rebuild with `scripts/build-web.sh` (or rebundle an existing
  build with `scripts/bundle-web.sh --no-build`).
- Secrets are declared in `secretspec.toml`. Read `ANTHROPIC_API_KEY` and
  `OPENAI_API_KEY` from the environment at runtime.
- The project is licensed under Apache-2.0. Keep the license field in each
  Cabal package and `flake.nix` in sync with `LICENSE`.
- Prose follows the writing rules in the NixOS agent settings. Run the prose
  checker before committing documentation.

## Avoid

- Automatic merge, prune, or delete.
- Routes outside the auth guard.
- Copying a live SQLite database with `cp`. Use `eza-bookmarks backup`, and
  restore with `eza-bookmarks restore`.
- Network calls in the database write path.
- Client-local copies of shared DTOs, or field-optional decoders that turn a
  renamed or missing field into a default. Extend the core module instead.
- Adding flake devShells.
