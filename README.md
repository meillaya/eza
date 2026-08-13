# Bookmarks

A tag-based, search-first bookmark manager for 10k+ links. Single-process Python.
SQLite + FTS5 on the backend, vanilla JS with native CSS virtualization on the frontend.

## Why

Browser bookmark managers collapse past a few thousand items. This is the minimal
honest version of "what if the search bar was the front door and tags replaced
folders":

- One flat list, multiple tags per item
- Fuzzy FTS5 search over title, description, URL
- Tag chips act as additive filters (AND semantics)
- Card grid uses `content-visibility: auto` so the browser virtualizes 10k+ cards
  with zero JS windowing code
- Metadata (title, favicon, description) is fetched **after** insertion, never
  blocking the response

## Tooling

Managed with [`uv`](https://github.com/astral-sh/uv). Linted with
[`ruff`](https://github.com/astral-sh/ruff). Type-checked with
[`ty`](https://github.com/astral-sh/ty). Tested with `pytest`.

```bash
# install everything (runtime + dev)
uv sync

# run the app
uv run uvicorn app.main:app --host 127.0.0.1 --port 8000
# or via the installed entry point
uv run bookmarks-server

# lint, format, typecheck, test
uv run ruff check .
uv run ruff format .
uv run ty check
uv run pytest
```

## Usage

- **`/`** — main grid. 60 cards per page, infinite scroll below the fold.
- **Type to search** — debounced 180 ms. Searches title, description, URL.
- **Click tag chips** — multi-select; selected tags are ANDed.
- **`/`** keyboard shortcut focuses the search bar.
- **`+ Add`** — opens a modal. URL is required, tags are comma-separated.
- **Import** — upload a browser `bookmarks.html` export (Chrome, Firefox, Safari,
  Edge all produce the Netscape format). Folder names become tags.
- **Hover a card** — `×` button removes it.

## Architecture

```
app/
  main.py        FastAPI routes
  db.py          SQLite + FTS5 schema, queries, bulk insert, dead-link helpers
  fetcher.py     async title/favicon fetcher (background)
  check_dead.py  CLI: HEAD-check all bookmarks, flag dead links
  auto_tag.py    CLI: LLM-powered semantic re-tagging of generic buckets
templates/
  index.html     single-page shell
static/
  app.js         vanilla JS controller
  style.css      light/dark, content-visibility: auto
  favicon-fallback.svg
tests/
  conftest.py        pytest fixtures (temp DB per test)
  test_db.py         DB layer coverage
  test_importer.py   Netscape importer regression tests
  test_check_dead.py dead-link checker helpers
  test_auto_tag.py   auto-tagger sampling, parsing, mocked LLM client
```

### Speed notes

- **SQLite WAL + FTS5** — full-text search over 10k rows is ~0.1–1 ms
- **External-content FTS5** — the FTS index references `bookmarks` rows by id;
  no duplicated data, smaller writes
- **Porter stemming** — `"running"` matches `"run"`, `"databases"` matches `"database"`
- **`synchronous=NORMAL`** — safe with WAL, ~10× faster writes than FULL
- **Prepared statements** — every list/count query is parameterized; no string SQL
- **Bulk inserts** — `bulk_insert_bookmarks()` wraps the entire import in a
  single transaction; ~10× faster than per-row commits
- **content-visibility: auto** — offscreen cards are not rendered by the browser,
  scrollbar height stays accurate via `contain-intrinsic-size`
- **Debounced search** — 180 ms; cheap to retype
- **Background enrichment** — title/favicon/description fetched after insert,
  never on the read path
- **HTTP/1.1 keepalive** — single uvicorn process, no per-request handshake
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
automatically by SQLite on close or can be forced with `PRAGMA wal_checkpoint(TRUNCATE)`.

## Importing from your browser

In Chrome/Firefox/Edge: bookmark manager → export to HTML.
In Safari: File → Export → Bookmarks.

Drop the resulting `bookmarks.html` onto the **Import** button. Folder paths
become slash-joined tags (e.g. `Bookmarks Bar / Dev / Rust` → `dev, rust`).

Two folder categories are recursed into but **not** added as tags:

1. **Top-level browser folders** — "Bookmarks bar", "Other bookmarks",
   "Mobile Bookmarks". Too generic to be useful.
2. **Timestamp-named folders** — anything matching patterns like
   `new folder – 18 apr 2025 14:06:10 GMT-04:00`, `2024-01-07 13:59:25`,
   `nov 7, 2024 3:56:44 am est`. These come from session-manager/tab-save
   exports and flood the tag list with non-meaningful labels.

Duplicate URLs are deduplicated by the `UNIQUE` constraint on `bookmarks.url`.

## Checking for dead links

```bash
# Full sweep — checks every bookmark that hasn't been checked yet
uv run bookmarks-check-dead

# Cap the batch
uv run bookmarks-check-dead --limit 500

# Only re-check bookmarks not checked within the last day
uv run bookmarks-check-dead --older-than 86400

# Re-check rows already flagged dead
uv run bookmarks-check-dead --include-dead

# Tune concurrency and timeout
uv run bookmarks-check-dead --concurrency 64 --timeout 5
```

Concurrency is bounded by an asyncio semaphore. A link is flagged dead when
the HEAD returns 4xx/5xx, when the host is unreachable, or when the request
times out. Some servers reject HEAD; we fall back to a ranged GET in that case.
The sweep updates `is_dead` and `last_checked_at` for every row.

On the real 9k-bookmark dataset, this runs at roughly 100 checks/s with
`--concurrency 32`.

## Auto-tagging generic buckets

Browser imports usually produce a few "fat" tags that hold thousands of
bookmarks each — `imported`, `tabs`, `archive`, `imported sessions` — and
they're useless for browsing. `bookmarks-retag` asks an LLM to suggest
specific topic tags for each fat bucket and applies them.

```bash
# Re-tag any tag applied to ≥ 500 bookmarks (default), using Anthropic
uv run bookmarks-retag --dry-run                       # preview first
uv run bookmarks-retag                                  # apply
uv run bookmarks-retag --remove-generic                 # drop the old generic tag

# Re-tag specific tags regardless of size
uv run bookmarks-retag --target imported --target tabs

# Re-tag everything with ≥ 100 bookmarks, OpenAI
uv run bookmarks-retag --provider openai --all-above 100

# Local Ollama / OpenAI-compatible endpoint
uv run bookmarks-retag \
    --provider openai-compatible \
    --base-url http://localhost:11434 \
    --model llama3.1

# Tune the sample the LLM sees
uv run bookmarks-retag --sample-size 50
```

How it works:

1. Pick the largest tags (or the ones you name with `--target`).
2. For each, draw a stratified sample of `--sample-size` bookmarks, spread
   across distinct domains so the LLM sees the cluster's true diversity.
3. Send a prompt that names the generic tag, lists the sample, and asks
   for 5–10 specific topic tags as a JSON array.
4. Apply those tags to every bookmark in the bucket via a single bulk
   insert. With `--remove-generic`, the original fat tag is unlinked.

API key resolution: `--provider anthropic` reads `ANTHROPIC_API_KEY`,
`--provider openai*` reads `OPENAI_API_KEY`. Override with `--api-key-env`,
or pass the key in your shell.

Approximate tagging tradeoff: the LLM sees ~30 bookmarks per cluster and
its tags are then applied to every member (e.g. 8,786). The tags describe
the cluster as a whole, so individual bookmarks can carry tags that don't
quite fit. For high precision, run with `--sample-size` larger or cluster
first and re-run per sub-cluster. In practice, filtering by the new tags
("rust-web", "academic-research") gets you a useful subset of the fat
bucket.

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
| `railway.toml` | Deployment config: Railpack builder, shell-wrapped start command, healthcheck path, restart policy | Worker-verified: parses, matches the Railway config-as-code schema (this file) |
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
   Railway volumes back SQLite fine (todo 35 verified the empty-volume case).
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

### Environment variables

| Variable | Value | Why |
|---|---|---|
| `BOOKMARKS_DB` | `/app/data/bookmarks.db` | The SQLite file **on the mounted volume** (step 2). Any other path is ephemeral. |
| `SECRET_KEY` | a long random string | Signs sessions. **Unset in prod ⇒ loud warning + insecure dev default.** Generate with `python -c "import secrets; print(secrets.token_urlsafe(64))"`. |
| `PUBLIC_ORIGIN` | `https://<your-custom-domain>` | Drives the prod predicate (Secure cookie) and session origin checks. Must match the domain users actually reach. |
| `WEBAUTHN_RP_ID` | `<your-custom-domain>` (no scheme, no path) | The WebAuthn relying-party ID. On a custom domain it **must** be set to the domain. See "Domain & passkeys". |
| `RAILWAY_RUN_UID` | `0` — **fallback only, see below** | Only if the container's non-root user can't write to the volume. **This is not the fix.** |
| `BACKUP_OFFBOX_DEST` | e.g. an S3-compatible URL (todo 37) | Offsite destination for the daily backup. See "Backups". |

#### `RAILWAY_RUN_UID=0` is a fallback, not the fix

The Docker image runs as the non-root `app` user. On Railway, a volume mounted
at `/app/data` **shadows the image's directory and its build-time ownership**,
so the image-level `chown` does **not** apply to the mount.

- **PRIMARY fix (todo 35):** `app/config.py` creates `BOOKMARKS_DB`'s parent
  directory at import time, against the **live** filesystem — i.e. the mounted
  volume. This is what makes the empty volume work; it's verified.
- **`RAILWAY_RUN_UID=0`:** a *fallback* that makes Railway run the container
  as root so it can write anywhere. Only reach for it if you hit
  permission errors on the volume despite the config-init fix. The tradeoff is
  losing the non-root hardening in the image. Do not set it preemptively.

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
  codes or `bookmarks-reset-auth` to re-enroll (see "Backup & recovery" in
  todo 37's runbook).

### Backups

Railway's daily volume snapshots are ZFS snapshots: **same-project-only and
wiped with the volume** — they are not a disaster-recovery story on their own.
The daily backup pipeline (todo 37) does:

1. An online SQLite `.backup` to `BACKUP_DIR` (default `/app/data/backups`)
   with integrity check and 14-day pruning.
2. An **offsite logical dump** copied to `BACKUP_OFFBOX_DEST` — Railway object
   storage or any S3-compatible bucket (create a bucket in the project, put
   its endpoint/credentials in the backup env, and set `BACKUP_OFFBOX_DEST`).

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
tests) from todo 13. The two flakes are independent; the deployment flake lives
in `nixos/` so they never collide.

What it provides, all **build-verified** (`nix flake check ./nixos` and
`nix build ./nixos#default` pass — the venv boots and serves):

| Piece | Details |
|---|---|
| **uv2nix venv** (`packages.default`) | `mkVirtualEnv` over the repo's `uv.lock` (hello-world template, wheel preference). Entry points: `uvicorn`, `bookmarks-server`, all `bookmarks-*` CLIs. QA: `nix run .#bookmarks-server` from `nixos/` starts the server. |
| **NixOS module** (`nixosModules.default`) | `services.bookmarks` option — domain, port (default 8000), `extraEnv`, and a `backup` sub-option (schedule, retention, optional offsite destination). |
| **Hardened systemd unit** | `DynamicUser`, `StateDirectory=bookmarks` → `/var/lib/private/bookmarks` with `BOOKMARKS_DB` pointing there, empty `CapabilityBoundingSet`, `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `PrivateDevices`, `RestrictAddressFamilies=AF_INET/AF_INET6/AF_UNIX`, `UMask=0027`, `Restart=on-failure`. |
| **Caddy** | Automatic HTTPS (ACME) for your domain, `reverse_proxy 127.0.0.1:8000`. |
| **agenix** | `SECRET_KEY` + optional API keys (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, …) injected as a systemd credential via `LoadCredential`. |
| **Backup timer** | `systemd` timer (default 03:17 daily) running `scripts/backup.sh` from a **Nix-store derivation** — see below. |

> **⚠️ `MemoryDenyWriteExecute` must stay OFF.** The hardened unit deliberately
> does **not** set `MemoryDenyWriteExecute`. That systemd policy breaks the
> V8/Node JIT and `require()` in Node — if an e2e runner (the todo-13
> Playwright harness) is ever added to this unit, MDWE would crash Chromium
> and the test runner at startup. Keep it unset. (`grep -c
> MemoryDenyWriteExecute nixos/flake.nix` must be 0.)

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
         offboxDest = "s3:/...";           # optional offsite (todo 37)
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

`scripts/backup.sh` (todo 37) is a repo source file, not a Nix package — the
systemd timer can't execute it from the mutable checkout. The flake copies it
into the store as a `pkgs.writeShellScript` derivation via
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

### Restore & recovery

The daily backup is an online, integrity-checked `.backup` copy — restore it
with `scripts/backup.sh verify <file>` or `sqlite3 <backup> ".backup
/tmp/restored.db"` then point `BOOKMARKS_DB` at the restored file (see "Backup
& recovery" in the todo-37 runbook for passkey recovery codes and
`bookmarks-reset-auth`).

## Extending

Common things you'll likely want next, in roughly increasing complexity:

1. **Full-page archive** — Playwright snapshot on save for visual recall.
2. **AI auto-tagging** — call an LLM with title+description to suggest tags on insert.
3. **Read-later queue** — a `is_read` flag and a separate queue view.
4. **Multi-device sync** — drop the local DB, host Postgres + the same schema.

The schema is deliberately small and additive — any of these are bolt-ons, not rewrites.

## License

MIT.