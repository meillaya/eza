# Bookmarks

A tag-based, search-first bookmark manager for 10k+ links. Single-process
Python — SQLite + FTS5 on the backend, vanilla JS with native CSS
virtualization on the frontend. Passkey auth (WebAuthn), a knowledge-base
layer (notes, wikilinks, article extraction), duplicate detection, and
Netscape import/export that round-trips with every major browser.

## Overview

Browser bookmark managers collapse past a few thousand items. This is the
minimal honest version of "what if the search bar was the front door and tags
replaced folders":

- **One flat list, multiple tags per item** — no folder tree to maintain
- **Fuzzy FTS5 search** over title, description, URL, and (KB) article text
- **Tag chips as additive filters** — AND semantics, multi-select
- **Passkey login** — WebAuthn (no passwords), with recovery codes as the
  self-hosted escape hatch
- **Knowledge base** — per-bookmark notes with `[[wikilinks]]` + backlinks,
  article-text extraction, full-page snapshots
- **Organization built in** — dead-link sweeps, duplicate detection, tag
  consolidation, LLM and heuristic tagging, a read-later inbox
- **Import/Export** — Netscape `bookmarks.html` in, Chromium-compatible
  Netscape `bookmarks.html` out
- **10k+ card grid** uses `content-visibility: auto`, so the browser
  virtualizes the whole library with zero JS windowing code
- **Metadata is fetched after insertion**, never blocking the response

## Quick start

Requirements: Python ≥ 3.11, [`uv`](https://github.com/astral-sh/uv), and
[`just`](https://github.com/casey/just) (the task runner — install via
`cargo install just`, a prebuilt binary from the GitHub releases page, or
`nix run nixpkgs#just`). No Makefile: `just` is the one runner.

```bash
# 1. Install dependencies from the lockfile (fails if the lockfile drifts)
just sync

# 2. (Optional) environment variables — the dev defaults below are fine to
#    start with. Set SECRET_KEY once you deploy anywhere non-loopback.
#    See the table under "Configuration".

# 3. Run the server
just run            # uvicorn on 127.0.0.1:8000, DB at data/bookmarks.db

# 4. First run: register your passkey
#    OPEN THIS IN THE BROWSER:
open http://localhost:8000/setup
```

> **⚠️ Use `http://localhost:8000` — NOT `http://127.0.0.1:8000`.**
> The server binds `127.0.0.1:8000`, but WebAuthn credentials are bound to
> the *origin* you register them against, and the default relying-party ID
> (`WEBAUTHN_RP_ID`) is `localhost` for loopback hosts. If you open
> `127.0.0.1:8000` the RP ID won't match the origin and passkey registration
> will fail. The default `PUBLIC_ORIGIN` is `http://localhost:8000` — open
> exactly that.

The `/setup` page walks you through passkey registration and shows your
**recovery codes** (print/export them now — they are the only way to log in
again if you lose the passkey; see "Backup & recovery"). After setup, import
your browser bookmarks via **Import** in the UI, or just start adding links.

### Configuration (environment variables)

| Variable | Default | Why |
|---|---|---|
| `PUBLIC_ORIGIN` | `http://localhost:8000` | The origin users reach the app at. Anything non-loopback is treated as production (Secure session cookie). |
| `WEBAUTHN_RP_ID` | `localhost` (loopback) / derived host | The WebAuthn relying-party ID. Must match the origin's host — see the pinned-host warning above and "Deploy". |
| `SECRET_KEY` | insecure dev default (+ loud warning in prod) | Signs sessions. Generate with `python -c "import secrets; print(secrets.token_urlsafe(64))"`. |
| `BOOKMARKS_DB` | `<repo>/data/bookmarks.db` | SQLite file location. Parent directory is created at import time. |
| `SESSION_TTL_SECONDS` | `2592000` (30 days) | Session lifetime. |
| `BACKUP_DIR` | `<db dir>/backups` | Where `bookmarks-backup` writes. |
| `BACKUP_OFFBOX_DEST` | unset | Optional offsite destination (local dir, rclone remote, S3). |
| `EXPORT_TOOLBAR_TAG` | `toolbar` | Tag whose bookmarks land in the exported `PERSONAL_TOOLBAR_FOLDER`. |
| `IMPORT_TOOLBAR_TAG` / `IMPORT_UNFILED_TAG` | `toolbar` / `unfiled` | Tags applied to Chromium's special folders on import. |
| `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` | unset | Used by `bookmarks-retag` (LLM tagging). |

## Task runner

[`just`](https://github.com/casey/just) is the one task runner. `just --list`
shows everything; the recipes are:

| Recipe | Command | What it does |
|---|---|---|
| `just sync` | `uv sync --locked` | Install dependencies from the lockfile |
| `just test` | `uv run pytest -p no:cacheprovider -q` | Python test suite (pytest + TestClient) |
| `just lint` | `uv run ruff check .` | Ruff lint |
| `just check` | `uv run ty check` | ty type-check |
| `just build` | `uv build` | Build the wheel + sdist |
| `just run` | `uv run bookmarks-server` | Run the server on `127.0.0.1:8000` |
| `just backup` | `uv run bookmarks-backup` | Online SQLite backup into `data/backups` |
| `just export` | `uv run bookmarks-export` | Export the library as Netscape `bookmarks.html` |
| `just seed` | `uv run python -c "from app import db; db.get_conn()"` | Initialize the local database (schema + migrations) |
| `just e2e` | `docker compose run --rm e2e bun run test:e2e` | Browser e2e suite via the pinned Docker harness |
| `just e2e-nix` | `nix develop --command bun run test:e2e` | Browser e2e suite via the Nix devshell |

## Usage

- **`/`** — main grid. 60 cards per page, infinite scroll below the fold.
- **Type to search** — debounced 180 ms. Searches title, description, URL
  (and article text once extracted). Operators like `is:unread`, `is:dead`,
  `tag:x`, and `url:` are supported.
- **Click tag chips** — multi-select; selected tags are ANDed.
- **`/`** keyboard shortcut focuses the search bar.
- **`+ Add`** — opens a modal. URL is required, tags are comma-separated.
- **Import / Export** — upload a browser `bookmarks.html` export, or download
  the whole library as `bookmarks.html` (see "Import & Export").
- **Hover a card** — `×` button removes it.
- **`/bookmark/{id}`** — detail page: edit the note body, see backlinks, run a
  snapshot.
- **`/inbox`** — read-later queue: unread bookmarks, with "mark all above"
  as you scroll past them.
- **`/graph`** — neighborhood graph of a bookmark's links (1–2 hops).
- **`/dedup`** — duplicate-candidate review + merge.
- **`/tags-cleanup`** — tag consolidation candidates (case-duplicates,
  near-duplicates) + merge.
- **`/maintenance`** — run a bounded dead-link sweep and review age-pruning
  candidates.

## Architecture

```
app/
  main.py              FastAPI routes (search, setup, import/export, dedup,
                       tags, graph, inbox, maintenance, detail)
  db.py                SQLite + FTS5 schema, connection, queries, bulk insert
  migrations/          versioned SQLite migrations (m0001 … m0006)
  auth.py              WebAuthn passkeys, sessions, CSRF, recovery codes
  config.py            environment-driven settings (see table above)
  fetcher.py           background title/favicon/description enrichment +
                       article-extraction scheduling (never on the read path)
  extractor.py         parse-only article extraction (trafilatura)
  check_dead.py        CLI: HEAD-check all bookmarks, flag dead links
  auto_tag.py          CLI: LLM-powered semantic re-tagging of fat tags
  heuristic_tag.py     CLI: domain-rule tagger (no API key, no network)
  dedup.py             duplicate-candidate detection engine
  links.py             wikilink parsing + backlinks (linked/unlinked)
  tag_cleanup.py       tag consolidation candidates + merge
  exporter.py          CLI: Chromium-compatible Netscape bookmarks.html
  export_notes.py      CLI: per-bookmark Markdown export
  snapshot.py          CLI: single-file HTML snapshots (monolith binary)
  backfill_extract.py  CLI: resumable article-extraction backfill
  backup.py            CLI: online SQLite .backup + verify + prune
  reset_auth.py        CLI: clear passkeys/sessions/codes → first-run /setup
templates/             server-rendered pages (index, setup, detail, graph,
                       inbox, dedup, tags-cleanup, maintenance, …)
static/                app.js (vanilla JS controller), style.css,
                       favicon-fallback.svg
tests/                 pytest layer (test_*.py) + tests/e2e Playwright specs
scripts/backup.sh      systemd/cron daily backup entry point (see "Backup")
justfile               the one task runner (see above)
```

Key properties:

- **Single SQLite file, WAL + FTS5** — the whole app is one process, one
  database, zero infrastructure.
- **Parse, don't validate at the UI** — the importer classifies Netscape
  `<DT>` nodes by structure, not string matching.
- **Explicit, versioned migrations** — `PRAGMA user_version`-stamped steps in
  `app/migrations/`, each in its own transaction.
- **Background everything** — enrichment, extraction, snapshots, dead-link
  sweeps, backups never block the request path.

### Speed notes

- **SQLite WAL + FTS5** — full-text search over 10k rows is ~0.1–1 ms
- **External-content FTS5** — the FTS index references `bookmarks` rows by id;
  no duplicated data, smaller writes
- **Porter stemming** — `"running"` matches `"run"`, `"databases"` matches `"database"`
- **`synchronous=NORMAL`** — safe with WAL, ~10× faster writes than FULL
- **Prepared statements** — every list/count query is parameterized; no string SQL
- **Bulk inserts** — `bulk_insert_bookmarks()` wraps the entire import in a
  single transaction; ~100× faster than per-row commits
- **`content-visibility: auto`** — offscreen cards are not rendered by the
  browser; scrollbar height stays accurate via `contain-intrinsic-size`
- **Debounced search** — 180 ms; cheap to retype
- **Background enrichment** — title/favicon/description fetched after insert,
  never on the read path
- **No ORM** — direct SQL means zero abstraction tax

### Measured on a real 9k-bookmark import

| Operation | Latency |
|---|---|
| Import 9,415 bookmarks | 448 ms |
| `GET /api/search?q=rust` (139 matches over 9k) | 2.6 ms |
| `GET /api/search?q=python` (51 matches) | 2.6 ms |
| `GET /api/search?q=github` (869 matches) | 3.2 ms |
| `GET /` initial render (60 cards, 63 KB HTML) | 10 ms |

### Storage

10k bookmarks ≈ 5 MB on disk. SQLite handles this trivially. The WAL file
(`bookmarks.db-wal`) can grow during heavy writes; it's checkpointed
automatically by SQLite on close or can be forced with
`PRAGMA wal_checkpoint(TRUNCATE)`.

## Organization

The app is search-first, but keeping 10k links *organized* is a distinct
job — dead-link hygiene, dedup, tag consolidation, AI tagging, and a
read-later queue.

### Dead links

```bash
# Full sweep — checks every bookmark that hasn't been checked yet
uv run bookmarks-check-dead

# Cap the batch / only re-check rows not checked within the last day
uv run bookmarks-check-dead --limit 500
uv run bookmarks-check-dead --older-than 86400

# Re-check rows already flagged dead / tune concurrency and timeout
uv run bookmarks-check-dead --include-dead
uv run bookmarks-check-dead --concurrency 64 --timeout 5
```

Concurrency is bounded by an asyncio semaphore. A link is flagged dead when
the HEAD returns 4xx/5xx, when the host is unreachable, or when the request
times out. Some servers reject HEAD; we fall back to a ranged GET in that
case. The sweep updates `is_dead` and `last_checked_at` for every row. On the
real 9k-bookmark dataset this runs at roughly 100 checks/s with
`--concurrency 32`.

The **`/maintenance`** page (`GET /api/check-dead/run` to trigger a bounded
sweep, `GET /api/search?is_dead=1` to review, per-row delete) is the in-UI
version; it also lists **age-pruning candidates** (`GET /api/prune/candidates`,
apply via `POST /api/prune/apply` — user-confirmed, never automatic).

### AI tagging

Browser imports usually produce a few "fat" tags holding thousands of
bookmarks each — `imported`, `tabs`, `archive` — useless for browsing. Two
CLIs attack this:

**`bookmarks-retag`** (LLM) — asks an LLM to suggest specific topic tags for
each fat bucket and applies them.

```bash
uv run bookmarks-retag --dry-run                       # preview first
uv run bookmarks-retag                                  # apply
uv run bookmarks-retag --remove-generic                 # drop the old generic tag
uv run bookmarks-retag --target imported --target tabs  # specific tags
uv run bookmarks-retag --provider openai --all-above 100
uv run bookmarks-retag --provider openai-compatible --base-url http://localhost:11434 --model llama3.1
uv run bookmarks-retag --sample-size 50
```

API key resolution: `--provider anthropic` reads `ANTHROPIC_API_KEY`,
`--provider openai*` reads `OPENAI_API_KEY`. Override with `--api-key-env`.

**`bookmarks-heuristic-tag`** (no key, no network) — for each bookmark in a
fat bucket, looks up the URL's domain in a hand-tuned rules table and applies
the resulting tag. Fast, deterministic, and free.

### Dedup

The **`/dedup`** page and `GET /api/dedup/candidates` find duplicate groups
via three independent signals: normalized URLs (lowercased host, no
`www.`/trailing slash/fragment, tracking params dropped), identical titles,
and identical `title + domain`. Merging (`POST /api/dedup/merge`) folds one
bookmark's tags, notes, links and open/click history into the survivor and
removes the duplicate; `DELETE /api/dedup/undo` reverts the most recent merge.

### Tag consolidation

The **`/tags-cleanup`** page (`GET /api/tags/consolidation-candidates`)
surfaces tag names that differ only by case ("Music"/"music") or that are
near-duplicates via fuzzy matching (rapidfuzz). Merging (`POST /api/tags/merge`)
is user-confirmed — there is no automatic merge anywhere. `GET
/api/tags/{tag}/suggestions` + `POST /api/tags/apply` offer per-tag rename
suggestions in the review UI.

### Inbox (read-later)

`/inbox` is the read-later queue: unread bookmarks newest-first, with
"mark all above" (`POST /api/bookmarks/mark-all-above`) flipping everything
above a cursor to read in one transaction. Saved-search collections
(`GET/POST /api/saved-searches`, delete by id) persist named search filters.

### Graph

`/graph` + `GET /api/graph?seed={id}&depth={1|2}` render the seed bookmark's
1–2 hop neighborhood over the `links` table — never the whole corpus — with
node size ∝ indegree and tag/`is:unread` filters. It's a view of your links,
not the primary navigation.

## Import & Export

### Import (Netscape)

In Chrome/Firefox/Edge: bookmark manager → export to HTML. In Safari:
File → Export → Bookmarks. Drop the resulting `bookmarks.html` onto the
**Import** button. Folder paths become slash-joined tags (e.g.
`Bookmarks Bar / Dev / Rust` → `dev, rust`).

Two folder categories are recursed into but **not** added as tags:

1. **Top-level browser folders** — "Bookmarks bar", "Other bookmarks",
   "Mobile Bookmarks". Too generic to be useful.
2. **Timestamp-named folders** — anything matching patterns like
   `new folder – 18 apr 2025 14:06:10 GMT-04:00`, `2024-01-07 13:59:25`. These
   come from session-manager/tab-save exports and flood the tag list.

Chromium's special folders (`PERSONAL_TOOLBAR_FOLDER`, `UNFILED_BOOKMARKS_FOLDER`)
map to `IMPORT_TOOLBAR_TAG`/`IMPORT_UNFILED_TAG` instead of their folder
names. Duplicate URLs are deduplicated by the `UNIQUE` constraint on
`bookmarks.url`.

### Export (Netscape)

```bash
# Whole library as a Chromium-compatible bookmarks.html (stdout by default)
uv run bookmarks-export -o bookmarks.html

# Include note bodies as <DD> descriptions (excluded by default)
uv run bookmarks-export --with-notes -o bookmarks.html
```

The exporter (`app/exporter.py`) renders Chromium-compatible output — the
canonical Netscape header, `\r\n` line endings, `PERSONAL_TOOLBAR_FOLDER` for
the toolbar tag (`EXPORT_TOOLBAR_TAG`), Other-bucket flattening — so the file
imports cleanly back into Chrome/Firefox/Edge/Safari **and** into this app's
own importer. The UI offers the same via `GET /api/export`.

### Notes export (Markdown portability guardrail)

Notes live in SQLite. `bookmarks-export-notes` is the escape hatch that keeps
them portable — one `.md` file per bookmark with YAML-ish frontmatter (title,
url, tags, created) + the note body + the links list:

```bash
uv run bookmarks-export-notes ./export              # bookmarks with a note body
uv run bookmarks-export-notes ./export --all        # every bookmark
uv run bookmarks-export-notes ./export --include-extracted
```

## Testing

There are **two** test layers. Run both before shipping anything.

### Layer 1 — Python (pytest + TestClient)

The Python layer covers the DB layer, the importer/exporter, auth APIs,
search operators, dedup/tag-consolidation engines, migrations, packaging,
and performance. It runs fast and needs nothing installed beyond the venv:

```bash
just test          # uv run pytest -p no:cacheprovider -q
```

### Layer 2 — browser e2e (reproducible Playwright/Chromium harness)

All browser behavior — passkey ceremonies, first-run `/setup`, notes editor,
backlinks, quick-switcher, graph rendering, visual QA — is covered by
Playwright specs in `tests/e2e/`, run through the **reproducible harness** in
[`reproducible-e2e-browser-testing/`](reproducible-e2e-browser-testing/e2e/README.md)
(plan todo 13). Browsers, Bun, and Node are pinned in lockstep across the
Docker image (`mcr.microsoft.com/playwright:v1.62.1-noble` + Bun 1.3.11), the
CI container, the devcontainer, and the Nix flake (`590d737e`), so the same
suite runs byte-for-byte identical browser binaries anywhere.

| Run it with | Command | What it uses |
|---|---|---|
| Docker (Chromium + WebKit) | `just e2e` | `docker compose run --rm e2e bun run test:e2e` |
| Nix devshell | `just e2e-nix` | `nix develop --command bun run test:e2e` |
| CI | push/PR to GitHub | `.github/workflows/e2e.yml` |

`playwright.config.ts` boots two app servers itself (port 8000 = auth
ceremony DB, port 8001 = UI DB, both wiped per run), so the suite is
self-contained. When `PLAYWRIGHT_BASE_URL` is set, the `webServer` array is
emptied and the suite targets that external origin instead.

**CI workflow** (`.github/workflows/e2e.yml`): runs on every push and pull
request; builds the adapted harness image from `Dockerfile.e2e` (which ships
Python 3.12 + uv alongside the pinned browsers), then inside it runs
`bun install --frozen-lockfile && uv sync --frozen && bun run test:e2e`;
on failure it uploads `playwright-report/` and `test-results/` as artifacts.

**Harness runbooks** — the repo's
[`reproducible-e2e-browser-testing/e2e/README.md`](reproducible-e2e-browser-testing/e2e/README.md)
is the authoritative source; the README section pointers:

- **§2 — Railway cron deployed-app smoke.** Create a second Railway service
  (`e2e-cron`) from the repo, set a cron schedule, and point it at the
  **deployed** app: `PLAYWRIGHT_BASE_URL=https://<your-app>.up.railway.app`
  (the config then skips booting servers), `RAILWAY_SHM_SIZE_BYTES=268435456`
  (Chromium hits the 64 MB default `/dev/shm`), `PLAYWRIGHT_BROWSERS_PATH=/ms-playwright`
  (browsers are prebaked — no install step). Scope the run to **env-free
  specs only** — specs that depend on the harness-gated, locally-booted
  servers must never be pointed at a production domain. Use `--workers=1` and
  a short spec list so the job self-terminates before the next cron tick
  (Railway skips runs that are still executing). See §2.3 for the exact start
  command.
- **§3 — bare-metal systemd.** The hardened but Chromium-safe unit template:
  non-root `User=playwright`, `ProtectSystem=strict` + `ReadWritePaths` for
  `test-results/`/`playwright-report/`, `PrivateTmp`, `NoNewPrivileges`,
  `MemoryMax=2G`, `TasksMax=256`. **`MemoryDenyWriteExecute=yes` is
  forbidden** — it blocks `mprotect(PROT_EXEC)` and Chromium's V8 JIT dies
  instantly; it is the single most common "hardened unit crashes Playwright"
  cause. On Ubuntu 23.10+/24.04 you must also handle the AppArmor
  unprivileged-user-namespace restriction (sysctl or a `userns,` profile) or
  Chromium fails with "No usable sandbox!". Full unit + timer in §3.1–3.2.
- **§4 — Arch/CachyOS.** `npx playwright install --with-deps` is unsupported
  (no Arch package mapping → `apt-get` exit 127). Install OS deps with
  pacman, or point the runner at the distro Chromium via `executablePath`, or
  use the repo's Nix devshell (zero-pacman option). Watch for the
  `cachyos-ksm-settings` freeze bug (disable the service if Chromium hangs at
  launch) and the rootless-podman-on-btrfs storage driver fix. Details in §4.

## Tests

The complete pytest inventory — **reconciled against `ls tests/test_*.py`**
on every change so the list never drifts (each file's first line states the
plan todo it pins):

```
tests/conftest.py
tests/test_ai_tagging.py
tests/test_api_autocomplete.py
tests/test_auth.py
tests/test_auth_tables.py
tests/test_auto_tag.py
tests/test_backup.py
tests/test_check_dead.py
tests/test_config.py
tests/test_conn.py
tests/test_credentials.py
tests/test_db.py
tests/test_dedup.py
tests/test_dedup_merge.py
tests/test_detail.py
tests/test_exporter.py
tests/test_export_notes.py
tests/test_extractor.py
tests/test_fts_trigger.py
tests/test_graph_api.py
tests/test_health.py
tests/test_heuristic_tag.py
tests/test_importer.py
tests/test_inbox.py
tests/test_kb_schema.py
tests/test_links.py
tests/test_maintenance.py
tests/test_migrations.py
tests/test_packaging.py
tests/test_recovery.py
tests/test_search_operators.py
tests/test_search_perf.py
tests/test_setup.py
tests/test_tag_consolidation.py
```

The browser layer lives in `tests/e2e/` and is counted separately:

```
tests/e2e/auth.spec.ts          passkey ceremony (register/login) on the 8000 server
tests/e2e/setup.spec.ts         first-run /setup registration on the 8001 server
tests/e2e/smoke.spec.ts         first-run page assertions (runs before setup claims the DB)
tests/e2e/notes-editor.spec.ts  note body editing on the detail page
tests/e2e/backlinks.spec.ts     wikilink backlink rendering
tests/e2e/graph.spec.ts         graph canvas renders, node click navigates
tests/e2e/quick-switcher.spec.ts
tests/e2e/visual-qa.spec.ts
tests/e2e/fixtures/index.ts     shared Playwright fixture
tests/e2e/helpers/seed_credential.py  CDP WebAuthn credential seeding helper
```

## Deploy — Railway

Railway is the supported one-command hosting path. The repo ships the verified
Docker image (`Dockerfile`) and a `railway.toml` deployment config; this
section is the runbook. **The `railway up` step itself is a user-run step** — it
needs a Railway account and login, so nothing here requires (or runs) Railway
credentials.

### What ships and what's verified

| Artifact | Role | Verification boundary |
|---|---|---|
| `Dockerfile` | Reproducible uv multi-stage image (non-root `app` user, monolith binary, `HEALTHCHECK /health`, `CMD uvicorn ... --port ${PORT:-8000}`) | Worker-verified: image builds, boots, `/health` 200 with an empty volume (todo 35) |
| `railway.toml` | Deployment config: Railpack builder, shell-wrapped start command, healthcheck path, restart policy | Worker-verified: parses, matches the Railway config-as-code schema |
| This runbook | Everything you must set and check before `railway up` | Read it before deploying |

`railway.toml`:

```toml
"$schema" = "https://railway.com/railway.schema.json"

[build]
builder = "RAILPACK"

[deploy]
startCommand = '/bin/sh -c "exec uvicorn app.main:app --host 0.0.0.0 --port $PORT"'
healthcheckPath = "/health"
restartPolicyType = "ON_FAILURE"
```

Field notes:

- **`builder = "RAILPACK"`** — Railpack (the default, Nixpacks' successor)
  detects the uv project and builds it. The Dockerfile is the verified image
  for local/NixOS-with-Docker; if you prefer to deploy *that* image instead,
  set `builder = "DOCKERFILE"` and drop the `startCommand` (the Dockerfile
  already carries an identical `CMD` + `HEALTHCHECK`).
- **`startCommand` is wrapped in `/bin/sh -c`** — Railway runs start commands
  in **exec form, which does not expand environment variables**. `$PORT` is
  injected by Railway and must expand at runtime; the shell wrapper is the
  documented equivalent of shell form that makes that work. The Dockerfile's
  `CMD` is already shell form for the same reason.
- **`healthcheckPath = "/health"`** — Railway polls this until it returns 200
  before routing traffic. `/health` is auth-exempt, side-effect-free, and does
  a `SELECT 1` DB probe (503 when the DB is unreachable). Railway probes from
  the `healthcheck.railway.app` host — the app does not restrict hostnames, so
  this is fine.
- **`restartPolicyType = "ON_FAILURE"`** — restart only after a crash, never
  on clean exit.

### One-time setup checklist (user-run)

Do this in order. Verify each step before moving on.

1. **Log in / create the project.** `railway login`, then
   `railway init` (or create the project in the dashboard).
2. **Add a volume mounted at `/app/data`.** This is non-negotiable — without a
   volume the SQLite DB is ephemeral and **every redeploy wipes your data**.
   Railway volumes back SQLite fine (verified with the empty-volume case).
3. **Set the environment variables** (see the table below).
4. **Attach a custom domain** (see "Domain & passkeys" — this is the supported
   path).
5. **Check `/health` on the deployed service** before doing anything else:
   `curl https://<your-domain>/health` must return `200 {"status":"ok"}`.
   Railway's own healthcheck gates the deploy too — if the deploy "fails"
   immediately, this is the first place to look.
6. **Register your first passkey** at `/setup` (one-time bootstrap).
7. **Confirm a passkey login round-trips**, then **import your bookmarks**
   (the volume is empty until you do).

### Environment variables (Railway)

| Variable | Value | Why |
|---|---|---|
| `BOOKMARKS_DB` | `/app/data/bookmarks.db` | The SQLite file **on the mounted volume** (step 2). Any other path is ephemeral. |
| `SECRET_KEY` | a long random string | Signs sessions. **Unset in prod ⇒ loud warning + insecure dev default.** Generate with `python -c "import secrets; print(secrets.token_urlsafe(64))"`. |
| `PUBLIC_ORIGIN` | `https://<your-custom-domain>` | Drives the prod predicate (Secure cookie) and session origin checks. Must match the domain users actually reach. |
| `WEBAUTHN_RP_ID` | `<your-custom-domain>` (no scheme, no path) | The WebAuthn relying-party ID. On a custom domain it **must** be set to the domain. See "Domain & passkeys". |
| `RAILWAY_RUN_UID` | `0` — **fallback only, see below** | Only if the container's non-root user can't write to the volume. **This is not the fix.** |
| `BACKUP_OFFBOX_DEST` | e.g. an S3-compatible URL | Offsite destination for the daily backup. See "Backup & recovery". |

#### `RAILWAY_RUN_UID=0` is a fallback, not the fix

The Docker image runs as the non-root `app` user. On Railway, a volume mounted
at `/app/data` **shadows the image's directory and its build-time ownership**,
so the image-level `chown` does **not** apply to the mount.

- **PRIMARY fix:** `app/config.py` creates `BOOKMARKS_DB`'s parent directory
  at import time, against the **live** filesystem — i.e. the mounted volume.
  This is what makes the empty volume work; it's verified.
- **`RAILWAY_RUN_UID=0`:** a *fallback* that makes Railway run the container
  as root so it can write anywhere. Only reach for it if you hit permission
  errors on the volume despite the config-init fix. The tradeoff is losing the
  non-root hardening in the image. Do not set it preemptively.

### Domain & passkeys

**A custom domain is the supported path.** Railway's `*.up.railway.app`
hostnames sit on a public-suffix boundary; whether passkey registration works
on them is **PSL-dependent and must be tested at deploy** — do not assume it.
Plan for a custom domain from the start.

- Set `PUBLIC_ORIGIN=https://<your-custom-domain>` and
  `WEBAUTHN_RP_ID=<your-custom-domain>`.
- **Changing the hostname invalidates existing passkeys.** WebAuthn
  credentials are bound to the origin and RP ID you registered them against.
  If you move from `*.up.railway.app` to a custom domain (or change the domain
  later), previously registered passkeys will not verify — use the recovery
  codes or `bookmarks-reset-auth` to re-enroll (see "Backup & recovery").

### Serverless sleep is NOT enabled by default

`railway.toml` does not set `sleepApplication`, and **you should not enable it**:

- **Cold-boot 502s** — a sleeping service returns a 502 on the first request
  while it wakes; Railway may show it as unhealthy.
- **Background-job impact** — dead-link sweeps, fetcher enrichment, and the
  daily backup run inside the container; a sleeping service never runs them,
  so the DB silently stops being maintained and backed up.

If you ever *do* enable sleep for cost reasons, you must move the daily backup
out of the container (Railway cron + the offsite logical dump is the pattern)
and accept cold-boot latency. Default: keep it always-on.

## Deploy — NixOS

For a bare-metal box (or any NixOS host) the repo ships a self-contained
**deployment flake** at [`nixos/`](nixos/flake.nix) — do not confuse it with
the repo-root `flake.nix`, which is the *e2e-harness devshell* (Playwright
tests). The two flakes are independent; the deployment flake lives in `nixos/`
so they never collide.

What it provides, all **build-verified** (`nix flake check ./nixos` and
`nix build ./nixos#default` pass — the venv boots and serves):

| Piece | Details |
|---|---|
| **uv2nix venv** (`packages.default`) | `mkVirtualEnv` over the repo's `uv.lock` (hello-world template, wheel preference). Entry points: `uvicorn`, `bookmarks-server`, all `bookmarks-*` CLIs. QA: `nix run .#bookmarks-server` from `nixos/` starts the server. |
| **NixOS module** (`nixosModules.default`) | `services.bookmarks` option — domain, port (default 8000), `extraEnv`, and a `backup` sub-option (schedule, retention, optional offsite destination). |
| **Hardened systemd unit** | `DynamicUser`, `StateDirectory=bookmarks` → `/var/lib/private/bookmarks` with `BOOKMARKS_DB` pointing there, empty `CapabilityBoundingSet`, `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `PrivateDevices`, `RestrictAddressFamilies=AF_INET/AF_INET6/AF_UNIX`, `UMask=0027`, `Restart=on-failure`. |
| **Caddy** | Automatic HTTPS (ACME) for your domain, `reverse_proxy 127.0.0.1:8000`. |
| **agenix** | `SECRET_KEY` + optional API keys (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, …) injected as a systemd credential via `LoadCredential`. |
| **Backup timer** | `systemd` timer (default 03:17 daily) running `scripts/backup.sh` from a **Nix-store derivation** — see "Backup & recovery". |

> **⚠️ `MemoryDenyWriteExecute` must stay OFF.** The hardened unit deliberately
> does **not** set `MemoryDenyWriteExecute`. That systemd policy breaks the
> V8/Node JIT and `require()` in Node — if an e2e runner (the Playwright
> harness) is ever added to this unit, MDWE would crash Chromium and the test
> runner at startup. Keep it unset. (`grep -c MemoryDenyWriteExecute
> nixos/flake.nix` must be 0.)

### One-time provisioning (user-run, needs the target box)

The steps below are executed on the NixOS host. Nothing in the repo requires a
live NixOS box to build or test.

1. **Add the flake to your NixOS config.** In `flake.nix` (your system's),
   add `bookmarks.url = "path:/path/to/this/repo/nixos"` (or push the repo and
   use a `git+file:`/`github:` URL) and import the module:

   ```nix
   inputs.bookmarks.url = "path:/srv/bookmarks/nixos";

   # in modules:
   {
     imports = [ inputs.bookmarks.nixosModules.default ];
     services.bookmarks = {
       enable = true;
       domain = "bm.example.com";          # must resolve to this host's public IP
       backup = {
         enable = true;
         offboxDest = "s3:/...";           # optional offsite
       };
     };
   }
   ```

2. **Provision the agenix secret.** `secrets/bookmarks-env.age` is *not*
   committed (no secrets in the repo; the flake evaluates without it — the
   service then falls back to the app's loud dev default until you do this):

   ```bash
   # on the target host (as root):
   mkdir -p /srv/bookmarks/nixos/secrets
   # find the host age key
   ls /etc/ssh/ssh_host_ed25519_key.pub   # nixos-rebuild uses this by default
   # encrypt SECRET_KEY + any API keys into the env file:
   nix run github:ryantm/agenix -- -i /etc/ssh/ssh_host_ed25519_key -e \
     /srv/bookmarks/nixos/secrets/bookmarks-env.age
   # content: KEY=VALUE lines, e.g.
   #   SECRET_KEY=<long random string>
   #   OPENAI_API_KEY=...
   #   ANTHROPIC_API_KEY=...
   ```

   Generate the key with
   `python3 -c "import secrets; print(secrets.token_urlsafe(64))"`.

3. **`nixos-rebuild switch`** (on the host, from your system flake). This
   builds the venv, installs the hardened unit, the Caddy vhost, the agenix
   secret and the backup timer. Caddy obtains the ACME certificate for the
   domain on first request.

4. **Verify.** `curl https://bm.example.com/health` → `200 {"status":"ok"}`;
   register your first passkey at `/setup`; import bookmarks. The DB lives at
   `/var/lib/private/bookmarks/bookmarks.db` (survives restarts; owned by the
   dynamic user).

### How the backup reaches the Nix store

`scripts/backup.sh` is a repo source file, not a Nix package — the systemd
timer can't execute it from the mutable checkout. The flake copies it into the
store as a `pkgs.writeShellScript` derivation via
`lib.strings.fileContents`, and the timer's `ExecStart` points at that store
path. If `scripts/backup.sh` doesn't exist yet, a built-in equivalent (online
`sqlite3 .backup` + `integrity_check` + prune) is used instead, so the timer
path always resolves. The backup unit is a hardened, **network-isolated root
oneshot** (minimal `CapabilityBoundingSet` of read/traverse/unlink caps, no
`AF_INET`): the app's state dir sits behind the root-owned 0700
`/var/lib/private` boundary, which systemd only relaxes inside the owning
DynamicUser's mount namespace, so no second unit can read the DB as the app's
user — root with a minimal capability set is the only way in. It runs
`sqlite3 .backup` (safe against the live writer), verifies the copy, prunes
older than `BACKUP_KEEP_DAYS` (default 14), and copies offsite when
`backup.offboxDest` is set.

### Secrets in the unit

`age.secrets.bookmarks-env` decrypts to a 0400 root file at activation;
`LoadCredential=bookmarks-env:<path>` makes systemd read it as root
(DynamicUser-proof) and re-exports it at `$CREDENTIALS_DIRECTORY/bookmarks-env`,
which the unit's `ExecStart` wrapper sources into the environment. Non-secret
settings (`BOOKMARKS_DB`, `PUBLIC_ORIGIN`, `WEBAUTHN_RP_ID`, `extraEnv`) are
plain `Environment=` lines.

## Backup & recovery

### Daily backups

Two mechanisms, both online (safe against the live writer, no downtime):

1. **`bookmarks-backup` CLI** (`just backup`) — the SQLite **online backup
   API** (`sqlite3 .backup`), integrity-checked on the copy, pruned older than
   `BACKUP_KEEP_DAYS` (default 14), with an optional offsite copy to
   `BACKUP_OFFBOX_DEST` (a local dir, an rclone remote like `bucket:bookmarks`,
   or an S3-style mount). A corrupt copy fails loudly and is removed rather
   than kept in rotation:

   ```bash
   just backup
   # or with flags:
   uv run bookmarks-backup --keep-days 30 --offbox s3:/bookmarks
   ```

2. **`scripts/backup.sh`** — the same operation as a shell entry point for a
   cron/systemd timer (and what the NixOS timer runs). Subcommands:
   `scripts/backup.sh` (backup + integrity check + prune + offsite) and
   `scripts/backup.sh verify [FILE]` (restore the file into a temp path and
   compare row counts against the live DB; exits non-zero on mismatch).

> Railway's daily volume snapshots are ZFS snapshots: **same-project-only and
> wiped with the volume** — they are not a disaster-recovery story on their
> own. Treat the offsite logical dump (`BACKUP_OFFBOX_DEST`) as the actual DR
> path on Railway.

### Restore

The backup is an online, integrity-checked `.backup` copy. Restore it with

```bash
scripts/backup.sh verify <backup-file>          # verify first
sqlite3 <backup-file> ".backup /tmp/restored.db"
# then point BOOKMARKS_DB at /tmp/restored.db (or copy it into place)
```

### Recovery codes

Registration at `/setup` issues a set of **recovery codes** (one-time, single
use each). They are the self-hosted escape hatch: if you lose your passkey —
or every passkey — a recovery code opens a scoped recovery session
(`POST /api/recovery/redeem`) that lets you revoke the old credentials and
re-register. **Store them somewhere safe** (password manager / offline copy);
they are the only way in without a passkey. New codes can be regenerated in
the credentials UI.

### Reset CLI

If passkeys **and** recovery codes are both lost, `bookmarks-reset-auth`
deletes every credential, session and recovery code and clears the
`setup_claimed` marker — returning the app to the first-run `/setup` state:

```bash
uv run bookmarks-reset-auth            # prompts for confirmation
uv run bookmarks-reset-auth --yes      # non-interactive (scripts)
```

Note that this invalidates all recovery codes too — you must re-register and
save the new codes.

## Extending

Common things you'll likely want next, in roughly increasing complexity:

1. **Full-page archive** — Playwright snapshot on save for visual recall
   (the `bookmarks-snapshot` CLI and `/api/bookmarks/{id}/snapshot` already
   record single-file HTML via the `monolith` binary).
2. **Multi-device sync** — drop the local DB, host Postgres + the same schema.

The schema is deliberately small and additive — any of these are bolt-ons, not
rewrites.

## License

MIT.
